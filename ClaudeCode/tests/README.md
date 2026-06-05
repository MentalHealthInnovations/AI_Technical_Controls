# Hook regression tests

Self-contained shell-based tests for the PreToolUse and PostToolUse hooks. Each test feeds a JSON payload to the hook on stdin (the same shape the Claude Code harness produces) and asserts the hook's decision.

These tests run outside the Claude Code sandbox — invoke them directly from a normal shell. They are intentionally not wired into the bash-policy allowlist, because executing arbitrary `.sh` scripts is exactly the kind of thing the allowlist exists to block; the tradeoff is that developers run these locally during hook changes, not from within an agent session.

## Run all tests

```bash
ClaudeCode/tests/run_all.sh
```

Exits non-zero if any case fails.

## Run a single hook's tests

```bash
ClaudeCode/tests/run_hook_cases.sh \
  ClaudeCode/opt/claude/hooks/pii-path-policy-check.sh \
  ClaudeCode/tests/cases/pii-path-policy.jsonl
```

## Case file format

One JSON object per line (JSONL). Required fields:

| Field | Meaning |
|---|---|
| `name` | Short label printed in the test output |
| `input` | The full `tool_input` object passed to the hook (e.g. `{"file_path": "/repo/users.csv"}`) |
| `expect` | Expected `permissionDecision` — `deny`, `allow`, or `unset` (hook exited without emitting a decision) |

## Staged-scan tests

`run_staged_scan_cases.sh` tests the pre-commit / CI scanner ([pii-staged-scan.sh](../scripts/pii-staged-scan.sh)). The scanner needs a real git index, not a JSONL payload, so this runner creates a throwaway repo under `$TMPDIR`, stages fixtures inside it, runs the scanner, and asserts the exit code. The host repo's index is never touched.

`run_all.sh` invokes this runner automatically after the JSONL hook suites.

## Wild-corpus / false-positive guard

`run_wild_corpus_cases.sh` runs every file under [cases/fixtures/pii-content-wild/](cases/fixtures/pii-content-wild/) through `pii-content-sniff.sh` and asserts that none of them trip a deny. Beyond pass/fail, it prints per-pattern hit counts so a future PR that lowers a threshold visibly shifts the counts.

See the directory's [MANIFEST.md](cases/fixtures/pii-content-wild/MANIFEST.md) for provenance, known sub-threshold scores, and how to add a new fixture.

## Known-gap cases (expected to FAIL until fixed)

Some cases assert the **desired** behaviour for confirmed detection holes surfaced
in review, so they fail against the current hooks. A red result on these is the
point — it keeps the gap visible in CI until the underlying code is fixed, at
which point the case flips to green. Each is labelled `KNOWN GAP (...)` in its
name. Current entries:

| Gap | Where | What the case asserts | Why it fails today |
|---|---|---|---|
| NUL-byte content bypass | `pii-content-sniff.jsonl` (`nul_prefixed_pii.txt`) | A text file with a leading NUL byte + 3 PII categories should be denied | A NUL in the first 1 KiB makes the binary heuristic classify the file as binary and skip scanning ([pii-content-sniff.sh](../opt/claude/hooks/pii-content-sniff.sh) lines 69-74). Content-sniff only — the staged scanner reads via `$(git show)`, which strips NULs, so the bypass does not reproduce there. |
| Adjacency undercount | `pii-content-sniff.jsonl` + `run_staged_scan_cases.sh` (18 space-separated postcodes) | 18 postcodes should trip the density threshold | Boundary-wrapped patterns `(^\|[^A-Za-z0-9])...([^A-Za-z0-9]\|$)` consume the separator, so `gsub` counts adjacent matches as one — 18 postcodes count as 9, under `DENSITY_TRIP=10`. |
| Spaced-IBAN miss | `pii-content-sniff.jsonl` + `run_staged_scan_cases.sh` (12 spaced IBANs) | A file full of space-grouped IBANs should trip | The IBAN regex requires contiguous alphanumerics, so the ISO 13616 human-readable form (`GB29 NWBK 6016 ...`) matches 0 times. |

The Write-path gap (content-sniff is registered for `Read` only, so an
innocuously-named PII file written via `Write` is never content-scanned at
runtime) is a `managed-settings.json` registration gap, not a hook-script bug, so
it is not expressible in these script-level runners — it is documented in the PR's
security risk assessment instead.

## Integration tests

End-to-end tests against the live agent live in `.claude/skills/test-guardrails/SKILL.md`. The harness in this directory is for fast iteration on hook logic; the skill is the authoritative integration test.
