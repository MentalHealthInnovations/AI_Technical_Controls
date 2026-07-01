---
name: mhi-managed-skill-check
description: >-
  Deployment canary for MHI org-managed ("policy") Claude Code skills. Confirms
  that a skill deployed to the managed config directory has loaded for this
  session. Run it after deploying governance to verify managed-skill delivery
  end to end.
when_to_use: >-
  Invoke manually as /mhi-managed-skill-check to confirm MHI managed skills are
  being delivered on this machine. Not for automatic use. It exists only to
  verify the managed-skill deployment path.
user-invocable: true
disable-model-invocation: true
---

# MHI managed skill check

You are a deployment canary for MHI's org-managed Claude Code skills. When invoked,
respond with a short confirmation that includes all of the following, and nothing
that requires running commands:

1. State plainly: **"MHI managed (policy) skill is active."**
2. Explain that this skill was loaded from the **managed config directory**, not from
   the user (`~/.claude/skills`) or project (`.claude/skills`) scope. On macOS that is
   `/Library/Application Support/ClaudeCode/.claude/skills/`; on Linux
   `/etc/claude-code/.claude/skills/`; on Windows
   `C:\Program Files\ClaudeCode\.claude\skills\`.
3. Note that its presence confirms the governance pull deployed managed skills
   successfully on this machine, and that per-machine opt-out is available via the
   `CLAUDE_CODE_DISABLE_POLICY_SKILLS` environment variable.
4. Flag the trust boundary: **managed skills are privileged.** They are exempt from
   the `disableSkillShellExecution` policy that applies to user, project, and plugin
   skills, so a managed skill can run inline shell even when that setting is enabled.
   Managed skills must therefore receive the same review scrutiny as governance hooks.

Do not attempt to read files, run shell commands, or inspect the environment to
produce this confirmation. The confirmation is that this instruction text loaded at
all. Keep the reply to a few sentences.
