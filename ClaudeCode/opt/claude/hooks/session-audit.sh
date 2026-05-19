#!/usr/bin/env bash
# SessionStart / Stop / SessionEnd hook — records session-level events.
#
# A single script handles all three events; the event name is read from the
# payload and recorded in the audit line. This gives us a ledger of "session
# X started here, ended here, ran N turns" without one script per event.
#
# Output: ~/.claude/debug/session-audit.jsonl
#
# Per event we capture:
#   SessionStart : source (startup|resume|clear|compact), cwd
#   Stop         : stop_hook_active flag (Claude is asking whether to continue)
#   SessionEnd   : reason, if provided by the payload
set -u

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/audit-log.sh
source "$HOOK_DIR/lib/audit-log.sh"
audit_init "session-audit"

payload="$(cat)"
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // ""')"

case "$event" in
  SessionStart)
    source="$(printf '%s' "$payload" | jq -r '.source // ""')"
    audit_emit "$payload" "session_start" source "$source"
    ;;
  Stop)
    stop_hook_active="$(printf '%s' "$payload" | jq -r '.stop_hook_active // false')"
    audit_emit "$payload" "stop" stop_hook_active:json "$stop_hook_active"
    ;;
  SessionEnd)
    reason="$(printf '%s' "$payload" | jq -r '.reason // ""')"
    audit_emit "$payload" "session_end" reason "$reason"
    ;;
  *)
    # Defensive: if wired to an event we didn't anticipate, still record
    # something rather than silently dropping it.
    audit_emit "$payload" "$event"
    ;;
esac

exit 0
