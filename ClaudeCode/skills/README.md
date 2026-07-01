# Managed Claude Code skills

Skills in this directory are deployed org-wide as **managed ("policy") skills**. Every
folder here that contains a `SKILL.md` is copied to the managed config directory by
[`pull_claude_governance.sh`](../pull_claude_governance.sh) on each governance pull, so
it applies to **all users on the machine** with no per-user opt-in.

## Layout

```
ClaudeCode/skills/
└── <skill-name>/
    └── SKILL.md        # required; frontmatter + instructions
```

Each skill is a folder with a `SKILL.md`. Set the `name:` frontmatter to a single
space-free token in kebab-case that matches the folder name (e.g. `mhi-managed-skill-check`).
Claude Code uses `name:` verbatim as the `/`-menu command, so a value with spaces produces
a broken command (only the text up to the first space is parsed as the command). Observed
in Claude Code 2.1.185.

## Where it lands on disk

The governance pull copies `ClaudeCode/skills/` into a `.claude/skills/` subdirectory
**inside** the managed config directory (note the nested `.claude`):

| Platform | Deployed path |
| --- | --- |
| macOS | `/Library/Application Support/ClaudeCode/.claude/skills/` |
| Linux | `/etc/claude-code/.claude/skills/` |
| Windows | `C:\Program Files\ClaudeCode\.claude\skills\` |

This path is the managed-skill load location used by the Claude Code skill loader
(internally "policy skills"). It is **not published in Anthropic's public docs**. It was
confirmed by reading the Claude Code binary's skill loader. Because it is undocumented,
it may change between Claude Code releases, so verify on one machine after a Claude Code
upgrade before assuming continued delivery. Per-machine opt-out is available
via the `CLAUDE_CODE_DISABLE_POLICY_SKILLS` environment variable.

## Trust tier: treat these like hooks

Managed skills are **privileged**. They are exempt from the `disableSkillShellExecution`
policy that constrains user, project, and plugin skills, so a managed skill can run
inline shell commands even though `managed-settings.json` sets
`disableSkillShellExecution: true`. Review every skill added here with the same scrutiny
as a governance hook: two-person / CODEOWNERS review, no untrusted inline execution.

## Verifying deployment

`mhi-managed-skill-check` is a deployment canary. After a governance pull, run
`/mhi-managed-skill-check` in a Claude Code session on the target machine; it confirms
managed skills are being delivered. It contains no shell execution.
