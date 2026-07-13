# Project guidance

## Pull request descriptions

PR descriptions in this repo **must** follow [`.github/pull_request_template.md`](../.github/pull_request_template.md). When opening a PR or updating a PR body (e.g. via `gh pr create` / `gh pr edit`), populate every section of that template — do not substitute a free-form summary.

Required sections, in order:

1. **Summary** — what the change does and why.
2. **Guardrail test results** — CI (pre-commit + hook-tests) is the mandatory gate for every PR. `/test-guardrails` requires a live agent session with the branch's changes actually deployed, so it can only be run locally before opening the PR, not against the PR itself — it is not a check performed on the PR. If you ran it locally beforehand, paste its markdown table inside the `<details>` block for reviewer context; otherwise leave that section as-is.
3. **Security risk assessment** — tick the checklist boxes that apply. If any box is checked, fill in *What guardrails does this change weaken or remove?*, *What new attack surface does this open?*, *Mitigations in place*, and *Residual risk rating* (**Low** / **Medium** / **High**). If a prose box does not apply, write "None" rather than leaving it blank.

Keep the reviewer footer line intact.
