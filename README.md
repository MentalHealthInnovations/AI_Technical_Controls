# Claude Code — AI Agent Governance Control Pack

A layered configuration system that makes Claude Code safer to use at scale. The goal is fewer prompts, not more — by removing the riskiest options from the environment up front.

## File manifest

| File | Purpose |
|------|---------|
| `ClaudeCode/managed-settings.json` | Org-wide immutable guardrails (permissions, sandbox, hooks, MCP allowlist) |
| `ClaudeCode/managed-mcp.json` | Server definitions for approved MCP servers (Claude Code's "exclusive control" mode) |
| `ClaudeCode/CLAUDE.md` | Behavioural guidance for Claude Code agents |
| `ClaudeCode/control_mappings.csv` | Control mapping to ISO 42001 / NIST AI RMF |
| `ClaudeCode/opt/claude/hooks/bash-policy-check.sh` | Pre-execution policy hook for Bash |
| `ClaudeCode/opt/claude/hooks/webfetch-policy-check.sh` | Pre-execution policy hook for WebFetch |
| `ClaudeCode/opt/claude/hooks/pii-path-policy-check.sh` | Pre-execution PII path/extension denylist for Read, Edit, Write, MultiEdit |
| `ClaudeCode/opt/claude/hooks/pii-content-sniff.sh` | Pre-execution PII content scanner for Read, Edit, Write, MultiEdit (catches misnamed files and PII introduced via a write payload) |
| `ClaudeCode/opt/claude/hooks/pii-patterns.sh` | Shared PII pattern definitions, sourced by the content sniffer and the pre-commit scanner |
| `ClaudeCode/opt/claude/hooks/output-redact.sh` | Post-execution secret redaction for Bash/Read/WebFetch |
| `ClaudeCode/opt/claude/hooks/tool-audit.sh` | Audit-only hook for Edit, Write, Task, SlashCommand, Read |
| `ClaudeCode/opt/claude/hooks/prompt-submit.sh` | Audit-only hook for `UserPromptSubmit` (logs redacted prompt text) |
| `ClaudeCode/opt/claude/hooks/session-audit.sh` | Audit-only hook for `SessionStart`, `Stop`, `SessionEnd` |
| `ClaudeCode/opt/claude/hooks/lib/audit-log.sh` | Shared helper: appends a JSONL record per invocation |
| `ClaudeCode/opt/claude/hooks/lib/redact.sh` | Shared secret-redaction patterns (output + prompt) |
| `ClaudeCode/scripts/pii-staged-scan.sh` | Pre-commit / CI scanner that blocks commits containing PII |
| `ClaudeCode/opt/claude/bin/upload-audit-logs.sh` | Daily uploader: ships the six hook logs to the audit S3 bucket (see appendix) |
| `ClaudeCode/pull_claude_governance.sh` | Pulls and deploys policy files; self-updates each run |
| `ClaudeCode/InstallClaudeGovernance.sh` | One-time macOS bootstrap for `pull_claude_governance.sh` |
| [Appendix: AWS audit-log setup](#appendix-aws-audit-log-setup) | Phase 0 manual AWS setup for the audit-log S3 bucket + IAM (IaC later) |
| `.claude/skills/test-guardrails/SKILL.md` | `/test-guardrails` verification suite |
| `.github/workflows/ci.yml` | CI: runs `pre-commit run --all-files` (incl. the PII staged-scan) and the hook regression suites on PRs and pushes to `main` |
| `.pre-commit-config.yaml` | Single source of truth for lint/format/validation checks (run by CI and optionally locally) |
| `ClaudeCode/tests/` | Shell-based hook regression tests (see [tests/README.md](ClaudeCode/tests/README.md)) |

## Installation

### Prerequisites

The install script installs both dependencies on demand via Jamf custom triggers. Both are required; the script refuses to proceed if either is missing and the corresponding trigger isn't supplied.

| Parameter | Resource | Used when |
|---|---|---|
| `$4` | `jq` | `command -v jq` fails. The script runs `jamf policy -event "$4"`. |
| `$5` | Xcode Command Line Tools | `xcode-select -p` fails. The script runs `jamf policy -event "$5"`. |
| `$6` | AWS CLI | Audit-log S3 upload is being configured and `aws` is missing. The script runs `jamf policy -event "$6"` (trigger `installAwsCli`). Optional. |
| `$7`, `$8` | `claude-audit-writer` access key id / secret | Both supplied to enable audit-log S3 upload. Optional; when either is empty, upload is skipped and governance install is unaffected. |

Configure the script in Jamf with the custom triggers of your existing jq and CLT install policies as parameters 4 and 5. Both dependencies are runtime-critical — `jq` parses every hook payload and reads the WebFetch allowlist; CLT provides `git` and a C compiler that this script needs to install other governance components. If jq is later removed from a machine, the hooks fail closed (preserving security) and block every Bash, WebFetch, and Read call until it's reinstalled.

Parameters 6–8 are optional and configure the audit-log S3 upload add-on (see the [AWS audit-log appendix](#appendix-aws-audit-log-setup)). They are best-effort: a failure to set up upload logs a warning but never blocks the governance install.

### Run

Run `InstallClaudeGovernance.sh` once as root on each managed machine. It:

1. Installs `/usr/local/bin/pull_claude_governance.sh` and runs it immediately.
2. Installs `/usr/local/bin/update_ai_governance`, a setuid wrapper so any local user can trigger a refresh without sudo.
3. Schedules a daily cron (12:00) to keep policies current.

Each run of `pull_claude_governance.sh` deploys `managed-settings.json`, `managed-mcp.json`, and `CLAUDE.md` to `/Library/Application Support/ClaudeCode/`, hook scripts to `/opt/claude/hooks/`, and the audit-log uploader to `/opt/claude/bin/`.

## Settings hierarchy

Claude Code uses a four-layer configuration system; higher layers take precedence and deny rules are cumulative. See [the Claude Code docs](https://code.claude.com/docs/en/settings#configuration-scopes) for full detail.

`managed-settings.json` is the security boundary — network egress, credential deny rules, sandbox policy, approved MCP servers, and mandatory hooks. Developers cannot edit it.

`CLAUDE.md` sits outside the permissions hierarchy. It shapes Claude's behaviour (conventions, tone, review expectations); the settings layers define what it is *allowed* to do.

## Control surfaces

- **Bash** — known-bad commands denied outright; medium-risk requires approval; common low-risk allowed.
- **Network** — egress restricted to an allowlist; generic download/exfiltration tools blocked.
- **Filesystem** — safe working dirs allowed; `.env`, `secrets/`, SSH keys, cloud creds, and system paths blocked.
- **GitHub** — read operations mostly allowlisted; PR creation/merge requires approval; history-rewriting flags blocked.
- **MCP servers** — locked to the managed allowlist. New servers go through the same PR process as new domains.
    - Atlassian server: Streamable HTTP (`https://mcp.atlassian.com/v1/mcp`), per-user OAuth, acting as the signed-in engineer. A managed PreToolUse hook (`mcp-policy-check.sh`) enforces a default-deny tool allowlist, currently scoped to Jira reads only. See [MCP server operational notes → Tool allowlist](#tool-allowlist-default-deny).
- **Skills** — `disableSkillShellExecution: true` prevents skill scripts from shelling out directly, forcing them through the hook-policed tool pathway.

## Hooks

Hooks are deployed to `/opt/claude/hooks/` and must be present before Claude Code runs — if a policy hook is missing or fails, the operation is blocked.

Two roles: **policy** hooks make allow/deny decisions; **audit** hooks observe and always allow. Both write to the same JSONL audit trail.

| Hook | Role | Triggers on |
|---|---|---|
| `bash-policy-check.sh` | policy | `PreToolUse` / Bash |
| `webfetch-policy-check.sh` | policy | `PreToolUse` / WebFetch |
| `pii-path-policy-check.sh` | policy | `PreToolUse` / Read, Edit, Write, MultiEdit |
| `pii-content-sniff.sh` | policy | `PreToolUse` / Read, Edit, Write, MultiEdit |
| `output-redact.sh` | policy | `PostToolUse` / Bash, Read, WebFetch |
| `tool-audit.sh` | audit | `PreToolUse` / Edit, Write, Task, SlashCommand, Read |
| `prompt-submit.sh` | audit | `UserPromptSubmit` |
| `session-audit.sh` | audit | `SessionStart`, `Stop`, `SessionEnd` |

- **`bash-policy-check.sh`** — enforces policy beyond glob matching; catches obfuscation and compound expressions that would bypass simple deny patterns.
- **`webfetch-policy-check.sh`** — enforces the domain allowlist.
- **`pii-path-policy-check.sh`** — deterministic denylist for file paths that suggest PII content: data exports (`*-export.csv`, `members.xlsx`), record dumps (`users.sql`, `customers.json`), and files inside data folders (`referrals/`, `exports/`, `dumps/`, `pii/`, `dsar/`). Matched case-insensitively against the basename and any parent directory segment. Fires on any tool whose `tool_input` carries a `file_path` (Read, Edit, Write, MultiEdit), so the agent cannot create a PII-named file via Write/Edit either — see [CLAUDE.md](ClaudeCode/CLAUDE.md) for the agent-behaviour layer that handles content discovered after a read.
- **`pii-content-sniff.sh`** — content-level fallback for misnamed files. On Read, scans the first 64 KiB of the on-disk file; on Write/Edit/MultiEdit, scans the inline `content`/`new_string`/`edits[].new_string` payload being written (there is nothing on disk yet for those tools). Scans for emails, UK postcodes, UK phone numbers, UK National Insurance numbers, IBANs, dates of birth, and grouped 16-digit card-shaped sequences. Denies the operation when at least 3 distinct categories appear or any single high-confidence pattern hits 10+ times. On Read, known binary extensions (xlsx, sqlite, png, etc.) with a NUL byte in the first KiB are skipped — the path-policy hook owns those by name; a NUL byte alone (with no binary extension) does not trigger the skip, so a text file cannot dodge scanning by prepending a NUL. Patterns, thresholds, and the counting logic are shared with `pii-staged-scan.sh` via `pii-patterns.sh`.
- **`output-redact.sh`** — scans tool output for secrets. On match, the result is blocked before entering Claude's context. The UI transcript may still show the raw output, but Claude cannot read or act on it. Patterns (defined in `lib/redact.sh`): PEM blocks, AWS keys, GitHub PATs (classic and fine-grained), `sk-` keys, Slack tokens, JWTs, Bearer headers, generic `key=value` / `password=value` assignments, connection strings, and Stripe/Twilio/SendGrid keys.
- **`tool-audit.sh`** — pure observer. Logs file paths and sizes for Edit/Write, subagent type and prompt length for Task, the command string for SlashCommand, and file path / offset / limit for Read. Never blocks.
- **`prompt-submit.sh`** — captures every prompt the user submits. The prompt text is passed through the same redaction patterns as tool output, so credentials pasted into prompts are stripped before they reach the audit log. The list of patterns that fired is recorded so an analyst can see *that* a secret was present without storing it.
- **`session-audit.sh`** — records session start (with source: `startup` / `resume` / `clear` / `compact`), `Stop` events, and `SessionEnd` reasons. Lets you reconstruct a per-session timeline by filtering the JSONL trail on `session_id`.

### Commit-time PII scanning

`ClaudeCode/scripts/pii-staged-scan.sh` runs at `git commit` time (via `.pre-commit-config.yaml`) and on every PR (via the `pre-commit` job in [.github/workflows/ci.yml](.github/workflows/ci.yml), which runs `pre-commit run --all-files`). It scans each file using the same pattern set as the runtime sniffer (sourced from [pii-patterns.sh](ClaudeCode/opt/claude/hooks/pii-patterns.sh)), and fails the commit/CI run if any file trips the 3-distinct-category or 10-density threshold.

This layer protects against PII that the runtime hooks can't see — content pasted into a file by a human, generated by Claude from memory, or staged from an unrelated working directory. It is independent of the agent: the scanner will refuse the commit regardless of how the content got there.

To enable locally:

```bash
pip install pre-commit
pre-commit install
```

`pre-commit install` cannot be run by Claude — the bash-policy hook blocks it. Enabling pre-commit is an explicit human action.

## Audit logs

Every hook writes one structured JSON Lines record per invocation to `~/.claude/debug/<hook>.jsonl`. **All invocations are logged, not just blocks or redacts** — allow decisions are recorded as `decision: "allow"` and pure observers use `decision: "observe"`.

| Hook | Log path |
|---|---|
| `bash-policy-check.sh` | `~/.claude/debug/bash-policy.jsonl` |
| `webfetch-policy-check.sh` | `~/.claude/debug/webfetch-policy.jsonl` |
| `pii-path-policy-check.sh` | `~/.claude/debug/pii-path-policy.jsonl` |
| `pii-content-sniff.sh` | `~/.claude/debug/pii-content-sniff.jsonl` |
| `output-redact.sh` | `~/.claude/debug/output-redact.jsonl` |
| `tool-audit.sh` | `~/.claude/debug/tool-audit.jsonl` |
| `prompt-submit.sh` | `~/.claude/debug/prompt-submit.jsonl` |
| `session-audit.sh` | `~/.claude/debug/session-audit.jsonl` |

### Retention

Logs are written on device, rotated locally by `newsyslog` (see [Log rotation](#log-rotation)), and shipped daily to the `mhi-claude-audit` S3 bucket, where they are retained for 395 days under Object Lock (see the [AWS audit-log appendix](#appendix-aws-audit-log-setup)).

### Record shape

Every record carries a common envelope:

| Field | Description |
|---|---|
| `schema_version` | Integer. Bumped on backwards-incompatible envelope changes (rename, semantic shift). Adding optional fields does not bump it. |
| `ts` | UTC timestamp, ISO-8601 |
| `hook` | Hook name (e.g. `bash-policy`) |
| `user` | Local OS user |
| `host` | Short hostname (`hostname -s`) — identifies which machine emitted the record |
| `proc_cwd` | Hook process working directory |
| `payload_cwd` | `cwd` reported by Claude Code in the hook payload |
| `session_id` | Claude Code session UUID |
| `transcript` | Path to the Claude Code transcript file on disk |
| `tool_name` | Tool the hook fired for (empty for session events) |
| `decision` | `allow`, `deny`, `redact`, `observe`, `submit`, `session_start`, `stop`, `session_end` |

Plus hook-specific fields. Examples:

```json
{"schema_version":1,"ts":"2026-05-19T14:22:01Z","hook":"bash-policy","user":"alice","host":"alice-mbp","session_id":"…","decision":"allow","cmd":"git status","segs":0}
{"schema_version":1,"ts":"2026-05-19T14:22:03Z","hook":"bash-policy","user":"alice","host":"alice-mbp","session_id":"…","decision":"deny","cmd":"sudo ls","reason":"sudo_su"}
{"schema_version":1,"ts":"2026-05-19T14:22:10Z","hook":"output-redact","user":"alice","host":"alice-mbp","session_id":"…","decision":"redact","matched":["AWS_KEY_ID"],"output_len":4096}
{"schema_version":1,"ts":"2026-05-19T14:22:30Z","hook":"prompt-submit","user":"alice","host":"alice-mbp","session_id":"…","decision":"submit","prompt":"deploy to staging using [REDACTED]","prompt_len":142,"redactions":["AWS_KEY_ID"]}
```

Review logs for repeated denies on the same command (legitimate use case to allow, or a workaround attempt), unexpected redact hits (project storing secrets badly), or repeated WebFetch denies on the same domain (dependency on an unapproved service).

The six logs are append-only and safe to tail or rotate. The governance pack ships them to S3 daily (see the [AWS audit-log appendix](#appendix-aws-audit-log-setup)); to forward them elsewhere as well (a SIEM, osquery), tail the same six paths.

### Log rotation

Manually:

```bash
: > ~/.claude/debug/bash-policy.jsonl
: > ~/.claude/debug/webfetch-policy.jsonl
: > ~/.claude/debug/pii-path-policy.jsonl
: > ~/.claude/debug/pii-content-sniff.jsonl
: > ~/.claude/debug/output-redact.jsonl
: > ~/.claude/debug/tool-audit.jsonl
: > ~/.claude/debug/prompt-submit.jsonl
: > ~/.claude/debug/session-audit.jsonl
```

For automated rotation, drop a `newsyslog` config into `/etc/newsyslog.d/`. Because logs are per-user, the config must use an expanded home path:

```
# /etc/newsyslog.d/claude-hooks-alice.conf
/Users/alice/.claude/debug/bash-policy.jsonl      alice:staff  640  7  -1  $D0  ZN
/Users/alice/.claude/debug/webfetch-policy.jsonl  alice:staff  640  7  -1  $D0  ZN
/Users/alice/.claude/debug/pii-path-policy.jsonl  alice:staff  640  7  -1  $D0  ZN
/Users/alice/.claude/debug/pii-content-sniff.jsonl alice:staff 640  7  -1  $D0  ZN
/Users/alice/.claude/debug/output-redact.jsonl    alice:staff  640  7  -1  $D0  ZN
/Users/alice/.claude/debug/tool-audit.jsonl       alice:staff  640  7  -1  $D0  ZN
/Users/alice/.claude/debug/prompt-submit.jsonl    alice:staff  640  7  -1  $D0  ZN
/Users/alice/.claude/debug/session-audit.jsonl    alice:staff  640  7  -1  $D0  ZN
```

Daily rotation, 7 compressed archives, no daemon signal. See `man 5 newsyslog.conf`.

## MCP server operational notes

This section covers how engineers use the Model Context Protocol (MCP) servers listed in [Control surfaces → MCP servers](#mcp-servers). The control pack defines *which* servers are permitted. This section explains how each one is authenticated and used.

### Atlassian Remote MCP server

**What it does.** Lets Claude Code read and update Jira issues and Confluence pages: fetch a ticket, post a comment, transition a status, or summarise a Confluence page. Useful for ticket triage, drafting comments from local code context, and pulling acceptance criteria into a working session.

**Endpoint.** `https://mcp.atlassian.com/v1/mcp` (Streamable HTTP transport). Hosted by Atlassian, so there is no local install, no API token, and no env var required on the engineer's machine. Atlassian also still serves an `/v1/sse` Server-Sent Events (SSE) endpoint for backward compatibility, but [recommends `/mcp`](https://github.com/atlassian/atlassian-mcp-server) for new clients. Claude Code also flags SSE as deprecated.

**Authentication model: per user, not global.** The Atlassian Remote MCP defaults to OAuth 2.1 and authenticates each engineer individually:

- On first use, Claude Code opens a browser. The engineer signs in with their MHI Atlassian account and grants scopes.
- Atlassian issues a per-user token bound to that engineer's identity and stored locally by Claude Code.
- Every action runs **as that engineer**, so existing Atlassian permissions, project access, and audit logs apply unchanged.

Atlassian also offers a per-user API token mode for headless or long-running clients. We don't use it here because the OAuth flow is friendlier and gives the same per-user attribution.

We do not configure a shared admin token. Beyond Atlassian not supporting that mode for Rovo MCP, it would break the audit trail (every action would appear as a service account) and would grant every Claude Code user the union of all permissions.

> **One-time org admin step (verify before broad rollout):** an Atlassian org admin may need to confirm the Remote MCP / Rovo feature is enabled at the org level in the Atlassian admin console before individual users can connect. On some Atlassian plans this is on by default. On plans with stricter defaults an admin must allow it. This needs to be confirmed against the current Atlassian admin documentation before this PR is marked ready for review. Contact max.levine@mhiuk.org or edward@mhiuk.org, who hold the Atlassian admin role.

### First-use setup (per engineer)

1. Open Claude Code in any working directory.
2. At the prompt, type `/mcp`. The `atlassian` server should be listed with status `disconnected`.
3. Select `atlassian` and choose `Connect`. Claude Code opens your browser to Atlassian.
4. Sign in with your MHI Atlassian account.
5. Review the requested scopes carefully. Grant only the scopes you need for your work. You can re-grant later if more are needed.
6. Return to Claude Code. `/mcp` should now show `atlassian` as `connected`.

You only need to do this once per machine. The token is stored locally by Claude Code and refreshed automatically by Atlassian.

### Scope guidance

When the OAuth consent screen asks for scopes:

- **Grant:** read access to Jira issues and Confluence pages, required for the common case (ticket lookup, page summarisation).
- **Grant only if you need it:** write access (creating issues, posting comments, transitioning status, editing pages). If your work is read-only, do not grant write scopes.
- **Do not grant:** admin scopes (user management, project administration). Claude Code does not need these, and they widen the blast radius if a prompt injection drives Claude into unintended actions.

Scope choices are made by the engineer at the consent screen and can be widened by reconnecting, so they bound but do not enforce what Claude may do. The tool allowlist below is the enforced layer.

### Tool allowlist (default-deny)

Connecting authenticates Claude Code **as the signed-in engineer**, so without a further control it could call any tool the Atlassian MCP exposes with that engineer's permissions. To bound this, a managed PreToolUse hook (`/opt/claude/hooks/mcp-policy-check.sh`, matcher `mcp__.*`) enforces a per-server **default-deny allowlist**: an MCP tool runs only when its name is listed for its server in the `is_allowed` function inside the hook. Every tool not listed is denied, and every tool of a server with no entry at all is denied. An unparseable tool name also denies. The allowlist is the only thing that grants tool access, and it lives in the hook script itself (the sole consumer), not in `managed-settings.json`. `allowedMcpServers` in `managed-settings.json` controls which servers may connect; the hook controls which of their tools may run.

This is a managed control, not an engineer preference: it cannot be overridden from user or project settings, and it holds regardless of which OAuth scopes were granted or how broad the engineer's Atlassian permissions are.

The current `atlassian` allowlist permits Jira **reads only**: `getJiraIssue`, `getJiraIssueRemoteIssueLinks`, `getJiraIssueTypeMetaWithFields`, `getJiraProjectIssueTypesMetadata`, `getIssueLinkTypes`, `getTransitionsForJiraIssue`, `getVisibleJiraProjects`, `lookupJiraAccountId`, and `searchJiraIssuesUsingJql`, plus the two shared tools every call needs (`getAccessibleAtlassianResources`, `atlassianUserInfo`). All write tools (`createJiraIssue`, `editJiraIssue`, `addCommentToJiraIssue`, `addWorklogToJiraIssue`, `createIssueLink`, `transitionJiraIssue`) and the Rovo cross-product `search` and `fetch` tools are denied, as are all Confluence, Compass, and Teamwork Graph tools. To change what is permitted, edit the `is_allowed` function in `mcp-policy-check.sh` and redeploy the hook.

#### Project scoping

On top of the tool allowlist, the same hook bounds Jira reads to an allowlist of **project keys**, held in `ATLASSIAN_PROJECTS` in `mcp-policy-check.sh` (currently `PLAN`, `DENGS`, `DATA`, `MJB`). A read that names a project or issue is allowed only when its key is on that list; every other project is denied with `project_not_in_allowlist` before the call reaches Atlassian. The key is taken from the prefix of an `issueIdOrKey` (`PLAN-12` → `PLAN`), from a `projectIdOrKey`, or from the project clause of a `searchJiraIssuesUsingJql` query. Keys are compared case-insensitively.

Two cases fail closed (denied), because the hook cannot resolve them without calling Atlassian: a bare numeric issue id or project id (use the `KEY-123` / `KEY` form instead), and a JQL query that is not bounded to allowlisted projects. A JQL query is accepted only when it is AND-only (no `OR`, no `NOT`, so every clause is conjunctive and a positive project restriction bounds the whole result set) and carries a `project = KEY` or `project in (KEY, ...)` clause naming only allowlisted keys. This deliberately rejects some safe-but-complex queries rather than risk allowing one that escapes the allowlist. The cross-project tools that take no project key (`getVisibleJiraProjects`, `lookupJiraAccountId`, `getIssueLinkTypes`, and the two shared tools) are not bound by the project allowlist, since it cannot express "list only these projects". To change which projects are readable, edit `ATLASSIAN_PROJECTS` and redeploy the hook.

The full Atlassian tool catalogue, with the permission group and OAuth scope for each tool, is at <https://support.atlassian.com/atlassian-rovo-mcp-server/docs/supported-tools/>. An Atlassian organisation admin can also revoke whole permission groups (for example `write_jira`) at source in the admin console, which is independent of this hook and worth pairing with it for defence in depth.

### Revocation

To revoke Claude Code's access to your Atlassian account:

1. Sign in to <https://id.atlassian.com>.
2. Go to **Account settings → Connected apps** (or **Authorized apps**, depending on UI version).
3. Find the Claude Code / Anthropic entry and click **Revoke access**.

The next `/mcp` connection attempt will require re-consent.

### Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `/mcp` shows `atlassian` as `disconnected` and `Connect` does nothing | Browser handler not registered, or the Atlassian login page is blocked by a corporate proxy | Try again from a network that can reach `id.atlassian.com` and `mcp.atlassian.com`. If your browser does not auto-open, copy the URL from the Claude Code log |
| `Connect` opens the browser but the page is blank or shows an Atlassian error | Org-level Remote MCP / Rovo not enabled, or your Atlassian account does not have access to the requested product | Contact an Atlassian admin (max.levine@mhiuk.org / edward@mhiuk.org) to confirm the feature is enabled and your account is provisioned |
| `mcp__atlassian__*` tool calls fail with `403` or `401` after a successful connect | OAuth scope mismatch: the action requires a scope you did not grant | Disconnect via `/mcp`, reconnect, and grant the missing scope on the consent screen |
| `mcp.atlassian.com` requests blocked at the network layer | Hook or sandbox not yet updated on this machine | Run `update_ai_governance` and retry, then confirm `mcp.atlassian.com` is in the deployed `managed-settings.json` `network.allowedDomains` |
| An `mcp__atlassian__<tool>` call is denied with "not in the policy allowlist" | The tool is intentionally blocked: the allowlist permits Jira reads only | Expected for write tools and non-Jira products. If you genuinely need a tool, propose adding it to the `is_allowed` function in `mcp-policy-check.sh` through the usual PR process |
| A read is denied with "Jira project not in the policy allowlist" | The project is not on `ATLASSIAN_PROJECTS`, or a JQL query is not bounded to allowlisted projects | Use a `KEY-123` issue key or `KEY` project key from an allowlisted project, and write JQL as an AND-only query with a `project = KEY` / `project in (...)` clause. To read a new project, propose adding its key to `ATLASSIAN_PROJECTS` through the usual PR process |

### Audit and visibility

All Jira and Confluence actions made through this MCP appear in Atlassian's standard audit log, attributed to the signed-in engineer. There is no separate Claude Code audit log on the Atlassian side. On the Claude Code side, MCP tool calls appear in the conversation transcript as `mcp__atlassian__<toolname>` entries.

## Deployment

Merging to `main` does **not** auto-deploy — the daily cron picks it up. To push immediately:

```bash
update_ai_governance                            # any local user, no sudo
/usr/local/bin/pull_claude_governance.sh        # or directly as root
```

Verify after deploying:

```bash
cat /Library/Application\ Support/ClaudeCode/VERSION
shasum -a 256 /opt/claude/hooks/*.sh
shasum -a 256 /Library/Application\ Support/ClaudeCode/managed-settings.json
```

Then open Claude Code in this repo and run `/test-guardrails` to confirm all controls are live. For hook or permission changes, do this on affected machines immediately after merge rather than waiting for cron.

### Incident response

On suspected bypass:

1. Review `~/.claude/debug/*.jsonl` on the affected machine.
2. Confirm deployed version matches `main`: `cat /Library/Application\ Support/ClaudeCode/VERSION`.
3. Verify installed hooks match the repo at that SHA via `shasum`.
4. If tampering is evident, follow MHI's standard incident response.

## Troubleshooting

Most hook errors (`hook exited with non-zero status`, `hook script not found`) mean hooks aren't deployed. Run `update_ai_governance` and retry.

If it persists: confirm hooks exist and are executable in `/opt/claude/hooks/`, check the relevant log in `~/.claude/debug/`, and run `/test-guardrails`. If a command you expect to work is blocked and the log shows a false positive, raise a PR — don't work around it.

## Change control

Ownership:

| Layer | Owned by |
|---|---|
| `managed-settings.json`, `CLAUDE.md`, hooks, sandbox, approved domains/MCP | IT and security |
| `.claude/settings.json` (repo-local automation, low-risk allowlists) | Repo maintainers |
| `~/.claude/settings.json`, `.claude/settings.local.json` (personal/convenience) | Individual engineers |

Engineers may improve convenience inside the rails; they do not control the rails.

> **Important:** settings layers control whether Claude *asks* before acting. They do not control what the *hooks* allow. Adding an allow rule locally will not unblock something a hook rejects — that requires a PR to the hook or to `managed-settings.json`.

### What needs a PR here

| Request | Target file |
|---|---|
| New WebFetch domain | `managed-settings.json` (`network.allowedDomains` — `webfetch-policy-check.sh` reads this list at runtime, no separate hook edit needed) |
| Restrict a WebFetch domain to a path prefix | `managed-settings.json` (`network._webfetchPathScopes` — WebFetch-only; the OS sandbox and Bash egress still reach any path on the host) |
| Allow a currently-blocked Bash command | `bash-policy-check.sh` |
| New/updated secret-detection pattern | `opt/claude/hooks/lib/redact.sh` |
| New/updated PII path or directory pattern | `pii-path-policy-check.sh` |
| New/updated PII content detector or threshold tweak | `pii-patterns.sh` (shared by sniffer and pre-commit scanner) |
| Pre-commit/CI scanner change (exclude prefixes, thresholds) | `pii-staged-scan.sh` |
| New MCP server | `managed-settings.json` |
| Behavioural guidance change | `CLAUDE.md` |
| Team-wide repo allow rule | `.claude/settings.json` in that repo (not here) |
| Personal preference | `~/.claude/settings.json` locally (not here) |

If unsure, raise an issue or contact IT and security.

### Exception process

Before requesting an exception, check whether Claude can reach the same outcome a different way (a different tool, a rephrased command, or generating the command for you to run manually).

If not, open a PR against `main` using the PR template — it prompts for the security risk assessment. If you'd rather not raise the PR yourself, contact max.levine@mhiuk.org or edward@mhiuk.org.

The security team reviews against: whether existing controls already cover the use case, prompt-injection exploit risk if widened, and whether a project-level setting would be more appropriate than an org-wide change. Both CODEOWNERS (@edwardmhi, @maxlevine-mhi) must approve. Response within 5 working days; flag urgency in the PR.

Approved PRs are tested with `/test-guardrails`, merged, and deployed via the next cron (or `update_ai_governance` for immediate rollout).

If declined and you disagree, escalate via your line manager to head of IT or security.

#### Commonly refused requests

| Request | Reason | Alternative |
|---|---|---|
| `curl` / `wget` | Exfiltration vector | Use `WebFetch` (domain-allowlisted) |
| `sudo` | Privilege escalation | Run privileged operations outside Claude Code |
| Read `.env` | Credential exposure | Pass values via env vars, not files |
| Read `users.csv`, `members-export.xlsx`, `referrals/*` | PII exposure | Use a redacted sample, schema-only view, or synthetic fixture |
| Arbitrary domains | Egress control | Submit a domain addition |
| `git --force` | Destructive | Use non-destructive git workflows |

## Continuous integration

`.github/workflows/ci.yml` runs on every PR and on pushes to `main`. It installs `pre-commit` and runs `pre-commit run --all-files`, so the lint, format, and config-validity checks are defined once in `.pre-commit-config.yaml` and run identically locally and in CI.

What CI covers:

| Check | Hook | Catches |
|---|---|---|
| Shell lint | `shellcheck` (`-x`, severity warning) | unquoted vars, lost exit codes, subshell scoping bugs, and similar faults that can make a hook silently *allow* what it should block |
| JSON validity | `check-json` | a malformed `managed-settings.json` or `.claude/settings.json` that would break enforcement or startup |
| YAML validity | `check-yaml` | broken workflow / config YAML |
| Hygiene | `end-of-file-fixer`, `trailing-whitespace`, `mixed-line-ending`, `check-merge-conflict`, `check-added-large-files`, shebang checks | stray bytes, unresolved conflicts, accidental large files |

> **CI does not verify guardrail *behaviour*.** It checks that scripts parse and configs are valid, not that a given command is still blocked. The `/test-guardrails` suite is the behaviour regression net; a full run is required in the PR description for changes to hooks, permissions, sandbox config, or `managed-settings.json` (see the PR template).

`.pre-commit-config.yaml` is in the sandbox write-deny list by design, so Claude Code cannot edit it — the same control that protects `.git/hooks` and `.husky`. Maintainers edit it by hand.

Optional local install (catches the same issues before you push):

```sh
pip install pre-commit   # or: brew install pre-commit
pre-commit install       # runs the hooks on each commit
pre-commit run --all-files   # run them all on demand
```

Pre-commit is bypassable with `git commit --no-verify`, so CI is the real gate; local install is a convenience.

## Governance alignment

`control_mappings.csv` maps each control to ISO 42001, NIST AI RMF, and OWASP LLM Top 10 (LLM01 Prompt Injection, LLM02 Insecure Output, LLM06 Sensitive Info Disclosure, LLM08 Excessive Agency).

---

# Appendix: AWS audit-log setup

Manual AWS setup for the Claude Code audit log pipeline. Provisions the S3 bucket the devices ship logs to, one fleet-wide write-only writer identity, and the read-only investigation access.

This is **Phase 0** of the audit logging rollout. The local JSONL hooks above are the source of the records; this appendix covers shipping them off-box. The device side is already implemented: `ClaudeCode/opt/claude/bin/upload-audit-logs.sh` runs from a daily root cron and uploads new log bytes with `aws s3 cp` (no Vector, no daemon). See [Device side: the uploader](#device-side-the-uploader).

**Upload identity is deliberately simple.** Uploads are not cryptographically attributed to a device. Attribution comes from the `user` and `host` fields stamped into every record (see [Record shape](#record-shape)), so one fleet-wide write-only credential is enough. The trade-offs, and the upgrade path if per-device crypto identity is ever needed, are in [Identity model](#identity-model-and-upgrade-path).

> **Status: manual setup.** The AWS side is delivered by hand via the AWS CLI steps below. It will be converted to infrastructure-as-code (Terraform) at a later date. Until then, treat this section as the source of truth for what exists in the account, and make changes by following these steps, not ad-hoc in the console, so the eventual IaC import is clean.

## What you create

| Resource | Purpose |
|---|---|
| S3 bucket `mhi-claude-audit` | The log bucket. UK region. SSE-S3. Versioning ON. Object Lock (GOVERNANCE, 395d). Lifecycle policy. TLS-only. |
| Bucket lifecycle rule `claude-audit-tiering` | 30d hot → 120d IA → 395d delete |
| IAM user `claude-audit-writer` (one, fleet-wide) | Single write-only writer. `s3:PutObject` under `claude-audit/` only. No read, no list, no delete. |
| SSO permission set `claude-audit-reader` | Read-only access for ad-hoc DuckDB investigation, assigned to a readers group in IAM Identity Center |

The bucket and writer IAM go in MHI's dedicated logging / security account (Log Archive pattern), not a workload account, so a compromised workload account cannot tamper with or delete the audit trail. All commands assume the AWS CLI is configured with an admin profile for **that** account and `eu-west-2` (London) as the region.

```bash
export AWS_REGION=eu-west-2          # UK region, required for GDPR data residency (see below)
export BUCKET=mhi-claude-audit       # must be globally unique; change if taken

aws sts get-caller-identity          # confirm you are in the logging/security account before creating anything
```

## 1. Create and harden the S3 bucket

### 1.1 Create the bucket

**Region is pinned to the UK (`eu-west-2`) for UK GDPR data residency.** The logs contain prompt text and command lines, which can include personal data.

`--object-lock-enabled-for-bucket` must be set at creation. Object Lock requires versioning and, once enabled, cannot be disabled, so this is a create-time, effectively-permanent decision. Enabling it at creation also turns versioning on automatically.

```bash
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION" \
  --object-lock-enabled-for-bucket
```

### 1.2 Block all public access

Blocks every form of public access at the bucket's control plane, regardless of any future bucket policy.

```bash
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

> Apply this **before** the bucket policy in step 1.7, otherwise the policy attempt can race the account-level restriction.

### 1.3 Enable encryption at rest

```bash
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": { "SSEAlgorithm": "AES256" },
      "BucketKeyEnabled": true
    }]
  }'
```

### 1.4 Versioning is ON

Versioning was enabled automatically by `--object-lock-enabled-for-bucket` in step 1.1. Confirm it:

```bash
aws s3api get-bucket-versioning --bucket "$BUCKET"   # expect: Status = Enabled
```

The uploader writes immutable gzipped deltas with unique keys and never reuses a key, so versioning adds negligible storage in normal operation. Its purpose here is to satisfy Object Lock (step 1.8), which gives the audit trail WORM protection. The lifecycle rule (step 1.6) expires noncurrent versions too, so cost stays bounded.

### 1.5 Confirm Object Ownership is Bucket owner enforced (default)

New buckets default to **Bucket owner enforced**, which disables ACLs. That is what we want: access is governed by IAM/bucket policy only, and the writer policy in section 2 grants no ACL permission. With ACLs disabled, any `PutObject` that specifies an ACL is rejected with `400 AccessControlListNotSupported`; the uploader sends none. Confirm the default:

```bash
aws s3api get-bucket-ownership-controls --bucket "$BUCKET"
# Expect: ObjectOwnership = BucketOwnerEnforced (or no controls set, the same default)
```

### 1.6 Lifecycle policy

30 days hot (Standard) → Standard-IA → Glacier Instant Retrieval → delete at 395 days.

**395 days = 13 months.** The current-version `Expiration` (395d) and the Object Lock default retention (step 1.8) express the same 395-day intent; keep them equal so a lifecycle delete never collides with an unexpired lock.

```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "claude-audit-tiering",
      "Status": "Enabled",
      "Filter": { "Prefix": "claude-audit/" },
      "Transitions": [
        { "Days": 30,  "StorageClass": "STANDARD_IA" },
        { "Days": 120, "StorageClass": "GLACIER_IR" }
      ],
      "Expiration": { "Days": 395 },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 395 }
    }]
  }'
```

### 1.7 TLS-only bucket policy

Belt-and-braces alongside AWS's own TLS-only endpoint default: this denies plaintext attempts at the bucket layer too, so a misconfigured client can't accidentally write logs over HTTP. Substitute your bucket ARN (`arn:aws:s3:::mhi-claude-audit`).

```bash
aws s3api put-bucket-policy \
  --bucket "$BUCKET" \
  --policy '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::mhi-claude-audit",
        "arn:aws:s3:::mhi-claude-audit/*"
      ],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }]
  }'
```

### 1.8 Object Lock default retention

A GOVERNANCE-mode default retention means every uploaded object is WORM-protected for 395 days: the writer and routine admins cannot delete or overwrite logs within that window. GOVERNANCE (not COMPLIANCE) is deliberate, a break-glass role holding `s3:BypassGovernanceRetention` can still erase data if a GDPR obligation (e.g. a data-subject erasure request) requires it. COMPLIANCE mode was rejected: under it nothing, including root, can delete before expiry, which conflicts with GDPR erasure duties.

```bash
aws s3api put-object-lock-configuration \
  --bucket "$BUCKET" \
  --object-lock-configuration '{
    "ObjectLockEnabled": "Enabled",
    "Rule": { "DefaultRetention": { "Mode": "GOVERNANCE", "Days": 395 } }
  }'
```

> Keep `s3:BypassGovernanceRetention` off the writer policy (section 2 grants `s3:PutObject` only) and off routine admin roles; restrict it to a named break-glass role. That is what makes the WORM guarantee meaningful: the writer physically cannot delete the audit trail.

### 1.9 Tag the bucket

Tags drive cost allocation (the budget filter keys on `Project`) and record ownership and data classification.

```bash
aws s3api put-bucket-tagging \
  --bucket "$BUCKET" \
  --tagging 'TagSet=[
    {Key=Project,Value=claude-code-audit},
    {Key=Owner,Value=IT and Security},
    {Key=DataClassification,Value=audit-logs-personal-data},
    {Key=ManagedBy,Value=manual}
  ]'
```

## 2. Create the single write-only writer IAM user

One IAM user for the whole fleet. Its inline policy allows only `s3:PutObject` under the `claude-audit/` prefix: it cannot read any object, cannot list the bucket, and cannot delete. Because attribution comes from the record contents (`user` / `host`), there is no per-host identity to provision.

The object key layout the uploader writes (the `host` and `user` segments partition the bucket for browsability; they are **not** a security boundary now, since the single writer may write any path under `claude-audit/`):

```
claude-audit/year=YYYY/month=MM/day=DD/host=<host>/user=<user>/<hook>/<epoch>-<offset>-<rand>.log.gz
```

### 2.1 Create the user

```bash
aws iam create-user \
  --user-name claude-audit-writer \
  --path /claude-audit/ \
  --tags Key=Role,Value=claude-audit-writer Key=Project,Value=claude-code-audit Key=Owner,Value="IT and Security" Key=ManagedBy,Value=manual
```

### 2.2 Attach the write-only inline policy

`s3:PutObject` only. No `s3:PutObjectAcl`: ACLs are disabled (step 1.5), so an ACL-bearing PUT would be rejected and the grant is dead weight. No read, list, or delete, so a leaked writer key cannot read other people's logs or delete anything (and Object Lock blocks deletion regardless).

```bash
aws iam put-user-policy \
  --user-name claude-audit-writer \
  --policy-name claude-audit-writer \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "WriteOnlyAuditLogs",
      "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": "arn:aws:s3:::mhi-claude-audit/claude-audit/*"
    }]
  }'
