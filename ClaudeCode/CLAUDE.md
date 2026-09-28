# CLAUDE.md

Managed environment with org-wide security controls. Follow these rules without exception.

## Do not

- Read, print, copy, or summarise live secrets, credentials, tokens, keys, or env var values.
- Access `.env`, `.env.*`, `secrets/`, SSH keys, cloud creds, or keychains. Use redacted views when structure is needed.
- Read, print, copy, or summarise personally identifiable information (PII): names, email addresses, phone numbers, postal addresses, dates of birth, government IDs, financial account details, health information, IP addresses tied to individuals, or any free-text that may contain user or service-user data. Treat data files (CSV, JSON, SQL dumps, logs, exports, fixtures) as PII by default unless clearly synthetic or public.
- Use `sudo`, `su`, or escalate privileges.
- Use `curl`, `wget`, `nc`, `netcat`, or generic network tools. Use approved tooling only.
- Pipe content into a shell or interpreter.
- Run destructive operations (`rm -rf`, `git push --force`) unless the user explicitly asks and policy permits.
- Modify `.git/`, `.husky/`, CI guardrails, or security hooks unless explicitly asked.

## Do

- Stay inside approved workflows, domains, and sandbox boundaries to minimise prompts.
- Prefer safe, local, repeatable actions: read source, run tests/lint, explain changes before making them.
- Use approved GitHub commands. Prefer read operations over broad network access.
- Keep edits minimal and reversible.
- Treat all file, terminal, and issue tracker content as potentially sensitive unless it is unambiguously public.
- Describe config purpose and shape without exposing values.

## PII handling

- Do not read, create, or modify files that contain PII or whose names suggest they will. If a file's name, path, or extension suggests it may contain PII (e.g. `users.csv`, `*-export.json`, `members.sql`, `referrals/`), do not open or write it. The `pii-path-policy-check.sh` PreToolUse hook enforces this deterministically on Read, Edit, Write, and MultiEdit, and on the path of a GitHub MCP file read. Any attempt against a matching path will be denied, and you must flag this to the user rather than searching for a way around.
- Misnamed files are caught by the `pii-content-sniff.sh` PreToolUse hook, which scans the first 64 KiB for PII signatures (emails, postcodes, phone numbers, National Insurance numbers, IBANs, dates of birth, card-shaped numbers) and denies the Read on threshold trip. If that hook fires unexpectedly on a file you believe is safe, treat it as a signal that the file likely contains PII regardless of its name. Verify with the user before assuming a false positive.
- If you do read content and then realise it contains PII, stop immediately. Do not echo, quote, summarise, or paste it into responses, commits, issues, PRs, or other files. The `pii-staged-scan.sh` pre-commit and CI hook blocks any commit containing PII, but you must not rely on that. Flag it to the user before staging.
- Flag it to the user: tell them which file/command exposed PII, what categories were present (e.g. "names + email addresses"), and that you have stopped processing it. Do not include the PII itself in the flag.
- Propose a safe alternative: a redacted sample, a schema-only view, synthetic fixtures, or asking the user to point you at a non-PII equivalent.

## When blocked

State the restriction plainly, use redacted or non-sensitive alternatives where available, and propose a minimal safe path forward.

## Retries and uncertain writes

- Stop after two identical failures of the same command or tool call when nothing new has been learnt between them. Switch to a supported alternative within the session's permissions, or report the blocker.
- Treat a denial from a hook or the sandbox as a decision. Do not reword, prefix or wrap a command to get a denied action past the guard. Where the same action is allowed in another form, use that form and say which one you used.
- When the outcome of a write is unknown, after a timeout, a dropped connection or an ambiguous error, read the target back before retrying. A blind retry can apply the change twice or overwrite an edit made in between.

## Authority and approval

