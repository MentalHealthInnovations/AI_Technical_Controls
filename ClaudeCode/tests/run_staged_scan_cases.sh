#!/usr/bin/env bash
# Tests for pii-staged-scan.sh.
#
# The scanner reads its input from `git show :path`, so unit-testing it
# requires actual staged files in a git index. This script:
#
#   1. Creates a throwaway git repo under $TMPDIR (or /tmp if unset),
#      independent of the host repo so the host index is never touched.
#   2. Copies the scanner and its sourced patterns file into the temp repo.
#   3. For each test case, writes fixture content, stages it, runs the scanner,
#      compares exit status and stderr against expectations.
#   4. Cleans up the temp repo.
#
# Exit non-zero if any case fails.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
scanner_src="$repo_root/ClaudeCode/scripts/pii-staged-scan.sh"
patterns_src="$repo_root/ClaudeCode/opt/claude/hooks/pii-patterns.sh"

if [[ ! -x "$scanner_src" ]]; then
  echo "Missing or non-executable scanner: $scanner_src" >&2
  exit 2
fi

tmp_root="${TMPDIR:-/tmp}"
mkdir -p "$tmp_root"
sandbox="$(mktemp -d "$tmp_root/pii-staged-scan-test.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT

# Mirror the repo's directory layout so the scanner can resolve the patterns
# file via its `script_dir/../opt/claude/hooks/pii-patterns.sh` path.
mkdir -p "$sandbox/ClaudeCode/scripts"
mkdir -p "$sandbox/ClaudeCode/opt/claude/hooks"
cp "$scanner_src" "$sandbox/ClaudeCode/scripts/pii-staged-scan.sh"
cp "$patterns_src" "$sandbox/ClaudeCode/opt/claude/hooks/pii-patterns.sh"
chmod +x "$sandbox/ClaudeCode/scripts/pii-staged-scan.sh"

cd "$sandbox"
git init -q
git config user.email "test@example.test"
git config user.name "Test"

scanner="$sandbox/ClaudeCode/scripts/pii-staged-scan.sh"

fail=0
total=0

# stage_and_scan <test-name> <expect-exit> <path> <content>
# Writes content to path inside the sandbox, stages it, runs the scanner
# against just that one path, and compares exit status.
stage_and_scan() {
  local name="$1" expect="$2" path="$3" content="$4"
  total=$((total + 1))
  mkdir -p "$(dirname "$path")"
  printf '%s' "$content" > "$path"
  git add "$path" 2>/dev/null
  set +e
  "$scanner" "$path" >/dev/null 2>&1
  local rc=$?
  set -e 2>/dev/null || true
  if [[ "$rc" -eq "$expect" ]]; then
    printf 'PASS  %-55s rc=%d\n' "$name" "$rc"
  else
    printf 'FAIL  %-55s expected=%d actual=%d\n' "$name" "$expect" "$rc"
    fail=$((fail + 1))
  fi
  # Tidy: drop the file from the index so the next case starts clean.
  git rm -f --quiet --cached -- "$path" 2>/dev/null
  rm -f "$path"
}

# stage_and_scan_raw <test-name> <expect-exit> <path> <printf-fmt> [args...]
# Like stage_and_scan, but the content is written to disk with a redirected
# printf using the given format/args, never captured into a bash variable
# (not even via command substitution) first. bash scalars cannot hold an
# embedded NUL byte — they are C strings internally, and this holds for
# command-substitution results too, not just plain assignment — so any
# content with a real NUL must be constructed this way, never passed as a
# $content string parameter the way stage_and_scan's other callers do.
stage_and_scan_raw() {
  local name="$1" expect="$2" path="$3"
  shift 3
  total=$((total + 1))
  mkdir -p "$(dirname "$path")"
  # shellcheck disable=SC2059  # the format string IS the caller-supplied
  # content, by design — that's how a literal NUL byte reaches the file.
  printf "$@" > "$path"
  git add "$path" 2>/dev/null
  set +e
  "$scanner" "$path" >/dev/null 2>&1
  local rc=$?
  set -e 2>/dev/null || true
  if [[ "$rc" -eq "$expect" ]]; then
    printf 'PASS  %-55s rc=%d\n' "$name" "$rc"
  else
    printf 'FAIL  %-55s expected=%d actual=%d\n' "$name" "$expect" "$rc"
    fail=$((fail + 1))
  fi
  git rm -f --quiet --cached -- "$path" 2>/dev/null
  rm -f "$path"
}