```

Writing to a bucket that carries a default retention configuration needs only `s3:PutObject`; retention is applied by the bucket, not the caller (validated 2026-06-24, see [Validating the write-only boundary](#validating-the-write-only-boundary)).

### 2.3 Create an access key

The secret is returned **exactly once**, capture it now. Store it in 1Password; never redirect it to a file in the repo. It is deployed to each device via Jamf (see [Device side: the uploader](#device-side-the-uploader), parameters `$7`/`$8`). The key is visible to whoever holds Jamf admin, which is acceptable for a write-only key.

```bash
aws iam create-access-key --user-name claude-audit-writer
```

## 3. Grant read-only investigation access via SSO

Readers get access through **AWS IAM Identity Center (SSO)**, not per-person IAM users. This means no static reader keys to store or rotate, no IAM user per individual, and removal is a group-membership change. Investigators authenticate with `aws sso login`, which vends short-lived credentials that DuckDB picks up from the named profile.

Do this **once** for the account, then add/remove people by group membership.

### 3.1 Create the permission set

A permission set is the SSO equivalent of the read-only IAM policy: list + get across the whole bucket, no write. Replace `<sso-instance-arn>` with your Identity Center instance ARN (`aws sso-admin list-instances`).

```bash
export SSO_INSTANCE_ARN=<sso-instance-arn>

