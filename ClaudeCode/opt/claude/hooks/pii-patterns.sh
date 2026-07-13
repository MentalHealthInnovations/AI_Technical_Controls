#!/usr/bin/env bash
# Shared PII pattern definitions, scan constants, and scoring helpers. Sourced
# by pii-path-policy-check.sh, pii-content-sniff.sh (PreToolUse runtime hooks),
# pii-staged-scan.sh (pre-commit + CI scanner), and run_wild_corpus_cases.sh
# (false-positive guard) so every consumer detects the same signals against
# the same thresholds with one counting implementation.
#
# This file defines three parallel positional arrays:
#   pattern_names    — short label for each detector (used in logs/output)
#   pattern_regexes  — POSIX extended regular expression (awk-compatible)
#   pattern_confs    — "high" or "low" confidence rating
#
# Pipe characters (|) inside regexes are why these are parallel positional
# arrays instead of pipe-delimited strings — splitting on | would corrupt any
# regex that uses alternation.
#
# Regex dialect: POSIX ERE, compatible with mawk (Ubuntu default), busybox awk
# (Alpine default), and BWK awk (macOS default). Specifically, this means:
#
#   - No \b word boundaries. Where a boundary is needed, alternate with
#     (^|[^A-Za-z0-9]) at the start and ([^A-Za-z0-9]|$) at the end. The
#     boundary character ends up inside the match. Consumers therefore count
#     with pii_count_matches()'s match()/RSTART/RLENGTH loop, NOT gsub() —
#     gsub would consume the trailing boundary and undercount two adjacent
#     items as one. The match string in diagnostics still includes one
#     wrapping character on either side.
#   - No PCRE shortcuts: no \d (use [0-9]), no \s (use [ \t]), no lookaround.
#   - No non-capturing groups (?:...). awk has no capture-group cost for the
#     count use case, so regular groups (...) work fine.
#   - Backslash-escaped metacharacters like \+ and \. must be expressed as
#     character classes ([+] and [.]). The patterns are passed to awk via
#     `awk -v r="$regex"`, which goes through one round of shell-style string
#     interpretation that strips a single backslash before the regex engine
#     ever sees it. \+ becomes a bare + (illegal as a leading quantifier),
#     and \. silently degrades to "any character". Character-class syntax
#     bypasses this by needing no backslash at all.
#
# Confidence levels:
#   high — robust enough to trip a single-pattern density threshold on its own
#          (low false-positive risk on technical content).
#   low  — only contributes to a multi-category distinct threshold; on its own
#          it would produce too many false positives (e.g. dates in code).
#
# To add a new pattern, append one entry to each of the three arrays. Keep
# the arrays the same length — every consumer iterates by index via
# pii_score_sample().
#
# bash 3.2 compatible (macOS system bash). No associative arrays, no
# namerefs — pii_score_sample() below reports results via plain globals,
# the same idiom the pattern arrays themselves already use.
#
# shellcheck disable=SC2034  # arrays/constants are consumed by sourcing files

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
  # No word boundary needed at either end: usernames and domains are
  # self-delimiting via the literal @ and the .TLD suffix.
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}'

  # UK postcode — 1-2 letters, 1-2 digits (optional trailing letter), space, digit, 2 letters.
  # Inter-segment whitespace constrained to [ \t]+ so the regex cannot span lines.
  # Word boundaries replaced by (^|[^A-Za-z0-9]) and ([^A-Za-z0-9]|$) for awk.
  # Lowercase-only letter classes: pii_score_sample() lowercases the sample
  # before matching (see below), so a lowercase postcode is caught too. None
  # of mawk/busybox-awk/BWK-awk support IGNORECASE (that's a gawk extension),
  # so case-folding the input is the only portable option.
  '(^|[^A-Za-z0-9])[a-z]{1,2}[0-9][a-z0-9]?[ \t]+[0-9][a-z]{2}([^A-Za-z0-9]|$)'

  # UK NI number — strict character classes exclude D/F/I/Q/U/V first, O second.
  # Inter-group whitespace constrained to [ \t]? so the regex cannot span lines.
  # Lowercase-only, matching the pre-lowercased sample (see UK_POSTCODE above).
  '(^|[^A-Za-z0-9])[a-ceghj-pr-tw-z][a-ceghj-npr-tw-z][ \t]?[0-9]{2}[ \t]?[0-9]{2}[ \t]?[0-9]{2}[ \t]?[a-d]([^A-Za-z0-9]|$)'

  # UK phone — +44 prefix or leading 0, allowing optional spaces between digits.
  # Inter-digit whitespace constrained to [ \t]? (single space/tab, not arbitrary
  # whitespace) so the regex cannot stretch across newlines. Leading
  # (^|[^A-Za-z0-9]) prevents the regex from starting mid-token (originally a
  # PCRE negative lookbehind; awk-portable replacement consumes the boundary
  # character). Trailing ([^0-9]|$) replaces \b at the digit-string end.
  '(^|[^A-Za-z0-9])([+]44|0)([ \t]?[0-9]){9,10}([^0-9]|$)'

  # IBAN — 2-letter country, 2 check digits, up to 30 alphanumerics. Optional
  # single spaces/tabs between characters cover the ISO 13616 human-readable
  # form ("GB29 NWBK 6016 1331 9268 19") as well as the compact form. The
  # body ([a-z0-9]) keeps spaced prose from matching, since the trailing
  # boundary must follow 11-30 alphanumerics. [ \t]* (not \s) so the match
  # cannot span newlines. Lowercase-only, matching the pre-lowercased sample.
  '(^|[^A-Za-z0-9])[a-z]{2}[0-9]{2}([ \t]*[a-z0-9]){11,30}([^A-Za-z0-9]|$)'

  # DOB — d/m/y with 2 or 4-digit year, slash/dash/dot separators.
  '(^|[^A-Za-z0-9])(0?[1-9]|[12][0-9]|3[01])[/.-](0?[1-9]|1[0-2])[/.-](19|20)[0-9]{2}([^A-Za-z0-9]|$)'

  # 16-digit grouped number — credit-card shaped (4-4-4-4 with space/dash).
  # Inter-group separator constrained to [ \t-] so a card cannot span lines.
  '(^|[^A-Za-z0-9])([0-9]{4}[ \t-]){3}[0-9]{4}([^A-Za-z0-9]|$)'
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

