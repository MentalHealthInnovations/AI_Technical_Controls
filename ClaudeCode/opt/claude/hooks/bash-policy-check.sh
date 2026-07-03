#!/usr/bin/env bash
# PreToolUse hook for Bash commands. Enforces an allowlist policy: blocks network tools,
# pipe-to-shell patterns, base64 decode-and-execute, excessive command chaining, and
# any command not explicitly permitted. Outputs Claude Code hookSpecificOutput JSON.
#
# Audit: every invocation (allow or deny) is appended as a single JSON Lines
# record to ~/.claude/debug/bash-policy.jsonl via the shared audit-log helper.
set -u

# Load the shared JSONL audit helper. Resolve relative to this script so it
# works whether the hook is run from /opt/claude/hooks/ or a test directory.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/audit-log.sh
source "$HOOK_DIR/lib/audit-log.sh"
audit_init "bash-policy"

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"

if [[ -z "$cmd" ]]; then
  exit 0
fi

# Helper: emit a deny decision via JSON to stdout AND record the audit line.
emit_deny() {
  local reason_short="$1"   # short label for the audit log (e.g. "sudo_su")
  local reason_user="$2"    # user-facing reason returned to Claude
  audit_emit "$payload" deny cmd "$cmd" reason "$reason_short"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason_user"
  exit 0
}