aws sso-admin create-permission-set \
  --instance-arn "$SSO_INSTANCE_ARN" \
  --name "claude-audit-reader" \
  --description "Read-only access to the Claude Code audit log bucket for DuckDB investigation" \
  --session-duration "PT4H"
```

Capture the returned `PermissionSetArn` as `$PS_ARN`, then attach the same read-only policy as an inline policy on the permission set:

```bash
aws sso-admin put-inline-policy-to-permission-set \
  --instance-arn "$SSO_INSTANCE_ARN" \
  --permission-set-arn "$PS_ARN" \
  --inline-policy '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "ListBucket",
        "Effect": "Allow",
        "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
        "Resource": "arn:aws:s3:::mhi-claude-audit"
      },
      {
        "Sid": "ReadObjects",
        "Effect": "Allow",
        "Action": ["s3:GetObject"],
        "Resource": "arn:aws:s3:::mhi-claude-audit/*"
      }
    ]
  }'
```

### 3.2 Assign the permission set to a readers group

Create (or reuse) a group in your identity source (e.g. `claude-audit-readers`) and assign the permission set to it for the target account:

```bash
aws sso-admin create-account-assignment \
  --instance-arn "$SSO_INSTANCE_ARN" \
  --permission-set-arn "$PS_ARN" \
  --principal-type GROUP \
  --principal-id "<group-id>" \
  --target-type AWS_ACCOUNT \
  --target-id "<account-id>"