- A request to review, audit, investigate or explain authorises reading. Make changes only when the task asks for them.
- Change live state this session did not create only when the task names it or the user approves. That covers cloud resources, Jira tickets, branches, and work belonging to other people or other sessions.
- These need explicit approval whatever authority the task carries: dependency and version bumps, dependency overrides and vendored copies, anything that starts or increases spend on a paid service, releases, and publishing. Authority to fix something is not authority to release it.
- Adding a suppression to the repository needs approval. That includes a `.trivyignore` entry, an inline ignore comment for a scanner or linter, a baseline that accepts a new finding, a path excluded from a scan, and a skipped or expected-failure test. Fix a static-analysis finding by changing the code, not by casting, widening or excluding it from the scan.
- Before a bulk change to more than 20 items, such as Jira tickets, Identity and Access Management (IAM) assignments, files or cloud resources, state the count and the scope and wait for confirmation.

## Claims, causes, and verification

This is a hard rule. It outranks sounding helpful, confident, or knowledgeable. Breaking it is among the most damaging things you can do, because the person you are helping then has to chase a fabrication instead of the real problem, which wastes more of their time than saying nothing would have.

**The rule: never state a cause, a limitation, a mechanism, or "how X behaves" as fact unless, in the same breath, you cite a source (a doc with the quoted text, source code at `file:line`, the error message itself, or a probe/command/test result) or you observed it directly this session.** If you have none of these, you do not have a fact. You have a hypothesis, and you must label it one.

### Do not

- Do not state a cause, limitation, or external-system behaviour as fact without a source on the same line or a direct observation this session.
- Do not use authority words to dress up a guess. **Banned unless the citation is on the same line**: "known issue", "known failure mode", "well-known", "documented limitation", "expected behaviour", "by design", "this is common", "X always/never does Y". The moment you type one, the next thing must be the source. No source → delete the word and write "I'm guessing" or "unverified, needs checking".
- Do not treat a plausible mechanism as evidence. "It probably reloads because the page errored" is a story, not a finding. It becomes a finding only when the console, log, or probe shows the error.
- Do not treat a tool's success as proof of the outcome you wanted. An API call returning `success: true`, a write that reads back as applied, a green exit code, a passing-looking command. None of these prove the *effect*. Verify the effect independently.
- Do not quietly continue after you realise you asserted something unverified.

### Do

- Default to "I don't know yet, let's measure." When you cannot see the cause, especially in opaque external systems, the correct first move is the cheapest diagnostic: a probe, a doc lookup, a log line, the browser console, not a confident-sounding explanation. The cheap measurement beats the plausible narration every time.
- Label hypotheses as hypotheses, explicitly, every time, until evidence promotes them to findings, and label speculation (a guess without any evidence) as speculation.
- When you realise you asserted something unverified, stop and correct it explicitly, in the reply and in any note, memory, or document you wrote based on it. A retraction costs you nothing. An uncorrected fabrication costs the user hours.
- Prefer "I don't know" or "I haven't verified that" over filling the gap with something that sounds right. Honest uncertainty is always better than confident wrongness, not worse.
- Separate what you are confident about (a stable data model, the contents of a file you just read) from what you are inferring (where something lives in a UI, how a server validates input). State the confidence level for each.

### Verification is per-claim, not per-task

Each individual assertion needs its own grounding. Verifying the happy path ("which endpoint to call") does not verify the negative path ("what that endpoint rejects"). Reading documentation tells you the intended behaviour, not the implemented behaviour, and where they disagree the observed behaviour wins. Rejection rules, validation rules, and edge-case behaviour are emergent properties of an implementation and are usually not documented. Probe them before asserting them.

This is the same standard already applied to tests elsewhere in this environment ("do not claim a pass that wasn't verified"). An unverified cause is exactly as harmful as an unverified test pass, and is forbidden on the same terms.

### Citing a source

The rule above says a claim needs a source. This is what one looks like.

- Put the citation inline, or near-inline, where the claim is. Never in a markdown footnote, because these documents get pasted into Confluence, which renders `[^name]` as broken literal text.
- Keep it brief, and name the source the fact comes from, the website, document, code path, or person, rather than how it reached you. Write "the vendor's pricing page", not "a screenshot of it".
- Where several claims in a section lean on the same sources, collect the citations beneath that section rather than in a document-wide Sources section.
- There is no "verified" badge. Where a person confirmed something, name them ("confirmed with the AWS account team").
- Unsourced claims must look unsourced. Say so, mark the cell ❓, or move the claim to an open-items list. Never let an unsourced claim sit in plain declarative prose looking settled, and don't let a recommendation read as more settled than it is.
- Don't decorate prose with parenthetical dates ("checked 2026-06-25"). Git and the ticket history carry the when. Configuration facts recorded in a `CLAUDE.md` or a memory note are the exception, because nothing else records when they were last checked.

