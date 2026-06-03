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
#
# Engine note: matching uses `sed -E` (POSIX ERE), not perl. The previous
# implementation shelled out to `perl -pe "s/$regex/.../"`, which did not redact
# at runtime in this environment (verified via /test-guardrails: AWS/PAT/Slack/
# Stripe samples all passed through with matched=[]). sed -E is available and
# verified working here. Two consequences of the engine switch are encoded
# below:
#   * Patterns are written in ERE, with case-insensitivity expressed as explicit
#     [Aa] character classes rather than perl's (?i), and `\s` as [[:space:]].
#   * Each substitution uses `#` as the s-command delimiter so literal `/`
#     inside a pattern (URLs, base64 alphabets) needs no escaping.
# sed -E is line-oriented, so a PEM block spanning multiple lines is only
# best-effort matched on its delimiter lines (the perl -p version was equally
# line-oriented, so this is not a regression).

[[ -n "${__REDACT_LIB_LOADED:-}" ]] && return 0
__REDACT_LIB_LOADED=1

# KEY_ASSIGNMENT is built from a shared key-name+separator prefix so the
# placeholder guard in redact_text can reuse the exact same prefix to decide
# whether a value is a documentation placeholder. The prefix matches the key
# name, an optional separator word boundary, the = or : separator, and an
# optional opening quote.
__REDACT_KEY_PREFIX='([Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Aa][Pp][Ii][_-]?[Ss][Ee][Cc][Rr][Ee][Tt]|[Aa][Uu][Tt][Hh][_-]?[Tt][Oo][Kk][Ee][Nn]|[Aa][Cc][Cc][Ee][Ss][Ss][_-]?[Tt][Oo][Kk][Ee][Nn]|[Cc][Ll][Ii][Ee][Nn][Tt][_-]?[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Rr][Ii][Vv][Aa][Tt][Ee][_-]?[Kk][Ee][Yy]|[Rr][Ee][Ff][Rr][Ee][Ss][Hh][_-]?[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Ss][Ss][Ii][Oo][Nn][_-]?[Tt][Oo][Kk][Ee][Nn]|[Ee][Nn][Cc][Rr][Yy][Pp][Tt][Ii][Oo][Nn][_-]?[Kk][Ee][Yy]|[Ss][Ii][Gg][Nn][Ii][Nn][Gg][_-]?[Kk][Ee][Yy]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd])[[:space:]]*[=:][[:space:]]*'

# Patterns are listed (name, ERE regex) in priority order — more-specific first
# so log labels stay unambiguous when multiple patterns could match the same
# substring. Regexes are ERE for `sed -E` and use `#` as the eventual s-command
# delimiter, so a literal `#` must not appear unescaped in a pattern.
__REDACT_PATTERNS=(
  "PEM_BLOCK"          '-----BEGIN [A-Z ]+-----'
  "AWS_KEY_ID"         '(AKIA|ASIA)[A-Z0-9]{16}'
  "AWS_SECRET"         '([Aa][Ww][Ss]_)?[Ss][Ee][Cc][Rr][Ee][Tt]_[Aa][Cc][Cc][Ee][Ss][Ss]_[Kk][Ee][Yy][[:space:]]*[=:][[:space:]]*[A-Za-z0-9/+]{40}'
  "GITHUB_PAT"         'gh[pousr]_[A-Za-z0-9]{34,}'
  "GITHUB_FINE_PAT"    'github_pat_[A-Za-z0-9_]{82}'
  "SK_API_KEY"         'sk-[A-Za-z0-9_-]{20,}'
  "STRIPE_KEY"         '(sk|pk|rk)_(live|test)_[A-Za-z0-9]{24,}'
  "SLACK_TOKEN"        'xox[baprs]-[A-Za-z0-9-]{10,}'
  "JWT"                'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'
  "AUTH_HEADER"        '([Bb][Ee][Aa][Rr][Ee][Rr]|[Tt][Oo][Kk][Ee][Nn]|[Bb][Aa][Ss][Ii][Cc])[[:space:]]+[A-Za-z0-9_.~+/=-]{8,}'
  "TWILIO_KEY"         'SK[a-f0-9]{32}'
  "SENDGRID_KEY"       'SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}'
  "CONNECTION_STRING"  '(mongodb(\+srv)?|postgres(ql)?|mysql|redis|amqp)://[^:@ ]+:[^@ ]+@'
  "KEY_ASSIGNMENT"     "${__REDACT_KEY_PREFIX}\"?[A-Za-z0-9+/_!@%^*-]{20,}"
  "SSH_KEY_MATERIAL"   'AAAA[A-Za-z0-9+/]{40,}={0,2}'
  "GOOGLE_API_KEY"     'AIza[A-Za-z0-9_-]{35}'
)

# Values matching KEY_ASSIGNMENT whose secret portion contains one of these
# tokens are treated as documentation placeholders, not real secrets, and left
# untouched. (sed ERE has no negative lookahead, so this exclusion is applied
# as a bash-level guard rather than inside the pattern.)
__REDACT_PLACEHOLDER='(example|placeholder|your[-_]|xxx|changeme|dummy|fake|test|sample)'

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

    if [[ "$name" == "KEY_ASSIGNMENT" ]]; then
      # ERE has no negative lookahead, so the placeholder exclusion is applied
      # per line in awk: a line whose value starts with a documentation
      # placeholder (password=example...) is left untouched; any other matching
      # assignment is redacted. awk evaluates each line independently in one
      # pass. Trailing-newline handling matches the sed branch below: the
      # surrounding $() strips trailing newlines uniformly, and callers
      # (output-redact.sh, prompt-submit.sh) already pass newline-stripped text.
      current="$(printf '%s' "$current" | awk \
        -v kv="$regex" \
        -v ph="${__REDACT_KEY_PREFIX}\"?${__REDACT_PLACEHOLDER}" \
        '{ if ($0 ~ ph) { print } else if ($0 ~ kv) { gsub(kv, "[REDACTED]"); print } else { print } }')"
    else
      current="$(printf '%s' "$current" | sed -E "s#${regex}#[REDACTED]#g")"
    fi

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