```

Add or remove investigators by editing membership of `claude-audit-readers` in your identity source. No AWS changes are needed per person.

### 3.3 Reader workflow

Each investigator configures an SSO profile once and logs in to get temporary credentials; DuckDB's S3 reads use that profile:

```bash
aws configure sso --profile claude-audit          # one-time, per machine
aws sso login --profile claude-audit              # whenever the session expires
export AWS_PROFILE=claude-audit                    # DuckDB picks creds up from here
```

No long-lived reader secrets exist, so there is nothing to commit, rotate, or revoke per person.

## Device side: the uploader

The uploader ships with the governance pack, so most of this is automatic.

- **What it is:** `ClaudeCode/opt/claude/bin/upload-audit-logs.sh`, deployed to `/opt/claude/bin/` by `pull_claude_governance.sh` (self-updating, like the hooks) and run by a daily root cron at 12:30.
- **What it ships:** only the six governance hook logs, from every user's `~/.claude/debug/`. It reads each file's new bytes since the last successful run (a per-`(user,hook)` byte offset under `/var/root/.claude-audit-state/`), gzips them, and uploads an immutable delta object. Growing files are never re-uploaded; nothing is overwritten or deleted, and `newsyslog` owns local retention. Claude Code's own debug output and session transcripts are never shipped (the uploader whitelists the six hook names).
- **Credentials:** the single write-only key at `/var/root/.aws/credentials` (mode 0600), written once by `InstallClaudeGovernance.sh`. The uploader sets `AWS_SHARED_CREDENTIALS_FILE` / `AWS_CONFIG_FILE` explicitly, so it does not depend on the cron environment's `$HOME`.

To enable it on a machine, supply three parameters to the Jamf install policy (alongside the jq/CLT triggers `$4`/`$5`):

| Parameter | Value |
|---|---|
| `$6` | Jamf custom trigger that installs the AWS CLI (trigger name `installAwsCli`) |
| `$7` | `claude-audit-writer` access key id |
| `$8` | `claude-audit-writer` secret access key |

When `$7`/`$8` are absent the upload add-on is skipped entirely and the core governance install is unaffected. It is best-effort and never blocks the security controls. The AWS CLI is net-new on the fleet and is installed via the `installAwsCli` policy when missing.

## Validating the write-only boundary

Validated against the live bucket on 2026-06-24 (account `286308815827`, `eu-west-2`). Re-run after any change to the writer policy, using a profile configured with the **writer** credential. Do not use an admin profile, under which all of these pass trivially and prove nothing.

```bash
aws configure --profile claude-writer        # writer AccessKeyId + Secret, region eu-west-2

