# Bash command allowlist — risk assessment and decision log

This document risk-assesses candidate commands for the `bash-policy-check.sh`
allowlist, and records which have been implemented, which are safe to add on
request, and which require an explicit policy decision before they can be added.

It exists because "add command X to the allowlist" is not a uniform request:
some commands are inert read-outs, while others execute arbitrary project-defined
code and can only be contained by the OS sandbox, not by the hook.

> **Note on a fixed enforcement gap.** Until fixed on this branch, the allowlist
> loop skipped the final command segment (a `while read` over `printf`-without-a-
> -trailing-newline drops the last line), so a bare single command — or the final
> segment of a chain — was never allowlist-checked and ran if it evaded the
> explicit deny patterns. The loop now uses `read ... || [[ -n "$segment" ]]`.
> Practical effect: before the fix, default-deny did not really apply to single
> commands, so the allowlist entries here only bit on non-final chain segments;
> after it, they apply as intended. Regression guards: tests 119–122 in the
> guardrail suite.

## Background: what the allowlist can and cannot see

`bash-policy-check.sh` is a **PreToolUse hook that gates a single command
string.** It does not observe subprocesses that the command spawns. The hook's
own code already documents this for pre-commit (see the `execve` comment above
the pre-commit pre-block): a tool that spawns other programs runs them via
`execve`, so none of the hook's deny checks (`curl`, `sudo`, shell-invocation,
`base64`, dangerous flags) nor the allowlist are consulted for the spawned
commands.

Consequence: **any command whose purpose is to run other programs launders
arbitrary execution past the entire hook.** For those commands the only
remaining controls are:

- the **OS sandbox** — filesystem read/write scoping and the network egress
  allowlist in `managed-settings.json` (`sandbox.filesystem`, `sandbox.network`).
  This *does* contain subprocesses, since it is enforced at the OS level.
- **`output-redact.sh`** — redacts secret patterns from tool output.

What the sandbox does **not** contain, even for a spawned subprocess:

- reading any file inside the repo / managed-read zone;
- writing or deleting anywhere inside the repo write zone (`.`, `./tmp`, …);
- network calls to **allowlisted** hosts (github.com, pypi.org, registry.npmjs.org,
  the docker registries, etc.) — sufficient to exfiltrate to an attacker-controlled
  GitHub repo or pull arbitrary packages;
- CPU / resource consumption.

And a subprocess-spawning command **blinds the audit trail**: the JSONL log
records one `allow` line for e.g. `make test` with no record of what it spawned.
Per-command auditing is a stated goal of this control pack, so this is a real
loss, not just a theoretical one.

Therefore the test for adding any spawner is not "is this command safe?" but:
**"is the org content to rely on sandbox-only containment, with no per-subprocess
audit record, for whatever this command executes?"**

## Decision categories

- **[Implemented]** — added to the allowlist; inert or read-only, no arbitrary
  subprocess execution.
- **[Safe to add on request]** — inert/read-only, not yet added only because we
  don't currently use it. Add when specifically needed; no policy decision
  required, just a scoped allowlist entry + a guardrail test.
- **[Policy decision required]** — executes arbitrary project-defined code.
  Adding it means accepting sandbox-only containment. Requires CODEOWNERS sign-off
  and should be recorded here with the rationale and, ideally, a narrower scope
  (e.g. per-repo) than a blanket allowlist entry.

> Guidance: do **not** open these up pre-emptively. Add a command only when a
> real workflow needs it. An unused allowlist entry is pure attack surface.

## Assessment

