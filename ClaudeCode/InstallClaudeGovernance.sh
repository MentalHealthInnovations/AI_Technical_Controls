#!/usr/bin/env bash
#
# InstallClaudeGovernance.sh - Install MHI Claude Code governance policies on this machine.
#
# Run this script once as root (or with sudo) to:
#   1. Install /usr/local/bin/pull_claude_governance.sh, which pulls the latest policies
#      from the MentalHealthInnovations/AI_Governance GitHub repo.
#   2. Run that script immediately to apply the current policies.
#   3. Install /usr/local/bin/update_ai_governance, a setuid binary that allows any local
#      user to trigger a policy update without root access by running: update_ai_governance
#   4. Schedule a daily cron job (root crontab, 12:00) to keep policies up to date.
#
# Jamf parameters:
#   $1, $2, $3 — supplied by Jamf (mount point, computer name, console user); unused.
#   $4         — Jamf custom trigger for a policy that installs jq. Required if jq
#                is not already on the machine; this script invokes
#                `jamf policy -event "$4"` to install it from an IT-controlled
#                package. Hooks fail closed without jq, so we refuse to proceed.
#   $5         — Jamf custom trigger for a policy that installs Xcode Command Line
#                Tools. Required if CLT is not already installed; this script
#                invokes `jamf policy -event "$5"` to install it.
#
# Dependencies (both are required at runtime; both are installed via Jamf
# policy triggers passed as $4 and $5 if missing — no Homebrew or softwareupdate
# fallback, so IT keeps full control over what lands on managed machines):
#   - Xcode Command Line Tools (provides git, cc/gcc).
#   - jq (used at runtime by the governance hooks to parse hook payloads and the
#     domain allowlist; missing jq fails closed and blocks every Bash, Read, and
#     WebFetch call).

set -e

JAMF_JQ_TRIGGER="${4:-}"
JAMF_XCODE_CLT_TRIGGER="${5:-}"

# trigger_jamf_install RESOURCE TRIGGER VERIFY_CMD
# Fires a Jamf policy by its custom trigger and verifies that the resource is
# present afterwards. Aborts with a clear error if the trigger is empty, the
# jamf binary is unavailable, or the post-install verify fails. Centralises the
# pattern shared between the jq and CLT install paths.
trigger_jamf_install() {
  local resource="$1" trigger="$2" verify_cmd="$3"
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
  if ! eval "$verify_cmd" &>/dev/null; then
    echo "Jamf trigger '$trigger' ran but $resource is still missing." >&2
    echo "Check the policy is scoped to this machine and that it actually installs $resource." >&2
    return 1
  fi
  echo "$resource installed."
}

if ! xcode-select -p &>/dev/null; then
  trigger_jamf_install "Xcode Command Line Tools" "$JAMF_XCODE_CLT_TRIGGER" "xcode-select -p"
else
  echo "Xcode Command Line Tools are already installed."
fi

if ! command -v jq &>/dev/null; then
  # Jamf-pushed jq typically lands in /usr/local/bin (Intel) or /opt/homebrew/bin
  # (Apple Silicon). Neither is on root's default PATH, so extend PATH before the
  # post-install verify can find a freshly installed jq. The hooks themselves run
  # under Claude Code's PATH, not this one, so no export is needed for them.
  export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
  trigger_jamf_install "jq" "$JAMF_JQ_TRIGGER" "command -v jq"
else
  echo "jq is already installed."
fi

script_dest="/usr/local/bin/pull_claude_governance.sh"
ai_governance_repo_dir="/tmp/AI_Governance"

echo "Starting to pull Claude governance files."

# Bootstrap: clone the repo, copy pull_claude_governance.sh to /usr/local/bin/, then execute it.
# After this first install, pull_claude_governance.sh self-updates on every subsequent run —
# changes to it deploy automatically via the daily cron without requiring this script to be re-run.
echo "Cloning AI_Governance repository..."
rm -rf "$ai_governance_repo_dir"
git clone --quiet --depth 1 https://github.com/MentalHealthInnovations/AI_Governance "$ai_governance_repo_dir"

echo "Installing pull script..."
sudo cp "$ai_governance_repo_dir/ClaudeCode/pull_claude_governance.sh" "$script_dest"
sudo chmod +x "$script_dest"
rm -rf "$ai_governance_repo_dir"

echo "Created script to pull governance files."

# Run the installed script to deploy all policy files
sudo "$script_dest"

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

echo "Script completed successfully."