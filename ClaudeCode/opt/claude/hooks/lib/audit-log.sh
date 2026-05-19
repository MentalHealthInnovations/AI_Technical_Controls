#!/usr/bin/env bash
# Shared audit-log helper. Sourced by the policy hooks to emit a single JSON
# Lines record per invocation to ~/.claude/debug/<hook>.jsonl.
#
# Usage:
#   source "$(dirname "$0")/lib/audit-log.sh"
#   audit_init "bash-policy"               # sets AUDIT_HOOK + AUDIT_LOG path
#   audit_emit "$payload" allow \           # decision: allow|deny|redact|observe
#     --arg cmd "$cmd"                      # extra jq --arg pairs
#
# The record carries a stable common envelope (ts, hook, user, cwd, decision,
# session_id, transcript_path, cwd_payload, tool_name) plus any extra fields
# passed as jq --arg/--argjson pairs after the decision.
#
# Designed to be drop-in safe: failure to write the log MUST NOT block the
# hook. Each helper traps errors and falls back silently.

# Guard against multiple sourcing.
[[ -n "${__AUDIT_LOG_LOADED:-}" ]] && return 0
__AUDIT_LOG_LOADED=1

audit_init() {
  AUDIT_HOOK="$1"
  AUDIT_DIR="$HOME/.claude/debug"
  AUDIT_LOG="$AUDIT_DIR/${AUDIT_HOOK}.jsonl"
  mkdir -p "$AUDIT_DIR" 2>/dev/null || true
}

# audit_emit PAYLOAD DECISION [extra jq --arg/--argjson pairs...]
#
# PAYLOAD is the raw hook stdin JSON. We pull session_id, transcript_path,
# cwd, and tool_name from it so every record is self-describing.
audit_emit() {
  local payload="$1"
  local decision="$2"
  shift 2 || true

  # Best-effort field extraction. jq returns "null" for missing keys; we
  # convert those to empty strings so the record is consistent.
  local session_id transcript_path payload_cwd tool_name
  session_id="$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null || true)"
  transcript_path="$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null || true)"
  payload_cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null || true)"
  tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null || true)"

  local ts user proc_cwd
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  user="${USER:-$(id -un 2>/dev/null || echo unknown)}"
  proc_cwd="$(pwd)"

  # Build the record. Common fields first, then merge the caller's extras.
  # Caller passes extras as jq variable bindings (--arg / --argjson) followed
  # by a final --argjson-built object would be awkward, so we keep it simple:
  # callers pass `key value` pairs as additional positional args and we
  # convert them to --arg bindings here. Numeric/boolean extras can use the
  # `key:json` form (e.g. `len:42`) which we route to --argjson.
  local jq_args=(
    --arg ts          "$ts"
    --arg hook        "$AUDIT_HOOK"
    --arg user        "$user"
    --arg proc_cwd    "$proc_cwd"
    --arg payload_cwd "$payload_cwd"
    --arg session_id  "$session_id"
    --arg transcript  "$transcript_path"
    --arg tool_name   "$tool_name"
    --arg decision    "$decision"
  )

  # shellcheck disable=SC2016  # single-quoted jq filter — $-vars are jq bindings, not shell
  local jq_obj='{
    ts: $ts,
    hook: $hook,
    user: $user,
    proc_cwd: $proc_cwd,
    payload_cwd: $payload_cwd,
    session_id: $session_id,
    transcript: $transcript,
    tool_name: $tool_name,
    decision: $decision
  }'

  # Extra fields: pairs of (name, value). A name ending in ":json" is
  # interpreted as raw JSON (numbers, booleans, arrays).
  while [[ $# -ge 2 ]]; do
    local k="$1" v="$2"
    shift 2
    if [[ "$k" == *:json ]]; then
      local bare="${k%:json}"
      jq_args+=(--argjson "$bare" "$v")
      jq_obj+=" | . + {\"$bare\": \$$bare}"
    else
      jq_args+=(--arg "$k" "$v")
      jq_obj+=" | . + {\"$k\": \$$k}"
    fi
  done

  # Compact (-c) so each record is one line.
  local line
  if ! line="$(jq -cn "${jq_args[@]}" "$jq_obj" 2>/dev/null)"; then
    return 0  # never break the hook on a log-build failure
  fi

  printf '%s\n' "$line" >> "$AUDIT_LOG" 2>/dev/null || true
}
