#!/usr/bin/env bash
# PreToolUse hook for WebFetch. Enforces a domain allowlist: blocks all fetches
# except those to explicitly permitted domains. Outputs Claude Code hookSpecificOutput JSON.
#
# Audit: every invocation (allow or deny) is appended as a single JSON Lines
# record to ~/.claude/debug/webfetch-policy.jsonl via the shared audit-log helper.
set -u

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/audit-log.sh
source "$HOOK_DIR/lib/audit-log.sh"
audit_init "webfetch-policy"

payload="$(cat)"
url="$(printf '%s' "$payload" | jq -r '.tool_input.url // empty')"

if [[ -z "$url" ]]; then
  exit 0
fi

# Extract hostname from URL (strip scheme, userinfo, path, port, query).
# The regex uses two capture groups: group 1 optionally matches and discards a
# "userinfo@" prefix (e.g. "user:pass@"), group 2 captures the actual host.
# This prevents a bypass where an allowlisted domain is placed in the userinfo
# position (https://allowed.com@attacker.com/path) — RFC 3986 §3.2.1 defines
# userinfo as the component before @, so "allowed.com" would be the username and
# "attacker.com" the real host. The old two-expression sed ran the @-strip on the
# already-shortened string (which had no @ left), so the strip was a no-op.
hostname="$(printf '%s' "$url" | sed -E 's|^[^:]+://([^/:?#@]*@)?([^/:?#]*).*|\2|')"

# Allowlist is the bare-hostname list from managed-settings.json, read at runtime
# so the OS sandbox layer (network.allowedDomains) and this hook stay in lockstep
# without a manual sync step. No wildcard subdomain matching — subdomains must
# be listed explicitly.
#
# Path scoping (sandbox.network._webfetchPathScopes) is an OPTIONAL second layer
# read only by this hook: a host listed there is restricted, for WebFetch only,
# to URLs whose path is under the given prefix. The OS sandbox cannot express a
# path (its allowedDomains entries are bare hosts; a "/" makes an entry invalid)
# so the sandbox always allows the whole host. This key therefore constrains the
# WebFetch tool only — it does NOT restrict Bash network egress, which can still
# reach any path on an allowlisted host. Hosts not listed here get any path.
#
# Depends on `jq` (also required by bash-policy-check.sh and output-redact.sh).
managed_settings="/Library/Application Support/ClaudeCode/managed-settings.json"

if [[ ! -r "$managed_settings" ]]; then
  audit_emit "$payload" deny \
    url      "$url" \
    hostname "$hostname" \
    reason   "allowlist_unavailable"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"WebFetch allowlist unavailable — managed-settings.json missing or unreadable"}}'
  exit 0
fi

# jq emits one host per line; grep -Fx matches the extracted hostname against
# any line exactly. Fails closed: if jq errors or no domains are configured,
# nothing matches and the deny below fires.
if printf '%s\n' "$hostname" | grep -Fxq -f <(jq -r '.sandbox.network.allowedDomains[]? // empty' "$managed_settings" 2>/dev/null); then
  # Host is allowed. If it carries a path scope, the URL path must be under it.
  # An empty scope (host absent from _webfetchPathScopes, or the key missing)
  # leaves the host unrestricted. jq failures yield an empty scope too — that
  # fails open on the path check only, never on the host check above.
  scope="$(jq -r --arg h "$hostname" '.sandbox.network._webfetchPathScopes[$h]? // empty' "$managed_settings" 2>/dev/null)"
  if [[ -n "$scope" ]]; then
    # Extract the path (strip scheme+host, then query/fragment); default to "/".
    req_path="$(printf '%s' "$url" | sed -E 's|^[^:]+://[^/?#]*([/][^?#]*)?.*|\1|')"
    req_path="${req_path:-/}"
    case "$req_path" in
      "$scope"|"$scope"/*) ;;
      *)
        audit_emit "$payload" deny \
          url      "$url" \
          hostname "$hostname" \
          reason   "path_not_allowed" \
          scope    "$scope" \
          attempted_path "$req_path"
        echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"WebFetch path not under the allowed prefix for this host"}}'
        exit 0
        ;;
    esac
  fi
  audit_emit "$payload" allow \
    url      "$url" \
    hostname "$hostname"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  exit 0
fi

audit_emit "$payload" deny \
  url      "$url" \
  hostname "$hostname" \
  reason   "domain_not_allowed"
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Domain not in WebFetch allowlist"}}'
exit 0
