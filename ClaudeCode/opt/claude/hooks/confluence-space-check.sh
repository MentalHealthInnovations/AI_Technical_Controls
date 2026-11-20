#!/usr/bin/env bash
# PostToolUse hook for mcp__atlassian__getConfluenceContent. Replaces what the tool
# returned unless the content is in a space on CONFLUENCE_SPACES (lib/confluence-spaces.sh).
#
# Why this runs after the call. getConfluenceContent names a content id and nothing
# else, so mcp-policy-check.sh cannot tell beforehand which space the content is in. The
# response can. A read changes nothing in Confluence, so checking afterwards and
# withholding the result is enough for a read. It is not enough for a write, which is why
# updateConfluenceContent is not handled here.
#
# How the result is withheld. The hook answers with updatedToolOutput, which the Claude
# Code hooks reference describes as "Replaces the tool's output with the provided value
# before it is sent to Claude" (https://code.claude.com/docs/en/hooks.md, PostToolUse
# decision control). decision:block alone is not enough, because the same table says
# "Claude still sees the original output". updatedMCPToolOutput is sent as well, as the
# older name for the same thing. decision:block and a reason are sent so that the session
# is told why. Whether the replacement takes effect has not been observed on a deployed
# machine.
#
# This hook fails open if it does not run to the end. The same reference says a hook
# that exits non-zero, prints invalid JSON or times out renders no decision, and the
# original output then stands. So every path below that does not positively find a
# listed space id ends in withhold, including a failure of jq.
#
# Where the space id is looked for. The shape of this tool's response has not been
# seen, because the tool was denied until this hook existed. The paths in SPACE_ID_PATHS
# are guesses. They are fixed places in the response's own structure, never a search of
# the text, so a page body that mentions a space id cannot stand in for the real one. If
# none of them is present the result is withheld, and the reason lists the field names
# of the response (names only, no values) so that the right path can be set here.
#
# Audit: one JSON Lines record per call in ~/.claude/debug/confluence-space-check.jsonl.
# Each record carries response_keys, the same list of field names, so the shape of a real
# response can be read from the log whatever the decision was.
set -u

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/audit-log.sh
source "$HOOK_DIR/lib/audit-log.sh"
# shellcheck source=lib/confluence-spaces.sh
source "$HOOK_DIR/lib/confluence-spaces.sh"
audit_init "confluence-space-check"

payload="$(cat)"
tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"

# The matcher should keep this hook to the one tool. Anything else is left alone.
if [[ "$tool_name" != "mcp__atlassian__getConfluenceContent" ]]; then
  exit 0
fi

# withhold <audit-reason> <text for the session>. Replaces the tool output with <text>,
# in the same outer shape the tool used, and ends the hook.
withhold() {
  local reason_short="$1" text="$2"
  audit_emit "$payload" deny reason "$reason_short" response_keys "${keys:-}"
  printf '%s' "$payload" | jq -c --arg t "$text" '
    (.tool_response | type) as $shape
    | (if $shape == "string" then $t
       elif $shape == "array" then [{type: "text", text: $t}]
       else {content: [{type: "text", text: $t}]} end) as $out
    | {
        decision: "block",
        reason: $t,
        hookSpecificOutput: {
          hookEventName: "PostToolUse",
          updatedToolOutput: $out,
          updatedMCPToolOutput: $out
        }
      }' 2>/dev/null && exit 0
  # jq could not build the answer. Send a fixed one, so the result is still replaced.
  printf '%s\n' '{"decision":"block","reason":"Confluence content withheld by confluence-space-check.sh.","hookSpecificOutput":{"hookEventName":"PostToolUse","updatedToolOutput":{"content":[{"type":"text","text":"Confluence content withheld by confluence-space-check.sh."}]},"updatedMCPToolOutput":{"content":[{"type":"text","text":"Confluence content withheld by confluence-space-check.sh."}]}}}'
  exit 0
}

# The response is read as one or two JSON documents: structuredContent where the tool
# sends it, and the first text item, parsed as JSON. Only the first text item is read, so
# that a later item holding a page body cannot supply the space id. From each document
# the space id is taken from these paths and no others:
#   .spaceId   .space.id   .metadata.spaceId   .metadata.space.id
# "keys" is the list of field names to two levels, for the reason given when no space id
# is found. It holds names only.
verdict="$(printf '%s' "$payload" | jq -c '
  def parsed: if type == "string" then (try fromjson catch null) else null end;
  def first_text:
    if type == "array"
    then ([.[] | select(type == "object" and .type == "text") | .text] | .[0])
    else null end;
  .tool_response as $r
  | ( if ($r | type) == "string" then [$r | parsed]
      elif ($r | type) == "array" then [$r | first_text | parsed]
      elif ($r | type) == "object" then
        if ($r | has("content")) or ($r | has("structuredContent"))
        then [($r.structuredContent // null), ($r.content | first_text | parsed)]
        else [$r] end
      else [] end
      | map(select(type == "object")) ) as $docs
  | {
      ids: [ $docs[]
             | (.spaceId?), (.space? | .id?), (.metadata? | .spaceId?), (.metadata? | .space? | .id?)
             | select(. != null) | tostring ],
      keys: ( [ $docs[] | paths | select(length <= 2) | map(tostring) | join(".") ]
              | unique
              | map(select(test("^[A-Za-z_][A-Za-z0-9_.]{0,60}$")))
              | .[0:60] | join(", ") )
    }' 2>/dev/null)"

if [[ -z "$verdict" ]]; then
  withhold "unreadable_response" "Confluence content withheld by confluence-space-check.sh. The response could not be read, so its space could not be checked."
fi

ids="$(printf '%s' "$verdict" | jq -r '.ids[]' 2>/dev/null)"
keys="$(printf '%s' "$verdict" | jq -r '.keys' 2>/dev/null)"

if [[ -z "$ids" ]]; then
  withhold "no_space_id" "Confluence content withheld by confluence-space-check.sh. The response did not carry a space id where this hook looks for one, so its space could not be checked. Report this to the maintainers of AI_Technical_Controls with the field names of the response, which are (names only, no values): ${keys:-none found}"
fi

while IFS= read -r id; do
  if ! confluence_space_id_allowed "$id"; then
    withhold "space_not_in_allowlist" "Confluence content withheld by confluence-space-check.sh. It is not in a space on the policy allowlist."
  fi
done <<< "$ids"

# Every space id found is on the list. The result stands as the tool returned it.
audit_emit "$payload" allow reason "space_in_allowlist" response_keys "$keys"
exit 0
