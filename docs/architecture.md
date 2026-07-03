# Architecture and control flow

Visual overview of how the MHI Claude Code governance control pack works. These
diagrams describe the *installed* system (deployed to `/opt/claude/` and
`/Library/Application Support/ClaudeCode/` via MDM), grounded in
[`managed-settings.json`](../ClaudeCode/managed-settings.json) and the hooks under
[`ClaudeCode/opt/claude/hooks/`](../ClaudeCode/opt/claude/hooks/).

## 1. Layered architecture — where enforcement lives

Controls are cumulative and independent: a request must pass every layer that
applies to it. Settings alone are not the boundary — the hooks and the OS sandbox
are.

```mermaid
flowchart TB
    subgraph Config["Managed configuration (MDM-deployed, non-overridable)"]
        MS["managed-settings.json<br/>permissions - deny - sandbox - hook wiring"]
        MM["managed-mcp.json<br/>which MCP servers may connect"]
    end

    subgraph Enforce["Enforcement layers (a request passes ALL that apply)"]
        direction TB
        PERM["1 - Permissions engine<br/>Read/Edit/Write deny rules"]
        HOOKS["2 - PreToolUse hooks<br/>bash / webfetch / mcp policy checks"]
        SANDBOX["3 - OS sandbox<br/>filesystem + network isolation<br/>contains subprocesses too"]
        POST["4 - PostToolUse redaction<br/>strips secrets from output"]
    end

    subgraph Audit["Audit + retention"]
        JSONL["~/.claude/debug/*.jsonl<br/>one record per invocation"]
        S3["S3 mhi-claude-audit<br/>Object Lock 395-day WORM"]
    end

    Agent["Claude Code agent<br/>tool call"] --> PERM
    PERM --> HOOKS
    HOOKS --> SANDBOX
    SANDBOX --> Exec["Command / read / fetch executes"]
    Exec --> POST
    POST --> Model["Result enters model context"]

    MS -.governs.-> PERM
    MS -.governs.-> HOOKS
    MS -.governs.-> SANDBOX
    MM -.governs.-> HOOKS

    HOOKS -.appends.-> JSONL
    POST -.appends.-> JSONL
    JSONL -->|daily cron upload| S3
```

## 2. PreToolUse routing — which hook sees which tool

Each tool type is routed to exactly one dispatcher script by the `matcher` in
`managed-settings.json` (`hooks.PreToolUse`). There is one dispatcher per matcher.

```mermaid
flowchart LR
    TC["Tool call"] --> R{matcher}
    R -->|Bash| BP["bash-policy-check.sh<br/>allow/deny command"]
    R -->|WebFetch| WF["webfetch-policy-check.sh<br/>domain + path allowlist"]
    R -->|"mcp__.*"| MCP["mcp-policy-check.sh<br/>tool allowlist + Jira project scope"]
    R -->|"Edit / Write / Read / Task / SlashCommand"| TA["tool-audit.sh<br/>observe only, no block"]

    BP --> D1{decision}
    WF --> D2{decision}
    MCP --> D3{decision}
    D1 -->|allow| OK["proceed"]
    D1 -->|deny| NO["blocked"]
    D2 -->|allow| OK
    D2 -->|deny| NO
    D3 -->|allow| OK
    D3 -->|deny| NO
    TA --> OK

    BP -.audit.-> LOG["JSONL audit log"]
    WF -.audit.-> LOG
    MCP -.audit.-> LOG
    TA -.audit.-> LOG
```

## 3. Bash policy decision flow — order of checks

`bash-policy-check.sh` applies explicit deny checks first (these scan the whole
command string, so they still catch a bad token in any position), then a
default-deny allowlist evaluated per chain-segment. The explicit denies are what
stop the genuinely dangerous cases even for commands that spawn subprocesses.

