#!/usr/bin/env bash
# False-positive guard: runs every file in tests/cases/fixtures/pii-content-wild
# through pii-content-sniff.sh and asserts that none of them trip a deny.
#
# Beyond pass/fail, this runner prints per-pattern hit counts for each fixture,
# so a future PR that lowers a threshold or tightens a regex visibly shifts the
# counts even if no fixture trips yet.
#
# Adding a fixture: drop it under fixtures/pii-content-wild/ and update that
# directory's MANIFEST.md. The runner discovers files automatically.
#
# pattern_names / pattern_regexes are defined in the sourced pii-patterns.sh,
# which shellcheck cannot follow at lint time (SC1091 / SC2154).
# shellcheck disable=SC2154
set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
hook="$repo_root/ClaudeCode/opt/claude/hooks/pii-content-sniff.sh"
patterns_file="$repo_root/ClaudeCode/opt/claude/hooks/pii-patterns.sh"
corpus_dir="$here/cases/fixtures/pii-content-wild"

if [[ ! -x "$hook" ]]; then
  echo "Hook not executable: $hook" >&2
  exit 2
fi
if [[ ! -f "$patterns_file" ]]; then
  echo "Patterns file not found: $patterns_file" >&2
  exit 2
fi
if [[ ! -d "$corpus_dir" ]]; then
  echo "Corpus dir not found: $corpus_dir" >&2
  exit 2
fi

# shellcheck source=../opt/claude/hooks/pii-patterns.sh disable=SC1091
. "$patterns_file"

# Locate all corpus files. Skip MANIFEST.md (documentation, not a fixture).
# Use a while-read loop instead of mapfile so this works on bash 3.2 (macOS).
fixtures=()
while IFS= read -r line; do
  fixtures+=("$line")
done < <(find "$corpus_dir" -type f ! -name "MANIFEST.md" | sort)

if [[ "${#fixtures[@]}" -eq 0 ]]; then
  echo "No fixtures found in $corpus_dir" >&2
  exit 2
fi

# Column widths match the longest pattern name so the table stays aligned.
pname_width=0
for name in "${pattern_names[@]}"; do
  [[ "${#name}" -gt "$pname_width" ]] && pname_width="${#name}"
done

printf 'Per-pattern hit counts (each fixture is expected to be sub-threshold):\n'
printf '\n'
printf '  %-40s' "fixture"
for name in "${pattern_names[@]}"; do
  printf ' %-*s' "$pname_width" "$name"
done
printf '  verdict\n'

fail=0
total=0

for fixture in "${fixtures[@]}"; do
  total=$((total + 1))
  rel="${fixture#"$repo_root"/}"
  short_rel="${rel#ClaudeCode/tests/cases/fixtures/pii-content-wild/}"

  # Drive the hook the same way Claude's harness does, then capture the verdict.
  payload="$(jq -n --arg p "$fixture" '{tool_input: {file_path: $p}}')"
  out="$(printf '%s' "$payload" | "$hook" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    verdict="allow"
  else
    decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "unset"' 2>/dev/null)"
    if [[ "$decision" == "deny" ]]; then
      verdict="DENY"
      fail=$((fail + 1))
    else
      verdict="$decision"
    fi
  fi

  # Count each pattern against the fixture with the same sample size (first
  # 64 KiB) and the same match()/RSTART/RLENGTH loop as the hook, so the
  # displayed counts match what the hook actually scored.
  sample="$(head -c 65536 "$fixture")"
  printf '  %-40s' "$short_rel"
  n="${#pattern_names[@]}"
  for ((i=0; i<n; i++)); do
    regex="${pattern_regexes[$i]}"
    count="$(printf '%s' "$sample" | awk -v r="$regex" 'BEGIN{c=0} {s=$0; while (match(s,r)>0) {c++; adv=RSTART+RLENGTH-1; if (adv<1) adv=1; s=substr(s,adv)}} END{print c+0}' 2>/dev/null)"
    [[ -z "$count" ]] && count=0
    printf ' %-*s' "$pname_width" "$count"
  done
  printf '  %s\n' "$verdict"
done

echo
echo "Thresholds: DISTINCT=3 categories, DENSITY=10 hits of a single high-confidence pattern."
echo "Total: $total fixture(s), Failed (tripped deny): $fail"

# Any deny is a failure. Sub-threshold counts shifting upward across PRs is a
# warning sign but doesn't fail the suite; it's visible in the diff of this
# table in CI output.
exit "$fail"
