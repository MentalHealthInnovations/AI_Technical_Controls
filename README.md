# Claude Code — AI Agent Governance Control Pack

A layered configuration system that makes Claude Code safer to use at scale. The goal is fewer prompts, not more — by removing the riskiest options from the environment up front.

## File manifest

| File | Purpose |
|------|---------|
| `ClaudeCode/managed-settings.json` | Org-wide immutable guardrails |
| `ClaudeCode/CLAUDE.md` | Behavioural guidance for Claude Code agents |
| `ClaudeCode/control_mappings.csv` | Control mapping to ISO 42001 / NIST AI RMF |
| `ClaudeCode/opt/claude/hooks/bash-policy-check.sh` | Pre-execution policy hook for Bash |
| `ClaudeCode/opt/claude/hooks/webfetch-policy-check.sh` | Pre-execution policy hook for WebFetch |
| `ClaudeCode/opt/claude/hooks/output-redact.sh` | Post-execution secret redaction for Bash/Read/WebFetch |
| `ClaudeCode/opt/claude/hooks/tool-audit.sh` | Audit-only hook for Edit, Write, Task, SlashCommand, Read |
| `ClaudeCode/opt/claude/hooks/prompt-submit.sh` | Audit-only hook for `UserPromptSubmit` (logs redacted prompt text) |
| `ClaudeCode/opt/claude/hooks/session-audit.sh` | Audit-only hook for `SessionStart`, `Stop`, `SessionEnd` |
| `ClaudeCode/opt/claude/hooks/lib/audit-log.sh` | Shared helper: appends a JSONL record per invocation |
| `ClaudeCode/opt/claude/hooks/lib/redact.sh` | Shared secret-redaction patterns (output + prompt) |
| `ClaudeCode/pull_claude_governance.sh` | Pulls and deploys policy files; self-updates each run |
| `ClaudeCode/InstallClaudeGovernance.sh` | One-time macOS bootstrap for `pull_claude_governance.sh` |
| `.claude/skills/test-guardrails/SKILL.md` | `/test-guardrails` verification suite |

## Installation

Run `InstallClaudeGovernance.sh` once as root on each managed machine. It:

1. Installs `/usr/local/bin/pull_claude_governance.sh` and runs it immediately.
2. Installs `/usr/local/bin/update_ai_governance`, a setuid wrapper so any local user can trigger a refresh without sudo.
3. Schedules a daily cron (12:00) to keep policies current.

Each run of `pull_claude_governance.sh` deploys `managed-settings.json` and `CLAUDE.md` to `/Library/Application Support/ClaudeCode/`, and hook scripts to `/opt/claude/hooks/`.

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
- **Skills** — `disableSkillShellExecution: true` prevents skill scripts from shelling out directly, forcing them through the hook-policed tool pathway.

## Hooks

Hooks are deployed to `/opt/claude/hooks/` and must be present before Claude Code runs — if a policy hook is missing or fails, the operation is blocked.

Two roles: **policy** hooks make allow/deny decisions; **audit** hooks observe and always allow. Both write to the same JSONL audit trail.

| Hook | Role | Triggers on |
|---|---|---|
| `bash-policy-check.sh` | policy | `PreToolUse` / Bash |
| `webfetch-policy-check.sh` | policy | `PreToolUse` / WebFetch |
| `output-redact.sh` | policy | `PostToolUse` / Bash, Read, WebFetch |
| `tool-audit.sh` | audit | `PreToolUse` / Edit, Write, Task, SlashCommand, Read |
| `prompt-submit.sh` | audit | `UserPromptSubmit` |
| `session-audit.sh` | audit | `SessionStart`, `Stop`, `SessionEnd` |

- **`bash-policy-check.sh`** — enforces policy beyond glob matching; catches obfuscation and compound expressions that would bypass simple deny patterns.
- **`webfetch-policy-check.sh`** — enforces the domain allowlist.
- **`output-redact.sh`** — scans tool output for secrets. On match, the result is blocked before entering Claude's context. The UI transcript may still show the raw output, but Claude cannot read or act on it. Patterns (defined in `lib/redact.sh`): PEM blocks, AWS keys, GitHub PATs (classic and fine-grained), `sk-` keys, Slack tokens, JWTs, Bearer headers, generic `key=value` / `password=value` assignments, connection strings, and Stripe/Twilio/SendGrid keys.
- **`tool-audit.sh`** — pure observer. Logs file paths and sizes for Edit/Write, subagent type and prompt length for Task, the command string for SlashCommand, and file path / offset / limit for Read. Never blocks.
- **`prompt-submit.sh`** — captures every prompt the user submits. The prompt text is passed through the same redaction patterns as tool output, so credentials pasted into prompts are stripped before they reach the audit log. The list of patterns that fired is recorded so an analyst can see *that* a secret was present without storing it.
- **`session-audit.sh`** — records session start (with source: `startup` / `resume` / `clear` / `compact`), `Stop` events, and `SessionEnd` reasons. Lets you reconstruct a per-session timeline by filtering the JSONL trail on `session_id`.

