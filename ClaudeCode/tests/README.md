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
  ClaudeCode/tests/cases/pii-path-policy.json
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

## Integration tests

End-to-end tests against the live agent live in `.claude/skills/test-guardrails/SKILL.md`. The harness in this directory is for fast iteration on hook logic; the skill is the authoritative integration test.
