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

## Regression guards for review-fixed gaps

Some cases lock in fixes for detection holes found in review; each guards
against the hole reopening:

- **NUL-byte bypass** (`pii-content-sniff.jsonl`, `nul_prefixed_pii.txt`) — the
  binary skip is gated on a binary file *extension*, not NUL presence alone, so
  a text file with a stray NUL is still scanned. Content-sniff only: the staged
  scanner reads via `git show`, which strips NULs, so the bypass never applied
  there.
- **Adjacency undercount** (`pii-content-sniff.jsonl` + `run_staged_scan_cases.sh`,
  18 space-separated postcodes) — both consumers count with a
  `match()`/`RSTART`/`RLENGTH` loop instead of `gsub()`, so adjacent matches
  are counted individually (18 postcodes count as 18, not 9).
- **Spaced-IBAN miss** (`pii-content-sniff.jsonl` + `run_staged_scan_cases.sh`,
  12 spaced IBANs) — the IBAN regex allows optional whitespace between
  characters, so the ISO 13616 human-readable form (`GB29 NWBK 6016 ...`)
  matches.

The Write-path gap (an innocuously-named PII file created via `Write`/`Edit` was
never content-scanned at runtime) is addressed in `managed-settings.json` by
registering `pii-content-sniff.sh` for `Edit|Write|MultiEdit` as well as `Read`;
the hook scans the inline `content`/`new_string` payload when there is no file on
disk yet.

## Integration tests

End-to-end tests against the live agent live in `.claude/skills/test-guardrails/SKILL.md`. The harness in this directory is for fast iteration on hook logic; the skill is the authoritative integration test.
