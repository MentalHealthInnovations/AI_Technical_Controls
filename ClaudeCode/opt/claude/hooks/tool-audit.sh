#!/usr/bin/env bash
# PreToolUse audit hook — observes invocations of high-signal tools that
# don't currently have a policy hook of their own (Edit, Write, Task,
# SlashCommand, Read). Always allows the call; only writes one JSON Lines
# audit record per invocation.
#
# This hook MUST NOT block. Its only job is to leave a breadcrumb. Bash and
# WebFetch keep their own dedicated policy hooks; this hook is for everything
# else we want a fleet-level trail of.
#
# Output: ~/.claude/debug/tool-audit.jsonl
#
# Fields per tool:
#   Edit         : file_path, old_len, new_len, replace_all
#   Write        : file_path, content_len
#   Task         : subagent_type, description, prompt_len
#   SlashCommand : command (the /name + args verbatim)
#   Read         : file_path, offset, limit
#   (default)    : tool_name only — keeps the hook future-safe if it gets
#                  wired to a tool we haven't special-cased
set -u

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/audit-log.sh
source "$HOOK_DIR/lib/audit-log.sh"
audit_init "tool-audit"

payload="$(cat)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // ""')"

case "$tool" in
  Edit)
    file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""')"
    old_len="$(printf '%s' "$payload" | jq -r '.tool_input.old_string // "" | length')"
    new_len="$(printf '%s' "$payload" | jq -r '.tool_input.new_string // "" | length')"
    replace_all="$(printf '%s' "$payload" | jq -r '.tool_input.replace_all // false')"
    audit_emit "$payload" observe \
      file_path        "$file_path" \
      old_len:json     "${old_len:-0}" \
      new_len:json     "${new_len:-0}" \
      replace_all:json "$replace_all"
    ;;

  Write)
    file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""')"
    content_len="$(printf '%s' "$payload" | jq -r '.tool_input.content // "" | length')"
    audit_emit "$payload" observe \
      file_path        "$file_path" \
      content_len:json "${content_len:-0}"
    ;;

  Task|Agent)
    # The tool name for subagent launches is "Task" in current Claude Code
    # builds; "Agent" is an alias seen in some payloads. Accept both.
    subagent_type="$(printf '%s' "$payload" | jq -r '.tool_input.subagent_type // ""')"
    description="$(printf '%s' "$payload" | jq -r '.tool_input.description // ""')"
    prompt_len="$(printf '%s' "$payload" | jq -r '.tool_input.prompt // "" | length')"
    audit_emit "$payload" observe \
      subagent_type   "$subagent_type" \
      description     "$description" \
      prompt_len:json "${prompt_len:-0}"
    ;;

  SlashCommand)
    # SlashCommand carries the literal command string the user typed. We log
    # it verbatim — it's user input, not tool output, so there's no secret to
    # redact and the audit value is high (records skill invocations).
    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"
    audit_emit "$payload" observe command "$command"
    ;;

  Read)
    file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""')"
    offset="$(printf '%s' "$payload" | jq -r '.tool_input.offset // 0')"
    limit="$(printf '%s' "$payload" | jq -r '.tool_input.limit // 0')"
    audit_emit "$payload" observe \
      file_path    "$file_path" \
      offset:json  "${offset:-0}" \
      limit:json   "${limit:-0}"
    ;;

  *)
    # Anything else — log just the tool name so the trail is complete even
    # for tools we haven't enumerated. No tool_input fields are extracted
    # to avoid accidentally capturing sensitive content from unknown shapes.
    audit_emit "$payload" observe
    ;;
esac

# Always allow. This hook is observational; policy hooks (bash-policy,
# webfetch-policy) are responsible for actual denies.
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
