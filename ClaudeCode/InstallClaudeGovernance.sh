#!/usr/bin/env bash
#
# InstallClaudeGovernance.sh - Install MHI Claude Code governance policies on this machine.
#
# Run this script once as root (or with sudo) to:
#   1. Install /usr/local/bin/pull_claude_governance.sh, which pulls the latest policies
#      from the MentalHealthInnovations/AI_Technical_Controls GitHub repo.
#   2. Run that script immediately to apply the current policies.
#   3. Install /usr/local/bin/update_ai_governance, a setuid binary that allows any local
#      user to trigger a policy update without root access by running: update_ai_governance
#   4. Schedule a daily cron job (root crontab, 12:00) to keep policies up to date.
#
# Jamf parameters:
#   $1, $2, $3: supplied by Jamf (mount point, computer name, console user); unused.
#   $4: Jamf custom trigger for a policy that installs jq.
#   $5: Jamf custom trigger for a policy that installs Xcode Command Line Tools.
#   $6: Jamf custom trigger for a policy that installs the AWS CLI (trigger name
#       installAwsCli). Only used when audit-log S3 upload is being configured
#       (see $7/$8); this script invokes `jamf policy -event "$6"` if the `aws`
#       binary is missing.
#   $7, $8: access key id and secret access key for the write-only S3
#       audit-log writer (IAM user `claude-audit-writer`). When both are supplied,
#       this script installs the AWS CLI (via $6 if needed), writes the credentials
#       to /var/root/.aws/ (0600), and schedules a daily upload cron. When either is
#       empty, audit-log upload is skipped.
#   $9: git branch or tag to install instead of the default branch. Testing only:
#       use it to validate unreleased policy changes on a single machine. The ref
#       applies to the bootstrap clone here and is passed through to the installed
#       pull script for this install run. The daily cron and the update_ai_governance
#       setuid wrapper invoke the pull script with no argument, so subsequent updates
#       revert the machine to the default branch. When empty, the default branch is
#       installed. Run by hand with placeholders for the unused slots, e.g.:
#         sudo ./InstallClaudeGovernance.sh "" "" "" "" "" "" "" "" feat/my-change
#
# Dependencies are required and installed via Jamf policy triggers:
#   - Xcode Command Line Tools (provides git, cc/gcc).
#   - jq (used to parse hook payloads and domain allowlist).
#
# Optional add-on (configured only when $7/$8 are supplied):
#   - AWS CLI (used to upload hook audit logs to S3).

set -e

JAMF_JQ_TRIGGER="${4:-}"
JAMF_XCODE_CLT_TRIGGER="${5:-}"
JAMF_AWS_CLI_TRIGGER="${6:-}"
AWS_AUDIT_ACCESS_KEY_ID="${7:-}"
AWS_AUDIT_SECRET_ACCESS_KEY="${8:-}"
GOVERNANCE_GIT_REF="${9:-}"

# trigger_jamf_install RESOURCE TRIGGER VERIFY_CMD [VERIFY_ARGS...]
# Fires a Jamf policy by its custom trigger and verifies that the resource is
# present afterwards. The verify command is passed as separate arguments and run
# directly (no eval/shell parsing), so there is no string-interpolation surface.
# Aborts with a clear error if the trigger is empty, the jamf binary is
# unavailable, or the post-install verify fails. Centralises the pattern shared
# between the jq and CLT install paths.
trigger_jamf_install() {
  local resource="$1" trigger="$2"
  shift 2
  if [[ -z "$trigger" ]]; then
    echo "$resource not found and no Jamf trigger supplied." >&2
    echo "Pass the Jamf custom trigger for the $resource install policy as the script parameter described in the header." >&2
    return 1
  fi
  if ! command -v jamf &>/dev/null; then
    echo "$resource not found and the 'jamf' binary is unavailable on this machine." >&2
    echo "Either install $resource manually before running this script, or run this on a Jamf-managed machine." >&2
    return 1
  fi
  echo "Installing $resource via Jamf policy trigger '$trigger'…"
  jamf policy -event "$trigger"
  if ! "$@" &>/dev/null; then
    echo "Jamf trigger '$trigger' ran but $resource is still missing." >&2
    echo "Check the policy is scoped to this machine and that it actually installs $resource." >&2
    return 1
  fi
  echo "$resource installed."
}

