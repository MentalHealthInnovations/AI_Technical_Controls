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

# Shared pattern definitions, sourced from the file deployed alongside this
# hook. Defines pattern_names, pattern_regexes, pattern_confs (three parallel
# positional arrays). Updates to detectors live in pii-patterns.sh so this
# hook and the pre-commit scanner detect the same signals.
script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=pii-patterns.sh
. "$script_dir/pii-patterns.sh"

# Match each pattern via awk's gsub (POSIX ERE) and aggregate hits.
#
# Why awk, not perl: perl is not in the busybox/Alpine base, which means the
# previous perl-based implementation forced a perl install in every minimal
# environment. awk is POSIX-mandated and present in every base distribution
# including Alpine (busybox awk). The regex set in pii-patterns.sh was
# migrated to POSIX ERE at the same time — see that file for dialect notes.
#
# gsub(regex, replacement) returns the number of substitutions, which is what
# we want as a count. Passing the regex via -v is safer than shell-substituting
# into a quoted script body: no escape issues with $, ", or backslashes.
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
  count="$(printf '%s' "$sample" | awk -v r="$regex" 'BEGIN{c=0} {c+=gsub(r,"&")} END{print c+0}' 2>>"$HOOK_LOG")"
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
