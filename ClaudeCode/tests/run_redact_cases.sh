#!/usr/bin/env bash
# Runs a JSONL case file against the shared redaction library and reports
# pass/fail.
#
# Usage:
#   ClaudeCode/tests/run_redact_cases.sh [cases.jsonl]
#
# Defaults to cases/redact.jsonl next to this script.
#
# This exercises redact_text() from opt/claude/hooks/lib/redact.sh directly
# rather than driving output-redact.sh with a hook payload. Every pattern and
# guard lives in the library, so calling it directly keeps a failure pointing at
# the pattern rather than at the hook's JSON plumbing.
#
# Like the other runners here, this is not wired into the bash-policy allowlist.
# Run it from a normal shell, not from inside an agent session.
#
# Case file format is one JSON object per line, with these fields.
#   name       short label printed in the output
#   text       the text passed to redact_text
#   expect     "redacted" (at least one [REDACTED] appears) or "clear" (text
#              comes back byte-identical and no pattern matched)
#   pattern    optional. Pattern name that must appear in the match sentinel
#   survives   optional. Substring that must still be present after redaction,
#              which pins per-occurrence behaviour. On a line holding prose and
#              a credential, the prose has to come back intact.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
cases="${1:-$here/cases/redact.jsonl}"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../opt/claude/hooks/lib/redact.sh
. "$here/../opt/claude/hooks/lib/redact.sh"

if [[ ! -f "$cases" ]]; then
  echo "Cases file not found: $cases" >&2
  exit 2
fi

fail=0
total=0
while IFS= read -r line; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  name=$(printf '%s' "$line" | jq -r '.name')
  text=$(printf '%s' "$line" | jq -r '.text')
  expect=$(printf '%s' "$line" | jq -r '.expect')
  want_pattern=$(printf '%s' "$line" | jq -r '.pattern // empty')
  survives=$(printf '%s' "$line" | jq -r '.survives // empty')

  # Line 1 of redact_text is the match sentinel, the remainder is the body.
  out="$(redact_text "$text")"
  names="${out%%$'\n'*}"
  body="${out#*$'\n'}"

  total=$((total+1))
  problem=""

  case "$expect" in
    redacted)
      [[ "$body" == *"[REDACTED]"* ]] || problem="expected a redaction, got: $body"
      ;;
    clear)
      if [[ "$body" != "$text" ]]; then
        problem="expected text unchanged, got: $body"
      elif [[ -n "$names" ]]; then
        problem="expected no pattern match, sentinel reported: $names"
      fi
      ;;
    *)
      problem="unknown expect value: $expect"
      ;;
  esac

  if [[ -z "$problem" && -n "$want_pattern" && "$names" != *"$want_pattern"* ]]; then
    problem="expected pattern $want_pattern, sentinel reported: ${names:-none}"
  fi
  if [[ -z "$problem" && -n "$survives" && "$body" != *"$survives"* ]]; then
    problem="expected '$survives' to survive, got: $body"
  fi

  if [[ -z "$problem" ]]; then
    printf 'PASS  %-45s %s\n' "$name" "$expect"
  else
    printf 'FAIL  %-45s %s\n' "$name" "$problem"
    fail=$((fail+1))
  fi
done < "$cases"

echo
echo "Total: $total, Failed: $fail"
exit "$fail"