# Shared scan constants. Single source of truth for every consumer so runtime
# detection (pii-content-sniff.sh) and commit-time detection
# (pii-staged-scan.sh) cannot silently drift apart — both scripts' headers
# assert "thresholds match"; this is what makes that true rather than aspirational.
SNIFF_BYTES=65536
DISTINCT_TRIP=3
DENSITY_TRIP=10
MAX_BINARY_CHECK_BYTES=1024

# pii_count_matches SAMPLE REGEX
# Prints the number of matches of REGEX in SAMPLE.
#
# Uses a match()/RSTART/RLENGTH loop rather than gsub() counting: gsub()
# consumes each match's boundary character, so two PII items separated by a
# single non-alphanumeric char (e.g. "SW1A 2AA SW1A 2AA") count as one — the
# first match eats the space the second needs as its leading boundary. The
# loop instead re-scans from RSTART+RLENGTH-1, one char before the match end,
# so that consumed trailing boundary is available again as the next match's
# leading boundary. This counts adjacent matches correctly and cannot
# undercount the density threshold. (All patterns match >=2 chars, so the -1
# rewind still guarantees forward progress and cannot loop forever.)
#
# Passing the regex via -v is safer than shell-substituting into a quoted
# script body: no escape issues with $, ", or backslashes.
pii_count_matches() {
  local sample="$1" regex="$2" count
  # PII_SAMPLE="$sample" scopes the env var to just this one awk invocation
  # (a POSIX "simple command" environment assignment), read back via
  # ENVIRON in a BEGIN-only program (no main pattern-action rule, so awk
  # never touches stdin) — one process instead of two per pattern.
  #
  # This is NOT the same as `awk -v s="$sample" ...`: verified directly that
  # BWK awk (macOS's /usr/bin/awk, one of this file's three target
  # implementations) hard-errors ("newline in string") on any -v assignment
  # whose value contains a literal newline, silently producing an empty
  # command-substitution result and a false "0 matches" for every multi-line
  # sample. ENVIRON has no such restriction: the value is read at runtime,
  # never lexed as a source-level string literal.
  count="$(PII_SAMPLE="$sample" awk -v r="$regex" 'BEGIN{s=ENVIRON["PII_SAMPLE"]; c=0; while (match(s,r)>0) {c++; adv=RSTART+RLENGTH-1; if (adv<1) adv=1; s=substr(s,adv)}; print c+0}' 2>/dev/null)"
  [[ -z "$count" ]] && count=0
  printf '%s' "$count"
}

# pii_score_sample SAMPLE
# Scores SAMPLE against every pattern in pattern_names/pattern_regexes/
# pattern_confs. bash 3.2 has no namerefs and no associative arrays, so
# results are reported via plain globals — the same return-by-global idiom
# the pattern arrays above already use:
#   PII_DISTINCT          — number of categories with >=1 hit
#   PII_DENSITY_MAX        — highest count among high-confidence categories
#   PII_DENSITY_NAME        — name of the pattern that produced PII_DENSITY_MAX
#   PII_DISTINCT_NAMES[]     — "NAME=count" entries, one per category with a hit
#   PII_COUNTS[]             — every pattern's count, parallel to pattern_names,
#                              for callers that need per-pattern diagnostics
#                              (e.g. the content-sniff log and the wild-corpus
#                              table) without re-scanning the sample.
pii_score_sample() {
  # Case-fold once, up front: UK_POSTCODE, UK_NI, and IBAN match lowercase-only
  # character classes (see pii-patterns.sh above) so a lowercase postcode or NI
  # number isn't invisible to the scanner. EMAIL/DOB/UK_PHONE/CARD_GROUPED are
  # unaffected (digits, or already accept both cases), so folding them too is
  # a harmless no-op.
  local sample
  sample="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  PII_DISTINCT=0
  PII_DENSITY_MAX=0
  PII_DENSITY_NAME=""
  PII_DISTINCT_NAMES=()
  PII_COUNTS=()
  local n="${#pattern_names[@]}"
  local i name regex conf count
  for ((i=0; i<n; i++)); do
    name="${pattern_names[$i]}"
    regex="${pattern_regexes[$i]}"
    conf="${pattern_confs[$i]}"
    count="$(pii_count_matches "$sample" "$regex")"
    PII_COUNTS+=("$count")
    if [[ "$count" -gt 0 ]]; then
      PII_DISTINCT=$((PII_DISTINCT + 1))
      PII_DISTINCT_NAMES+=("$name=$count")
      if [[ "$conf" == "high" && "$count" -gt "$PII_DENSITY_MAX" ]]; then
        PII_DENSITY_MAX="$count"
        PII_DENSITY_NAME="$name"
      fi
    fi
  done
}

