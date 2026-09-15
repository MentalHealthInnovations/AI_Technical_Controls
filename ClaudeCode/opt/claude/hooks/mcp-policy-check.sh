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
# outside the allowlisted projects is still denied. The github write tools are bound the
# same way to GITHUB_REPOS by repo_scope_ok. Other state-changing tools stay omitted,
# which denies them before the call reaches the server.
#
# A name that does not match the server's actual tool is inert rather than dangerous,
# because the call denies either way. So a tool that should work but reports
# not_in_allowlist means the name here is wrong, and `/mcp` on a connected session
# lists the real ones.
# Tools that write to a repository, listed once because two places need them: is_allowed
# grants them and repo_scope_ok binds them to GITHUB_REPOS. Keeping one list means a tool
# cannot be granted here and left unscoped there.
GITHUB_WRITE_TOOLS="add_issue_comment issue_write \
                    create_pull_request update_pull_request \
                    pull_request_review_write add_comment_to_pending_review \
                    add_reply_to_pull_request_comment"

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
    github)
      # Reads, plus the issue and pull request writes listed last. Those writes are bound
      # to GITHUB_REPOS by repo_scope_ok below, the same way the Jira writes are bound to
      # ATLASSIAN_PROJECTS, so a write outside the allowlisted repositories is denied
      # even though the tool itself is allowed.
      #
      # Omitted deliberately, beyond the write tools listed:
      #   get_secret_scanning_alert and list_secret_scanning_alerts, because they locate
      #     live secrets and can quote them, which CLAUDE.md forbids reading.
      #   get_teams, get_team_members and list_repository_collaborators, because they
      #     return personal data, covered by the same rule as the PII file hooks.
      #   merge_pull_request and update_pull_request_branch, because landing or moving a
      #     branch is a human decision, and branch protection should not be the only
      #     thing standing in the way.
      #   create_or_update_file, push_files, delete_file and create_branch, because
      #     content writes belong in git under the bash policy, not here.
      #   create_repository, delete_repository, fork_repository, actions_run_trigger,
      #     label_write and the governance writes, because none of them are review work.
      #   list_issue_types and list_issue_fields, because MHI does not use issue types,
      #     and the first needs an organisation-level permission nobody grants.
      #   The notification reads, discussions, gists, projects and search_orgs, because
      #     nothing needs them yet. Add on request.
      allowed="get_me get_file_contents get_repository_tree \
               get_commit list_commits search_commits \
               list_branches list_tags get_tag \
               list_releases get_latest_release get_release_by_tag \
               search_code search_repositories \
               issue_read list_issues search_issues get_label \
               pull_request_read list_pull_requests search_pull_requests \
               actions_get actions_list get_job_logs \
               get_code_scanning_alert list_code_scanning_alerts \
               get_dependabot_alert list_dependabot_alerts \
               $GITHUB_WRITE_TOOLS"
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

# --- GitHub repository allowlist ---------------------------------------------
# Every github write tool is bound to these repositories. EDIT THIS LIST to change
# where Claude Code may write. An empty list denies every github write. Entries are
# owner/repo, compared case-insensitively, with no wildcards, because an org-wide entry
# would make the allowlist a formality.
#
# Reads are not bound by this list. The token carries its own repository selection, so
# a read already cannot reach a repository the engineer did not grant, and several read
# tools (search_code, search_repositories, get_me) name no repository at all.
GITHUB_REPOS="MentalHealthInnovations/AI_Technical_Controls"

# repo_allowed <owner> <repo> — true iff owner/repo (any case) is in GITHUB_REPOS.
repo_allowed() {
  local want r
  [[ -n "$1" && -n "$2" ]] || return 1
  want="$(printf '%s/%s' "$1" "$2" | tr '[:upper:]' '[:lower:]')"
  for r in $GITHUB_REPOS; do
    [[ "$(printf '%s' "$r" | tr '[:upper:]' '[:lower:]')" == "$want" ]] && return 0
  done
  return 1
}

# repo_scope_ok <server> <tool> <payload> — true unless a github write names a
# repository outside GITHUB_REPOS. Only the github server is repository-scoped.
# Each write branch ends in repo_allowed, so a call whose owner or repo is missing
# or unparseable is denied rather than passed through.
repo_scope_ok() {
  local server="$1" tool="$2" pl="$3" owner repo t
  [[ "$server" == github ]] || return 0
  for t in $GITHUB_WRITE_TOOLS; do
    [[ "$t" == "$tool" ]] || continue
    owner="$(printf '%s' "$pl" | jq -r '.tool_input.owner // empty')"
    repo="$(printf '%s' "$pl" | jq -r '.tool_input.repo // empty')"
    repo_allowed "$owner" "$repo"
    return
  done
  return 0
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
  # And scope github writes to GITHUB_REPOS.
  if ! repo_scope_ok "$server" "$tool" "$payload"; then
    emit_deny "repo_not_in_allowlist" "GitHub repository not in the policy allowlist for this server"
  fi
  audit_emit "$payload" allow tool_name "$tool_name" server "$server" tool "$tool"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  exit 0
fi

emit_deny "not_in_allowlist" "MCP tool not in the policy allowlist for this server"
