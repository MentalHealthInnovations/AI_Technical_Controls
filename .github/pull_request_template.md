## Summary

<!-- What the change does and why. -->

## Security risk assessment

**Does this change affect any of the following?**

- [ ] A hook under `ClaudeCode/opt/claude/hooks/`
- [ ] `managed-settings.json` (permissions, sandbox, network allowlist, path scopes)
- [ ] `managed-mcp.json`

**If any box is ticked, complete the sections below.**

### What guardrails does this change weaken or remove?

### What new attack surface does this open?

<!-- Command injection, credential exposure, network access, privilege escalation. -->

### New ALLOW entries

<!-- Every permission, domain or path-scope entry this change adds to an allowlist, and why. -->

### Mitigations in place

<!-- Compensating controls, or the monitoring that would catch abuse. -->

### Residual risk rating

- [ ] Low
- [ ] Medium
- [ ] High

## Rollback plan

<!-- Merges to main deploy to managed machines by the daily pull_claude_governance.sh cron. How to revert if the change misbehaves, and how it is gated if it cannot be auto-deployed. -->

---

_Reviewer: confirm every new ALLOW entry above is justified before approving._
