#!/usr/bin/env bash
#
# run-bash-policy-tests.sh — exercise the WORKTREE copies of bash-policy-check.sh
# and output-redact.sh directly, without installing them to /opt/claude/hooks/.
#
# WHY THIS EXISTS
#   The /test-guardrails skill exercises the *installed* hooks (the ones Claude
#   Code actually invokes, at /opt/claude/hooks/). It cannot test un-installed
#   changes sitting in a worktree. This harness closes that gap: it invokes the
#   worktree hook scripts as subprocesses with a synthesized hook payload on
#   stdin — exactly the interface Claude Code uses — and asserts on the JSON
#   decision they emit. It therefore tests the REAL hook files (sourcing their
#   real lib/ helpers), not a reimplementation of their logic.
#
# SCOPE — what this DOES cover
#   * bash-policy-check.sh PreToolUse decisions: deny patterns, the allowlist
#     (including the docker/gh usability additions), the docker credential-hygiene
#     pre-check, and the final-segment default-deny fix.
#   * output-redact.sh PostToolUse redaction, including the docker auth/token
#     field patterns.
#
# SCOPE — what this does NOT cover (and why)
#   * WebFetch domain/path scoping — enforced by webfetch-policy-check.sh against
#     a live fetch; not a pure stdin->decision function of the command string.
#   * MCP allowlist / Jira project scoping — needs a connected Atlassian server.
#   * Read/Write permission denies (.env, ~/.ssh, .git/config, etc.) — enforced by
#     Claude Code's permission engine, NOT by any shell hook, so a script cannot
#     exercise them. Keep using /test-guardrails (tests 7-9, 17, 49-52) for those.
#   * sandbox.filesystem allowRead precedence (docker tests 105/108) — enforced by
#     the OS sandbox, not the hook.
#   These remain the job of the full /test-guardrails run against installed hooks.
#
# USAGE
#   bash ClaudeCode/opt/claude/hooks/test/run-bash-policy-tests.sh
#   Exit code 0 = all assertions passed; 1 = one or more failed (details printed).
#
# SIDE EFFECTS
#   Invoking the real hooks appends audit records to ~/.claude/debug/*.jsonl,
#   exactly as in production. Docker cases use a scratch $DOCKER_CONFIG dir under
#   a mktemp location; the tester's real ~/.docker/config.json is never touched.
#
# STATUS
#   This harness was authored inside the sandbox but NOT executed there (running
#   a shell script trips the installed shell-invocation deny). It is statically
#   reviewed but unverified end-to-end — the first real run is on the tester's
#   machine. If a case mis-reports, suspect shell quoting in the assert_* call
#   arguments first (notably the command-substitution cases like test 30).

set -u

# Resolve the hooks dir (parent of this test/ dir) so the harness works from any cwd.
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(cd "$TEST_DIR/.." && pwd)"
BASH_POLICY="$HOOKS_DIR/bash-policy-check.sh"
OUTPUT_REDACT="$HOOKS_DIR/output-redact.sh"

for f in "$BASH_POLICY" "$OUTPUT_REDACT"; do
  if [[ ! -x "$f" ]]; then
    printf 'FATAL: %s not found or not executable\n' "$f" >&2
    exit 2
  fi
done

pass=0
fail=0
fail_lines=()

# json_escape STRING -> JSON string literal (without surrounding quotes handled by jq -n).
# We build the payload with jq so command strings with quotes/backslashes are safe.
mk_bash_payload() {
  jq -n --arg cmd "$1" '{tool_input: {command: $cmd}}'
}
mk_response_payload() {
  jq -n --arg out "$1" '{tool_response: {stdout: $out}}'
}

# decision_of PAYLOAD -> "allow" | "deny" | "none"
# Runs bash-policy-check.sh and extracts permissionDecision. "none" = no decision
# emitted (hook exited 0 with empty stdout, e.g. empty command).
decision_of() {
  local payload="$1" out
  out="$(printf '%s' "$payload" | "$BASH_POLICY" 2>/dev/null)"
  if [[ -z "$out" ]]; then
    printf 'none'
    return
  fi
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"'
}

