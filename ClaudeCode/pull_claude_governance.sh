#!/usr/bin/env bash
#
# pull_claude_governance.sh - Pull the latest MHI Claude Code governance policies from GitHub.
#
# Installed to /usr/local/bin/ by InstallClaudeGovernance.sh. Run by the daily root cron job
# and by the update_ai_governance setuid binary (which allows non-root users to trigger a pull).
#
# This script self-updates on each run: it copies itself out of the cloned repo before copying
# the policy files, so changes to this script deploy automatically without requiring
# InstallClaudeGovernance.sh to be re-run on each managed machine.

set -e

claude_config_dir="/Library/Application Support/ClaudeCode/"
claude_hooks_dir="/opt/claude/hooks/"
ai_governance_repo_dir="/tmp/AI_Governance"
script_dest="/usr/local/bin/pull_claude_governance.sh"

echo "Creating directories..."
mkdir -p "$claude_config_dir" "$claude_hooks_dir"

echo "Cloning AI_Governance repository..."
rm -rf "$ai_governance_repo_dir"
# Clone main. Integrity is enforced at the source: CODEOWNERS and branch protection
# require two-person approval for every merge, so a tampered main implies the
# security team itself was compromised — client-side tag pinning would not add
# meaningful protection against that threat.
git clone --quiet --depth 1 https://github.com/MentalHealthInnovations/AI_Governance "$ai_governance_repo_dir"

# Self-update: replace this script with the latest version from the repo before copying
# policy files. Uses cp (atomic inode replacement) so the running process is unaffected;
# the new version takes effect on the next invocation.
echo "Updating pull script..."
cp "$ai_governance_repo_dir/ClaudeCode/pull_claude_governance.sh" "$script_dest"
chmod +x "$script_dest"

echo "Copying managed-settings.json..."
cp "$ai_governance_repo_dir/ClaudeCode/managed-settings.json" "$claude_config_dir"

echo "Copying CLAUDE.md..."
cp "$ai_governance_repo_dir/ClaudeCode/CLAUDE.md" "$claude_config_dir"

echo "Copying hooks..."
# Recursive (-R) because hooks now ship with a lib/ subdirectory containing
# shared sourced libraries (audit-log.sh, redact.sh). Hook scripts resolve
# lib/ relative to their own location, so the directory layout under
# /opt/claude/hooks/ must mirror the repo layout.
#
# Stale-file cleanup: rm any non-hidden file/dir under the hooks directory
# before copying. Prevents an orphaned hook script from a previous version
# remaining executable on disk and continuing to fire after we've removed it
# from the repo. Hidden files (e.g. .DS_Store) are left alone.
find "$claude_hooks_dir" -mindepth 1 -not -path '*/.*' -delete 2>/dev/null || true
cp -R "$ai_governance_repo_dir"/ClaudeCode/opt/claude/hooks/. "$claude_hooks_dir"

echo "Writing version stamp..."
# Record the deployed SHA so fleet operators can verify which policy version is
# active on a given machine without diffing files manually.
git -C "$ai_governance_repo_dir" rev-parse HEAD > "$claude_config_dir/VERSION"

echo "Cleaning up..."
rm -rf "$ai_governance_repo_dir"

deployed_sha="$(cat "$claude_config_dir/VERSION")"
echo "Governance files updated successfully. Deployed version: $deployed_sha"