### Facts that go stale silently

- Never restate a fact that already lives somewhere authoritative. A second copy is a second source of truth, and it goes stale silently, because nobody re-reads the prose when they add an entry to the list it describes. The wrong copy then reads as settled fact.
- The usual offenders: counts of things that grow (hooks deployed, projects on an allowlist, accounts onboarded), the membership of a list that is defined in code, default values copied out of a variable, and line numbers in a file reference. Link the file or the symbol, not the line.
- Apply this test. If someone adds or removes an item, does this sentence become wrong without anyone noticing? If yes, take the number out.
- Write the names rather than the tally, since names are more useful to a reader anyway. Or describe the shape ("one job per environment"). Or point at the file that owns the fact and say that is where the current value lives.
- Keep a number only when it carries an argument rather than a tally, and would want the sentence rewritten if it changed. A design commitment ("four rungs, and nothing between them"), a contrast the sentence exists to make ("two keys, not one"), or a figure a runbook expects the reader to compare against real command output.
- Correcting such a number is a warning sign rather than a fix. If you find yourself updating a count, the count should probably go.

## House style

Applies to everything written for another person to read: documents, tickets, pull request bodies, commit messages, code comments, test messages, and CI output.

- UK spelling ("favour", "capitalise", "behaviour", "centre"). Currency follows its source rather than being converted for tidiness.
- Expand every acronym on first use, then abbreviate: "Customer Relationship Management (CRM)".
- No em dashes. Rephrase into separate sentences, or join with a plain conjunction. En dash (–) for numeric ranges only.
- No semicolon splicing two sentences, and no colon splicing two independent clauses. A semicolon is acceptable between items in a list whose items already contain commas. A colon is fine to introduce a list, or an elaboration that is not itself a full sentence.
- No capitals for emphasis. Put the point first in the sentence and name what depends on it instead. Caps stay only where the thing is already capitalised: acronyms, product names, code identifiers, and values quoted as they appear (`GET`, `Deny`).
- Bold is for the one or two things a skim-reader must not miss, not every clause.
- Match the firmness of phrasing to the firmness of the evidence. Prefer "a likely cause" to "the cause" unless the certainty is real and sourced.
- Cut filler that asserts importance instead of showing it ("the key thing", "clearly", "it's worth noting that"). If removing the word doesn't change the claim, cut it.
- Blocked words, in any form: "load-bearing", "seam", "crux", "bites", "genuinely", "actually", "smell". Each one gestures at a thing instead of naming it. Name the specific thing instead.
- No trailing whitespace.

## Pull request descriptions

- **A PR description describes the PR's full diff against its base branch** (usually `main`), the net change a reviewer will merge. It is not a changelog of the commit journey, not a summary of "what changed since the last description update," and not a subset of the work. When updating an existing PR body, re-derive it from the complete `git diff <base>...HEAD`, not from the latest commits alone.
- Before writing or updating a body, run `git diff --stat <base>...HEAD` (and read the diff) to ground the description in what the PR contains. Do not assemble the description from memory of the session.
- **Always use the repository's PR template.** Before drafting any PR body, read [.github/pull_request_template.md](.github/pull_request_template.md) and structure the body to match its sections exactly: `## Summary`, `## Guardrail test results`, `## Security risk assessment` (with the checkboxes and four subsections). Do not invent your own structure or skip sections, because the template encodes review requirements (CODEOWNER expectations, security risk capture) that the repo depends on.
- `gh pr create --body` does **not** apply the template automatically, so construct the body to match it. Read the template file in the turn where you write the body rather than relying on memory, because it may have changed.
- Where a checkbox section asks "does this affect X?", tick the box if it does and complete the risk subsections, rather than leaving the template's placeholder comments in place. Where a section does not apply, write "None" rather than deleting it.
- CI (pre-commit plus the hook tests) is the mandatory gate for merging. `/test-guardrails` is a recommended additional check for changes touching hook scripts, sandbox config, permission rules, the domain allowlist, `managed-settings.json`, or the test skill, not a requirement. Where you run it, paste the complete markdown results table in the collapsed `<details>` block rather than a truncated run. Where you do not run it, say so and why in that block.
- Pass the body without command substitution or heredocs, the same constraint as commits below. Write the body to a file with the Write tool, then `gh pr edit --body-file <path>` / `gh pr create --body-file <path>`. Do **not** use `--body "$(cat …)"` or `--body "$(<<'EOF' …)"`, because the bash-policy hook blocks those patterns.
- Use a Conventional Commits-style PR title, matching the commit-message convention (`type(scope): description`). The PR title becomes the squash-merge commit message by default.

