#!/usr/bin/env bash
#
# Upload MHI Claude Code governance audit logs to S3.
#
# Deployed to /opt/claude/bin/ by pull_claude_governance.sh.
# Run by a daily root cron added by InstallClaudeGovernance.sh.
#
# Reads hook logs from ~/.claude/debug/ and uploads log lines since last upload.
# Uses gzip to compress logs and compute changes.
#
# Single write only IAM key used for all devices. See the README "Appendix: AWS audit-log pipeline".

set -uo pipefail

BUCKET="mhi-claude-audit"
PREFIX="claude-audit"
REGION="eu-west-2"
STATE_DIR="/var/root/.claude-audit-state"

# Credentials live in root's AWS config, written once by InstallClaudeGovernance.sh.
export AWS_SHARED_CREDENTIALS_FILE="/var/root/.aws/credentials"
export AWS_CONFIG_FILE="/var/root/.aws/config"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# Included hook logs
HOOK_LOGS=(bash-policy webfetch-policy pii-path-policy pii-content-sniff output-redact prompt-submit session-audit tool-audit)

# Find the aws cli
if ! AWS_BIN="$(command -v aws 2>/dev/null)"; then
  echo "upload-audit-logs: aws CLI not found on PATH ($PATH); nothing uploaded." >&2
  exit 0
fi

# Quit if no credentials found
if [[ ! -r "$AWS_SHARED_CREDENTIALS_FILE" ]]; then
  echo "upload-audit-logs: no writer credentials at $AWS_SHARED_CREDENTIALS_FILE; nothing uploaded." >&2
  exit 0
fi

# State dir holds the current file offsets.
# These are not secret but don't need to be user visible
if ! mkdir -p "$STATE_DIR"; then
  echo "upload-audit-logs: could not create state dir $STATE_DIR; nothing uploaded." >&2
  exit 1
fi
if ! chmod 700 "$STATE_DIR"; then
  echo "upload-audit-logs: could not secure state dir $STATE_DIR (mode 700); nothing uploaded." >&2
  exit 1
fi

host="$(hostname -s 2>/dev/null || echo unknown)"

# Find every user's debug dir
shopt -s nullglob # Assume no users if * below matches nothing
for debug_dir in /Users/*/.claude/debug; do
  # Get username from the path: /Users/<user>/.claude/debug
  user="${debug_dir#/Users/}"   # strip the leading "/Users/"
  user="${user%%/*}"            # strip from the first "/" to the end
  for hook in "${HOOK_LOGS[@]}"; do
    log_file="$debug_dir/$hook.jsonl"
    [[ -f "$log_file" ]] || continue # Skip if file doesn't exist

    size="$(wc -c < "$log_file" | tr -d '[:space:]')"
    [[ "$size" =~ ^[0-9]+$ ]] || continue

    offset_file="$STATE_DIR/${user}__${hook}.offset"
    offset="$(cat "$offset_file" 2>/dev/null || echo 0)"
    [[ "$offset" =~ ^[0-9]+$ ]] || offset=0

    # Reset offset if log file is rotated (e.g. newsyslog)
    (( size < offset )) && offset=0
    # Nothing new since the last successful upload.
    (( size <= offset )) && continue

    epoch="$(date -u +%s)"
    day="$(date -u +'year=%Y/month=%m/day=%d')"

    # $RANDOM used to ensure files don't conflict on upload
    s3_key="$PREFIX/$day/host=$host/user=$user/$hook/${epoch}-${offset}-${RANDOM}.log.gz"

    # Upload from offset to size-1
    start=$(( offset + 1 ))
    count=$(( size - offset ))

    # Read that slice, compress it, and stream it to S3. Suppress the upload's
    # stdout but capture stderr so a failure can be reported with its cause
    # (AccessDenied, missing credentials, network/region errors), not silently.
    if err="$( { tail -c "+$start" "$log_file" \
                 | head -c "$count" \
                 | gzip -c \
                 | "$AWS_BIN" s3 cp - "s3://$BUCKET/$s3_key" --region "$REGION" --content-encoding gzip \
                   >/dev/null; } 2>&1 )"; then
      # Advance the offset on successful upload. If failed, retry next time.
      echo "$size" > "$offset_file"
      echo "upload-audit-logs: uploaded ${user}/${hook} bytes ${offset}-${size} -> s3://${BUCKET}/${s3_key}"
    else
      echo "upload-audit-logs: upload FAILED for ${user}/${hook} (offset unchanged, will retry next run): ${err:-no error output}" >&2
    fi
  done
done
