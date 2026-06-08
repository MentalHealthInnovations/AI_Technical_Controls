---
name: ship-feature
description: One-shot feature delivery. Given a task description and its boundaries, sync main, branch off it, implement with frequent small conventional commits, push, test the change against the installed policy (running /test-guardrails for enforced-config changes), and open a PR with gh. Use when the user hands off a self-contained feature/fix to take from a clean main all the way to an open PR. Any command the agent cannot run — including the privileged install needed to test enforced-policy changes — is handed back to the user to run.
---

You are running a **one-shot feature delivery**. The user has described a task and its boundaries; your job is to take it from a clean, up-to-date `main` all the way to an open pull request, in small reviewable steps, without further prompting beyond what the boundaries leave genuinely ambiguous. A PR that changes enforced policy (hooks, `managed-settings.json`, permissions, allowlist, or the test skill) is **tested against the installed policy before it is opened** — never opened untested.

## Inputs

The user's invocation should contain:

- **Task** — what to build or change.
- **Boundaries** — what is in scope, what is explicitly out of scope, constraints (files to touch/avoid, APIs to use, things not to break).

If either is missing or the boundaries leave a decision that materially changes the implementation (not a detail with an obvious default), ask **before** branching — use `AskUserQuestion` for crisp choices. Do not invent scope. When a boundary says "don't touch X", treat it as hard.

## Hard rule: hand back commands you cannot run

This environment is sandboxed with governance hooks. Some commands will be **blocked** (network tools, privilege escalation, heredocs/command-substitution in commit messages, writes to denied paths) and some may require credentials you don't have (e.g. `gh` auth, pushing to a protected remote).

- Attempt the command the approved way first (see the git/PR conventions below).
- If it is **denied by a hook**, **fails on auth/permissions**, or is **outside the sandbox**, do **not** search for a workaround. Stop, and hand the exact command to the user to run themselves, with a one-line explanation of why you couldn't. Then wait for them to confirm it's done (or paste output) before continuing any step that depends on it.
- Some failures look like auth errors but are sandbox file-access denials. Git remote operations (`fetch`, `pull`, `push`) can fail on SSH host-key verification when `~/.ssh/known_hosts` is unreadable, and `gh` can fail when `~/.config/gh/` is unreadable. Treat these as handoffs, not as auth problems to debug: give the user the exact command and wait.
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
- Do not commit secrets, PII, or anything a guardrail would block. If a pre-commit hook blocks a commit because of your change, read its output, fix the cause, and retry. Do not bypass it (`--no-verify` is off-limits).
- A pre-commit hook can also fail for an environmental reason unrelated to your diff, for example a hook that runs via Docker when the Docker socket is unreachable in the sandbox. That is not a fix-the-cause case. Verify your change independently where you can, for example run `shellcheck` directly, then hand the exact `git commit` command to the user to run outside the sandbox. Do not use `--no-verify`.

### 4. Push

- `git push -u origin <branch>`.
- If push is blocked/fails on auth or remote permissions, hand the exact `git push -u origin <branch>` command to the user and wait for confirmation before opening the PR.
- Never `git push --force` unless the user explicitly asks and policy permits.

### 5. Test before opening the PR

**Decide whether this PR changes enforced policy.** It does if the diff touches any of: hook scripts (`ClaudeCode/opt/claude/hooks/`), `managed-settings.json`, permission rules, the domain allowlist or path scopes, or the `/test-guardrails` skill itself.

- **If it does not** (e.g. docs, this skill, fixtures, code with no policy effect): no install or guardrail run is required. Note in the PR that it is a docs/non-enforcing change and skip to step 6. Run `/test-guardrails` anyway only if it is practical and meaningful.

