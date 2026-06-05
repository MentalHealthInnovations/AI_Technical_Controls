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
| [Appendix: AWS audit-log setup](#appendix-aws-audit-log-setup) | Phase 0 manual AWS setup for the audit-log S3 bucket + IAM (IaC later) |
| `.claude/skills/test-guardrails/SKILL.md` | `/test-guardrails` verification suite |
| `.github/workflows/ci.yml` | CI: runs `pre-commit run --all-files` on PRs and pushes to `main` |
| `.pre-commit-config.yaml` | Single source of truth for lint/format/validation checks (run by CI and optionally locally) |

## Installation

### Prerequisites

The install script installs both dependencies on demand via Jamf custom triggers. Both are required; the script refuses to proceed if either is missing and the corresponding trigger isn't supplied.

| Parameter | Resource | Used when |
|---|---|---|
| `$4` | `jq` | `command -v jq` fails. The script runs `jamf policy -event "$4"`. |
| `$5` | Xcode Command Line Tools | `xcode-select -p` fails. The script runs `jamf policy -event "$5"`. |

Configure the script in Jamf with the custom triggers of your existing jq and CLT install policies as parameters 4 and 5. Both dependencies are runtime-critical — `jq` parses every hook payload and reads the WebFetch allowlist; CLT provides `git` and a C compiler that this script needs to install other governance components. If jq is later removed from a machine, the hooks fail closed (preserving security) and block every Bash, WebFetch, and Read call until it's reinstalled.

### Run

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

Manual AWS setup for the Claude Code audit log pipeline. Provisions the S3 bucket Vector ships logs to, plus the per-host writer IAM users and the read-only investigation access.

This is **Phase 0** of the audit logging rollout — the local JSONL hooks above are the source of the records; this appendix covers shipping them off-box.

> **Status: manual setup.** This phase is delivered by hand via the AWS CLI / console steps below. It will be converted to infrastructure-as-code (Terraform) at a later date. Until then, treat this section as the source of truth for what exists in the account, and make changes by following these steps — not ad-hoc in the console — so the eventual IaC import is clean.

## What you create

| Resource | Purpose |
|---|---|
| S3 bucket `mhi-claude-audit` | The log bucket. UK region. SSE-S3. Lifecycle policy. TLS-only. |
| Bucket lifecycle rule `claude-audit-tiering` | 30d hot → 120d IA → 395d delete |
| IAM user `vector-<host>` (one per Mac) | Per-machine writer, scoped to write under `host=<host>/` only. **Phase 0 only — see [Target: IAM Roles Anywhere for writers](#target-iam-roles-anywhere-for-writers).** |
| SSO permission set `claude-audit-reader` | Read-only access for ad-hoc DuckDB investigation, assigned to a readers group in IAM Identity Center |

All commands assume the AWS CLI is configured with an admin profile for the target account and `eu-west-2` (London) as the region. Adjust `--region` / `--profile` to taste.

```bash
export AWS_REGION=eu-west-2          # UK region — required for GDPR data residency (see below)
export BUCKET=mhi-claude-audit       # must be globally unique; change if taken
```

## 1. Create and harden the S3 bucket

### 1.1 Create the bucket

**Region is pinned to the UK (`eu-west-2`) for UK GDPR data residency.** The logs contain prompt text and command lines, which can include personal data. Do not create this bucket in a non-EU region without DPO sign-off — the region is part of the lawful-basis assessment.

```bash
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"
```

### 1.2 Block all public access (account-plane defence in depth)

Blocks every form of public access at the bucket's control plane, regardless of any future bucket policy.

```bash
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

> Apply this **before** the bucket policy in step 1.5, otherwise the policy attempt can race the account-level restriction.

### 1.3 Enable encryption at rest (SSE-S3 / AES-256)

SSE-S3 is sufficient for Phase A. Move to SSE-KMS only if a compliance requirement asks for customer-managed key control over the logs at rest.

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

### 1.4 Leave versioning OFF (intentional)

Do **not** enable bucket versioning. Audit records are append-only per record, not per file — Vector writes one new gzipped blob per batch and never overwrites. Versioning would multiply storage cost for no benefit. New buckets default to versioning disabled, so there is nothing to do here; this note exists so nobody "helpfully" turns it on later.

### 1.5 Lifecycle policy (tiering + expiry)

30 days hot (Standard) → Standard-IA → Glacier Instant Retrieval → delete at 395 days.

**395 days = 13 months**, the default retention for security audit telemetry. Changing the expiry requires DPO sign-off — the retention figure is part of the lawful-basis assessment. Keep retention between 90 days and 7 years.

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
      "Expiration": { "Days": 395 }
    }]
  }'
```

### 1.6 TLS-only bucket policy

Belt-and-braces alongside AWS's own TLS-only endpoint default — this denies plaintext attempts at the bucket layer too, so a misconfigured client can't accidentally write logs over HTTP. Substitute your bucket ARN (`arn:aws:s3:::mhi-claude-audit`).

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

## 2. Create a writer IAM user per managed Mac

Create **one IAM user per machine**, named `vector-<host>`, where `<host>` matches `hostname -s` on the machine — the same value Vector stamps into the JSONL `host` field. The user's inline policy is scoped so it can **only** write under its own `host=<host>/` partition: a leaked credential for `alice-mbp` cannot write to `bob-mbp`'s partition or read any data at all.

Repeat this whole section for each host. Below, `HOST` is the short hostname.

```bash
export HOST=alice-mbp                 # must match `hostname -s` on the machine
```

### 2.1 Create the user

```bash
aws iam create-user \
  --user-name "vector-$HOST" \
  --path /claude-audit/ \
  --tags Key=Hostname,Value="$HOST" Key=Role,Value=vector-writer
```

### 2.2 Attach the per-host inline write policy

Vector writes to:

```
claude-audit/year=YYYY/month=MM/day=DD/host=<host>/<hook>/<file>.log.gz
```

The partition path contains `host=<their-hostname>`, so the resource ARN is constrained with a wildcard either side of it. **Edit the `host=alice-mbp` segment to match `$HOST`** before running.

```bash
aws iam put-user-policy \
  --user-name "vector-$HOST" \
  --policy-name "vector-writer-$HOST" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "WriteOwnHostPartition",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:PutObjectAcl"],
      "Resource": "arn:aws:s3:::mhi-claude-audit/claude-audit/*/host=alice-mbp/*"
    }]
  }'
```

### 2.3 Create an access key

The secret is returned **exactly once** — capture it now. Pipe straight into 1Password / your secrets manager; never redirect to a file in the repo.

```bash
aws iam create-access-key --user-name "vector-$HOST"
```

Store the `AccessKeyId` + `SecretAccessKey` under that machine's 1Password entry, then inject them into the Jamf install policy's parameters 4 and 5 at install time.

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

Create (or reuse) a group in your identity source — e.g. `claude-audit-readers` — and assign the permission set to it for the target account:

```bash
aws sso-admin create-account-assignment \
  --instance-arn "$SSO_INSTANCE_ARN" \
  --permission-set-arn "$PS_ARN" \
  --principal-type GROUP \
  --principal-id "<group-id>" \
  --target-type AWS_ACCOUNT \
  --target-id "<account-id>"
```

Add or remove investigators by editing membership of `claude-audit-readers` in your identity source — no AWS changes needed per person.

### 3.3 Reader workflow

Each investigator configures an SSO profile once and logs in to get temporary credentials; DuckDB's S3 reads use that profile:

```bash
aws configure sso --profile claude-audit          # one-time, per machine
aws sso login --profile claude-audit              # whenever the session expires
export AWS_PROFILE=claude-audit                    # DuckDB picks creds up from here
```

No long-lived reader secrets exist, so there is nothing to commit, rotate, or revoke per person.

## Secrets handling

This applies to the **writer** keys only — readers now use SSO (section 3) and hold no static credentials. These writer IAM access keys are long-lived static credentials; the AWS API returns each secret exactly once, at creation.

- Never commit a secret. There is no state file in this phase, so nothing on disk holds them — keep it that way. Store every key directly in 1Password / a secrets manager.
- Vector needs static keys in Phase 0 because it's a long-running daemon with no interactive session, so interactive SSO login can't vend its credentials. The target state (IAM Roles Anywhere — see [Target: IAM Roles Anywhere for writers](#target-iam-roles-anywhere-for-writers)) gives Vector short-lived credentials non-interactively and removes these static keys entirely.
- Limit who can run `iam create-access-key` against these users to operators who already hold IAM admin in the account — key-creation access *is* credential access.

When this phase is converted to Terraform, the access keys will end up in Terraform state; at that point the remote state backend must be encrypted at rest and access-controlled. That trade-off is deferred until the IaC conversion.

## Adding a new managed Mac

1. Set `HOST` to the new machine's `hostname -s`.
2. Run section 2 (create user → attach per-host policy → create access key).
3. Store the credentials in 1Password under that machine's entry.
4. Trigger the Jamf install policy on that machine.

## Removing / revoking a machine

1. Delete the access key(s), then the inline policy, then the user:
   ```bash
   aws iam list-access-keys --user-name vector-$HOST          # find the key IDs
   aws iam delete-access-key --user-name vector-$HOST --access-key-id <id>
   aws iam delete-user-policy --user-name vector-$HOST --policy-name vector-writer-$HOST
   aws iam delete-user --user-name vector-$HOST
   ```
   Vector on that machine will start 403'ing within minutes.
2. (Optional) Remove the now-orphaned log data — only if the machine genuinely shouldn't have data retained:
   ```bash
   aws s3 rm "s3://$BUCKET/claude-audit/" --recursive \
     --exclude "*" --include "*/host=$HOST/*"
   ```

## Rotating credentials

Annual rotation, manual:

```bash
# 1. Create the replacement key (machine now has two active keys)
aws iam create-access-key --user-name vector-$HOST

# 2. Push the new credential via Jamf, confirm Vector is writing with it

# 3. Mark the old key inactive
aws iam update-access-key --user-name vector-$HOST --access-key-id <old-id> --status Inactive

# 4. After 24h with no errors, delete the old key
aws iam delete-access-key --user-name vector-$HOST --access-key-id <old-id>
```

A future improvement (post-IaC): eliminate writer keys entirely with IAM Roles Anywhere (see below), which removes the rotation problem rather than automating it. If static keys are still in use when IaC lands, an interim Lambda + EventBridge schedule could rotate them every 90 days — but treat that as a stopgap, not the target.

## Target: IAM Roles Anywhere for writers

> **Not implemented in Phase 0.** This section documents the target state so the eventual IaC conversion has a north star. The live setup today is the static per-host keys in section 2.

The per-Mac IAM user model (section 2) is the bulk of the ongoing operational toil: one IAM user + inline policy + static key per machine, created by hand, rotated manually, revoked manually. It scales linearly with the fleet and every step is a chance to leak a long-lived credential.

**IAM Roles Anywhere** removes that toil while *keeping* the strict per-host write isolation. The shift is from *one identity per machine* to *one role whose scope is derived from a per-machine certificate*:

- **One IAM role** (`vector-writer`) replaces all `vector-<host>` users.
- Each Mac holds an **X.509 certificate** delivered by Jamf (Jamf already manages device certs via SCEP/PKI). A **trust anchor** in Roles Anywhere validates certs issued by your CA.
- The role's session is **tagged with the hostname**, sourced from a certificate field (e.g. CN or a SAN) — *not* self-asserted by the client. Roles Anywhere maps cert attributes to session tags.
- The write policy scopes the resource with an ABAC condition instead of a hardcoded host:

  ```
  arn:aws:s3:::mhi-claude-audit/claude-audit/*/host=${aws:PrincipalTag/x509Subject}/*
  ```

  so a Mac presenting `alice-mbp`'s cert can only write under `host=alice-mbp/` — the same guarantee as today's per-user policy, enforced by the request-time condition rather than by N separate users.

What this buys:

- **No per-Mac IAM objects.** Adding a Mac is Jamf cert enrollment, not `aws iam create-user` + policy + key.
- **No static AWS keys.** Vector gets short-lived credentials via the Roles Anywhere credential helper; there is nothing in 1Password to leak.
- **No manual key rotation.** Credentials are ephemeral; the cert rotates on the PKI's own schedule, which Jamf already manages.
- **Same isolation.** The blast radius of a compromised machine is still exactly its own `host=<host>/` partition.

Why it's deferred: it needs a CA / trust anchor and Jamf cert delivery wired up, which is more than Phase 0's "stand it up by hand" scope. Vector supports Roles Anywhere via the `aws_credentials_helper` it can shell out to (the `aws_signing_helper credential-process`), so no Vector code changes are needed — only AWS + Jamf configuration.

The critical correctness point: **the hostname session tag must come from the certificate identity, never from a client-supplied value.** If a machine could set its own hostname tag, the isolation is theatre. Sourcing it from the cert subject (which the machine cannot forge without the CA) is what makes the ABAC condition a real boundary.

## Validating the policy enforcement

Test the per-host scoping **before** fleet rollout. Configure the AWS CLI with an `alice-mbp` writer credential, then:

```bash
# This should succeed — writing to alice's own partition
echo test | gzip | aws s3 cp - s3://mhi-claude-audit/claude-audit/year=2026/month=05/day=20/host=alice-mbp/test/file.log.gz

# These should BOTH 403
echo test | gzip | aws s3 cp - s3://mhi-claude-audit/claude-audit/year=2026/month=05/day=20/host=bob-mbp/test/file.log.gz
aws s3 ls s3://mhi-claude-audit/
```

If either deny test succeeds, the policy isn't doing its job — investigate before rolling out.

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

£20/month is well above the expected ~£1–2/month for a fleet of this size. Any alert means something is wrong — investigate before paying it.

> The cost filter keys on a `Project=claude-code-audit` tag. The Terraform applied that tag automatically via `default_tags`; in the manual flow there's no provider to do it for you, so the budget filter is best-effort. When you convert to IaC, restore the `default_tags` block (`Project=claude-code-audit`, `Owner=security`, `ManagedBy=terraform`) so the filter becomes reliable.
