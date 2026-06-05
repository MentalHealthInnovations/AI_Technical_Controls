#!/usr/bin/env bash
# Shared PII pattern definitions. Sourced by pii-content-sniff.sh (PreToolUse
# runtime hook) and pii-staged-scan.sh (pre-commit + CI scanner) so that both
# layers detect the same signals with the same regexes.
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
#     boundary character ends up inside the match — fine for counting via
#     gsub(), but the match string in diagnostics will include one wrapping
#     character on either side.
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
# the arrays the same length — both consumers iterate by index.
#
# bash 3.2 compatible (macOS system bash). No associative arrays, no namerefs.
#
# shellcheck disable=SC2034  # arrays are consumed by sourcing files (sniff/scan)

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
  '(^|[^A-Za-z0-9])[A-Z]{1,2}[0-9][A-Z0-9]?[ \t]+[0-9][A-Z]{2}([^A-Za-z0-9]|$)'

  # UK NI number — strict character classes exclude D/F/I/Q/U/V first, O second.
  # Inter-group whitespace constrained to [ \t]? so the regex cannot span lines.
  '(^|[^A-Za-z0-9])[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z][ \t]?[0-9]{2}[ \t]?[0-9]{2}[ \t]?[0-9]{2}[ \t]?[A-D]([^A-Za-z0-9]|$)'

  # UK phone — +44 prefix or leading 0, allowing optional spaces between digits.
  # Inter-digit whitespace constrained to [ \t]? (single space/tab, not arbitrary
  # whitespace) so the regex cannot stretch across newlines. Leading
  # (^|[^A-Za-z0-9]) prevents the regex from starting mid-token (originally a
  # PCRE negative lookbehind; awk-portable replacement consumes the boundary
  # character). Trailing ([^0-9]|$) replaces \b at the digit-string end.
  '(^|[^A-Za-z0-9])([+]44|0)([ \t]?[0-9]){9,10}([^0-9]|$)'

  # IBAN — 2-letter country, 2 check digits, up to 30 alphanumerics.
  '(^|[^A-Za-z0-9])[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}([^A-Za-z0-9]|$)'

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
