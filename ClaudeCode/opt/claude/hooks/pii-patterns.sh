#!/usr/bin/env bash
# Shared PII pattern definitions. Sourced by pii-content-sniff.sh (PreToolUse
# runtime hook) and pii-staged-scan.sh (pre-commit + CI scanner) so that both
# layers detect the same signals with the same regexes.
#
# This file defines three parallel positional arrays:
#   pattern_names    — short label for each detector (used in logs/output)
#   pattern_regexes  — Perl-compatible regex source (PCRE)
#   pattern_confs    — "high" or "low" confidence rating
#
# Pipe characters (|) inside regexes are why these are parallel positional
# arrays instead of pipe-delimited strings — splitting on | would corrupt any
# regex that uses alternation.
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
  # Inter-segment whitespace constrained to [ \t]+ so the regex cannot span lines.
  '\b[A-Z]{1,2}[0-9][A-Z0-9]?[ \t]+[0-9][A-Z]{2}\b'

  # UK NI number — strict character classes exclude D/F/I/Q/U/V first, O second.
  # Inter-group whitespace constrained to [ \t]? so the regex cannot span lines.
  '\b[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z][ \t]?[0-9]{2}[ \t]?[0-9]{2}[ \t]?[0-9]{2}[ \t]?[A-D]\b'

  # UK phone — +44 prefix or leading 0, allowing optional spaces between digits.
  # Inter-digit whitespace constrained to [ \t]? (single space/tab, not arbitrary
  # whitespace) so the regex cannot stretch across newlines. Negative lookbehind
  # (?<![A-Za-z0-9]) requires a non-alphanumeric boundary before the prefix so
  # the regex cannot start mid-token — without this, `0669719602` matches
  # inside a hex hash like `2a6f0669719602` because there is no \b between two
  # word characters (hex letter and digit both being word chars).
  '(?<![A-Za-z0-9])(?:\+44|0)(?:[ \t]?[0-9]){9,10}\b'

  # IBAN — 2-letter country, 2 check digits, up to 30 alphanumerics.
  '\b[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\b'

  # DOB — d/m/y with 2 or 4-digit year, slash/dash/dot separators.
  '\b(?:0?[1-9]|[12][0-9]|3[01])[\/\-\.](?:0?[1-9]|1[0-2])[\/\-\.](?:19|20)[0-9]{2}\b'

  # 16-digit grouped number — credit-card shaped (4-4-4-4 with space/dash).
  # Inter-group separator constrained to [ \t\-] so a card cannot span lines.
  '\b(?:[0-9]{4}[ \t\-]){3}[0-9]{4}\b'
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
