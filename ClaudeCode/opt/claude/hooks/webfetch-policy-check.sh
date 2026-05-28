#!/usr/bin/env bash
# PreToolUse hook for WebFetch. Enforces a domain allowlist: blocks all fetches
# except those to explicitly permitted domains. Outputs Claude Code hookSpecificOutput JSON.
set -u

logtofile() {
  echo "[$(date)] [webfetch-policy] [$(pwd)] $1" >> "$HOME/.claude/debug/webfetch-policy.log"
}

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

logtofile "hostname extracted: $hostname"

# Unified allowlist. Each entry is either:
#   "example.com"        — allows requests to exactly example.com, any path
#   "example.com/path"   — allows requests to exactly example.com under /path/* only
#
# No wildcard subdomain matching — subdomains must be listed explicitly.
#
# *** SYNC REQUIRED ***
# This list and network.allowedDomains in managed-settings.json enforce the same
# boundary at different layers (hook vs OS sandbox) and must be kept identical.
# When adding or removing a domain here, make the same change in managed-settings.json.
# Use only the bare hostname there — path-scoped entries are only supported in this file.
allowed_entries=(
  "github.com"
  "api.github.com"
  "objects.githubusercontent.com"
  "raw.githubusercontent.com"
  "registry.npmjs.org"
  "pypi.org"
  "files.pythonhosted.org"
  "proxy.golang.org"
  "crates.io"
  "index.crates.io"
  "opentofu.org/docs"
  "developer.hashicorp.com/terraform"
  "registry-1.docker.io"
  "auth.docker.io"
  "production.cloudflare.docker.com"
  "hub.docker.com"
  "public.ecr.aws"
  "api.ecr-public.aws"
  "mentalhealthinnovations.org"
  "themix.org.uk"
  "giveusashout.org"
  "code.claude.com/docs"
  "www.twilio.com"
  "learn.jamf.com"
  "community.jamf.com"
  "docs.aws.amazon.com"
)

path="$(printf '%s' "$url" | sed -E 's|^[^:]+://[^/]*(/.*)$|\1|')"
path="${path:-/}"

for entry in "${allowed_entries[@]}"; do
  entry_host="${entry%%/*}"
  if [[ "$entry" == */* ]]; then
    entry_path="/${entry#*/}"
  else
    entry_path=""
  fi

  if [[ "$hostname" == "$entry_host" ]]; then
    if [[ -z "$entry_path" || "$path" == "$entry_path" || "$path" == "$entry_path/"* ]]; then
      echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
      exit 0
    fi
    logtofile "DENY host '$entry_host' matched but path '$path' not under '$entry_path': $url"
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Domain not in WebFetch allowlist"}}'
    exit 0
  fi
done

logtofile "DENY domain not in allowlist: $hostname"
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Domain not in WebFetch allowlist"}}'
exit 0