# strip_quoted_strings removes everything inside "..." or '...' (including multi-line values)
# so that words like "exec" in a commit message body — or regex alternation operators like
# `grep "a\|b\|c"` — don't trigger false positives. The full $cmd is still used where
# quoted values must be inspected (e.g. --exec="curl ...").
strip_quoted_strings() {
  local full_command="$1"
  local result="" current_char="" open_quote=""
  local position=0
  while [[ $position -lt ${#full_command} ]]; do
    current_char="${full_command:$position:1}"
    if [[ -n "$open_quote" ]]; then
      # Inside a quoted string — skip until the matching closing quote
      [[ "$current_char" == "$open_quote" ]] && open_quote=""
    else
      if [[ "$current_char" == '"' || "$current_char" == "'" ]]; then
        open_quote="$current_char"   # entering a quoted string
      else
        result+="$current_char"     # outside any quotes — keep this character
      fi
    fi
    (( position++ ))
  done
  printf '%s' "$result"
}
stripped_cmd="$(strip_quoted_strings "$cmd")"

# Count chain operators outside quoted strings only. Operators inside quotes are literal
# argument text (e.g. a grep regex), not shell-level chaining, so they must not count.
separators=$(printf '%s' "$stripped_cmd" | grep -oE '(\&\&|;|\|\||\|)' | wc -l | tr -d ' ')
if [[ "${separators:-0}" -gt 2 ]]; then
  emit_deny "chaining" "Command chaining exceeds policy threshold"
fi

if printf '%s' "$stripped_cmd" | grep -Eqi '(^|\s)(sudo|su)(\s|$)'; then
  emit_deny "sudo_su" "Privilege escalation (sudo/su) blocked by policy"
fi

if printf '%s' "$cmd" | grep -Eqi '\b(curl|wget|nc|netcat|ncat|socat)\b'; then
  emit_deny "network_tool" "Network tool usage blocked by policy"
fi

# Match shell/interpreter invocation as a command token, not as a substring.
# Anchors: start of string, after pipe (|), after semicolon, after &&/||, or after backtick.
# Catches: sh, bash, zsh, fish, dash, ksh, csh, tcsh, python, python3, perl, ruby, node,
#          nodejs, php, lua, exec, eval. The \b word-boundary prevents matching branch names
#          like "fish-fix" or arguments that contain these strings.
# shellcheck disable=SC2016  # single-quoted regex: $ is a literal char, not a variable
if printf '%s' "$stripped_cmd" | grep -Eqi '(^|[|;&`$( ])(sh|bash|zsh|fish|dash|ksh|csh|tcsh|python3?|perl|ruby|node(js)?|php|lua|exec|eval)\b'; then
  emit_deny "shell_invocation" "Shell or interpreter invocation blocked by policy"
fi

if printf '%s' "$cmd" | grep -Eqi 'base64\s+(-d|--decode)'; then
  emit_deny "base64_decode" "Decode-and-execute pattern blocked"
fi

if printf '%s' "$cmd" | grep -Eqi '(^|\s)(--force|-D|--force-delete|--no-verify)\b'; then
  emit_deny "dangerous_flag" "Dangerous flag blocked by policy"
fi

if printf '%s' "$cmd" | grep -Eq '^git\s+.*\s(-f|--hard)\b'; then
  emit_deny "git_force_flag" "Dangerous flag blocked by policy"
fi

# find -exec/-execdir bypasses the shell-invocation check because "-exec" is
# preceded by "-", which is not in the anchor character class used on line 72.
# Block it explicitly before reaching the allowlist so that "^find\b" cannot
# be used to launder arbitrary subprocess execution.
if printf '%s' "$cmd" | grep -Eqi '^find\b.*[[:space:]]-exec(dir)?\b'; then
  emit_deny "find_exec" "find -exec/-execdir blocked by policy"
fi

# find -delete is a built-in mass-deletion action that bypasses the shell-invocation
# check for the same reason as -exec. Block it here for defense-in-depth even though
# the FS sandbox limits write scope.
if printf '%s' "$cmd" | grep -Eqi '^find\b.*[[:space:]]-delete\b'; then
  emit_deny "find_delete" "find -delete blocked by policy"
fi

# pre-commit subcommands that fetch or execute arbitrary code from network or
# .pre-commit-config.yaml escape the bash-policy boundary: pre-commit spawns
# hook binaries via execve, so the shell-invocation check on line ~71 is not
# consulted. Block the dangerous subcommands ahead of the allowlist so a
# future broadening of "^pre-commit\b" can't launder them.
if printf '%s' "$cmd" | grep -Eqi '^pre-commit\s+(try-repo|autoupdate|install-hooks|install|migrate-config|init-templatedir)\b'; then
  emit_deny "pre_commit_subcommand" "pre-commit try-repo/autoupdate/install-hooks blocked by policy"
fi

# terraform mutating/credential subcommands. Block ahead of the allowlist so a
# future broadening of "^terraform\b" can't launder them. Plain `terraform init`
# is blocked because it fetches providers and modules from the registry; the
# `-backend=false` form used by the terraform_validate pre-commit hook is
# explicitly allowed in the allowlist below.
if printf '%s' "$cmd" | grep -Eqi '^terraform\s+(apply|destroy|import|taint|untaint|state|login|logout|console|workspace\s+(delete|new))\b'; then
  emit_deny "terraform_subcommand" "terraform apply/destroy/import/state/login/console blocked by policy"
fi
if printf '%s' "$cmd" | grep -Eqi '^terraform\s+init\b' && ! printf '%s' "$cmd" | grep -Eqi '\-backend=false\b'; then
  emit_deny "terraform_init_backend" "terraform init requires -backend=false under policy"
fi

# terragrunt is a terraform wrapper with the same mutating surface plus run-all
# (executes against every module) and hooks (arbitrary shell from terragrunt.hcl).
if printf '%s' "$cmd" | grep -Eqi '^terragrunt\s+(apply|destroy|import|taint|untaint|state|login|console|run-all|aws-provider-patch|workspace\s+(delete|new))\b'; then
  emit_deny "terragrunt_subcommand" "terragrunt apply/destroy/import/state/run-all blocked by policy"
fi
if printf '%s' "$cmd" | grep -Eqi '^terragrunt\s+init\b' && ! printf '%s' "$cmd" | grep -Eqi '\-backend=false\b'; then
  emit_deny "terragrunt_init_backend" "terragrunt init requires -backend=false under policy"
fi

# tflint --init downloads plugins from GitHub at runtime; tfsec --update refreshes
# its rule database from the network. Both are setup-time operations that the
# pre-commit hooks do not need at runtime — block them ahead of the allowlist.
if printf '%s' "$cmd" | grep -Eqi '^tflint\b.*\s--init\b'; then
  emit_deny "tflint_init" "tflint --init blocked by policy"
fi
if printf '%s' "$cmd" | grep -Eqi '^tfsec\b.*\s--update\b'; then
  emit_deny "tfsec_update" "tfsec --update blocked by policy"
fi

# Array of allowed command patterns (regex format)
# Safe git commands: read-only, safe modifications, but blocks dangerous operations
allowed_patterns=(
  # basic commands - read-only/safe anywhere in pipeline
  "\bls\b"
  "\becho\b"
  "\bcat\b"
  "\btr\b"
  "\bsed\b"
  "\bawk\b"
  "\bgrep\b"
  "\bhead\b"
  "\btail\b"
  "\bwc\b"
  "\bsort\b"
  "\buniq\b"
  "\bcut\b"
  "\bpaste\b"
  "\bdiff\b"
  "\bdate\b"
  "\bpwd\b"
  "\bwhoami\b"
  "\buname\b"
  "\bwhich\b"
  "\btype\b"
  "\bjq\b"
  "\btee\b"
  "\bprintf\b"
  "\bshellcheck\b"

  # basic commands - anchored because they modify filesystem/env.
  # Not matched as bare \bword\b tokens because they must be the leading command,
  # not a segment after && in a chain (chaining threshold already limits this, but
  # anchoring here adds a second constraint for single-command uses).
  "^find\b"
  "^mkdir\b"
  "^cp\b"
  "^mv\b"
  "^touch\b"
  "^env\b"
  "^export\b"

  # Git read-only commands
  "^git status"
  "^git diff"
  "^git log"
  "^git show"
  "^git blame"
  "^git grep"
  "^git remote"

  # Git safe modifications
  "^git add"
  "^git commit"
  "^git tag"
  "^git stash"
  "^git fetch"
  "^git pull"
  "^git checkout"
  "^git branch"
  "^git merge"
  "^git rebase"   # --onto and non-hard rebases are allowed; --hard is caught above
  "^git push"
  "^git rm"
  "^git mv"
  "^git reset"    # non-destructive modes (--soft, HEAD~N) allowed; --hard caught above
  "^git clone"
  "^git help"

  # GitHub CLI
  "^gh\s+(issue|pr|repo|gist|label|release)"
  # GitHub Actions and status: read-only verbs only. `gh run` and `gh workflow`
  # have mutating verbs (run rerun/cancel/delete, workflow run/enable/disable)
  # that trigger or cancel CI, so each is scoped to its inspect verbs rather than
  # allowlisted bare. `gh status` and `gh browse` are read-only. `gh api` is
  # deliberately omitted: it takes --method POST/DELETE, so it cannot be
  # allowlisted as read-only via a leading-verb pattern.
  "^gh\s+run\s+(list|view|watch)\b"
  "^gh\s+workflow\s+(list|view)\b"
  "^gh\s+(status|browse)\b"

  # npm/pnpm/yarn - safe operations
  "^npm\s+(ci|test|lint|list|search|view|info|outdated)"
  "^pnpm\s+(test|lint|list|search|view|outdated)"
  "^yarn\s+(test|lint|audit|list|info)"

  # Python package managers
  "^pip\s+(list|show|search|check)"
  "^pip3\s+(list|show|search|check)"
  "^poetry\s+(show|search|lock|lock.*--no-update|update)"

  # Python testing and linting
  "^pytest"
  "^ruff\s+(check|format|format.*--check|lint)"
  "^mypy"

  # Docker - safe operations. version/info are pure read-outs. run/exec/push are
  # deliberately excluded as arbitrary-code / write vectors.
  "^docker\s+(build|ps|logs|pull|images|inspect|version|info)"
  # docker compose: read-only subcommands only. build/run/up/down execute
  # arbitrary Dockerfile RUN steps or container commands and are excluded; those
  # spawn subprocesses this hook cannot see, so they are a policy decision, not a
  # config tweak (see docs/command-allowlist-risk-assessment.md).
  "^docker\s+compose\s+(config|ps|logs|ls|version)\b"

  # pre-commit and the binaries its hooks invoke. Anchored at ^ because they
  # modify the filesystem (write per-language envs under ~/.cache/pre-commit,
  # provider plugins under ~/.terraform.d, .terraform/ inside the repo, etc.).
  # Paired sandbox allowances live in managed-settings.json under
  # sandbox.filesystem.{allowRead,allowWrite}.
  #
  # Each subcommand allowlist is paired with a pre-block above the allowlist
  # that denies the dangerous subcommands of the same tool, so a future
  # broadening of any pattern here can't launder them.
  #
  # pre-commit: only subcommands that do not fetch or execute network-supplied
  # hook repos. try-repo/autoupdate/install-hooks are pre-blocked above.
  "^pre-commit\s+(run|gc|sample-config|validate-config|validate-manifest|help|--version|hook-impl)\b"
  # terraform: lint/inspect subcommands plus `init -backend=false` for the
  # terraform_validate pre-commit hook. apply/destroy/import/state/login/console
  # are pre-blocked above; plain `init` (without -backend=false) is also blocked.
  "^terraform\s+(fmt|validate|plan|show|output|providers|graph|version|test|init)\b"
  # terragrunt: same shape as terraform. run-all/aws-provider-patch are pre-blocked.
  "^terragrunt\s+(fmt|validate|plan|show|output|providers|graph|version|init|hclfmt|hclvalidate)\b"
  # tflint: lint runs only. --init (plugin download) is pre-blocked above.
  "^tflint\b"
  # tfsec: scanner runs only. --update (rule DB refresh) is pre-blocked above.
  "^tfsec\b"
  # terraform-docs: pure stdout generator, no network or state side-effects.
  "^terraform-docs\b"
  # gitleaks: scanner subcommands only. No `gitleaks generate` (writes config).
  "^gitleaks\s+(detect|protect|dir|version|help)\b"
)

# Split command on chain operators (&&, ||, ;, |) and check each segment individually.
# This prevents allowlisted tokens mid-chain from laundering a blocked lead command,
# e.g. "rm -rf /tmp && cat file" must not pass just because \bcat\b is in the allowlist.
segment_allowed() {
  local seg
  seg="$(printf '%s' "$1" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
  [[ -z "$seg" ]] && return 0  # empty segment (e.g. trailing operator) is fine
  for pattern in "${allowed_patterns[@]}"; do
    if printf '%s' "$seg" | grep -Eqi "$pattern"; then
      return 0
    fi
  done
  return 1
}

# Split on &&, ||, ;, | (all chain operators) using sed to normalise to newlines.
# Split the quote-stripped command so that operators inside quotes (e.g. a grep regex
# `"a\|b\|c"`) are not treated as segment boundaries. The allowlist only needs to see
# each segment's leading verb, which lives outside any quoted argument.
while IFS= read -r segment; do
  if ! segment_allowed "$segment"; then
    audit_emit "$payload" deny \
      cmd          "$cmd" \
      reason       "not_in_allowlist" \
      bad_segment  "$segment"
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Command not in policy allowlist"}}'
    exit 0
  fi
done < <(printf '%s' "$stripped_cmd" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g; s/|/\n/g')

audit_emit "$payload" allow cmd "$cmd" segs:json "${separators:-0}"
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
