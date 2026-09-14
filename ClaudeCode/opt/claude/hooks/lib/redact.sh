# shellcheck shell=bash
# Shared secret-redaction library.
#
# Used by output-redact.sh (PostToolUse) and prompt-submit.sh (UserPromptSubmit).
# Exports two functions:
#
#   redact_text <text>
#     Stdout line 1: space-separated names of matched patterns (empty if none).
#     Stdout line 2+: <text> with every matched secret replaced by [REDACTED].
#     The line-1 sentinel is the authoritative match signal because callers run
#     this in $(...) (a subshell), where the REDACT_MATCHED global would be lost.
#
#   redact_matched_json [name...]
#     Echoes a compact JSON array of the given pattern names (typically the
#     word-split sentinel line from redact_text). Empty array with no args.
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
  # AUTH_HEADER selects candidates only. "Bearer", "Token" and "Basic" are all
  # ordinary English words, so the shape guard in redact_text checks the value
  # before anything is replaced (see __REDACT_CRED_SHAPE).
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

# Shape guard for AUTH_HEADER. The three markers are English words, so the
# pattern matched ordinary prose whenever 8 or more value characters followed
# one of them ("basic commands", "Token Authentication"). A value counts as
# credential material when it holds a digit, or two or more uppercase letters.
# Base64 basic-auth and opaque credentials both qualify, and a capitalised
# English word does not.
#
# It runs in awk rather than inside the ERE because ERE has no negative
# lookahead, the same reason the placeholder guard sits outside its pattern.
# Unlike that guard it runs per occurrence rather than per line, so prose and a
# real credential on one line are handled independently.
#
# Known miss. An all-lowercase, digit-free value is indistinguishable from an
# English word by shape, so it survives. The branded formats that shape could
# hide (JWT, GitHub PAT, Slack, Stripe, sk-) have their own patterns above.
__REDACT_CRED_SHAPE='function looks_like_credential(v,   n) {
  if (v ~ /[0-9]/) return 1
  n = gsub(/[A-Z]/, "", v)
  return (n >= 2)
}'

# redact_text: redacts secrets and reports which patterns matched.
#
# RETURN CONTRACT (important — read before changing callers):
#   stdout line 1   : space-separated names of patterns that matched (empty if
#                     none). This is the AUTHORITATIVE match signal.
#   stdout line 2.. : the redacted body.
#
# Why a stdout sentinel rather than the REDACT_MATCHED global: callers invoke
# this inside command substitution ($(...)), which runs in a subshell whose
# variable changes "cannot affect the shell's execution environment" (man bash,
# Command Execution Environment). So a global array populated here is LOST in
# the parent. stdout, by contrast, is exactly what $() captures — so the match
# signal must travel on stdout. REDACT_MATCHED is still populated for any direct
# (non-subshell) caller and for redact_matched_json, but it is NOT reliable
# across $(); the sentinel line is.
#
# Match detection counts [REDACTED] OCCURRENCES before vs after each pattern
# (via awk gsub), NOT raw string inequality. Inequality fired spuriously because
# $() strips trailing newlines, making benign multi-line text look "changed" and
# latch onto the first pattern. Occurrence counting also avoids grep -c's
# line-counting undercount when two secrets share a line.
redact_text() {
  local input="$1"
  local current="$input"
  local i=0
  local -a matched=()
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
    elif [[ "$name" == "AUTH_HEADER" ]]; then
      # Walks each candidate with match()/RSTART/RLENGTH (the same idiom
      # pii-patterns.sh uses) so the shape guard runs on one occurrence at a
      # time. The marker word and its trailing whitespace are stripped off
      # before the guard sees the value.
      current="$(printf '%s' "$current" | awk -v re="$regex" \
        "${__REDACT_CRED_SHAPE}"'
        {
          line = $0
          out = ""
          while (match(line, re) > 0) {
            hit = substr(line, RSTART, RLENGTH)
            out = out substr(line, 1, RSTART - 1)
            line = substr(line, RSTART + RLENGTH)
            val = hit
            sub(/^[A-Za-z]+[[:space:]]+/, "", val)
            if (looks_like_credential(val)) { out = out "[REDACTED]" } else { out = out hit }
          }
          print out line
        }')"
    else
      current="$(printf '%s' "$current" | sed -E "s#${regex}#[REDACTED]#g")"
    fi

    # A real match for this pattern iff the [REDACTED] occurrence count rose.
    local before_n after_n
    before_n="$(printf '%s' "$before"  | awk '{n+=gsub(/\[REDACTED\]/,"&")} END{print n+0}')"
    after_n="$(printf '%s'  "$current" | awk '{n+=gsub(/\[REDACTED\]/,"&")} END{print n+0}')"
    if [[ "${after_n:-0}" -gt "${before_n:-0}" ]]; then
      matched+=("$name")
      REDACT_MATCHED+=("$name")   # best-effort for direct (non-subshell) callers
    fi
    i=$((i + 2))
  done
  printf '%s\n' "${matched[*]:-}"   # sentinel line 1: matched names (authoritative)
  printf '%s' "$current"            # line 2..: redacted body
}

# redact_matched_json: compact JSON array of pattern names. Accepts the names as
# arguments (the sentinel line, word-split by the caller) so it does not depend
# on the subshell-fragile REDACT_MATCHED global. With no args, emits [].
redact_matched_json() {
  if [[ "$#" -eq 0 ]]; then
    printf '[]'
    return 0
  fi
  printf '%s\n' "$@" | jq -R . | jq -sc .
}