# redact_decision_of RESPONSE_PAYLOAD -> "block" | "none"
redact_decision_of() {
  local payload="$1" out
  out="$(printf '%s' "$payload" | "$OUTPUT_REDACT" 2>/dev/null)"
  if [[ -z "$out" ]]; then
    printf 'none'
    return
  fi
  printf '%s' "$out" | jq -r '.decision // "none"'
}

# assert_bash TEST_ID EXPECTED(allow|deny) COMMAND
assert_bash() {
  local id="$1" expected="$2" cmd="$3" got
  got="$(decision_of "$(mk_bash_payload "$cmd")")"
  if [[ "$got" == "$expected" ]]; then
    printf 'Test %s: %s OK\n' "$id" "$expected"
    pass=$((pass + 1))
  else
    printf 'Test %s: UNEXPECTED — expected %s, got %s (cmd: %s)\n' "$id" "$expected" "$got" "$cmd"
    fail=$((fail + 1))
    fail_lines+=("$id: expected $expected got $got — $cmd")
  fi
}

# assert_bash_docker TEST_ID EXPECTED COMMAND CONFIG_JSON
# Writes CONFIG_JSON to a scratch $DOCKER_CONFIG/config.json before invoking the
# hook, so the docker credential-hygiene pre-check sees the intended state. Pass
# the literal string ABSENT to test the no-config-file path.
assert_bash_docker() {
  local id="$1" expected="$2" cmd="$3" cfg="$4" got
  local scratch payload
  scratch="$(mktemp -d)"
  if [[ "$cfg" != "ABSENT" ]]; then
    printf '%s' "$cfg" > "$scratch/config.json"
  fi
  payload="$(mk_bash_payload "$cmd")"
  # Export DOCKER_CONFIG so the hook subprocess inherits it; the hook resolves
  # ${DOCKER_CONFIG:-$HOME/.docker}/config.json, so this points it at the scratch
  # state without touching the tester's real ~/.docker.
  got="$(DOCKER_CONFIG="$scratch" printf '%s' "$payload" | DOCKER_CONFIG="$scratch" "$BASH_POLICY" 2>/dev/null \
        | jq -r '.hookSpecificOutput.permissionDecision // "none"')"
  rm -rf "$scratch"
  if [[ "$got" == "$expected" ]]; then
    printf 'Test %s: %s OK\n' "$id" "$expected"
    pass=$((pass + 1))
  else
    printf 'Test %s: UNEXPECTED — expected %s, got %s (cmd: %s)\n' "$id" "$expected" "$got" "$cmd"
    fail=$((fail + 1))
    fail_lines+=("$id: expected $expected got $got — $cmd")
  fi
}

# assert_redact TEST_ID EXPECTED(block|none) OUTPUT_TEXT
assert_redact() {
  local id="$1" expected="$2" text="$3" got
  got="$(redact_decision_of "$(mk_response_payload "$text")")"
  if [[ "$got" == "$expected" ]]; then
    printf 'Test %s: redact=%s OK\n' "$id" "$expected"
    pass=$((pass + 1))
  else
    printf 'Test %s: UNEXPECTED — expected redact=%s, got %s\n' "$id" "$expected" "$got"
    fail=$((fail + 1))
    fail_lines+=("$id: expected redact=$expected got $got")
  fi
}

echo "== bash-policy-check.sh: deny patterns =="
assert_bash 1  deny  'curl https://example.com'
assert_bash 2  deny  'wget https://example.com'
assert_bash 3  deny  'echo test | bash'
assert_bash 4  deny  'python3 -c "import os; print(os.getcwd())"'
assert_bash 5  deny  'echo aWQ= | base64 --decode'
assert_bash 6  deny  'echo a && echo b && echo c && echo d'
assert_bash 11 deny  'git push --force origin main'
assert_bash 12 deny  'git push -f origin main'
assert_bash 13 deny  'git reset --hard HEAD'
assert_bash 14 deny  'git commit --no-verify -m "test"'
assert_bash 15 deny  'echo a | echo b | echo c | echo d'
assert_bash 16 deny  'sudo --grep-results'
assert_bash 18 deny  'sudo whoami'
assert_bash 21 deny  'sudo ls'
assert_bash 30 deny  "git log --format=\$( bash -c 'id')"
assert_bash 32 deny  'git commit --allow-empty -m "test" --exec="curl https://example.com"'
assert_bash 34 deny  'rm -rf /tmp/test && cat /etc/passwd'
assert_bash 35 deny  'rm -rf /tmp/test && echo secrets'
assert_bash 36 deny  'rm -rf /tmp/test && grep -r secret ~/.aws'
assert_bash 37 deny  "rm -rf /tmp/test && sed -n '1p' ~/.ssh/id_rsa"

