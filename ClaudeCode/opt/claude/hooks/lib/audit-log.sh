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

  # Best-effort field extraction in a single jq pass. Missing keys become
  # empty strings (// "") so the record is consistent. These four values are
  # all single-line strings, so @tsv + IFS read is safe (no embedded tabs).
  local session_id transcript_path payload_cwd tool_name
  IFS=$'\t' read -r session_id transcript_path payload_cwd tool_name < <(
    printf '%s' "$payload" | jq -r '
      [ .session_id // "", .transcript_path // "", .cwd // "", .tool_name // "" ]
      | @tsv' 2>/dev/null || true)

  local ts user proc_cwd host
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  user="${USER:-$(id -un 2>/dev/null || echo unknown)}"
  proc_cwd="$(pwd)"
  # hostname -s strips the domain suffix. On macOS this is typically the
  # machine name set in Settings → General → About. Captured once per
  # invocation; cheap call.
  host="$(hostname -s 2>/dev/null || echo unknown)"

  # Extras are passed as positional `key value` pairs; a key ending in ":json"
  # is bound with --argjson (raw number/bool/array) instead of --arg (string).
  #
  # schema_version: bumped only on backwards-incompatible envelope changes
  # (field renamed or semantics altered); adding an optional field does not.
  local jq_args=(
    --argjson schema_version 1
    --arg ts          "$ts"
    --arg hook        "$AUDIT_HOOK"
    --arg user        "$user"
    --arg host        "$host"
    --arg proc_cwd    "$proc_cwd"
    --arg payload_cwd "$payload_cwd"
    --arg session_id  "$session_id"
    --arg transcript  "$transcript_path"
    --arg tool_name   "$tool_name"
    --arg decision    "$decision"
  )

  # shellcheck disable=SC2016  # single-quoted jq filter — $-vars are jq bindings, not shell
  local jq_obj='{
    schema_version: $schema_version,
    ts: $ts,
    hook: $hook,
    user: $user,
    host: $host,
    proc_cwd: $proc_cwd,
    payload_cwd: $payload_cwd,
    session_id: $session_id,
    transcript: $transcript,
    tool_name: $tool_name,
    decision: $decision
  }'

  # Extra fields: pairs of (name, value). A name ending in ":json" is
  # interpreted as raw JSON (numbers, booleans, arrays); everything else is a
  # string. A ":json" value that is not valid JSON would make the whole
  # `jq -cn` below fail, silently dropping the entire record — so guard it:
  # malformed JSON degrades to a string binding rather than losing the line.
  while [[ $# -ge 2 ]]; do
    local k="$1" v="$2"
    shift 2
    if [[ "$k" == *:json ]] && printf '%s' "$v" | jq -e . >/dev/null 2>&1; then
      local bare="${k%:json}"
      jq_args+=(--argjson "$bare" "$v")
      jq_obj+=" | . + {\"$bare\": \$$bare}"
    else
      local bare="${k%:json}"
      jq_args+=(--arg "$bare" "$v")
      jq_obj+=" | . + {\"$bare\": \$$bare}"
    fi
  done

  # Compact (-c) so each record is one line.
  local line
  if ! line="$(jq -cn "${jq_args[@]}" "$jq_obj" 2>/dev/null)"; then
    return 0  # never break the hook on a log-build failure
  fi

  printf '%s\n' "$line" >> "$AUDIT_LOG" 2>/dev/null || true
}
