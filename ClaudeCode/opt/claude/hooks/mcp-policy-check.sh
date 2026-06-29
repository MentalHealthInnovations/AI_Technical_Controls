#!/usr/bin/env bash
# PreToolUse hook for MCP tools (matcher mcp__.*). Default-deny per server: a call is
# allowed only when its tool is listed for its server in `is_allowed` below. Everything
# else denies — unlisted tools, unknown servers, unparseable names. The allowlist lives
# here (this hook is its only consumer), not in managed-settings.json, which only governs
# which servers may connect (allowedMcpServers). Audits each decision to
# ~/.claude/debug/mcp-policy.jsonl.
set -u

# Resolve relative to this script so it works from /opt/claude/hooks/ or a test dir.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/audit-log.sh
source "$HOOK_DIR/lib/audit-log.sh"
audit_init "mcp-policy"

# Allowlist of permitted tools, keyed by server. To grant a tool, add its bare <tool>
# segment to its server's list. Keep read-only tools only: omitted state-changing tools
# (createJiraIssue, editJiraIssue, transitionJiraIssue, etc.) are thus denied before the
# call reaches the server.
is_allowed() {
  local server="$1" tool="$2" allowed="" t
  case "$server" in
    atlassian)
      allowed="getAccessibleAtlassianResources atlassianUserInfo getJiraIssue \
               getJiraIssueRemoteIssueLinks getJiraIssueTypeMetaWithFields \
               getJiraProjectIssueTypesMetadata getIssueLinkTypes \
               getTransitionsForJiraIssue getVisibleJiraProjects \
               lookupJiraAccountId searchJiraIssuesUsingJql"
      ;;
    *)
      return 1
      ;;
  esac
  # Unquoted $allowed word-splits on whitespace; match the tool name exactly.
  for t in $allowed; do
    [[ "$t" == "$tool" ]] && return 0
  done
  return 1
}

payload="$(cat)"
tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"

# Defensive: the matcher should keep this hook MCP-only, but ignore anything else.
if [[ "$tool_name" != mcp__* ]]; then
  exit 0
fi

# Emit a deny decision to stdout and record the audit line.
emit_deny() {
  local reason_short="$1"   # audit-log label (e.g. "not_in_allowlist")
  local reason_user="$2"    # reason returned to Claude
  audit_emit "$payload" deny tool_name "$tool_name" reason "$reason_short"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason_user"
  exit 0
}

# Parse mcp__<server>__<tool>. Split on the FIRST __ — tool names may contain single
# underscores (e.g. create_entities).
rest="${tool_name#mcp__}"          # <server>__<tool>
server="${rest%%__*}"              # <server>
tool="${rest#*__}"                 # <tool>

# Malformed: no __ separator, or an empty segment. Deny rather than guess.
if [[ "$rest" != *__* || -z "$server" || -z "$tool" ]]; then
  emit_deny "malformed_tool_name" "MCP tool name not in mcp__<server>__<tool> form"
fi

if is_allowed "$server" "$tool"; then
  audit_emit "$payload" allow tool_name "$tool_name" server "$server" tool "$tool"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  exit 0
fi

emit_deny "not_in_allowlist" "MCP tool not in the policy allowlist for this server"