| Command | Spawns arbitrary code? | Real risk if allowlisted | Category |
|---|---|---|---|
| `docker version`, `docker info` | No | None — read-only | **[Implemented]** |
| `docker compose config\|ps\|logs\|ls\|version` | No | Read-only inspection | **[Implemented]** |
| `gh run list\|view\|watch` | No | Read-only CI inspection | **[Implemented]** |
| `gh workflow list\|view` | No | Read-only | **[Implemented]** |
| `gh status`, `gh browse` | No (`browse` opens a URL) | Low | **[Implemented]** |
| `go test` | Yes — test code + `TestMain` is arbitrary Go, `go test` may fetch modules | Medium; repo-scoped code, sandbox-contained, network limited to allowlisted module hosts | **[Policy decision required]** |
| `cargo test` | Yes — `build.rs` runs arbitrary code at build time | High | **[Policy decision required]** |
| `make` | Yes — targets are arbitrary shell; cannot enumerate "safe targets" | High | **[Policy decision required]** |
| `gradle`, `mvn` | Yes — build scripts *are* Groovy/Kotlin/plugin code | High | **[Policy decision required]** |
| `tox`, `nox` | Yes — builds venvs, runs `setup.py`, installs from network | High | **[Policy decision required]** |
| `dotnet test` | Yes — MSBuild targets = arbitrary code | High | **[Policy decision required]** |
| `bundle exec …` | Yes — arbitrary Ruby (ruby is already in the interpreter deny list) | High | **[Policy decision required]** |
| `docker compose build\|run\|up\|down` | Yes — Dockerfile `RUN` steps / arbitrary container commands | High | **[Policy decision required]** |
| `npx …` | Yes — downloads and executes arbitrary npm packages from the network | Very high — functionally `curl \| sh` | **Recommend against** |
| `docker run`, `docker exec` | Yes — arbitrary command in a container | High | **Recommend against** |
| `gh api` | Yes (writes) — takes `--method POST/DELETE`; cannot be scoped read-only by a leading-verb regex | Mutates GitHub state | **Recommend against** (as a blanket entry) |

## Implementation checklist

Tick when merged and verified via `/test-guardrails`.

### Implemented in this change

- [ ] `docker version`, `docker info` added to the docker allowlist entry
- [ ] `docker compose config|ps|logs|ls|version` allowlisted (read-only compose)
- [ ] `gh run list|view|watch` allowlisted (read-only Actions runs)
- [ ] `gh workflow list|view` allowlisted (read-only workflows)
- [ ] `gh status`, `gh browse` allowlisted
- [ ] Guardrail tests added: each new entry ALLOWED; `docker compose up`,
      `docker run`, `gh run rerun`, `gh workflow run`, `gh api --method POST`
      remain BLOCKED
- [ ] `/test-guardrails` full run passes against the **installed** hooks

### Safe to add on request (no policy decision; add when needed)

- [ ] `docker compose` additional read verbs if they emerge (e.g. `top`, `port`)
- [ ] `gh cache list`, `gh release view` variants, other read-only `gh` verbs as
      workflows require them

### Policy decisions required (do NOT add without CODEOWNERS sign-off)

Record the decision, date, and rationale inline when taken.

- [ ] `go test` — decision: _pending_
- [ ] `cargo test` — decision: _pending_
- [ ] `make` (scoped how?) — decision: _pending_
- [ ] `gradle` / `mvn` — decision: _pending_
- [ ] `tox` / `nox` — decision: _pending_
- [ ] `dotnet test` — decision: _pending_
- [ ] `bundle exec` — decision: _pending_
- [ ] `docker compose build|run|up` — decision: _pending_

For any of the above, prefer a narrower mechanism than a blanket allowlist entry
where possible — e.g. permit only in explicitly-vouched repositories, or via a
wrapper that re-emits an audit record per spawned command — so the sandbox is not
the *sole* control and the audit trail is preserved.

## Related

- Enforcement mechanism: [`ClaudeCode/opt/claude/hooks/bash-policy-check.sh`](../ClaudeCode/opt/claude/hooks/bash-policy-check.sh)
- Sandbox scoping: [`ClaudeCode/managed-settings.json`](../ClaudeCode/managed-settings.json) (`sandbox.filesystem`, `sandbox.network`)
- Behaviour regression net: [`.claude/skills/test-guardrails/SKILL.md`](../.claude/skills/test-guardrails/SKILL.md)
