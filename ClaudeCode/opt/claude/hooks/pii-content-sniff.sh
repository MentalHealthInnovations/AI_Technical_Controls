#!/usr/bin/env bash
# PreToolUse hook for Read, Write, Edit, and MultiEdit. Content-sniff layer of
# the PII controls.
#
# Regex-scans up to SNIFF_BYTES of content for PII signatures (emails, UK
# postcodes, UK phone numbers, UK National Insurance numbers, dates of birth,
# IBANs, 16-digit card-like sequences). If the content crosses one of two
# thresholds — distinct categories or single-category density — the operation
# is denied via hookSpecificOutput.
#
# Content source depends on the tool: Read scans the on-disk file; Write/Edit/
# MultiEdit scan the inline text being written (.content / .new_string /
# .edits[].new_string). Scanning the write payload closes the gap where an
# innocuously-named PII file — which Layer 1's name check misses — could be
# created via Write and never content-scanned at runtime.
#
# Layer 2 of the PII controls. Layer 1 (pii-path-policy-check.sh) denies on
# path/extension; this layer catches misnamed files where the contents reveal
# PII that the name did not, on Read as well as on the write-family tools
# (Write/Edit/MultiEdit never touch disk before this hook runs, so Layer 1's
# path check is the only line of defence for those until this layer inspects
# the payload itself). The two layers are independent and registered
# separately in managed-settings.json so either can be tuned or audited in
# isolation.
#
# Tuning (shared with pii-staged-scan.sh via pii-patterns.sh so runtime and
# commit-time detection cannot drift apart):
#   SNIFF_BYTES    — how much of the content to scan. Larger = more accurate,
#                    slower on big files. Default 65536 (64 KiB).
#   DISTINCT_TRIP  — number of distinct categories that triggers a deny.
#   DENSITY_TRIP   — number of matches of a single high-confidence pattern
#                    that triggers a deny on its own.
#
# To add a new pattern, see pii-patterns.sh.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=pii-patterns.sh
. "$script_dir/pii-patterns.sh"
# Defines pattern_names/pattern_regexes/pattern_confs, the shared scan
# constants (SNIFF_BYTES, DISTINCT_TRIP, DENSITY_TRIP, MAX_BINARY_CHECK_BYTES),
# and the pii_score_sample() / pii_deny_json() helpers used below.

# shellcheck source=lib/audit-log.sh
source "$script_dir/lib/audit-log.sh"
audit_init "pii-content-sniff"
# Every allow/deny below is recorded as one JSON Lines record to
# ~/.claude/debug/pii-content-sniff.jsonl via the shared helper — the same
# mechanism every other policy hook uses, including audit_init's mkdir -p for
# a first-run ~/.claude/debug/. This replaced an ad-hoc plain-text log file
# that every other hook's log/rotation/S3-upload tooling didn't know about.

payload="$(cat)"
tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"

if [[ -z "$file_path" ]]; then
  exit 0
fi