### Audit logs

Every hook writes one structured JSON Lines record per invocation to `~/.claude/debug/<hook>.jsonl`. **All invocations are logged, not just blocks or redacts** — allow decisions are recorded as `decision: "allow"` and pure observers use `decision: "observe"`.

| Hook | Log path |
|---|---|
| `bash-policy-check.sh` | `~/.claude/debug/bash-policy.jsonl` |
| `webfetch-policy-check.sh` | `~/.claude/debug/webfetch-policy.jsonl` |
| `output-redact.sh` | `~/.claude/debug/output-redact.jsonl` |
| `tool-audit.sh` | `~/.claude/debug/tool-audit.jsonl` |
| `prompt-submit.sh` | `~/.claude/debug/prompt-submit.jsonl` |
| `session-audit.sh` | `~/.claude/debug/session-audit.jsonl` |

#### Record shape

Every record carries a common envelope:

| Field | Description |
|---|---|
| `ts` | UTC timestamp, ISO-8601 |
| `hook` | Hook name (e.g. `bash-policy`) |
| `user` | Local OS user |
| `proc_cwd` | Hook process working directory |
| `payload_cwd` | `cwd` reported by Claude Code in the hook payload |
| `session_id` | Claude Code session UUID |
| `transcript` | Path to the Claude Code transcript file on disk |
| `tool_name` | Tool the hook fired for (empty for session events) |
| `decision` | `allow`, `deny`, `redact`, `observe`, `submit`, `session_start`, `stop`, `session_end` |

Plus hook-specific fields. Examples:

```json
{"ts":"2026-05-19T14:22:01Z","hook":"bash-policy","user":"alice","session_id":"…","decision":"allow","cmd":"git status","segs":0}
{"ts":"2026-05-19T14:22:03Z","hook":"bash-policy","user":"alice","session_id":"…","decision":"deny","cmd":"sudo ls","reason":"sudo_su"}
{"ts":"2026-05-19T14:22:10Z","hook":"output-redact","user":"alice","session_id":"…","decision":"redact","matched":["AWS_KEY_ID"],"output_len":4096}
{"ts":"2026-05-19T14:22:30Z","hook":"prompt-submit","user":"alice","session_id":"…","decision":"submit","prompt":"deploy to staging using [REDACTED]","prompt_len":142,"redactions":["AWS_KEY_ID"]}
```

Review logs for repeated denies on the same command (legitimate use case to allow, or a workaround attempt), unexpected redact hits (project storing secrets badly), or repeated WebFetch denies on the same domain (dependency on an unapproved service).

Logs are local by default. To aggregate, ship the six JSONL paths to your SIEM via Jamf/osquery/log forwarder. They are append-only and safe to tail or rotate.

### Log rotation

Manually:

```bash
: > ~/.claude/debug/bash-policy.jsonl
: > ~/.claude/debug/webfetch-policy.jsonl
: > ~/.claude/debug/output-redact.jsonl
: > ~/.claude/debug/tool-audit.jsonl
: > ~/.claude/debug/prompt-submit.jsonl
: > ~/.claude/debug/session-audit.jsonl
```

For automated rotation, drop a `newsyslog` config into `/etc/newsyslog.d/`. Because logs are per-user, the config must use an expanded home path:

```
# /etc/newsyslog.d/claude-hooks-alice.conf
/Users/alice/.claude/debug/bash-policy.jsonl     alice:staff  640  7  -1  $D0  ZN
/Users/alice/.claude/debug/webfetch-policy.jsonl alice:staff  640  7  -1  $D0  ZN
/Users/alice/.claude/debug/output-redact.jsonl   alice:staff  640  7  -1  $D0  ZN
/Users/alice/.claude/debug/tool-audit.jsonl      alice:staff  640  7  -1  $D0  ZN
/Users/alice/.claude/debug/prompt-submit.jsonl   alice:staff  640  7  -1  $D0  ZN
/Users/alice/.claude/debug/session-audit.jsonl   alice:staff  640  7  -1  $D0  ZN
```

Daily rotation, 7 compressed archives, no daemon signal. See `man 5 newsyslog.conf`.

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

1. Review `~/.claude/debug/*.log` on the affected machine.
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
| New WebFetch domain | `managed-settings.json` + `webfetch-policy-check.sh` |
| Allow a currently-blocked Bash command | `bash-policy-check.sh` |
| New/updated secret-detection pattern | `opt/claude/hooks/lib/redact.sh` |
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
| Arbitrary domains | Egress control | Submit a domain addition |
| `git --force` | Destructive | Use non-destructive git workflows |

## Governance alignment

`control_mappings.csv` maps each control to ISO 42001, NIST AI RMF, and OWASP LLM Top 10 (LLM01 Prompt Injection, LLM02 Insecure Output, LLM06 Sensitive Info Disclosure, LLM08 Excessive Agency).
