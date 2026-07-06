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
# pattern_names / pattern_regexes / pattern_confs / DISTINCT_TRIP /
# DENSITY_TRIP / SNIFF_BYTES / pii_score_sample / PII_EXCLUDE_PREFIXES /
# pii_path_excluded are defined in pii-patterns.sh, sourced at runtime; the
# include cannot be followed at lint time (SC1091) so unassigned-variable
# checks (SC2154) would otherwise misfire on all of them.
# shellcheck disable=SC2154
set -u

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
  # while-read loop rather than mapfile: mapfile needs bash 4, and this
  # script runs directly on developer Macs via pre-commit (language: system),
  # where the system bash is 3.2 — the same constraint pii-content-sniff.sh
  # and run_wild_corpus_cases.sh already document and avoid.
  files=()
  while IFS= read -r line; do
    files+=("$line")
  done < <(git diff --cached --name-only --diff-filter=ACMR)
else
  files=("$@")
fi

# Per-file scan. For each file, read the staged blob, skip binaries, count
# pattern hits, decide whether the file trips a threshold.
scan_file() {
  local path="$1"

  # PII_EXCLUDE_PREFIXES / pii_path_excluded live in pii-patterns.sh, shared
  # with pii-content-sniff.sh. The extra prefix below is staged-scan-only:
  # fixtures/pii-content/ intentionally contains PII-shaped text so the
  # runtime hook's own test suite can verify detection on Read, but that same
  # content must not block committing the fixture files themselves.
  if pii_path_excluded "$path" "ClaudeCode/tests/cases/fixtures/pii-content/"; then
    return 0
  fi

  # Skip known binary formats — same intent, same extension list
  # (pii_is_binary_extension, pii-patterns.sh), as pii-content-sniff.sh.
  #
  # Gated on EXTENSION as well as git's own binary classification (`--numstat`
  # prints "-" for both counts on a binary blob, computed by git directly
  # from the blob bytes), not on git's classification alone: git's own
  # heuristic flags ANY file containing a NUL as binary, including a plain
  # text file with a single stray NUL byte — exactly the fail-open bypass
  # already fixed in pii-content-sniff.sh (a NUL-prefixed notes.txt must
  # still be scanned, not skipped). Extension-gating means only files that
  # are already binary-shaped by name get the git-classification skip.
  #
  # This replaces an earlier NUL-byte sniff on $blob that could never fire:
  # bash command substitution captures $blob as a scalar, and bash scalars
  # cannot hold an embedded NUL at all (they are C strings internally), so
  # that check was always false regardless of the file's actual content.
  local ext_lc="${path##*.}"
  ext_lc="$(printf '%s' "$ext_lc" | tr '[:upper:]' '[:lower:]')"
  if pii_is_binary_extension "$ext_lc"; then
    local numstat
    numstat="$(git diff --cached --numstat -- "$path" 2>/dev/null)"
    if [[ "$numstat" == -$'\t'-$'\t'* ]]; then
      return 0
    fi
  fi

  # Pull the staged blob. `git show :path` returns the version in the index,
  # which is what would be committed — not the working-tree copy.
  local blob
  if ! blob="$(git show ":$path" 2>/dev/null)"; then
    # Path is not in the index (e.g. pre-commit invoked with a file the user
    # didn't actually stage). Silently skip; there's nothing to scan.
    return 0
  fi

  local sample="${blob:0:$SNIFF_BYTES}"
  [[ -z "$sample" ]] && return 0

  # Same counting logic as pii-content-sniff.sh, from pii-patterns.sh's
  # pii_score_sample(): sets PII_DISTINCT, PII_DENSITY_MAX, PII_DENSITY_NAME,
  # PII_DISTINCT_NAMES[]. Kept in one place so runtime and commit-time
  # detection cannot silently drift apart.
  pii_score_sample "$sample"

  local tripped="" reason=""
  if [[ "$PII_DISTINCT" -ge "$DISTINCT_TRIP" ]]; then
    local joined
    # while-read loop rather than mapfile — see the bash-3.2 note above.
    local sorted=()
    while IFS= read -r line; do
      sorted+=("$line")
    done < <(printf '%s\n' "${PII_DISTINCT_NAMES[@]}" | sort)
    joined="$(IFS=, ; echo "${sorted[*]}")"
    tripped="distinct"
    reason="$PII_DISTINCT distinct PII categories ($joined)"
  elif [[ "$PII_DENSITY_MAX" -ge "$DENSITY_TRIP" ]]; then
    tripped="density"
    reason="$PII_DENSITY_MAX matches of $PII_DENSITY_NAME (high-confidence pattern)"
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
    PII_EXCLUDE_PREFIXES in ClaudeCode/opt/claude/hooks/pii-patterns.sh
    (shared with the runtime hook — security review required).

EOF
  exit 1
fi
exit 0