# Resolve path. Claude Code passes absolute paths but be defensive against
# relative ones for local-test purposes.
if [[ "$file_path" != /* ]]; then
  file_path="$(pwd)/$file_path"
fi

# PII_EXCLUDE_PREFIXES / pii_path_excluded (pii-patterns.sh) mark known
# synthetic-fixture / test-infrastructure locations — shared with
# pii-staged-scan.sh so both layers treat the same paths the same way. Without
# this, e.g. run_staged_scan_cases.sh (whitelisted for the commit-time
# scanner because its own test payloads are PII-shaped text) would still get
# denied on a plain Read by this hook.
if pii_path_excluded "$file_path"; then
  audit_emit "$payload" allow file_path "$file_path" reason "excluded_fixture_path"
  exit 0
fi

# Build the scan sample. Two sources, depending on the tool:
#
#   Read   — scan the on-disk file content (the bytes about to enter context).
#   Write  — scan the inline content being written; for a NEW file there is
#   Edit     nothing on disk yet, and even for an existing file the agent is
#   MultiEdit introducing the new text, so the payload is what matters. This
#            closes the gap where an innocuously-named PII file (which Layer 1's
#            name check misses) was created via Write and never content-scanned
#            at runtime — only caught later by the commit-time staged scanner.
#
# For write-family tools we pull the inline text out of tool_input: Write has
# .content, Edit has .new_string, MultiEdit has .edits[].new_string. We do NOT
# scan old_string (it is existing content being removed, not introduced).
sample=""
case "$tool_name" in
  Write|Edit|MultiEdit)
    sample="$(printf '%s' "$payload" | jq -r '
      [ .tool_input.content // empty,
        .tool_input.new_string // empty,
        ( .tool_input.edits // [] | .[]?.new_string // empty )
      ] | join("\n")' 2>/dev/null | head -c "$SNIFF_BYTES")"
    ;;
  *)
    # Read (and any other file_path-bearing tool): scan on disk. If the file
    # doesn't exist or isn't readable, exit silently — the tool will fail with
    # its own error and this hook should not preempt that.
    if [[ ! -f "$file_path" || ! -r "$file_path" ]]; then
      exit 0
    fi

    # Skip binary data *exports* — xlsx/parquet/sqlite and friends — where
    # content scanning would just produce noise. Layer 1 (path policy) denies
    # these by name; this is a second guard for the same formats.
    #
    # The skip is gated on the file EXTENSION (pii_is_binary_extension,
    # pii-patterns.sh — shared with pii-staged-scan.sh's own binary skip),
    # not on NUL presence alone. A previous version skipped any file with a
    # NUL in the leading bytes, which was a fail-open bypass: prepending a
    # single NUL to a text file (e.g. notes.txt) made the scanner classify it
    # as binary and skip it, even though the file plainly contained PII. NUL
    # alone is not evidence of a format we should ignore. So only known
    # binary extensions are skipped on NUL; any other file (text extension or
    # none) is scanned regardless of NULs. The sample read uses command
    # substitution, which strips NUL bytes, so the scanned text is clean even
    # when NULs are present.
    ext_lc="$(printf '%s' "${file_path##*.}" | tr '[:upper:]' '[:lower:]')"
    if pii_is_binary_extension "$ext_lc"; then
      head_len_before=$(head -c "$MAX_BINARY_CHECK_BYTES" "$file_path" | wc -c)
      head_len_after=$(head -c "$MAX_BINARY_CHECK_BYTES" "$file_path" | tr -d '\0' | wc -c)
      if [[ "$head_len_before" -ne "$head_len_after" ]]; then
        audit_emit "$payload" allow file_path "$file_path" reason "skip_binary_extension_nul"
        exit 0
      fi
    fi

    sample="$(head -c "$SNIFF_BYTES" "$file_path")"
    ;;
esac

if [[ -z "$sample" ]]; then
  exit 0
fi

# Score the sample once. pii_score_sample (pii-patterns.sh) sets PII_DISTINCT,
# PII_DENSITY_MAX, PII_DENSITY_NAME, PII_DISTINCT_NAMES[], and PII_COUNTS[] —
# the same counting logic pii-staged-scan.sh uses, so runtime and commit-time
# detection cannot silently drift apart.
pii_score_sample "$sample"

# One combined summary instead of a separate log line per pattern — attached
# to whichever audit_emit call below actually fires.
counts_summary=""
n=${#pattern_names[@]}
for ((i=0; i<n; i++)); do
  counts_summary+="${pattern_names[$i]}=${PII_COUNTS[$i]} "
done

deny() {
  local reason="$1"
  audit_emit "$payload" deny file_path "$file_path" reason "$reason" counts "$counts_summary"
  pii_deny_json "$reason. File content matches the PII content-sniff scanner (pii-content-sniff.sh). If this file is genuinely synthetic or public, ask the user to confirm; do not summarise the file content in your response."
  exit 0
}

if [[ "$PII_DISTINCT" -ge "$DISTINCT_TRIP" ]]; then
  # Sort for deterministic log output. Build the array with a while-read loop
  # rather than mapfile or $(...) word-splitting: mapfile needs bash 4 (this
  # hook can run under macOS system bash 3.2), and an unquoted $(...) trips
  # SC2207.
  sorted_distinct=()
  while IFS= read -r line; do
    sorted_distinct+=("$line")
  done < <(printf '%s\n' "${PII_DISTINCT_NAMES[@]}" | sort)
  joined="$(IFS=, ; echo "${sorted_distinct[*]}")"
  deny "PII content detected: $PII_DISTINCT distinct categories ($joined)"
fi

if [[ "$PII_DENSITY_MAX" -ge "$DENSITY_TRIP" ]]; then
  deny "PII content detected: $PII_DENSITY_MAX matches of $PII_DENSITY_NAME (high-confidence pattern)"
fi

# No trip — let the operation proceed.
audit_emit "$payload" allow file_path "$file_path" counts "$counts_summary"
exit 0