# ── Test cases ───────────────────────────────────────────────────────────────

# Clean files — exit 0.
stage_and_scan "clean markdown" 0 \
  "docs/intro.md" \
  "# Title

Plain prose, no PII signals.
"

stage_and_scan "clean source code" 0 \
  "src/main.go" \
  "package main

import \"fmt\"

func main() { fmt.Println(\"hi\") }
"

stage_and_scan "single email below thresholds" 0 \
  "docs/contact.md" \
  "Reach support at support@example.test for help.
"

# Trip cases — exit 1.
stage_and_scan "three distinct PII categories trips" 1 \
  "data/leak.md" \
  "Email: alex@example.test
Postcode: SW1A 1AA
Phone: +44 20 7946 0000
"

stage_and_scan "11 emails trips density" 1 \
  "data/many-emails.txt" \
  "$(printf 'synthetic-%d@example.test\n' {1..11})"

stage_and_scan "NI + postcode + phone trips" 1 \
  "data/uk.md" \
  "NI: AB 12 34 56 C
Postcode: EC1A 1BB
Phone: +44 20 7946 0000
"

# Excluded path — even with clear PII, the scanner must skip the pii-content/
# fixture directory (it exists specifically to hold PII-shaped detection
# fixtures for pii-content-sniff.sh's own test suite).
stage_and_scan "PII inside excluded pii-content/ fixtures path is skipped" 0 \
  "ClaudeCode/tests/cases/fixtures/pii-content/synthetic.md" \
  "Email: alex@example.test
Postcode: SW1A 1AA
Phone: +44 20 7946 0000
"

# Regression: the exclusion is scoped to pii-content/ specifically, not the
# whole fixtures/ tree — a file directly under fixtures/ (not pii-content/)
# must still trip. (Before this fix, EXCLUDE_PREFIXES was the broad
# "ClaudeCode/tests/cases/fixtures/" prefix, which silently exempted this
# path — and pii-content-wild/ below it — from ever being scanned.)
stage_and_scan "regression (narrowed exclusion): fixtures/ root (not pii-content/) still trips" 1 \
  "ClaudeCode/tests/cases/fixtures/synthetic-not-excluded.md" \
  "Email: alex@example.test
Postcode: SW1A 1AA
Phone: +44 20 7946 0000
"

# Regression: pii-content-wild/ is a false-positive guard that must be
# scanned normally — see its MANIFEST.md, which asserts it is "not excluded".
stage_and_scan "regression (wild-corpus not silently excluded): pii-content-wild/ still trips" 1 \
  "ClaudeCode/tests/cases/fixtures/pii-content-wild/synthetic-leak.fragment" \
  "Email: alex@example.test
Postcode: SW1A 1AA
Phone: +44 20 7946 0000
"

# The exact-path exclusion for this test runner itself (shared with
# pii-content-sniff.sh via PII_EXCLUDE_PREFIXES in pii-patterns.sh) — its own
# inline test payloads above are PII-shaped text that must not block a commit
# touching this file.
stage_and_scan "excluded exact path: run_staged_scan_cases.sh itself is skipped" 0 \
  "ClaudeCode/tests/run_staged_scan_cases.sh" \
  "Email: alex@example.test
Postcode: SW1A 1AA
Phone: +44 20 7946 0000
"

# Binary file (.bin extension + real NUL byte) — skipped by extension plus
# git's own binary classification (see stage_and_scan_raw's comment for why
# this can't use a bash $content variable the way every other case here does).
#
# Regression: an earlier version of this test used a $'\x00...' bash
# variable for the binary content. bash truncates a scalar at its first NUL
# byte at the moment of assignment (not just on capture via command
# substitution), so that variable was silently empty from the start — the
# "file" staged was 0 bytes, and the test passed because
# `[[ -z "$sample" ]] && return 0` caught an empty sample, not because any
# binary detection fired. This version writes the NUL directly to disk via
# printf's redirect, which is unaffected by that limitation, so the file
# genuinely contains a leading NUL plus PII-shaped text and this test
# actually exercises the extension + git-binary-classification check.
stage_and_scan_raw "binary file with embedded PII is skipped" 0 \
  "data/binary.bin" \
  '\000\001\002fake-binary-payload alex@example.test SW1A 1AA +44 20 7946 0000'

# Sub-threshold cases.
stage_and_scan "two categories - below distinct trip" 0 \
  "docs/partial.md" \
  "Email: alex@example.test
Postcode: SW1A 1AA
"

stage_and_scan "one IBAN only - no trip" 0 \
  "docs/iban.md" \
  "GB29NWBK60161331926819 is a synthetic IBAN.
"

stage_and_scan "two low-confidence categories (DOB+card)" 0 \
  "docs/lowconf.md" \
  "01/02/1990 and 4111 1111 1111 1111
"

# ── Regression guards for detection gaps fixed in review. Each previously
#    failed (the scanner exited 0 on real PII); the listed fix makes it trip. ──

# Spaced IBANs: the IBAN regex now allows optional whitespace between
# characters, so the ISO 13616 human-readable space-grouped form trips. (Before
# the fix the regex required contiguous alphanumerics and matched 0.)
stage_and_scan "regression (spaced IBAN fixed): 12 spaced IBANs trip" 1 \
  "data/ibans.md" \
  "$(printf 'GB29 NWBK 6016 1331 9268 19\n%.0s' {1..12})"

# Adjacency undercount: the consumers now count with a match()/RSTART/RLENGTH
# loop instead of gsub(), so adjacent items no longer share a consumed boundary.
# 18 space-separated postcodes now count as 18 (>= density trip). (Before the
# fix gsub counted them as 9, under the threshold.)
stage_and_scan "regression (undercount fixed): 18 packed postcodes trip" 1 \
  "data/postcodes.md" \
  "$(printf 'SW1A 2AA %.0s' {1..18})"

# NOTE: the NUL-byte bypass that affects the runtime content-sniff hook does
# NOT reproduce here. git's own binary classification (`git diff --cached
# --numstat`) flags ANY blob containing a NUL as binary — including a plain
# text file with one stray NUL byte — so the staged scanner also gates its
# binary skip on file EXTENSION (pii_is_binary_extension, pii-patterns.sh),
# exactly like pii-content-sniff.sh does. A NUL-prefixed .md/.txt file is
# still scanned normally here; see the regression case below.
stage_and_scan_raw "regression (NUL-prefixed text is still scanned, not classified binary)" 1 \
  "docs/nul_prefixed.md" \
  '\000Email: alex@example.test\nPostcode: SW1A 1AA\nPhone: +44 20 7946 0000\n'

# No-args invocation — scans whole index. Stage three files (one tripping)
# and confirm scanner exits non-zero with no positional args.
mkdir -p "$sandbox/multi"
printf 'clean file 1\n' > "$sandbox/multi/a.md"
printf 'clean file 2\n' > "$sandbox/multi/b.md"
printf 'Email: alex@example.test\nPostcode: SW1A 1AA\nPhone: +44 20 7946 0000\n' > "$sandbox/multi/c.md"
git add "$sandbox/multi/" 2>/dev/null
total=$((total + 1))
set +e
"$scanner" >/dev/null 2>&1
rc=$?
set -e 2>/dev/null || true
if [[ "$rc" -eq 1 ]]; then
  printf 'PASS  %-55s rc=%d\n' "no-args invocation scans whole index" "$rc"
else
  printf 'FAIL  %-55s expected=1 actual=%d\n' "no-args invocation scans whole index" "$rc"
  fail=$((fail + 1))
fi
git rm -rf --quiet --cached -- "$sandbox/multi/" 2>/dev/null
rm -rf "$sandbox/multi"

echo
echo "Total: $total, Failed: $fail"
exit "$fail"