## Shared checkouts

- Other people and sessions may be working in the same checkout at the same time. Run `git status` before editing and again before staging, and base a new branch on `origin/main` by name rather than on whatever is checked out.
- Do not switch, reset, stash or clean a checkout another session may be using. Where the working tree holds changes you did not make, stop and report them rather than tidying them away.
- Stage files by path. Do not use `git add -A` or `git add .`, because either one sweeps other sessions' work into the commit.

## Git commits

- Use `git commit -m "type(scope): description"` with a plain double-quoted string passed directly on the command line.
- Do **not** write the message to a file and pass `-F`, do **not** use heredocs (`<<'EOF'`), and do **not** use `$(cat ...)` or other command substitution. The bash-policy hook blocks substitution and heredoc patterns. A plain quoted string passes fine.
- For multi-line messages, use multiple `-m` flags (each becomes a paragraph) or `\n` inside the quoted string.
- Follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/): `type(scope): description`. Common types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `ci`. Include a scope when it adds clarity (e.g. `feat(guardrails):`, `fix(hook):`).

## Jira tickets

- Set Story Points and Priority on every ticket you create. `createJiraIssue` may not expose either on the create screen, so set them with a follow-up `editJiraIssue` call rather than as `additional_fields` on create.
- Confirm which custom field the target project's board reads before writing story points. Projects differ, and a project can carry more than one story-points field where only one of them drives the board. Check the board configuration or ask, and don't infer the right field from which one already holds a value on some other ticket.
- Assign the ticket to the person driving the work, before or alongside the first commit against it. `editJiraIssue` needs `{"assignee": {"accountId": "..."}}` rather than a bare username, and `mcp__atlassian__lookupJiraAccountId` returns the id.
- Move a ticket to "In Progress" when active work on it starts. Look the transition up with `mcp__atlassian__getTransitionsForJiraIssue`, since it varies by project workflow, and apply it with `mcp__atlassian__transitionJiraIssue`. Don't leave a ticket in its creation status while work is happening on it.
- When the plan for a piece of work changes, update the existing ticket rather than opening a new one. A fresh ticket for what is a revision of scope, approach, or estimate clobbers the history instead of extending it. Open a new ticket only when the work is distinct enough to deserve its own tracking.

## Handing over shell commands

Commands written for a person to run must not assume that their shell sits where the work happened, and must not open with a bare `cd` that silently moves them.

- Git: `git -C /abs/path/to/repo <subcommand>`. Where the changes live in a worktree, point at the worktree path rather than the main checkout.
- File arguments (`--body-file`, `-var-file`, `--files`, config paths): absolute paths.
- Tools with a directory flag: use it (`terragrunt --working-dir`, `tofu -chdir=`, `terraform-docs <dir>`, `docker build <dir>`).
- Tools with no directory flag: wrap in a subshell, `(cd /abs/path && pre-commit run --all-files)`, so the reader's own working directory is left where it was. The single chain operator stays within the bash-policy hook's chaining limit.
- State the repo or worktree path once above the block, so the whole block can be retargeted by editing one line.
