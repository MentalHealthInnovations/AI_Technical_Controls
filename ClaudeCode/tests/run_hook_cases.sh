#!/usr/bin/env bash
# Runs a JSONL case file against a hook script and reports pass/fail.
#
# Usage:
#   run_hook_cases.sh <hook-path> <cases.jsonl>
#
# Case file format: one JSON object per line with fields:
#   name   — short label
#   input  — object passed as tool_input to the hook
#   expect — "deny", "allow", or "unset"
#
# A case is "unset" when the hook exits 0 without emitting a hookSpecificOutput
# decision (e.g. our PII path hook lets the harness's default permission flow
# handle non-matching paths).
set -u

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <hook-path> <cases.jsonl>" >&2
  exit 2
fi

hook="$1"
cases="$2"

if [[ ! -x "$hook" ]]; then
  echo "Hook not executable: $hook" >&2
  exit 2
fi
if [[ ! -f "$cases" ]]; then
  echo "Cases file not found: $cases" >&2
  exit 2
fi

fail=0
total=0
while IFS= read -r line; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  name=$(printf '%s' "$line" | jq -r '.name')
  expect=$(printf '%s' "$line" | jq -r '.expect')
  input=$(printf '%s' "$line" | jq -c '.input')

  payload=$(jq -n --argjson i "$input" '{tool_input: $i}')
  out=$(printf '%s' "$payload" | "$hook" 2>/dev/null || true)

  if [[ -z "$out" ]]; then
    actual="unset"
  else
    actual=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "unset"' 2>/dev/null || echo "error")
  fi

  total=$((total+1))
  if [[ "$actual" == "$expect" ]]; then
    printf 'PASS  %-45s %s\n' "$name" "$actual"
  else
    printf 'FAIL  %-45s expected=%s actual=%s\n' "$name" "$expect" "$actual"
    # Re-run with stderr visible so environment failures (missing tools, cwd
    # mismatches, awk dialect quirks) are diagnosable from the log.
    printf '%s' "$payload" | "$hook" 2>&1 | sed 's/^/      | /' || true
    fp="$(printf '%s' "$input" | jq -r '.file_path // empty')"
    if [[ -n "$fp" && ! -e "$fp" && "$fp" != /* ]]; then
      printf '      diag: %s does not exist relative to cwd %s\n' "$fp" "$PWD"
    fi
    fail=$((fail+1))
  fi
done < "$cases"

echo
echo "Total: $total, Failed: $fail"
exit "$fail"
