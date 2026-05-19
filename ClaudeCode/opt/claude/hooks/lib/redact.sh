#!/usr/bin/env bash
# Shared secret-redaction library.
#
# Used by output-redact.sh (PostToolUse) and prompt-submit.sh (UserPromptSubmit).
# Exports two functions:
#
#   redact_text <text>
#     Echoes <text> to stdout with every matched secret replaced by [REDACTED].
#     Side effect: appends matched pattern names to the global REDACT_MATCHED
#     array (caller must declare it).
#
#   redact_matched_json
#     Echoes a compact JSON array of the pattern names matched on the most
#     recent redact_text call. Empty array on clean input.
#
# Callers reset REDACT_MATCHED=() before each scan.

[[ -n "${__REDACT_LIB_LOADED:-}" ]] && return 0
__REDACT_LIB_LOADED=1

# Patterns are listed (name, regex) in priority order — more-specific first
# so log labels stay unambiguous when multiple patterns could match the same
# substring.
__REDACT_PATTERNS=(
  "PEM_BLOCK"          '-----BEGIN [A-Z ]+-----[A-Za-z0-9+\/=\r\n]+-----END [A-Z ]+-----'
  "AWS_KEY_ID"         '(AKIA|ASIA)[A-Z0-9]{16}'
  "AWS_SECRET"         '(?i)(aws_secret_access_key|secret_access_key)\s*[=:]\s*[A-Za-z0-9\/+]{40}'
  "GITHUB_PAT"         'gh[pousr]_[A-Za-z0-9]{34,}'
  "GITHUB_FINE_PAT"    'github_pat_[A-Za-z0-9_]{82}'
  "SK_API_KEY"         'sk-[A-Za-z0-9_\-]{20,}'
  "STRIPE_KEY"         '(sk|pk|rk)_(live|test)_[A-Za-z0-9]{24,}'
  "SLACK_TOKEN"        'xox[baprs]-[A-Za-z0-9\-]{10,}'
  "JWT"                'eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+'
  "AUTH_HEADER"        '(?i)(bearer|token|basic)\s+(?=[A-Za-z0-9_.~+\/=-]*[A-Z0-9_.~+\/=-])[A-Za-z0-9_.~+\/=-]{8,}'
  "TWILIO_KEY"         'SK[a-f0-9]{32}'
  "SENDGRID_KEY"       'SG\.[A-Za-z0-9_\-]{22}\.[A-Za-z0-9_\-]{43}'
  "CONNECTION_STRING"  '(mongodb(\+srv)?|postgres(ql)?|mysql|redis|amqp):\/\/[^:@\s]+:[^@\s"'"'"']+@'
  "KEY_ASSIGNMENT"     '(?i)(api[_-]?key|api[_-]?secret|auth[_-]?token|access[_-]?token|client[_-]?secret|private[_-]?key|refresh[_-]?token|session[_-]?token|encryption[_-]?key|signing[_-]?key|password|passwd)\s*[=:]\s*["\x27]?(?!.*(?:example|placeholder|your[-_]|xxx|changeme|dummy|fake|test|sample))[A-Za-z0-9+\/\-_!@#$%^&*]{20,}["\x27]?'
  "SSH_KEY_MATERIAL"   'AAAA[A-Za-z0-9+\/]{40,}={0,2}'
  "GOOGLE_API_KEY"     'AIza[a-zA-Z0-9\-_\\]{35}'
)

# redact_text: returns the input with all matches replaced by [REDACTED].
# Appends pattern names to the caller's REDACT_MATCHED array on each hit.
redact_text() {
  local input="$1"
  local current="$input"
  local i=0
  while [[ $i -lt ${#__REDACT_PATTERNS[@]} ]]; do
    local name="${__REDACT_PATTERNS[$i]}"
    local regex="${__REDACT_PATTERNS[$((i+1))]}"
    local before="$current"
    current="$(printf '%s' "$current" | perl -pe "s/$regex/[REDACTED]/g")"
    if [[ "$current" != "$before" ]]; then
      REDACT_MATCHED+=("$name")
    fi
    i=$((i + 2))
  done
  printf '%s' "$current"
}

# redact_matched_json: compact JSON array of last scan's pattern names.
redact_matched_json() {
  if [[ "${#REDACT_MATCHED[@]}" -eq 0 ]]; then
    printf '[]'
    return 0
  fi
  printf '%s\n' "${REDACT_MATCHED[@]}" | jq -R . | jq -sc .
}