```mermaid
flowchart TB
    IN["Bash command payload"] --> EXTRACT["Extract command<br/>strip quoted strings"]
    EXTRACT --> CHAIN{"chain operators > 2 ?"}
    CHAIN -->|yes| DENY["DENY + audit reason"]
    CHAIN -->|no| DENYCHECKS

    subgraph DENYCHECKS["Explicit deny checks (scan full command)"]
        direction TB
        C1["sudo / su"]
        C2["curl / wget / nc / netcat / socat"]
        C3["shell / interpreter invocation"]
        C4["base64 decode-and-execute"]
        C5["dangerous flags / git force / --no-verify"]
        C6["find -exec / -delete"]
        C7["pre-commit / terraform / terragrunt / tflint / tfsec risky subcommands"]
        C8["docker credential-hygiene:<br/>block if ~/.docker/config.json has<br/>auth / identitytoken / registrytoken"]
    end

    DENYCHECKS -->|any match| DENY
    DENYCHECKS -->|none match| ALLOWLIST{"every chain segment<br/>matches the allowlist?"}
    ALLOWLIST -->|no| DENY
    ALLOWLIST -->|yes| ALLOW["ALLOW + audit"]

    DENY -.-> LOG["JSONL audit log"]
    ALLOW -.-> LOG
```

> Note on the allowlist: it is evaluated per segment split on `&&`, `||`, `;`, `|`,
> and every segment (including the last) must match — a single non-allowlisted
> command is denied. Commands that *spawn* other programs (make, gradle, npx,
> `docker compose up`) are excluded from the allowlist because the hook cannot
> inspect what they spawn; see
> [`command-allowlist-risk-assessment.md`](command-allowlist-risk-assessment.md).

## 4. PostToolUse redaction flow — secrets never reach the model

`output-redact.sh` runs after Bash, Read, and WebFetch. It scans the tool output
against the pattern library in [`lib/redact.sh`](../ClaudeCode/opt/claude/hooks/lib/redact.sh)
and, if anything matches, blocks the raw output and returns a `[REDACTED]`
version instead — so the secret never enters the model's context window.

```mermaid
flowchart TB
    OUT["Tool output<br/>Bash stdout / Read content / WebFetch body"] --> SCAN["redact_text via sed -E / awk<br/>against __REDACT_PATTERNS"]
    SCAN --> M{"any secret pattern matched?"}
    M -->|no| PASS["observe record<br/>output passes to model unchanged"]
    M -->|yes| BLOCK["decision: block<br/>return sanitised REDACTED text<br/>record matched pattern NAMES only"]
    PASS -.audit.-> LOG["output-redact.jsonl"]
    BLOCK -.audit.-> LOG
```

Patterns include AWS keys, GitHub PATs, `sk-`/Stripe/Slack tokens, JWTs, generic
`key=value` secrets, PEM blocks, connection strings, and the docker
`auth` / `identitytoken` / `registrytoken` config fields.

## 5. Audit pipeline — from hook to WORM store

Every hook (enforcing or observe-only) appends a single JSON Lines record via the
shared [`lib/audit-log.sh`](../ClaudeCode/opt/claude/hooks/lib/audit-log.sh)
helper. A daily root cron ships new bytes off-box; the bucket's Object Lock makes
records tamper-evident.

```mermaid
flowchart LR
    H1["bash-policy"] --> J
    H2["webfetch-policy"] --> J
    H3["mcp-policy"] --> J
    H4["output-redact"] --> J
    H5["tool-audit"] --> J
    H6["prompt-submit"] --> J
    H7["session-audit"] --> J
    J["~/.claude/debug/*.jsonl<br/>append-only, common envelope"]
    J -->|newsyslog| ROT["local rotation"]
    J -->|"upload-audit-logs.sh (daily cron)"| UP["aws s3 cp new bytes"]
    UP --> BUCKET["S3 mhi-claude-audit<br/>SSE-S3 - versioned<br/>Object Lock GOVERNANCE 395d"]
    BUCKET --> READ["read-only investigator identity<br/>SSO, DuckDB analysis"]
    WRITER["write-only device identity"] -.writes only.-> BUCKET
```

> Audit-trail limitation (recorded honestly for compliance): records are per
> top-level command. A subprocess-spawning tool logs one line and does not record
> what it spawned — the OS sandbox, not the audit log, is what contains those
> subprocesses.
