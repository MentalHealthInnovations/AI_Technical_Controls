#!/usr/bin/env bash
# PreToolUse hook for Read. Content-sniff layer of the PII controls.
#
# Reads up to SNIFF_BYTES from the target file and regex-scans for PII
# signatures (emails, UK postcodes, UK phone numbers, UK National Insurance
# numbers, dates of birth, IBANs, 16-digit card-like sequences). If the
# content crosses one of two thresholds — distinct categories or single-
# category density — the Read is denied via hookSpecificOutput.
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

logtofile() {
  echo "[$(date)] [pii-content-sniff] [$(pwd)] $1" >> "$HOOK_LOG"
}
HOOK_LOG="$HOME/.claude/debug/pii-content-sniff.log"

payload="$(cat)"
file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"

if [[ -z "$file_path" ]]; then
  exit 0
fi

# Resolve path. Claude Code passes absolute paths but be defensive against
# relative ones for local-test purposes.
if [[ "$file_path" != /* ]]; then
  file_path="$(pwd)/$file_path"
fi

# If the file doesn't exist or isn't readable, exit silently — the Read tool
# will fail with its own error and this hook should not preempt that.
if [[ ! -f "$file_path" || ! -r "$file_path" ]]; then
  exit 0
fi

# Skip obvious binaries. Layer 1 (path policy) is the right place for binary
# data exports — content scanning xlsx/parquet/sqlite would just produce noise.
# Heuristic: any NUL byte in the leading MAX_BINARY_CHECK_BYTES classifies
# the file as binary. Done by stripping all NULs with `tr -d '\0'` and
# comparing byte counts before vs after — `grep $'\x00'` cannot be used
# because shell-level NUL terminates the C-string argument.
head_len_before=$(head -c "$MAX_BINARY_CHECK_BYTES" "$file_path" | wc -c)
head_len_after=$(head -c "$MAX_BINARY_CHECK_BYTES" "$file_path" | tr -d '\0' | wc -c)
if [[ "$head_len_before" -ne "$head_len_after" ]]; then
  logtofile "skip binary (NUL detected): $file_path"
  exit 0
fi

# Read sample.
sample="$(head -c "$SNIFF_BYTES" "$file_path")"
if [[ -z "$sample" ]]; then
  exit 0
fi

# Pattern table — three parallel arrays so that pipe characters (|) inside
# regexes don't collide with a field-separator. Each index across the three
# arrays describes one detector. To add a new pattern, append one entry to
# each array. CONFIDENCE: "high" patterns are robust enough to trip
# DENSITY_TRIP on their own; "low" patterns only count toward DISTINCT_TRIP.
pattern_names=(
  "EMAIL"
  "UK_POSTCODE"
  "UK_NI"
  "UK_PHONE"
  "IBAN"
  "DOB"
  "CARD_GROUPED"
)
pattern_regexes=(
  # Email — RFC 5322 lite. High confidence; trivially recognisable.
  '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}'

  # UK postcode — 1-2 letters, 1-2 digits (optional trailing letter), space, digit, 2 letters.
  '\b[A-Z]{1,2}[0-9][A-Z0-9]?\s+[0-9][A-Z]{2}\b'

  # UK NI number — strict character classes exclude D/F/I/Q/U/V first, O second.
  '\b[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z]\s?[0-9]{2}\s?[0-9]{2}\s?[0-9]{2}\s?[A-D]\b'

  # UK phone — +44 prefix or leading 0, allowing optional spaces between digits.
  '(?:\+44|0)(?:\s?[0-9]){9,10}\b'

  # IBAN — 2-letter country, 2 check digits, up to 30 alphanumerics.
  '\b[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\b'

  # DOB — d/m/y with 2 or 4-digit year, slash/dash/dot separators.
  '\b(?:0?[1-9]|[12][0-9]|3[01])[\/\-\.](?:0?[1-9]|1[0-2])[\/\-\.](?:19|20)[0-9]{2}\b'

  # 16-digit grouped number — credit-card shaped (4-4-4-4 with space/dash).
  '\b(?:[0-9]{4}[\s\-]){3}[0-9]{4}\b'
)
pattern_confs=(
  "high"
  "high"
  "high"
  "high"
  "high"
  "low"
  "low"
)

# Match each pattern via Perl and aggregate hits.
#
# Note: bash 3.2 (the macOS system bash) lacks associative arrays, so we
# track results inline rather than building a name→count map.
distinct=0
density_max=0
density_name=""
distinct_names=()
n=${#pattern_names[@]}
for ((i=0; i<n; i++)); do
  name="${pattern_names[$i]}"
  regex="${pattern_regexes[$i]}"
  conf="${pattern_confs[$i]}"
  count="$(printf '%s' "$sample" | perl -ne 'BEGIN{$c=0} while(/'"$regex"'/g){$c++} END{print $c}' 2>>"$HOOK_LOG")"
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
  # Sort for deterministic log output.
  IFS=$'\n' sorted_distinct=($(sort <<<"${distinct_names[*]}"))
  unset IFS
  joined="$(IFS=, ; echo "${sorted_distinct[*]}")"
  deny "PII content detected: $distinct distinct categories ($joined)"
fi

if [[ "$density_max" -ge "$DENSITY_TRIP" ]]; then
  deny "PII content detected: $density_max matches of $density_name (high-confidence pattern)"
fi

# No trip — let the Read proceed.
exit 0
