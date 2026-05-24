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
  hook_stderr="$(mktemp)"
  out=$(printf '%s' "$payload" | "$hook" 2>"$hook_stderr" || true)

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
    # Diagnostic dump on failure: resolve the file_path the hook would see,
    # report existence/size, and surface hook stderr. Helps catch environment-
    # specific issues (cwd mismatches, missing tools, awk dialect quirks)
    # that produce silent "unset" outcomes.
    fp="$(printf '%s' "$input" | jq -r '.file_path // empty')"
    if [[ -n "$fp" ]]; then
      resolved="$fp"
      [[ "$fp" != /* ]] && resolved="$(pwd)/$fp"
      if [[ -f "$resolved" ]]; then
        size=$(wc -c < "$resolved" 2>/dev/null || echo "?")
        printf '      diag: file_path=%s resolved=%s exists=yes size=%s\n' "$fp" "$resolved" "$size"
      else
        printf '      diag: file_path=%s resolved=%s exists=NO\n' "$fp" "$resolved"
      fi
    else
      printf '      diag: no file_path in input\n'
    fi
    if [[ -s "$hook_stderr" ]]; then
      printf '      diag: hook stderr:\n'
      sed 's/^/        /' "$hook_stderr"
    fi
    if [[ -n "$out" ]]; then
      printf '      diag: hook stdout: %s\n' "$out"
    fi
    fail=$((fail+1))
  fi
  rm -f "$hook_stderr"
done < "$cases"

echo
echo "Total: $total, Failed: $fail"
exit "$fail"
