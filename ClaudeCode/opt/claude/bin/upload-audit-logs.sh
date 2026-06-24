#!/usr/bin/env bash
#
# upload-audit-logs.sh - Ship MHI Claude Code governance audit logs to S3.
#
# Deployed to /opt/claude/bin/ by pull_claude_governance.sh (self-updating, like the
# hooks) and run by a daily root cron added by InstallClaudeGovernance.sh.
#
# For every managed user's ~/.claude/debug/ directory it reads the six governance hook
# logs, uploads only the bytes written since the last successful run (immutable gzipped
# deltas), and advances a per-(user,hook) byte offset. Growing append-only files are
# therefore never re-uploaded and nothing is ever overwritten.
#
# Scope is deliberately limited to the six governance hook logs by name. Claude Code's
# own debug output and session transcripts can carry unredacted content and are never
# shipped.
#
# Identity: a single fleet-wide write-only IAM key, written to
# /var/root/.aws/credentials by InstallClaudeGovernance.sh. The upload source is NOT
# cryptographically attributed; the user/host fields stamped into every record provide
# attribution. See the README "Appendix: AWS audit-log pipeline".

set -u

BUCKET="mhi-claude-audit"
PREFIX="claude-audit"
REGION="eu-west-2"
STATE_DIR="/var/root/.claude-audit-state"

# Credentials live in root's AWS config, written once by InstallClaudeGovernance.sh.
# Set the paths explicitly so the uploader never depends on the cron environment's $HOME.
export AWS_SHARED_CREDENTIALS_FILE="/var/root/.aws/credentials"
export AWS_CONFIG_FILE="/var/root/.aws/config"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# The six governance hook logs we ship. Anything else under ~/.claude/debug/ is excluded.
HOOK_LOGS=(bash-policy webfetch-policy output-redact prompt-submit session-audit tool-audit)

# Resolve the aws binary. PATH is set above to include the Homebrew prefixes where
# installAwsCli puts the CLI, since root's cron PATH omits them; command -v then finds it.
if ! AWS_BIN="$(command -v aws 2>/dev/null)"; then
  echo "upload-audit-logs: aws CLI not found on PATH ($PATH); nothing uploaded." >&2
  exit 0
fi
if [[ ! -r "$AWS_SHARED_CREDENTIALS_FILE" ]]; then
  echo "upload-audit-logs: no writer credentials at $AWS_SHARED_CREDENTIALS_FILE; nothing uploaded." >&2
  exit 0
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

host="$(hostname -s 2>/dev/null || echo unknown)"

# Iterate every local user's debug dir. Globbing /Users/* avoids resolving the console
# user's home from a root cron and captures multi-user machines.
shopt -s nullglob
for debug_dir in /Users/*/.claude/debug; do
  # Owning username from the path: /Users/<user>/.claude/debug
  user="${debug_dir#/Users/}"
  user="${user%%/*}"
  for hook in "${HOOK_LOGS[@]}"; do
    f="$debug_dir/$hook.jsonl"
    [[ -f "$f" ]] || continue

    size="$(wc -c < "$f" | tr -d '[:space:]')"
    [[ "$size" =~ ^[0-9]+$ ]] || continue

    off_file="$STATE_DIR/${user}__${hook}.offset"
    offset="$(cat "$off_file" 2>/dev/null || echo 0)"
    [[ "$offset" =~ ^[0-9]+$ ]] || offset=0

    # newsyslog truncates in place (': > file'); a shrunk file resets the offset.
    (( size < offset )) && offset=0
    # Nothing new since the last successful upload.
    (( size <= offset )) && continue

    epoch="$(date -u +%s)"
    day="$(date -u +'year=%Y/month=%m/day=%d')"
    # epoch-offset-RANDOM keeps the key unique even if two users' deltas for the same
    # hook land in the same second at the same offset (host-only partition keeps the
    # local username out of the key path; it stays inside each record instead).
    key="$PREFIX/$day/host=$host/$hook/${epoch}-${offset}-${RANDOM}.log.gz"

    # Cap the read at the measured size: the offset only advances to `size`, so a
    # concurrent append past it would otherwise be re-shipped next run. -> [offset, size)
    if tail -c "+$((offset + 1))" "$f" | head -c "$((size - offset))" | gzip -c \
         | "$AWS_BIN" s3 cp - "s3://$BUCKET/$key" --region "$REGION" --content-encoding gzip >/dev/null 2>&1; then
      # Advance the offset only on a confirmed upload; a failure retries next run.
      echo "$size" > "$off_file"
      echo "upload-audit-logs: uploaded ${user}/${hook} bytes ${offset}-${size} -> s3://${BUCKET}/${key}"
    else
      echo "upload-audit-logs: upload FAILED for ${user}/${hook} (offset unchanged, will retry next run)" >&2
    fi
  done
done
