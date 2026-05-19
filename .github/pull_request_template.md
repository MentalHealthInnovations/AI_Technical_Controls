## Summary

<!-- What does this change do and why? -->

## Guardrail test results

<!-- Run /test-guardrails in Claude Code (open this repo as the working directory, then type /test-guardrails at the prompt). -->
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

- [ ] Hook scripts (`bash-policy-check.sh`, `webfetch-policy-check.sh`, `output-redact.sh`)
- [ ] Sandbox configuration (filesystem allow/deny lists, network allowed domains)
- [ ] Permission rules (allow/deny entries in `managed-settings.json`)
- [ ] Domain allowlist (`managed-settings.json` `network.allowedDomains` — read at runtime by `webfetch-policy-check.sh`)
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

### Mitigations in place

<!-- What compensating controls exist, or what monitoring will catch abuse? -->

### Residual risk rating

<!-- Circle or bold one: **Low** / **Medium** / **High** -->

---

_Reviewer: confirm the guardrail test table shows no unexpected ALLOWED results before approving._