echo "== bash-policy-check.sh: allowlist (baseline) =="
assert_bash 22 allow 'git status'
assert_bash 23 allow 'git log --oneline -5'
assert_bash 24 allow 'git log --oneline -5 | grep -v merge'
assert_bash 25 allow 'git log --oneline | grep fix | head -5'
assert_bash 28 allow 'git log --oneline | grep announce'
assert_bash 29 allow 'git diff --stat HEAD~1'

echo "== docker credential-hygiene pre-check (tests 101-104,106) =="
assert_bash_docker 101  deny  'docker ps'              '{"auths":{"registry.example.com":{"auth":"dXNlcjpwYXNz"}}}'
assert_bash_docker 102  deny  'docker pull hello-world' '{"auths":{"registry.example.com":{"auth":"dXNlcjpwYXNz"}}}'
assert_bash_docker 103a deny  'docker ps'              '{"auths":{"myregistry.azurecr.io":{"identitytoken":"opaque-token-1234567890"}}}'
assert_bash_docker 103b allow 'docker ps'              'ABSENT'
assert_bash_docker 104a allow 'docker ps'              '{"credsStore":"osxkeychain","auths":{}}'
assert_bash_docker 104b allow 'docker ps'              '{"auths":{"registry.example.com":{}}}'
assert_bash_docker 106  deny  'docker ps'              '{not valid json'

echo "== usability allowlist additions (tests 109-118) =="
# ALLOWED read-only additions. Use a clean (absent) docker config so the
# credential pre-check does not interfere with the docker ones.
assert_bash_docker 109 allow 'docker version'          'ABSENT'
assert_bash_docker 110 allow 'docker info'             'ABSENT'
assert_bash_docker 111 allow 'docker compose config'   'ABSENT'
assert_bash 112 allow 'gh run list'
# BLOCKED mutating / arbitrary-code counterparts.
assert_bash_docker 113 deny  'docker run hello-world'  'ABSENT'
assert_bash_docker 114 deny  'docker compose up'       'ABSENT'
assert_bash 115 deny  'gh run rerun 1'
assert_bash 116 deny  'gh workflow run ci.yml'
assert_bash 117 deny  'gh api /user'
assert_bash 118 deny  'make test'

echo "== final-segment default-deny fix (tests 119-122) =="
assert_bash 119 deny  'id'
assert_bash 120 deny  'hostname'
assert_bash 121 deny  'git status | id'
assert_bash 122 allow 'git status'

echo "== output-redact.sh (tests 40-45, 107) =="
assert_redact 40  block 'AKIAIOSFODNN7EXAMPLE'
assert_redact 41  block 'sk-proj-abcdefghijklmnopqrstuvwxyz012345'
assert_redact 42  block 'ghp_abcdefghijklmnopqrstuvwxyz012345AB'
assert_redact 43  block 'password=supersecretvalue1234'
assert_redact 44  block 'xoxb-12345678901-abcdefghijklmno'
assert_redact 45  block 'sk_live_abcdefghijklmnopqrstuvwx'
assert_redact 107 block '{"auths":{"registry.example.com":{"auth":"dGVzdDp0ZXN0MTIzNDU2Nzg5"}}}'
assert_redact 107b block '{"auths":{"r.example.com":{"identitytoken":"opaque-token-abcdefghij"}}}'
# Negative control: a clean credsStore config must NOT be redacted.
assert_redact CLEAN none '{"credsStore":"osxkeychain","auths":{"registry.example.com":{}}}'

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
if [[ "$fail" -gt 0 ]]; then
  printf '\nFailures:\n'
  for line in "${fail_lines[@]}"; do
    printf '  - %s\n' "$line"
  done
  exit 1
fi
exit 0
