#!/usr/bin/env bash
# UserPromptSubmit hook — records each prompt the user submits to Claude.
#
# Captures the full prompt text but routes it through the shared
# redact_text() patterns first, so credentials pasted into prompts (AWS keys,
# PATs, etc.) are stripped before they hit the audit log. The list of
# patterns that fired is recorded alongside the redacted text, so a
# downstream analyst can see "this prompt contained an AWS_KEY_ID" without
# ever storing the key itself.
#
# This hook does not block. It always returns an empty allow object so the
# prompt proceeds to the model.
#
# Output: ~/.claude/debug/prompt-submit.jsonl
set -u

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/audit-log.sh
source "$HOOK_DIR/lib/audit-log.sh"
# shellcheck source=lib/redact.sh
source "$HOOK_DIR/lib/redact.sh"
audit_init "prompt-submit"

payload="$(cat)"
prompt="$(printf '%s' "$payload" | jq -r '.prompt // ""')"

if [[ -z "$prompt" ]]; then
  exit 0
fi

prompt_len="${#prompt}"

# shellcheck disable=SC2034  # read inside lib/redact.sh via redact_text/redact_matched_json
REDACT_MATCHED=()
redacted_prompt="$(redact_text "$prompt")"
matched_json="$(redact_matched_json)"

# Use a "submit" decision rather than allow/deny — the prompt is not subject
# to a policy decision here, and using a distinct verb makes filtering the
# JSONL trivial later.
audit_emit "$payload" submit \
  prompt          "$redacted_prompt" \
  prompt_len:json "$prompt_len" \
  redactions:json "$matched_json"

# Empty response means "no modifications" — prompt proceeds normally.
exit 0
