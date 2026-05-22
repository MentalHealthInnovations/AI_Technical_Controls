#!/usr/bin/env bash
# Tests for pii-staged-scan.sh.
#
# The scanner reads its input from `git show :path`, so unit-testing it
# requires actual staged files in a git index. This script:
#
#   1. Creates a throwaway git repo under $TMPDIR (or /tmp/claude as fallback),
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

tmp_root="${TMPDIR:-/tmp/claude}"
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

# Excluded path — even with clear PII, the scanner must skip fixtures dir.
stage_and_scan "PII inside excluded fixtures path is skipped" 0 \
  "ClaudeCode/tests/cases/fixtures/synthetic.md" \
  "Email: alex@example.test
Postcode: SW1A 1AA
Phone: +44 20 7946 0000
"

# Binary file — skipped by NUL-byte detector.
binary_content=$'\x00\x01\x02fake-binary-payload alex@example.test SW1A 1AA +44 20 7946 0000'
stage_and_scan "binary file with embedded PII is skipped" 0 \
  "data/binary.bin" \
  "$binary_content"

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
