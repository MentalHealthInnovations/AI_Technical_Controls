#!/usr/bin/env bash
# Scans staged file content for PII signatures and fails the commit on any
# trip. Designed for two callers:
#
#   1. pre-commit framework — passes changed-file paths as positional args.
#   2. Manual / CI — call with no args to scan every file in the index diff.
#
# In both cases the *staged* version of each file is read via `git show :path`,
# not the working tree, so an unsaved local edit cannot fool the scan.
#
# Detection uses the same pattern set as pii-content-sniff.sh (PreToolUse
# runtime hook), sourced from pii-patterns.sh. Thresholds match too: 3 distinct
# categories or 10 hits of a single high-confidence pattern.
#
# Exit codes:
#   0 — no PII detected in any staged file
#   1 — PII detected; commit/CI should fail
#   2 — invocation error (missing dependency, not a git repo, etc.)
#
# pattern_names / pattern_regexes / pattern_confs are defined in pii-patterns.sh,
# sourced at runtime; shellcheck cannot follow that include (SC1091) so it would
# otherwise flag them as unassigned (SC2154).
# shellcheck disable=SC2154
set -u

DISTINCT_TRIP=3
DENSITY_TRIP=10
MAX_BINARY_CHECK_BYTES=1024
SNIFF_BYTES=65536

# Paths that are deliberately committed synthetic PII (test fixtures). The
# scanner skips any staged file whose path starts with one of these prefixes.
# Keep this list narrow — anything broader risks creating safe-harbour zones
# for accidental PII.
EXCLUDE_PREFIXES=(
  "ClaudeCode/tests/cases/fixtures/"
  # The staged-scan test runner embeds synthetic PII inline to drive the
  # scanner against temporary git repos. Its values are fictional (example.test
  # addresses, Ofcom reserved phone range, canonical example IBAN/postcode).
  "ClaudeCode/tests/run_staged_scan_cases.sh"
)

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
patterns_file="$repo_root/ClaudeCode/opt/claude/hooks/pii-patterns.sh"

if [[ ! -f "$patterns_file" ]]; then
  echo "pii-staged-scan: cannot find $patterns_file" >&2
  exit 2
fi
# shellcheck source=../opt/claude/hooks/pii-patterns.sh disable=SC1091
. "$patterns_file"

if ! command -v git >/dev/null 2>&1; then
  echo "pii-staged-scan: git not found" >&2
  exit 2
fi
if ! command -v awk >/dev/null 2>&1; then
  echo "pii-staged-scan: awk not found" >&2
  exit 2
fi

# Resolve target file list. With no args, ask git for the staged file list;
# with args, treat each as a path (this is how pre-commit invokes hooks).
if [[ $# -eq 0 ]]; then
  # Filter out deletions (only files still present in the index can be scanned).
  mapfile -t files < <(git diff --cached --name-only --diff-filter=ACMR)
else
  files=("$@")
fi

# Per-file scan. For each file, read the staged blob, skip binaries, count
# pattern hits, decide whether the file trips a threshold.
scan_file() {
  local path="$1"

  # An exclude entry ending in "/" is a directory prefix: it matches that path
  # and anything beneath it. An entry without a trailing "/" is an EXACT path
  # match. We avoid a bare "$prefix"* glob because that matched on a substring
  # boundary — e.g. the file entry "…/run_staged_scan_cases.sh" would also have
  # excluded "…/run_staged_scan_cases.sh.bak", silently creating a safe-harbour
  # for any derived file.
  for prefix in "${EXCLUDE_PREFIXES[@]}"; do
    if [[ "$prefix" == */ ]]; then
      if [[ "$path" == "$prefix"* ]]; then
        return 0
      fi
    elif [[ "$path" == "$prefix" ]]; then
      return 0
    fi
  done

  # Pull the staged blob. `git show :path` returns the version in the index,
  # which is what would be committed — not the working-tree copy.
  local blob
  if ! blob="$(git show ":$path" 2>/dev/null)"; then
    # Path is not in the index (e.g. pre-commit invoked with a file the user
    # didn't actually stage). Silently skip; there's nothing to scan.
    return 0
  fi

  # Binary detection — NUL byte in the first KiB. Same heuristic as the
  # runtime sniffer. Imperfect (UTF-16 false-positives) but consistent.
  local head_before head_after
  head_before=$(printf '%s' "${blob:0:$MAX_BINARY_CHECK_BYTES}" | wc -c)
  head_after=$(printf '%s' "${blob:0:$MAX_BINARY_CHECK_BYTES}" | tr -d '\0' | wc -c)
  if [[ "$head_before" -ne "$head_after" ]]; then
    return 0
  fi

  local sample="${blob:0:$SNIFF_BYTES}"
  [[ -z "$sample" ]] && return 0

  local distinct=0 density_max=0 density_name=""
  local distinct_names=()
  local n="${#pattern_names[@]}"
  local i name regex conf count
  for ((i=0; i<n; i++)); do
    name="${pattern_names[$i]}"
    regex="${pattern_regexes[$i]}"
    conf="${pattern_confs[$i]}"
    # match()/RSTART/RLENGTH loop, not gsub() counting: gsub consumes each
    # match's boundary char, undercounting adjacent PII items (two postcodes
    # separated by one space count as one). Re-scanning from RSTART+RLENGTH-1
    # keeps the consumed trailing boundary available as the next match's leading
    # boundary. All patterns match >=2 chars, so the rewind still advances.
    # Kept identical to pii-content-sniff.sh so both layers count the same.
    count="$(printf '%s' "$sample" | awk -v r="$regex" 'BEGIN{c=0} {s=$0; while (match(s,r)>0) {c++; adv=RSTART+RLENGTH-1; if (adv<1) adv=1; s=substr(s,adv)}} END{print c+0}' 2>/dev/null)"
    [[ -z "$count" ]] && count=0
    if [[ "$count" -gt 0 ]]; then
      distinct=$((distinct + 1))
      distinct_names+=("$name=$count")
      if [[ "$conf" == "high" && "$count" -gt "$density_max" ]]; then
        density_max="$count"
        density_name="$name"
      fi
    fi
  done

  local tripped="" reason=""
  if [[ "$distinct" -ge "$DISTINCT_TRIP" ]]; then
    local joined
    local sorted=()
    mapfile -t sorted < <(printf '%s\n' "${distinct_names[@]}" | sort)
    joined="$(IFS=, ; echo "${sorted[*]}")"
    tripped="distinct"
    reason="$distinct distinct PII categories ($joined)"
  elif [[ "$density_max" -ge "$DENSITY_TRIP" ]]; then
    tripped="density"
    reason="$density_max matches of $density_name (high-confidence pattern)"
  fi

  if [[ -n "$tripped" ]]; then
    echo "PII detected in staged file: $path" >&2
    echo "  reason: $reason" >&2
    return 1
  fi
  return 0
}

failed=0
for path in "${files[@]}"; do
  [[ -z "$path" ]] && continue
  if ! scan_file "$path"; then
    failed=$((failed + 1))
  fi
done

if [[ "$failed" -gt 0 ]]; then
  cat >&2 <<EOF

pii-staged-scan: $failed file(s) contain PII signatures and cannot be committed.
Detectors and thresholds match the runtime pii-content-sniff.sh hook.

Resolve by:
  - removing the PII content from the file, OR
  - replacing real values with synthetic/redacted equivalents, OR
  - if the file is a deliberate fixture, adding its path prefix to
    EXCLUDE_PREFIXES in ClaudeCode/scripts/pii-staged-scan.sh (security review required).

EOF
  exit 1
fi
exit 0