# aws_present: true if the AWS CLI is on PATH or at a Homebrew prefix. installAwsCli
# installs it via Homebrew, whose prefix isn't on root's PATH.
aws_present() {
  command -v aws &>/dev/null && return 0
  [[ -x /opt/homebrew/bin/aws || -x /usr/local/bin/aws ]]
}

# setup_audit_log_upload: optional add-on, run only when writer credentials are supplied
# as Jamf params $7/$8. Installs the AWS CLI (via $6 if missing), writes the write-only
# credential to /var/root/.aws/ (0600), and schedules a daily upload cron.
# Failures return non-zero and the caller warns and continues, without blocking the install.
setup_audit_log_upload() {
  if [[ -z "$AWS_AUDIT_ACCESS_KEY_ID" || -z "$AWS_AUDIT_SECRET_ACCESS_KEY" ]]; then
    echo "Audit-log S3 upload: no writer credentials supplied (params \$7/\$8); skipping."
    return 0
  fi

  if ! aws_present; then
    trigger_jamf_install "AWS CLI" "$JAMF_AWS_CLI_TRIGGER" aws_present || {
      echo "Audit-log S3 upload: AWS CLI install failed; upload not configured." >&2
      return 1
    }
  else
    echo "AWS CLI is already installed."
  fi

  # Write the write-only credential to root's AWS config with restrictive perms.
  # printf is a shell builtin, so the secret is not exposed as a process argument.
  local aws_dir="/var/root/.aws"
  local old_umask; old_umask="$(umask)"
  umask 177
  if ! install -d -m 700 "$aws_dir"; then
    umask "$old_umask"
    echo "Audit-log S3 upload: could not create $aws_dir; upload not configured." >&2
    return 1
  fi
  # A partial write here would leave a malformed or truncated credential the uploader
  # would then try to use, so treat any write failure as fatal: remove the half-written
  # file, restore umask, and bail.
  if ! printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
       "$AWS_AUDIT_ACCESS_KEY_ID" "$AWS_AUDIT_SECRET_ACCESS_KEY" > "$aws_dir/credentials" \
     || ! printf '[default]\nregion = eu-west-2\noutput = json\n' > "$aws_dir/config"; then
    rm -f "$aws_dir/credentials" "$aws_dir/config"
    umask "$old_umask"
    echo "Audit-log S3 upload: failed to write credentials to $aws_dir; upload not configured." >&2
    return 1
  fi
  chmod 600 "$aws_dir/credentials" "$aws_dir/config"
  umask "$old_umask"
  echo "Wrote write-only audit-log uploader credentials to $aws_dir/credentials."

  # Daily upload cron, separate from the governance-pull cron. The uploader itself is
  # deployed to /opt/claude/bin/ by pull_claude_governance.sh and self-updates.
  local uploader="/opt/claude/bin/upload-audit-logs.sh"
  local upload_marker="# Added by MHI Claude governance script - audit log S3 upload."
  local upload_cron="30 12 * * * $uploader $upload_marker"
  local current; current="$(sudo crontab -l 2>/dev/null || true)"
  current="$(echo "$current" | grep -vF "$upload_marker")"
  (echo "$current" ; echo "$upload_cron") | sudo crontab -
  echo "Scheduled daily audit-log upload cron."
}

if ! xcode-select -p &>/dev/null; then
  trigger_jamf_install "Xcode Command Line Tools" "$JAMF_XCODE_CLT_TRIGGER" xcode-select -p
else
  echo "Xcode Command Line Tools are already installed."
fi

if ! command -v jq &>/dev/null; then
  trigger_jamf_install "jq" "$JAMF_JQ_TRIGGER" command -v jq
else
  echo "jq is already installed."
fi

script_dest="/usr/local/bin/pull_claude_governance.sh"
ai_governance_repo_dir="/tmp/AI_Technical_Controls"

echo "Starting to pull Claude governance files."

# Bootstrap: clone the repo, copy pull_claude_governance.sh to /usr/local/bin/, then execute it.
# After this first install, pull_claude_governance.sh self-updates on every subsequent run.
# Changes to it deploy automatically via the daily cron without requiring this script to be re-run.
rm -rf "$ai_governance_repo_dir"
if [[ -n "$GOVERNANCE_GIT_REF" ]]; then
  echo "Cloning AI_Technical_Controls repository (ref: $GOVERNANCE_GIT_REF)..."
  git clone --quiet --depth 1 --branch "$GOVERNANCE_GIT_REF" \
    https://github.com/MentalHealthInnovations/AI_Technical_Controls "$ai_governance_repo_dir"