- **If it does**, the change must be tested against the **installed** policy before the PR is opened — and the test only means something if the *branch's* version is what is installed. This matters because the active hooks and settings run from managed locations, **not** from the repo working tree:
  - hooks: `/opt/claude/hooks/`
  - settings + managed `CLAUDE.md`: `/Library/Application Support/ClaudeCode/`

  The repo's own `update_ai_governance` / `pull_claude_governance.sh` path will **not** do this for you: it clones and deploys **merged `main` from GitHub**, so it cannot install an un-merged branch. Running it now would test `main`, not your change, a false pass.

  **You cannot perform the install yourself.** Writing to `/opt`, `/Library`, and `/usr/local` is outside the sandbox, and the deploy needs `sudo` (privilege escalation is blocked). So **hand the install to the user** and wait. Do this:

  1. Have the user deploy the branch's config with the repo's own script, run from the repo root on the branch under test:

     ```
     sudo ClaudeCode/deploy_local_governance.sh
     ```

     This copies the checkout's `managed-settings.json`, `CLAUDE.md`, and hooks into the managed locations (the same destinations `pull_claude_governance.sh` uses) and stamps `VERSION` with a `local:<sha>[-dirty]` marker so a test deploy is distinguishable from a released `main` checkout. It deploys the whole checkout, so there is no per-file copy to assemble or get wrong. Tell the user this overwrites their live policy with the branch version, and that `update_ai_governance` restores the released version afterwards (it re-pulls `main`).
  2. **Wait** for the user to confirm the deploy succeeded. Do not proceed on the assumption it worked. The script prints the deployed `VERSION`: confirm it reads `local:<sha>` for the branch under test, not a bare `main` SHA.
  3. Then run `/test-guardrails` and read the results. The suite restarts may be needed for some hook changes to take effect, so if results look like the old version, ask the user to confirm the deploy landed (and, where relevant, that the session was restarted) before trusting them.
  4. If any test is an unexpected result (especially a BLOCKED case that came back ALLOWED), **stop**, that is a guardrail regression. Fix it on the branch, have the user re-deploy, and re-run. Do not open the PR with a known regression unless the user explicitly accepts it.

  Keep the full `/test-guardrails` results table; it goes into the PR body in the next step.

### 6. Open the PR with `gh`

- Read the repo's PR template ([.github/pull_request_template.md](../../../.github/pull_request_template.md)) **in this turn** and populate **every** section against the full diff vs the base branch — re-derive the description from `git diff main...HEAD`, not from memory of the session. Run `git diff --stat main...HEAD` first to ground it.
- Use a Conventional-Commits-style PR title (it becomes the squash-merge message).
- Pass the body via a **file**, not command substitution: Write the body to a temp file, then `gh pr create --title "type(scope): ..." --base main --head <branch> --body-file <path>`. Do **not** use `--body "$(cat ...)"` or heredocs — the bash-policy hook blocks them.
- For an enforced-policy PR (step 5), paste the **full `/test-guardrails` results table you just produced** into the template's `<details>` block — not a remembered or assumed result. For a non-enforcing PR, state in that block that a run was not required and why. Either way, complete the Security risk assessment honestly: tick the boxes that apply and fill the prose subsections (write "None" where a box doesn't apply rather than leaving placeholders).
- If `gh` is unauthenticated or the create is blocked, hand the user the exact `gh pr create ...` command (and tell them where the body file is) and stop.

### 7. Report

Give the user: the branch name, the commit list (`git log --oneline main..HEAD`), the PR URL (or the command you handed off if creation was blocked), the `/test-guardrails` outcome (full pass, or which tests regressed), and a short note of anything left for them to run. If you handed off a `sudo ClaudeCode/deploy_local_governance.sh` install in step 5, remind the user their live policy now reflects the branch and that `update_ai_governance` restores the released `main` version. Be honest about what was verified vs. assumed: if tests didn't run, were run against the wrong version, or a step was handed off, say so plainly.

## Throughout

- Verify per claim: don't report a test as passing you didn't run, or a step as done that was actually handed off. Label anything unverified.
- A passing linter (`shellcheck` and similar) confirms the code parses and is style-clean. It does not confirm the code does what it should. For a script that performs privileged or out-of-sandbox actions you cannot run yourself, say so plainly, hand the user the exact command to exercise it, and treat the behaviour as unverified until a real run confirms the effect.
- Keep edits minimal and reversible. Match the surrounding code's style.
- If at any point a boundary turns out to be wrong or in conflict with the task, surface it to the user instead of choosing for them.