# pii_deny_json REASON
# Emits the PreToolUse deny envelope Claude Code expects, with REASON as the
# permissionDecisionReason. Shared by both PII PreToolUse hooks
# (pii-path-policy-check.sh, pii-content-sniff.sh) so the response shape
# lives in one place instead of two near-identical jq invocations.
pii_deny_json() {
  jq -n --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
}

# Extensions treated as "binary formats we should not content-scan" — data
# exports (xlsx, sqlite, parquet) and other non-text formats where pattern
# matching would just produce noise. Layer 1 (pii-path-policy-check.sh)
# already denies these by name; this only governs the content-scan skip in
# pii-content-sniff.sh and pii-staged-scan.sh, shared here so adding a format
# is one edit instead of two.
PII_BINARY_EXTENSIONS=(xlsx xls parquet avro sqlite db bin gz zip tar png jpg jpeg gif pdf so dylib o)

# pii_is_binary_extension EXT_LC
# Returns success if EXT_LC (already lowercased, no leading dot) is a known
# binary-format extension.
pii_is_binary_extension() {
  local ext="$1" candidate
  for candidate in "${PII_BINARY_EXTENSIONS[@]}"; do
    [[ "$ext" == "$candidate" ]] && return 0
  done
  return 1
}

# Paths that are deliberately synthetic PII test infrastructure, exempt from
# BOTH the runtime content-sniff hook and the commit-time staged scanner.
# Keep this list narrow — anything broader risks creating a safe-harbour zone
# for accidental PII. This deliberately does NOT include
# fixtures/cases/fixtures/pii-content/ (the content-sniff detection fixtures)
# or fixtures/pii-content-wild/ (the false-positive guard): both must still
# trip (or not trip) the runtime hook normally, since that is what their own
# test suites verify. pii-staged-scan.sh excludes pii-content/ separately,
# below, for commit-time purposes only — see its own EXTRA prefix argument.
PII_EXCLUDE_PREFIXES=(
  # The staged-scan test runner embeds synthetic PII inline to drive the
  # scanner against temporary git repos. Its values are fictional (example.test
  # addresses, Ofcom reserved phone range, canonical example IBAN/postcode).
  # pii-content-sniff.sh also needs this excluded: without it, a Read of this
  # very file trips a deny (its inline test fixtures ARE PII-shaped text).
  "ClaudeCode/tests/run_staged_scan_cases.sh"
  # The JSONL case file for pii-content-sniff.sh's own test suite carries the
  # Write/Edit/MultiEdit content-scan cases' input payloads inline (same
  # reason as run_staged_scan_cases.sh above) — its own fictional email/
  # postcode/phone values are what those test cases scan for.
  "ClaudeCode/tests/cases/pii-content-sniff.jsonl"
)

# pii_path_excluded PATH [EXTRA_PREFIX...]
# Returns success (0) if PATH is under one of PII_EXCLUDE_PREFIXES or any of
# the optional EXTRA_PREFIX arguments. Callers pass EXTRA_PREFIX for
# exclusions that apply only in their own context — e.g. pii-staged-scan.sh
# additionally excludes the pii-content/ fixture directory (so committing the
# intentional-PII detection fixtures doesn't fail CI), which
# pii-content-sniff.sh must NOT exclude, since its own test suite verifies
# that reading those exact fixtures is denied.
#
# PATH may be either repo-relative (as pii-staged-scan.sh gets from `git diff
# --cached --name-only`) or an absolute filesystem path (as
# pii-content-sniff.sh resolves file_path to) — this hook runs against any
# repo Claude Code happens to be working in, not just this one, so an
# absolute path is matched by checking whether one of its ancestor segments
# lines up with the prefix, not by trying to compute a repo root. An entry
# ending in "/" is a directory prefix; without a trailing "/" it is an exact
# path (matched the same way, anchored at the end instead of the start).
pii_path_excluded() {
  local path="$1"; shift
  local prefix
  for prefix in "${PII_EXCLUDE_PREFIXES[@]}" "$@"; do
    if [[ "$prefix" == */ ]]; then
      if [[ "$path" == "$prefix"* || "$path" == *"/$prefix"* ]]; then
        return 0
      fi
    elif [[ "$path" == "$prefix" || "$path" == *"/$prefix" ]]; then
      return 0
    fi
  done
  return 1
}
