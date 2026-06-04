#!/usr/bin/env bash
# PostToolUse hook — redacts secrets from tool output before they reach Claude.
#
# Registered for Bash, Read, and WebFetch. Scans tool_response for secret patterns
# (defined in lib/redact.sh) and replaces each match with [REDACTED] in-place,
# then returns the sanitised content via decision:block so Claude never sees the
# raw value.
#
# decision:block is the correct mechanism: it prevents the tool output from
# entering Claude's context window. The reason field carries the sanitised text
# that Claude sees instead. suppressOutput additionally hides raw values from
# the debug log.
#
# Patterns live in lib/redact.sh and are shared with the prompt-submit hook so
# secrets pasted into prompts get the same treatment as secrets in tool output.
# To add a new pattern, edit lib/redact.sh.
#
# Audit: every invocation is appended as a single JSON Lines record to
# ~/.claude/debug/output-redact.jsonl via the shared audit-log helper. The
# record carries the list of pattern names matched (empty when clean) plus the
# output byte length, so downstream analysis can spot unusual volume or
# repeated near-misses without ever storing the raw output.

set -u

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/audit-log.sh
source "$HOOK_DIR/lib/audit-log.sh"
# shellcheck source=lib/redact.sh
source "$HOOK_DIR/lib/redact.sh"
audit_init "output-redact"

payload="$(cat)"

# Pull raw output text. Field names differ by tool:
#   Bash:     .tool_response.stdout (primary output)
#   Read:     .tool_response.content (string or [{type,text}] array)
#   WebFetch: .tool_response.content (string)
raw_output="$(printf '%s' "$payload" | jq -r '
  if .tool_response.stdout? and (.tool_response.stdout | type) == "string" then
    .tool_response.stdout
  elif .tool_response.content? and (.tool_response.content | type) == "array" then
    [.tool_response.content[] | select(.type == "text") | .text] | join("\n")
  elif .tool_response.content? and (.tool_response.content | type) == "string" then
    .tool_response.content
  else
    ""
  end
')"

# Capture output length up front for the audit record. We measure bytes, not
# characters, since the goal is volume tracking. Length 0 means the response
# carried no scannable text (e.g. tool error, binary read) and we'll still
# emit an observe record so the call appears in the audit trail.
output_len="${#raw_output}"

if [[ -z "$raw_output" ]]; then
  audit_emit "$payload" observe matched:json '[]' output_len:json "$output_len"
  exit 0
fi

# redact_text returns the matched-pattern names on stdout line 1 (authoritative;
# survives this command substitution) and the redacted body on the rest. We split
# on the first newline: everything before it is the sentinel, everything after is
# the body. The sentinel — not a now-empty REDACT_MATCHED global — drives the
# block decision, so a secret cannot slip through on a lost side-channel.
result="$(redact_text "$raw_output")"
matched_names="${result%%$'\n'*}"
redacted="${result#*$'\n'}"
# shellcheck disable=SC2086  # word-splitting matched_names into separate args is intended
matched_json="$(redact_matched_json $matched_names)"

if [[ -z "$matched_names" ]]; then
  audit_emit "$payload" observe matched:json "$matched_json" output_len:json "$output_len"
  exit 0
fi

audit_emit "$payload" redact matched:json "$matched_json" output_len:json "$output_len"

# Block the tool output from entering Claude's context.
# decision:block prevents Claude from seeing the raw output; reason tells Claude
# what happened. suppressOutput additionally hides the raw value from debug logs.
printf '%s' "$redacted" | jq -Rs \
  '{
    decision: "block",
    reason: ("Tool output contained one or more secret patterns and was redacted by output-redact.sh. Sanitised output:\n\n" + .),
    suppressOutput: true
  }'
