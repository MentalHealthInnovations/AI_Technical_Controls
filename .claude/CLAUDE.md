# Project guidance

## Pull request descriptions

PR descriptions in this repo **must** follow [`.github/pull_request_template.md`](../.github/pull_request_template.md). When opening a PR or updating a PR body (e.g. via `gh pr create` / `gh pr edit`), populate every section of that template — do not substitute a free-form summary.

Required sections, in order:

1. **Summary** — what the change does and why.
2. **Guardrail test results** — paste the `/test-guardrails` markdown table inside the `<details>` block. A full run is mandatory for PRs touching hooks, permissions, sandbox config, or `managed-settings.json`; include one if practical for docs/fixture-only PRs.
3. **Security risk assessment** — tick the checklist boxes that apply. If any box is checked, fill in *What guardrails does this change weaken or remove?*, *What new attack surface does this open?*, *Mitigations in place*, and *Residual risk rating* (**Low** / **Medium** / **High**). If a prose box does not apply, write "None" rather than leaving it blank.

Keep the reviewer footer line intact.

## Keep the tests and risk assessment in sync with the allowlist

Any change to the Bash command allowlist or deny logic in [`ClaudeCode/opt/claude/hooks/bash-policy-check.sh`](../ClaudeCode/opt/claude/hooks/bash-policy-check.sh) — adding, removing, or rescoping a command — **must**, in the same PR, update all three of:

1. **The behavioural test suite** — add or amend cases in [`.claude/skills/test-guardrails/SKILL.md`](skills/test-guardrails/SKILL.md) (both the numbered test list and the results-table template). New ALLOW entries need an ALLOWED case; anything deliberately left out or blocked needs a BLOCKED case proving it.
2. **The offline harness** — add or amend the matching `assert_*` line in [`ClaudeCode/opt/claude/hooks/test/run-bash-policy-tests.sh`](../ClaudeCode/opt/claude/hooks/test/run-bash-policy-tests.sh) so the change is covered without needing an installed-hook run. (The harness covers hook-decision logic only; permission-layer, sandbox, WebFetch, and MCP cases stay in the `/test-guardrails` suite.)
3. **The risk assessment** — record the command in [`docs/command-allowlist-risk-assessment.md`](../docs/command-allowlist-risk-assessment.md): tick it off under the implemented checklist if added, or file it under *safe-to-add-on-request* / *policy-decision-required* if not. A command that spawns subprocesses (make, gradle, npx, `docker compose up`, etc.) is a policy decision, not a config tweak — never allowlist one without a recorded decision and CODEOWNERS sign-off.

The same applies to changes in `output-redact.sh` / `lib/redact.sh` (add a redaction test case) and to new hook scripts generally: if you change what the guardrails do, the tests and the risk assessment change with it — a PR that alters enforcement without updating both is incomplete.
