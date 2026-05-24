#!/usr/bin/env bash
# Run every hook's case file. Exits non-zero if any case fails.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
runner="$here/run_hook_cases.sh"

# Hooks resolve relative file_path values against $PWD. Case fixtures live
# under $repo_root/ClaudeCode/tests/cases/fixtures/..., so the suite must run
# with $repo_root as cwd regardless of where the runner was invoked from
# (CI workflow without working-directory, local cd into tests/, etc.).
cd "$repo_root"

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

# Staged-scan tests use their own runner because the scanner needs a real
# git index, not a JSONL payload feed.
echo "=== pii-staged-scan.sh ==="
if ! "$here/run_staged_scan_cases.sh"; then
  overall_fail=1
fi
echo

# Wild-corpus: real-world-shaped files that must not trip any detector.
# Catches threshold drift — see fixtures/pii-content-wild/MANIFEST.md.
echo "=== pii-content-sniff.sh (wild corpus) ==="
if ! "$here/run_wild_corpus_cases.sh"; then
  overall_fail=1
fi
echo

exit "$overall_fail"
