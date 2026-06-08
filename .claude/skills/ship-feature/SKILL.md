---
name: ship-feature
description: One-shot feature delivery. Given a task description and its boundaries, sync main, branch off it, implement with frequent small conventional commits, push, and open a PR with gh. Use when the user hands off a self-contained feature/fix to take from a clean main all the way to an open PR. Any command the agent cannot run is handed back to the user to run.
---

You are running a **one-shot feature delivery**. The user has described a task and its boundaries; your job is to take it from a clean, up-to-date `main` all the way to an open pull request, in small reviewable steps, without further prompting beyond what the boundaries leave genuinely ambiguous.

## Inputs

The user's invocation should contain:

- **Task** — what to build or change.
- **Boundaries** — what is in scope, what is explicitly out of scope, constraints (files to touch/avoid, APIs to use, things not to break).

If either is missing or the boundaries leave a decision that materially changes the implementation (not a detail with an obvious default), ask **before** branching — use `AskUserQuestion` for crisp choices. Do not invent scope. When a boundary says "don't touch X", treat it as hard.

## Hard rule: hand back commands you cannot run

This environment is sandboxed with governance hooks. Some commands will be **blocked** (network tools, privilege escalation, heredocs/command-substitution in commit messages, writes to denied paths) and some may require credentials you don't have (e.g. `gh` auth, pushing to a protected remote).

- Attempt the command the approved way first (see the git/PR conventions below).
- If it is **denied by a hook**, **fails on auth/permissions**, or is **outside the sandbox**, do **not** search for a workaround. Stop, and hand the exact command to the user to run themselves, with a one-line explanation of why you couldn't. Then wait for them to confirm it's done (or paste output) before continuing any step that depends on it.
- Never modify `.git/`, `.husky/`, CI guardrails, or hooks to get unblocked.

## Procedure

Track the run with `TodoWrite` so progress is visible. Work the steps in order.

### 1. Ensure `main` is up to date — before anything else

Do this first, before reading deeply into the task or writing any code.

- Confirm the working tree is clean: `git status --porcelain`. If it is dirty, stop and ask the user how to proceed (stash, commit elsewhere, or abort) — do not silently discard or carry over changes.
- `git fetch origin`
- `git checkout main`
- `git pull --ff-only origin main` — fast-forward only. If this fails (diverged local main), stop and hand it to the user; do not force or merge to resolve it on their behalf.

If `git pull`/`fetch` is blocked or fails on network/auth, hand those commands to the user and wait for confirmation that local `main` matches origin before branching.

### 2. Branch off `main`

- Create a feature branch from the now-current `main`: `git checkout -b <type>/<short-kebab-summary>` where `<type>` matches the change (`feat`, `fix`, `refactor`, `docs`, `chore`, etc.) and the summary is derived from the task (e.g. `feat/csv-export-redaction`).
- Confirm you branched from up-to-date main, not from some stale branch you happened to be on.

### 3. Implement — frequent, small, conventional commits

- Make the smallest change that advances the task, verify it (build/lint/tests as the repo provides), then commit. Repeat. Prefer many small commits over one large one — each commit should be a coherent, reviewable unit that leaves the tree working.
- Stay strictly inside the stated boundaries. If you discover the task needs work outside them, **stop and ask** rather than expanding scope.
- Commit messages follow **Conventional Commits**: `git commit -m "type(scope): description"` as a **plain double-quoted string on the command line**. Do **not** write the message to a file and `-F`, do **not** use heredocs (`<<'EOF'`), and do **not** use `$(...)` or any command substitution — the bash-policy hook blocks those. For multi-line messages use multiple `-m` flags. If a commit is blocked, hand the exact command to the user.
- Do not commit secrets, PII, or anything a guardrail would block. If a pre-commit hook blocks a commit, read its output, fix the cause, and retry — do not bypass it (`--no-verify` is off-limits).

### 4. Push

- `git push -u origin <branch>`.
- If push is blocked/fails on auth or remote permissions, hand the exact `git push -u origin <branch>` command to the user and wait for confirmation before opening the PR.
- Never `git push --force` unless the user explicitly asks and policy permits.

### 5. Open the PR with `gh`

- Read the repo's PR template ([.github/pull_request_template.md](../../../.github/pull_request_template.md)) **in this turn** and populate **every** section against the full diff vs the base branch — re-derive the description from `git diff main...HEAD`, not from memory of the session. Run `git diff --stat main...HEAD` first to ground it.
- Use a Conventional-Commits-style PR title (it becomes the squash-merge message).
- Pass the body via a **file**, not command substitution: Write the body to a temp file, then `gh pr create --title "type(scope): ..." --base main --head <branch> --body-file <path>`. Do **not** use `--body "$(cat ...)"` or heredocs — the bash-policy hook blocks them.
- If the PR touches hook scripts, sandbox config, permission rules, the domain allowlist, `managed-settings.json`, or the test skill, run `/test-guardrails` and paste the full results table into the template's `<details>` block. Complete the Security risk assessment honestly; tick the boxes that apply and fill the prose subsections (write "None" where a box doesn't apply rather than leaving placeholders).
- If `gh` is unauthenticated or the create is blocked, hand the user the exact `gh pr create ...` command (and tell them where the body file is) and stop.

### 6. Report

Give the user: the branch name, the commit list (`git log --oneline main..HEAD`), the PR URL (or the command you handed off if creation was blocked), and a short note of anything left for them to run. Be honest about what was verified vs. assumed — if tests didn't run or a step was handed off, say so plainly.

## Throughout

- Verify per claim: don't report a test as passing you didn't run, or a step as done that was actually handed off. Label anything unverified.
- Keep edits minimal and reversible. Match the surrounding code's style.
- If at any point a boundary turns out to be wrong or in conflict with the task, surface it to the user instead of choosing for them.