# SHOULD SUCCEED. Also confirms PutObject-only works against the Object Lock bucket
echo test | gzip | aws s3 cp - \
  s3://mhi-claude-audit/claude-audit/year=2026/month=06/day=24/host=probe/test/probe.log.gz \
  --content-encoding gzip --profile claude-writer

# SHOULD AccessDenied: no list/read
aws s3 ls s3://mhi-claude-audit/ --profile claude-writer

# SHOULD AccessDenied: no delete (Object Lock would hold anyway)
aws s3 rm s3://mhi-claude-audit/claude-audit/year=2026/month=06/day=24/host=probe/test/probe.log.gz \
  --profile claude-writer
```

If the write succeeds and both the `ls` and `rm` return `AccessDenied`, the boundary holds. Note: on a versioned bucket, `aws s3 rm` with no version id only writes a delete marker; the Object-Lock-protected version remains underneath. The probe object is itself WORM-locked for 395 days, so either accept a throwaway probe aging out via lifecycle or validate against a separate scratch bucket.

## Secrets handling

The writer key is a single long-lived static credential; the AWS API returns its secret exactly once, at creation.

- Never commit it. Store it in 1Password and deploy it only via Jamf, which writes it to `/var/root/.aws/credentials` (0600, root-only) on each machine.
- It is **write-only** (`s3:PutObject` under the log prefix). A leak cannot read or delete logs; the worst case is junk writes into the prefix (storage noise), which Object Lock and the cost alert both bound.
- Limit who can run `iam create-access-key` against the user to operators who already hold IAM admin in the logging account; key-creation access *is* credential access.
- Rotate on a schedule or on suspected compromise: create the replacement key, push it via Jamf, confirm uploads continue, then delete the old key.

When this phase is converted to Terraform, the access key will end up in Terraform state; at that point the remote state backend must be encrypted at rest and access-controlled.

## Adding or removing a managed Mac

- **Add:** enrol the Mac in Jamf and run the install policy with parameters `$6`–`$8`. It installs the AWS CLI, writes the shared credential, deploys the uploader, and schedules the cron. No per-machine AWS change.
- **Remove:** unenrol or wipe via Jamf. There is no per-machine AWS object to delete.
- **Revocation is fleet-wide, not per-device.** Because every Mac shares one key, you cannot cut off a single lost device without rotating the key for all of them (one `iam create-access-key` / `delete-access-key` cycle plus a Jamf policy update). If per-device revocation ever becomes a hard requirement, that is the trigger to consider the upgrade path below. Existing log data is never purged on offboarding; it stays until lifecycle expiry, erasable early only via the break-glass role for a GDPR obligation.

## Identity model and upgrade path

A single shared write-only key keeps Phase 0 small: no per-device provisioning, no certificates, no CA. The accepted costs are fleet-wide revocation (above) and that a leaked key could write junk into the prefix, though it can never read or delete (Object Lock holds).

If per-device identity is ever needed, the upgrade swaps only the credential mechanism; the bucket, uploader, and log format do not change.

## Cost monitoring

Set a CloudWatch budget alert (substitute your account ID):

```bash
aws budgets create-budget --account-id <acct> --budget '{
  "BudgetName": "claude-audit-monthly",
  "BudgetLimit": {"Amount": "20", "Unit": "GBP"},
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST",
  "CostFilters": {"TagKeyValue": ["user:Project$claude-code-audit"]}
}'
```

£20/month is well above the expected ~£1–2/month for a fleet of this size. Any alert means something is wrong, so investigate before paying it.

> The cost filter keys on a `Project=claude-code-audit` tag. The Terraform applied that tag automatically via `default_tags`; in the manual flow there's no provider to do it for you, so the budget filter is best-effort. When you convert to IaC, restore the `default_tags` block (`Project=claude-code-audit`, `Owner=security`, `ManagedBy=terraform`) so the filter becomes reliable.
