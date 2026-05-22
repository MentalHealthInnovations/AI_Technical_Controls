#!/usr/bin/env bash
# Run every hook's case file. Exits non-zero if any case fails.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
runner="$here/run_hook_cases.sh"

declare -a suites=(
  "pii-path-policy-check.sh|pii-path-policy.json"
  "pii-content-sniff.sh|pii-content-sniff.json"
)

overall_fail=0
for suite in "${suites[@]}"; do
  hook_name="${suite%%|*}"
  cases_name="${suite##*|}"
  hook_path="$repo_root/ClaudeCode/opt/claude/hooks/$hook_name"
  cases_path="$here/cases/$cases_name"

  echo "=== $hook_name ==="
  if ! "$runner" "$hook_path" "$cases_path"; then
    overall_fail=1
  fi
  echo
done

exit "$overall_fail"
