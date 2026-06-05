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
# PII that the name did not. The two layers are independent and registered
# separately in managed-settings.json so either can be tuned in isolation.
#
# Tuning:
#   SNIFF_BYTES    — how much of the file to scan. Larger = more accurate,
#                    slower on big files. Default 65536 (64 KiB).
#   DISTINCT_TRIP  — number of distinct categories that triggers a deny.
#   DENSITY_TRIP   — number of matches of a single high-confidence pattern
#                    that triggers a deny on its own.
#
# To add a new pattern:
#   Add an entry to the `patterns` array as "NAME|REGEX|CONFIDENCE" where
#   CONFIDENCE is "high" (counts toward density trip) or "low" (only counts
#   toward distinct-category trip). High-confidence patterns are those
#   unlikely to produce false positives on technical content.
set -u

SNIFF_BYTES=65536
DISTINCT_TRIP=3
DENSITY_TRIP=10
MAX_BINARY_CHECK_BYTES=1024

HOOK_LOG="$HOME/.claude/debug/pii-content-sniff.log"
# Ensure the log directory exists before any redirect targets $HOOK_LOG.
# Without this, on first run in any environment where ~/.claude/debug/ has
# not been created yet, bash's `>> "$HOOK_LOG"` redirect fails and breaks
# the surrounding pipeline — silently zeroing every pattern count.
mkdir -p "$(dirname "$HOOK_LOG")" 2>/dev/null || true
logtofile() {
  echo "[$(date)] [pii-content-sniff] [$(pwd)] $1" >> "$HOOK_LOG"
}

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
    # The skip is gated on the file EXTENSION, not on NUL presence alone. A
    # previous version skipped any file with a NUL in the leading bytes, which
    # was a fail-open bypass: prepending a single NUL to a text file (e.g.
    # notes.txt) made the scanner classify it as binary and skip it, even
    # though the file plainly contained PII. NUL alone is not evidence of a
    # format we should ignore. So only the known binary extensions below are
    # skipped on NUL; any other file (text extension or none) is scanned
    # regardless of NULs. The sample read uses command substitution, which
    # strips NUL bytes, so the scanned text is clean even when NULs are present.
    ext_lc="$(printf '%s' "${file_path##*.}" | tr '[:upper:]' '[:lower:]')"
    case "$ext_lc" in
      xlsx|xls|parquet|avro|sqlite|db|bin|gz|zip|tar|png|jpg|jpeg|gif|pdf|so|dylib|o)
        head_len_before=$(head -c "$MAX_BINARY_CHECK_BYTES" "$file_path" | wc -c)
        head_len_after=$(head -c "$MAX_BINARY_CHECK_BYTES" "$file_path" | tr -d '\0' | wc -c)
        if [[ "$head_len_before" -ne "$head_len_after" ]]; then
          logtofile "skip binary (binary extension + NUL detected): $file_path"
          exit 0
        fi
        ;;
    esac

    sample="$(head -c "$SNIFF_BYTES" "$file_path")"
    ;;
esac

if [[ -z "$sample" ]]; then
  exit 0
fi

# Shared pattern definitions, sourced from the file deployed alongside this
# hook. Defines pattern_names, pattern_regexes, pattern_confs (three parallel
# positional arrays). Updates to detectors live in pii-patterns.sh so this
# hook and the pre-commit scanner detect the same signals.
script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=pii-patterns.sh
. "$script_dir/pii-patterns.sh"

# Match each pattern via awk's match() (POSIX ERE) and aggregate hits.
#
# We loop with match()/RSTART/RLENGTH rather than gsub() counting. gsub()
# replaces each match including its consumed boundary character, so two PII
# items separated by a single non-alphanumeric char (e.g. "SW1A 2AA SW1A 2AA")
# count as one — the first match eats the space that the second needs as its
# leading boundary. The loop instead re-scans from RSTART+RLENGTH-1, one char
# before the match end, so that consumed trailing boundary is available again
# as the next match's leading boundary. This counts adjacent matches correctly
# and cannot undercount the density threshold. (All patterns match >=2 chars,
# so the -1 rewind still guarantees forward progress and cannot loop forever.)
#
# Passing the regex via -v is safer than shell-substituting into a quoted
# script body: no escape issues with $, ", or backslashes.
#
# bash 3.2 (the macOS system bash) lacks associative arrays, so we track
# results inline rather than building a name→count map.
distinct=0
density_max=0
density_name=""
distinct_names=()
n=${#pattern_names[@]}
for ((i=0; i<n; i++)); do
  name="${pattern_names[$i]}"
  regex="${pattern_regexes[$i]}"
  conf="${pattern_confs[$i]}"
  count="$(printf '%s' "$sample" | awk -v r="$regex" 'BEGIN{c=0} {s=$0; while (match(s,r)>0) {c++; adv=RSTART+RLENGTH-1; if (adv<1) adv=1; s=substr(s,adv)}} END{print c+0}' 2>/dev/null)"
  if [[ -z "$count" ]]; then
    count=0
  fi
  logtofile "pattern $name conf=$conf count=$count"
  if [[ "$count" -gt 0 ]]; then
    distinct=$((distinct + 1))
    distinct_names+=("$name=$count")
    if [[ "$conf" == "high" && "$count" -gt "$density_max" ]]; then
      density_max="$count"
      density_name="$name"
    fi
  fi
done

deny() {
  local reason="$1"
  logtofile "DENY $reason: $file_path"
  jq -n --arg reason "$reason. File content matches the PII content-sniff scanner (pii-content-sniff.sh). If this file is genuinely synthetic or public, ask the user to confirm; do not summarise the file content in your response." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

if [[ "$distinct" -ge "$DISTINCT_TRIP" ]]; then
  # Sort for deterministic log output. Build the array with a while-read loop
  # rather than mapfile or $(...) word-splitting: mapfile needs bash 4 (this
  # hook can run under macOS system bash 3.2), and an unquoted $(...) trips
  # SC2207.
  sorted_distinct=()
  while IFS= read -r line; do
    sorted_distinct+=("$line")
  done < <(printf '%s\n' "${distinct_names[@]}" | sort)
  joined="$(IFS=, ; echo "${sorted_distinct[*]}")"
  deny "PII content detected: $distinct distinct categories ($joined)"
fi

if [[ "$density_max" -ge "$DENSITY_TRIP" ]]; then
  deny "PII content detected: $density_max matches of $density_name (high-confidence pattern)"
fi

# No trip — let the Read proceed.
exit 0
