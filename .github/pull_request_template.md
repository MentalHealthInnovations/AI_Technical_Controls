## Summary

<!-- What does this change do and why? -->

## Guardrail test results

<!-- CI (pre-commit + hook-tests) is the mandatory gate for this PR: it checks shell lint/format, config -->
<!-- validity, and the hook regression suite. There is no check that can be run against an open PR itself -->
<!-- to exercise live guardrail behaviour under Claude Code — /test-guardrails requires a live agent session -->
<!-- with the branch's changes actually deployed, so it can only be run locally before opening the PR, not -->
<!-- against the PR as a review step. If you did run it locally beforehand, paste the results below for -->
<!-- reviewer context; otherwise leave this section as-is. -->

<details>
<summary>Test run output (optional, if run locally before opening this PR)</summary>

```
<!-- Paste the markdown results table here, if applicable -->
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

## Rollback plan

<!-- Merges to main are deployed to managed machines automatically by the daily pull_claude_governance.sh cron. -->
<!-- How to revert this change if it does not behave as intended in production. -->
<!-- If the change cannot be safely auto-deployed, say so here and describe how it will be gated. -->

---

_Reviewer: confirm the guardrail test table shows no unexpected ALLOWED results, and that every new ALLOW entry above is justified, before approving._