else
  echo "Cloning AI_Technical_Controls repository..."
  git clone --quiet --depth 1 \
    https://github.com/MentalHealthInnovations/AI_Technical_Controls "$ai_governance_repo_dir"
fi

echo "Installing pull script..."
sudo cp "$ai_governance_repo_dir/ClaudeCode/pull_claude_governance.sh" "$script_dest"
sudo chmod +x "$script_dest"

# Deploy policy files directly from the cloned ref. We do NOT invoke
# pull_claude_governance.sh here because that script unconditionally clones main,
# which would overwrite the just-deployed ref. The pull script is still installed
# above so the daily cron and update_ai_governance wrapper work as designed —
# both will pull main on their next run, which is the intended kill-switch when
# a test branch is bad.
claude_config_dir="/Library/Application Support/ClaudeCode/"
claude_hooks_dir="/opt/claude/hooks/"
echo "Deploying policy files from ref '$GOVERNANCE_GIT_REF'..."
sudo mkdir -p "$claude_config_dir" "$claude_hooks_dir"
sudo cp "$ai_governance_repo_dir/ClaudeCode/managed-settings.json" "$claude_config_dir"
sudo cp "$ai_governance_repo_dir/ClaudeCode/managed-mcp.json" "$claude_config_dir"
sudo cp "$ai_governance_repo_dir/ClaudeCode/CLAUDE.md" "$claude_config_dir"
sudo cp "$ai_governance_repo_dir"/ClaudeCode/opt/claude/hooks/* "$claude_hooks_dir"
deployed_sha="$(git -C "$ai_governance_repo_dir" rev-parse HEAD)"
echo "$deployed_sha" | sudo tee "$claude_config_dir/VERSION" >/dev/null
rm -rf "$ai_governance_repo_dir"

echo "Created script to pull governance files."

# Run the installed script to deploy all policy files. Pass the test ref through as the
# pull script's first argument so this install run deploys the same branch/tag the
# bootstrap cloned. With no ref, the pull script clones the default branch as usual.
if [[ -n "$GOVERNANCE_GIT_REF" ]]; then
  sudo "$script_dest" "$GOVERNANCE_GIT_REF"
else
  sudo "$script_dest"
fi

echo "Installed governance files."

# Install a setuid wrapper binary so local users can trigger a governance update without root access.
# The wrapper executes pull_claude_governance.sh as root via the setuid bit, without granting users
# any ability to edit the script or the policy files it manages.
wrapper_dest="/usr/local/bin/update_ai_governance"
if command -v gcc &>/dev/null; then
    compiler="gcc"
else
    compiler="cc"
fi
sudo "$compiler" -x c -o "$wrapper_dest" - << 'EOF'
#include <unistd.h>
int main() {
    // Set real UID/GID to root so bash doesn't drop setuid privileges on exec
    if (setuid(0) != 0 || setgid(0) != 0) return 1;
    return execl("/usr/local/bin/pull_claude_governance.sh", "pull_claude_governance.sh", NULL);
}
EOF
sudo chown root:staff "$wrapper_dest"
# 4750 (setuid, rwx for owner, rx for group, none for others) restricts execution
# to members of the "staff" group rather than every local user (4755 = world-executable).
# This reduces the privilege-escalation surface: only users already in the group
# can trigger a root-level policy update on demand.
sudo chmod 4750 "$wrapper_dest"
echo "Installed update_ai_governance wrapper."

# cron_marker used to detect if the crontab already exists, and only add it if it doesn't
cron_marker="# Added by MHI Claude governance script - see MHI_Device_Builds repository."
new_crontab="0 12 * * * $script_dest $cron_marker"
# don't raise an error if the crontab is empty, which is the case if the user has no crontab yet
existing_crontab=$(sudo crontab -l 2>/dev/null || true)

updated_crontab=$(echo "$existing_crontab" | grep -vF "$cron_marker")
echo "Adding crontab to update governance files daily."
(echo "$updated_crontab" ; echo "$new_crontab") | sudo crontab -

# Optional: configure audit-log S3 upload when writer credentials were supplied.
# Best-effort: a failure here must not fail the governance install.
setup_audit_log_upload || echo "Audit-log S3 upload setup did not complete; governance install is unaffected." >&2

echo "Script completed successfully."
