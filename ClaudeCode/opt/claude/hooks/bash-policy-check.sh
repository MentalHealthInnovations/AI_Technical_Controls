#!/usr/bin/env bash
# PreToolUse hook for Bash commands. Enforces an allowlist policy: blocks network tools,
# pipe-to-shell patterns, base64 decode-and-execute, excessive command chaining, and
# any command not explicitly permitted. Outputs Claude Code hookSpecificOutput JSON.
set -u

logtofile() {
  echo "[$(date)] [bash-policy] [$(pwd)] $1" >> "$HOME/.claude/debug/bash-policy.log"
}

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"

if [[ -z "$cmd" ]]; then
  exit 0
fi

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
  logtofile "DENY excessive chaining ($separators separators): $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Command chaining exceeds policy threshold"}}'
  exit 0
fi

if printf '%s' "$stripped_cmd" | grep -Eqi '(^|\s)(sudo|su)(\s|$)'; then
  logtofile "DENY sudo/su: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Privilege escalation (sudo/su) blocked by policy"}}'
  exit 0
fi

if printf '%s' "$cmd" | grep -Eqi '\b(curl|wget|nc|netcat|ncat|socat)\b'; then
  logtofile "DENY network tool: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Network tool usage blocked by policy"}}'
  exit 0
fi

# Match shell/interpreter invocation as a command token, not as a substring.
# Anchors: start of string, after pipe (|), after semicolon, after &&/||, or after backtick.
# Catches: sh, bash, zsh, fish, dash, ksh, csh, tcsh, python, python3, perl, ruby, node,
#          nodejs, php, lua, exec, eval. The \b word-boundary prevents matching branch names
#          like "fish-fix" or arguments that contain these strings.
# shellcheck disable=SC2016  # single-quoted regex: $ is a literal char, not a variable
if printf '%s' "$stripped_cmd" | grep -Eqi '(^|[|;&`$( ])(sh|bash|zsh|fish|dash|ksh|csh|tcsh|python3?|perl|ruby|node(js)?|php|lua|exec|eval)\b'; then
  logtofile "DENY shell invocation: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Shell or interpreter invocation blocked by policy"}}'
  exit 0
fi

if printf '%s' "$cmd" | grep -Eqi 'base64\s+(-d|--decode)'; then
  logtofile "DENY base64 decode: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Decode-and-execute pattern blocked"}}'
  exit 0
fi

if printf '%s' "$cmd" | grep -Eqi '(^|\s)(--force|-D|--force-delete|--no-verify)\b'; then
  logtofile "DENY dangerous flag: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Dangerous flag blocked by policy"}}'
  exit 0
fi

if printf '%s' "$cmd" | grep -Eq '^git\s+.*\s(-f|--hard)\b'; then
  logtofile "DENY git -f flag: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Dangerous flag blocked by policy"}}'
  exit 0
fi

# find -exec/-execdir bypasses the shell-invocation check because "-exec" is
# preceded by "-", which is not in the anchor character class used on line 72.
# Block it explicitly before reaching the allowlist so that "^find\b" cannot
# be used to launder arbitrary subprocess execution.
if printf '%s' "$cmd" | grep -Eqi '^find\b.*[[:space:]]-exec(dir)?\b'; then
  logtofile "DENY find -exec: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"find -exec/-execdir blocked by policy"}}'
  exit 0
fi

# find -delete is a built-in mass-deletion action that bypasses the shell-invocation
# check for the same reason as -exec. Block it here for defense-in-depth even though
# the FS sandbox limits write scope.
if printf '%s' "$cmd" | grep -Eqi '^find\b.*[[:space:]]-delete\b'; then
  logtofile "DENY find -delete: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"find -delete blocked by policy"}}'
  exit 0
fi

# pre-commit subcommands that fetch or execute arbitrary code from network or
# .pre-commit-config.yaml escape the bash-policy boundary: pre-commit spawns
# hook binaries via execve, so the shell-invocation check on line ~71 is not
# consulted. Block the dangerous subcommands ahead of the allowlist so a
# future broadening of "^pre-commit\b" can't launder them.
if printf '%s' "$cmd" | grep -Eqi '^pre-commit\s+(try-repo|autoupdate|install-hooks|install|migrate-config|init-templatedir)\b'; then
  logtofile "DENY pre-commit subcommand: $cmd"
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"pre-commit try-repo/autoupdate/install-hooks blocked by policy"}}'
  exit 0
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
  
  # Docker - safe operations
  "^docker\s+(build|ps|logs|pull|images|inspect)"

  # pre-commit, terraform, and gitleaks are not allowed directly because each
  # spawns subprocesses (hook binaries, provider plugins) via execve that
  # bypass this policy hook. Invoke them via the org-managed wrappers in
  # /opt/claude/bin/, which validate subcommands, pin cache locations into the
  # repo, refuse module/plugin fetches, and force --redact for gitleaks.
  "^/opt/claude/bin/pre-commit-safe\b"
  "^/opt/claude/bin/terraform-safe\b"
  "^/opt/claude/bin/terragrunt-safe\b"
  "^/opt/claude/bin/gitleaks-safe\b"
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
    logtofile "DENY segment not in allowlist: '$segment' (full cmd: $cmd)"
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Command not in policy allowlist"}}'
    exit 0
  fi
done < <(printf '%s' "$stripped_cmd" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g; s/|/\n/g')

echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
