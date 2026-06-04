## Summary

<!-- What does this change do and why? -->

## Guardrail test results

<!-- CI (pre-commit) checks shell lint/format and config validity only. It does NOT verify guardrail behaviour. -->
<!-- The /test-guardrails suite is the behaviour regression net. Run it in Claude Code (open this repo as the -->
<!-- working directory, then type /test-guardrails at the prompt). -->
<!-- PRs that modify hooks, permissions, sandbox config, or managed-settings.json must include a full run. -->
<!-- PRs that only change documentation or test fixtures should include a run if practical. -->

<details>
<summary>Test run output</summary>

```
<!-- Paste the markdown results table here -->
```

</details>

## Security risk assessment

**Does this change affect any of the following?**

- [ ] Hook scripts (anything under `ClaudeCode/opt/claude/hooks/`)
- [ ] Sandbox configuration (filesystem allow/deny lists, network allowed domains)
- [ ] Permission rules (allow/deny entries in `managed-settings.json`)
- [ ] Domain allowlist or path scoping (`managed-settings.json` `network.allowedDomains` / `network._webfetchPathScopes` — read at runtime by `webfetch-policy-check.sh`)
- [ ] `managed-settings.json` settings that affect policy enforcement
- [ ] The test skill itself (`/test-guardrails`)

**If any box is checked, complete the risk assessment below:**

### What guardrails does this change weaken or remove?

<!-- Describe any controls that are loosened, narrowed in scope, or removed entirely. -->
<!-- If none, write "None". -->

### What new attack surface does this open?

<!-- Describe any new ways a malicious prompt, tool output, or user action could bypass controls. -->
<!-- Consider: command injection, credential exposure, network access, privilege escalation. -->
<!-- If none, write "None". -->

### New ALLOW entries

<!-- List any permission, domain, or path-scope entries this change ADDS to an allowlist, and why each is needed. -->
<!-- Loosening a control most often looks like a new ALLOW, so call them out explicitly here even if small. -->
<!-- If none, write "None". -->

### Mitigations in place

<!-- What compensating controls exist, or what monitoring will catch abuse? -->

### Residual risk rating

- [ ] Low
- [ ] Medium
- [ ] High

## Deployment impact

<!-- Merges to main are deployed to managed machines automatically by the daily pull_claude_governance.sh cron. -->

- [ ] This change reaches managed machines on the next daily pull after merge.
- [ ] A rollback plan exists if it misbehaves (describe below).

<!-- Rollback / staging notes. If this change cannot be safely auto-deployed, say so and how it will be gated. -->

---

_Reviewer: confirm the guardrail test table shows no unexpected ALLOWED results, and that every new ALLOW entry above is justified, before approving._
