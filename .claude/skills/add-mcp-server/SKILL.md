---
name: add-mcp-server
description: Add a new MCP server to the managed allowlist, sync the WebFetch domain allowlist, and update documentation. Walks the user through a consistent flow so every MCP addition is reviewable as a single coherent change.
disable-model-invocation: true
---

Use this skill when a developer wants to propose a new MCP server for the managed allowlist. It enforces a single, repeatable shape so that reviewers see the same change pattern every time.

This skill **does not run any commands itself**. The harness enforces `disableSkillShellExecution: true`. Every edit happens through the normal Edit/Write tool path so the managed hooks and sandbox still apply.

## Preconditions

Before starting, confirm:

- The user is on a feature branch (`git -C . branch --show-current` should not return `main`). If they are on `main`, ask them to run `!git checkout -b feat/<server>-mcp-server` at the prompt — the sandbox blocks Claude from writing `.git/HEAD`.
- The user has read the README's **Change control** and **MCP servers** sections.

## Step-by-step procedure

### 1. Gather inputs

Use `AskUserQuestion` to collect, in one call:

- **Server slug** — the short key used in `mcpServers.<slug>`. Lower-case, no spaces.
- **Runtime** — `docker`, `binary`, or `npx`. (Docker is the safest default because the container is the isolation boundary.)
- **Command + args** — what Claude Code will spawn for stdio transport.
- **Required env vars** — names only. Never ask the user to paste a value.
- **Documentation URLs** — the canonical doc pages a developer (or Claude) will need to consult.

Do not proceed without all five. If the user is unsure, point them at the server's upstream README and ask them to come back.

### 2. Read the current state

Read each of the following before editing. The skill assumes the file shapes documented here; if any has drifted, stop and ask the user to update the skill first.

- `ClaudeCode/managed-settings.json` — must contain `allowedMcpServers`, `enabledMcpjsonServers`, and `sandbox.network.allowedDomains` arrays. **No server definitions live here** — `managed-settings.json` carries only the *policy* (allowlist, `allowManagedMcpServersOnly`).
- `ClaudeCode/managed-mcp.json` — the server-definition file deployed to `/Library/Application Support/ClaudeCode/managed-mcp.json`. When present, Claude Code treats it as the exclusive set of MCP servers (Option 1 in [the docs](https://code.claude.com/docs/en/mcp#managed-mcp-configuration)). All `mcpServers` entries belong here.
- `ClaudeCode/opt/claude/hooks/webfetch-policy-check.sh` — must contain the `allowed_entries=( ... )` array.
- `README.md` — the file manifest table near the top and the **Approved MCP servers** subsection near `## Control surfaces`.
- `.claude/skills/test-guardrails/SKILL.md` — the EXPECT: ALLOWED batch and the report table.

### 3. Edit `managed-settings.json` and `managed-mcp.json`

Make these edits in a single pass.

**In `managed-settings.json` (policy only):**

- Add the slug to `allowedMcpServers` as `{ "serverName": "<slug>" }`.
- Add the slug as a bare string to `enabledMcpjsonServers`.

**In `managed-mcp.json` (the server definition):**

Add a key under `mcpServers` using this exact shape for stdio servers:

```json
{
  "mcpServers": {
    "<slug>": {
      "command": "<command>",
      "args": ["..."],
      "env": {
        "<ENV_VAR_NAME>": ""
      }
    }
  }
}
```

Or for a remote HTTP server with OAuth (preferred — no token plumbing):

```json
{
  "mcpServers": {
    "<slug>": {
      "type": "http",
      "url": "https://server.example.com/mcp/"
    }
  }
}
```

The empty string for each env var is intentional — it documents the requirement without ever placing a secret in source control. Claude Code reads the live value from the user's environment at server startup. For remote HTTP servers, omit `headers` entirely so Claude Code falls back to OAuth on the first `401` — checked-in tokens are forbidden because `managed-mcp.json` is world-readable on the device.

### 4. Sync the WebFetch allowlist (if new domains)

If any documentation URL is on a domain not already in `sandbox.network.allowedDomains`:

- Append the bare hostname to `sandbox.network.allowedDomains` in `managed-settings.json`. Bare hostnames only at this layer — the OS sandbox does not honour path scoping.
- Append the same hostname (optionally with a `/path` suffix if you want to tighten access at the hook layer) to `allowed_entries` in `ClaudeCode/opt/claude/hooks/webfetch-policy-check.sh`.

The sync requirement is called out in the comment block at the top of `allowed_entries` in `webfetch-policy-check.sh` and in `_comment_allowedDomains` in `managed-settings.json`. The lists must be byte-identical for bare hostnames; the only divergence allowed is hook-side path scoping.

**Watch-out:** Adding a path-scoped entry (`example.com/docs`) to the hook when `example.com` was previously listed bare *narrows* access. Only do this if you intend to remove the bare entry at the same time.

### 5. Document the server in `README.md`

- Add a row to the file manifest table only if you are creating a new server-specific doc file. The `mcpServers` config itself lives in `managed-mcp.json` (already listed) and does not need a new manifest entry.
- Under **Approved MCP servers** (create the section if missing), add a bullet:
  > `<slug>` — one-line purpose. Runtime: `<runtime>`. Auth: `<ENV_VAR_NAME>` (with required scopes). Docs: `<URL>`.
- Under the same heading, add an **External prerequisites** sub-bullet block listing the human-side tasks. Always include:
  1. How to obtain the credential.
  2. Where to store it (1Password vault path or equivalent — never a dotfile).
  3. How to export it for a Claude Code session (`export <ENV_VAR_NAME>=...` at session start, never in `~/.zshrc`).
  4. Any one-time install step (`docker pull ...`, binary download, etc.).

### 6. Extend `test-guardrails`

Add at minimum:

- One ALLOWED test per new doc domain — a representative `WebFetch <https://newdomain/page>` URL.
- One BLOCKED test per new doc domain — `WebFetch <https://sub.newdomain/page>` to confirm no subdomain wildcard, mirroring tests 38 and 39.
- One ALLOWED test verifying the server entry is present in `managed-mcp.json` (a `grep -q '"<slug>"' ClaudeCode/managed-mcp.json` sequence) and another that the slug is in the allowlist in `managed-settings.json`.

Add matching rows to the report table at the bottom of `test-guardrails/SKILL.md`. Renumber subsequent tests only if you are inserting in the middle; appending at the end is always safer.

### 7. Print the external-task checklist

After all file edits are queued, print a short checklist to the user covering everything they need to do **outside** the repo before the change is usable. At minimum:

- [ ] Obtain credential (link to provider's docs).
- [ ] Store credential in 1Password.
- [ ] On their workstation: `<install command>` (e.g. `docker pull ghcr.io/...`).
- [ ] Validate locally: open Claude Code, run `/test-guardrails`, paste the result into the PR.

### 8. Hand off to the PR flow

Remind the user to:

1. Run `/test-guardrails` and capture the full markdown report.
2. Commit with a conventional-commit message: `feat(mcp): add <slug> MCP server`.
3. Open a PR using the existing template at `.github/pull_request_template.md`. The Security risk assessment section is **mandatory** — every checkbox under "Hook scripts", "Sandbox configuration", "Domain allowlist", and "`managed-settings.json` settings" applies.
4. Note the CODEOWNERS approval requirement (`@edwardmhi` and `@maxlevine-mhi`).

The skill ends here. Do not auto-commit or auto-push — both go through the user explicitly so they retain authorship and review responsibility.
