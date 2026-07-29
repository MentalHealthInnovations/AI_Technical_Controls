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
# segment to its server's list. Jira write tools (createJiraIssue, editJiraIssue,
# transitionJiraIssue, addCommentToJiraIssue, addWorklogToJiraIssue, createIssueLink) are
# allowed here but bound to ATLASSIAN_PROJECTS by project_scope_ok below, so a write
# outside the allowlisted projects is still denied. Other state-changing tools stay
# omitted, which denies them before the call reaches the server.
is_allowed() {
  local server="$1" tool="$2" allowed="" t
  case "$server" in
    atlassian)
      allowed="getAccessibleAtlassianResources atlassianUserInfo getJiraIssue \
               getJiraIssueRemoteIssueLinks getJiraIssueTypeMetaWithFields \
               getJiraProjectIssueTypesMetadata getIssueLinkTypes \
               getTransitionsForJiraIssue getVisibleJiraProjects \
               lookupJiraAccountId searchJiraIssuesUsingJql \
               createJiraIssue editJiraIssue transitionJiraIssue \
               addCommentToJiraIssue addWorklogToJiraIssue createIssueLink"
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

# --- Atlassian project (space) allowlist -------------------------------------
# Tools that name a Jira project or issue — reads and writes alike — are scoped
# to these project keys; every other project is denied. Keys are compared
# case-insensitively. EDIT THIS LIST to change which projects Claude Code may
# read or write. An empty list denies all project-scoped calls. Cross-project
# tools that take no project key (getVisibleJiraProjects, lookupJiraAccountId,
# getIssueLinkTypes, and the two shared tools getAccessibleAtlassianResources /
# atlassianUserInfo) are not bound by this list — a project allowlist cannot
# express "list only these projects".
ATLASSIAN_PROJECTS="PLAN DENGS DATA MJB DE DSD ED DAR"

# project_allowed <key> — true iff <key> (any case) is an alphanumeric Jira key
# present in ATLASSIAN_PROJECTS. Numeric ids fail the key shape and are denied,
# since the hook cannot resolve an id to a key without calling Atlassian.
project_allowed() {
  local want p
  want="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  [[ "$want" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
  for p in $ATLASSIAN_PROJECTS; do
    [[ "$(printf '%s' "$p" | tr '[:lower:]' '[:upper:]')" == "$want" ]] && return 0
  done
  return 1
}

# issue_key_project <issueIdOrKey> — echo the project key of a PROJ-123 issue
# key, or nothing if the argument is not in KEY-NUMBER form (e.g. a bare numeric
# issue id, which cannot be mapped to a project here).
issue_key_project() {
  [[ "$1" =~ ^([A-Za-z][A-Za-z0-9_]*)-[0-9]+$ ]] && printf '%s' "${BASH_REMATCH[1]}"
}

# jql_scope_ok <jql> — true iff the JQL is bounded to allowlisted projects.
# Accepts an AND-only query (no OR, no NOT — so every clause is conjunctive and a
# positive project restriction bounds the whole result set) that carries a
# `project = KEY` or `project in (KEY, ...)` clause naming only allowlisted keys.
# Everything else (OR/NOT, project negation, numeric project ids, no project
# clause, anything unparseable) is denied. This is deliberately conservative:
# it rejects some safe-but-complex queries rather than risk allowing one that
# escapes the allowlist.
jql_scope_ok() {
  local jql="$1" inside k found=0
  [[ -n "$jql" ]] || return 1
  # OR/NOT can broaden or invert the project restriction; reject both. -w so that
  # "ORDER", "reporter", "cannot" etc. do not match as substrings.
  printf '%s' "$jql" | grep -iqwE 'or|not' && return 1
  # Explicit project negation (project != / project < / project >).
  printf '%s' "$jql" | grep -iqE 'project[[:space:]]*(!=|<|>)' && return 1

  # project = KEY
  while IFS= read -r k; do
    k="${k#\"}"; k="${k%\"}"
    project_allowed "$k" || return 1
    found=1
  done < <(printf '%s' "$jql" \
             | grep -oiE 'project[[:space:]]*=[[:space:]]*"?[A-Za-z0-9_]+"?' \
             | sed -E 's/.*=[[:space:]]*//')

  # project in (KEY, KEY, ...)
  while IFS= read -r inside; do
    inside="${inside#*\(}"; inside="${inside%\)}"
    inside="${inside//,/ }"
    for k in $inside; do
      k="${k#\"}"; k="${k%\"}"
      project_allowed "$k" || return 1
      found=1
    done
  done < <(printf '%s' "$jql" | grep -oiE 'project[[:space:]]+in[[:space:]]*\([^)]*\)')

  [[ "$found" -eq 1 ]]
}

# project_scope_ok <server> <tool> <payload> — true unless the call names a
# Jira project/issue outside ATLASSIAN_PROJECTS. Only the atlassian server is
# project-scoped; tools that take no project key are unaffected.
project_scope_ok() {
  local server="$1" tool="$2" pl="$3" v proj in_v out_v in_proj out_proj
  [[ "$server" == atlassian ]] || return 0
  case "$tool" in
    getJiraIssue | getJiraIssueRemoteIssueLinks | getTransitionsForJiraIssue | \
    editJiraIssue | transitionJiraIssue | addCommentToJiraIssue | addWorklogToJiraIssue)
      v="$(printf '%s' "$pl" | jq -r '.tool_input.issueIdOrKey // empty')"
      proj="$(issue_key_project "$v")"
      [[ -n "$proj" ]] && project_allowed "$proj"
      ;;
    getJiraIssueTypeMetaWithFields|getJiraProjectIssueTypesMetadata)
      v="$(printf '%s' "$pl" | jq -r '.tool_input.projectIdOrKey // empty')"
      project_allowed "$v"
      ;;
    createJiraIssue)
      v="$(printf '%s' "$pl" | jq -r '.tool_input.projectKey // empty')"
      project_allowed "$v"
      ;;
    createIssueLink)
      # Both ends must resolve to an allowlisted project — one out-of-scope
      # issue is enough to deny, so a link write cannot touch an issue outside
      # ATLASSIAN_PROJECTS via its other end.
      in_v="$(printf '%s' "$pl" | jq -r '.tool_input.inwardIssue // empty')"
      out_v="$(printf '%s' "$pl" | jq -r '.tool_input.outwardIssue // empty')"
      in_proj="$(issue_key_project "$in_v")"
      out_proj="$(issue_key_project "$out_v")"
      [[ -n "$in_proj" && -n "$out_proj" ]] && project_allowed "$in_proj" && project_allowed "$out_proj"
      ;;
    searchJiraIssuesUsingJql)
      v="$(printf '%s' "$pl" | jq -r '.tool_input.jql // empty')"
      jql_scope_ok "$v"
      ;;
    *)
      return 0
      ;;
  esac
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
  # Tool is permitted; now scope project-bearing reads to ATLASSIAN_PROJECTS.
  if ! project_scope_ok "$server" "$tool" "$payload"; then
    emit_deny "project_not_in_allowlist" "Jira project not in the policy allowlist for this server"
  fi
  audit_emit "$payload" allow tool_name "$tool_name" server "$server" tool "$tool"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  exit 0
fi

emit_deny "not_in_allowlist" "MCP tool not in the policy allowlist for this server"
