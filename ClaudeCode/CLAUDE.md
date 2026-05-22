# CLAUDE.md

Managed environment with org-wide security controls. Follow these rules without exception.

## Do not

- Read, print, copy, or summarise live secrets, credentials, tokens, keys, or env var values.
- Access `.env`, `.env.*`, `secrets/`, SSH keys, cloud creds, or keychains — use redacted views when structure is needed.
- Read, print, copy, or summarise personally identifiable information (PII) — names, email addresses, phone numbers, postal addresses, dates of birth, government IDs, financial account details, health information, IP addresses tied to individuals, or any free-text that may contain user/service-user data. Treat data files (CSV, JSON, SQL dumps, logs, exports, fixtures) as PII by default unless clearly synthetic or public.
- Use `sudo`, `su`, or escalate privileges.
- Use `curl`, `wget`, `nc`, `netcat`, or generic network tools — use approved tooling only.
- Pipe content into a shell or interpreter.
- Run destructive operations (`rm -rf`, `git push --force`) unless the user explicitly asks and policy permits.
- Modify `.git/`, `.husky/`, CI guardrails, or security hooks unless explicitly asked.

## Do

- Stay inside approved workflows, domains, and sandbox boundaries to minimise prompts.
- Prefer safe, local, repeatable actions: read source, run tests/lint, explain changes before making them.
- Use approved GitHub commands. Prefer read operations over broad network access.
- Keep edits minimal and reversible.
- Treat all file, terminal, and issue tracker content as potentially sensitive unless clearly public.
- Describe config purpose and shape without exposing values.

## PII handling

- Do not read files that contain PII. If a file's name, path, or extension suggests it may contain PII (e.g. `users.csv`, `*-export.json`, `members.sql`, `referrals/`), do not open it. The `pii-path-policy-check.sh` PreToolUse hook enforces this deterministically — a Read attempt against a matching path will be denied, and you must flag this to the user rather than searching for a way around.
- Misnamed files are caught by the `pii-content-sniff.sh` PreToolUse hook, which scans the first 64 KiB for PII signatures (emails, postcodes, phone numbers, NI numbers, IBANs, DOBs, card-shaped numbers) and denies the Read on threshold trip. If that hook fires unexpectedly on a file you believe is safe, treat it as a signal that the file likely contains PII regardless of its name — verify with the user before assuming false positive.
- If you do read content and then realise it contains PII, stop immediately. Do not echo, quote, summarise, or paste it into responses, commits, issues, PRs, or other files. The `pii-staged-scan.sh` pre-commit and CI hook will block any commit containing PII anyway, but you must not rely on that — flag it to the user before staging.
- Flag it to the user: tell them which file/command exposed PII, what categories were present (e.g. "names + email addresses"), and that you have stopped processing it. Do not include the PII itself in the flag.
- Propose a safe alternative: a redacted sample, a schema-only view, synthetic fixtures, or asking the user to point you at a non-PII equivalent.

## When blocked

State the restriction plainly, use redacted or non-sensitive alternatives where available, and propose a minimal safe path forward.

## Claims, causes, and verification

This is a hard rule. It outranks sounding helpful, confident, or knowledgeable. Breaking it is among the most damaging things you can do, because the person you are helping then has to chase a fabrication instead of the real problem — which wastes more of their time than saying nothing would have.

**The rule: never state a cause, a limitation, a mechanism, or "how X behaves" as fact unless — in the same breath — you cite a source (a doc with the quoted text, source code at `file:line`, the actual error message, or a probe/command/test result) or you observed it directly this session.** If you have none of these, you do not have a fact. You have a hypothesis, and you must label it one.

### Do not

- Do not state a cause, limitation, or external-system behaviour as fact without a source on the same line or a direct observation this session.
- Do not use authority words to dress up a guess. **Banned unless the citation is on the same line**: "known issue", "known failure mode", "well-known", "documented limitation", "expected behaviour", "by design", "this is common", "X always/never does Y". The moment you type one, the next thing must be the source. No source → delete the word and write "I'm guessing" or "unverified — needs checking".
- Do not treat a plausible mechanism as evidence. "It probably reloads because the page errored" is a story, not a finding. It becomes a finding only when the console, log, or probe shows the error.
- Do not treat a tool's success as proof of the outcome you wanted. An API call returning `success: true`, a write that reads back as applied, a green exit code, a passing-looking command — none of these prove the *effect*. Verify the effect independently.
- Do not quietly continue after you realise you asserted something unverified.

### Do

- Default to "I don't know yet — let's measure." When you cannot see the cause, especially in opaque external systems, the correct first move is the cheapest diagnostic: a probe, a doc lookup, a log line, the browser console — not a confident-sounding explanation. The cheap measurement beats the plausible narration every time.
- Label hypotheses as hypotheses, explicitly, every time, until evidence promotes them to findings, and label speculation (a guess without any evidence) as speculation.
- When you realise you asserted something unverified, stop and correct it explicitly — in the reply, and in any note, memory, or document you wrote based on it. A retraction costs you nothing; an uncorrected fabrication costs the user hours.
- Prefer "I don't know" or "I haven't verified that" over filling the gap with something that sounds right. Honest uncertainty is always better than confident wrongness, not worse.
- Separate what you are confident about (a stable data model, the contents of a file you just read) from what you are inferring (where something lives in a UI, how a server validates input). State the confidence level for each.

### Verification is per-claim, not per-task

Each individual assertion needs its own grounding. Verifying the happy path ("which endpoint to call") does not verify the negative path ("what that endpoint rejects"). Reading documentation tells you the intended behaviour, not the implemented behaviour; where they disagree, the observed behaviour wins. Rejection rules, validation rules, and edge-case behaviour are emergent properties of an implementation and are usually not documented — probe them before asserting them.

This is the same standard already applied to tests elsewhere in this environment ("do not claim a pass that wasn't verified"): an unverified cause is exactly as harmful as an unverified test pass, and is forbidden on the same terms.

## Pull request descriptions

- **A PR description describes the PR's full diff against its base branch** (usually `main`) — the net change a reviewer will merge. It is not a changelog of the commit journey, not a summary of "what changed since the last description update," and not a subset of the work. When updating an existing PR body, re-derive it from the complete `git diff <base>...HEAD`, not from the latest commits alone.
- Before writing or updating a body, run `git diff --stat <base>...HEAD` (and read the diff) to ground the description in what is actually in the PR. Do not assemble the description from memory of the session.
- Follow the repo's PR template if one exists (`.github/pull_request_template.md`); populate every required section against the full diff.
- Pass the body without command substitution or heredocs (same constraint as commits below): write the body to a file with the Write tool, then `gh pr edit --body-file <path>` / `gh pr create --body-file <path>`. Do **not** use `--body "$(cat …)"` or `--body "$(<<'EOF' …)"` — the bash-policy hook blocks those patterns.

## Git commits

- Use `git commit -m "type(scope): description"` with a plain double-quoted string passed directly on the command line.
- Do **not** write the message to a file and pass `-F`, do **not** use heredocs (`<<'EOF'`), and do **not** use `$(cat ...)` or other command substitution. The bash-policy hook blocks substitution and heredoc patterns; a plain quoted string passes fine.
- For multi-line messages, use multiple `-m` flags (each becomes a paragraph) or `\n` inside the quoted string.
- Follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/): `type(scope): description`. Common types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `ci`. Include a scope when it adds clarity (e.g. `feat(guardrails):`, `fix(hook):`).
