#!/usr/bin/env bash
# PreToolUse hook for MCP tools. Enforces a default-deny allowlist per MCP server:
# a tool call is permitted only when its tool name is listed under its server's entry
# in managed-settings.json `_mcpAllowedTools`. Every other MCP tool is denied, including
# every tool of a server that has no allowlist entry at all. Outputs Claude Code
# hookSpecificOutput JSON.
#
# Matcher: mcp__.* (every MCP tool from every server). MCP tool names take the form
# mcp__<server>__<tool>; the delimiter between segments is the double underscore.
#
# Fail-closed by construction: a missing/unreadable managed-settings.json, malformed
# policy JSON, an unparseable tool name, or a server with no allowlist entry all result
# in a deny. The only path to allow is an explicit allowlist hit.
#
# Audit: every invocation (allow or deny) is appended as a single JSON Lines record to
# ~/.claude/debug/mcp-policy.jsonl via the shared audit-log helper.
set -u

# Resolve relative to this script so it works whether run from /opt/claude/hooks/ or a
# test directory, matching bash-policy-check.sh / webfetch-policy-check.sh.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/audit-log.sh
source "$HOOK_DIR/lib/audit-log.sh"
audit_init "mcp-policy"

payload="$(cat)"
tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"

# Not an MCP tool. The matcher should prevent this hook from firing on anything else,
# but guard defensively: a non-MCP tool is outside this hook's remit, so do not touch it.
if [[ "$tool_name" != mcp__* ]]; then
  exit 0
fi

# Emit a deny decision via JSON to stdout AND record the audit line.
emit_deny() {
  local reason_short="$1"   # short label for the audit log (e.g. "not_in_allowlist")
  local reason_user="$2"    # user-facing reason returned to Claude
  audit_emit "$payload" deny tool_name "$tool_name" reason "$reason_short"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason_user"
  exit 0
}

# Parse mcp__<server>__<tool>. Strip the mcp__ prefix, take the server as everything up
# to the first remaining __, and the tool as the rest. Tool names may contain single
# underscores (e.g. create_entities), so split on the FIRST __, not the last.
rest="${tool_name#mcp__}"          # <server>__<tool>
server="${rest%%__*}"              # <server>
tool="${rest#*__}"                 # <tool>

# Malformed: no __ separating server and tool (then tool would equal rest), or an empty
# segment. Deny rather than guess.
if [[ "$rest" != *__* || -z "$server" || -z "$tool" ]]; then
  emit_deny "malformed_tool_name" "MCP tool name not in mcp__<server>__<tool> form"
fi

# Single source of truth: the allowlist lives in managed-settings.json alongside the rest
# of the policy, read here at runtime so a policy edit needs no change to this script.
managed_settings="/Library/Application Support/ClaudeCode/managed-settings.json"

if [[ ! -r "$managed_settings" ]]; then
  emit_deny "allowlist_unavailable" "MCP allowlist unavailable — managed-settings.json missing or unreadable"
fi

# Allow only when $tool appears under _mcpAllowedTools[$server]. A server with no entry
# yields [] from the // fallback and never matches, so it is fully denied (default-deny).
# A jq failure (malformed JSON, etc.) exits non-zero and falls through to the deny below,
# so malformed policy also fails closed.
if jq -e --arg s "$server" --arg t "$tool" \
     '((._mcpAllowedTools[$s]) // []) | index($t) != null' \
     "$managed_settings" >/dev/null 2>&1; then
  audit_emit "$payload" allow tool_name "$tool_name" server "$server" tool "$tool"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  exit 0
fi

emit_deny "not_in_allowlist" "MCP tool not in the policy allowlist for this server"
