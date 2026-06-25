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
#
# Argument:
#   $1 (optional): git branch or tag to clone instead of the default branch. Used only for
#       testing unreleased policy changes on a single machine. The daily cron and the
#       update_ai_governance setuid wrapper both invoke this script with no argument, so
#       production machines always track the default branch.

set -e

# Optional git ref (branch or tag) to test. Empty => clone the repository default branch.
git_ref="${1:-}"

claude_config_dir="/Library/Application Support/ClaudeCode/"
claude_hooks_dir="/opt/claude/hooks/"
claude_bin_dir="/opt/claude/bin/"
ai_governance_repo_dir="/tmp/AI_Technical_Controls"
script_dest="/usr/local/bin/pull_claude_governance.sh"

echo "Creating directories..."
mkdir -p "$claude_config_dir" "$claude_hooks_dir" "$claude_bin_dir"

rm -rf "$ai_governance_repo_dir"
# Clone main by default. Integrity is enforced at the source: CODEOWNERS and branch
# protection require two-person approval for every merge, so a tampered main implies the
# security team itself was compromised, and client-side tag pinning would not add
# meaningful protection against that threat.
#
# When a ref is supplied (testing only, never by the cron or the setuid wrapper), clone
# that branch/tag instead so unreleased policy changes can be validated on one machine.
if [[ -n "$git_ref" ]]; then
  echo "Cloning AI_Technical_Controls repository (ref: $git_ref)..."
  git clone --quiet --depth 1 --branch "$git_ref" \
    https://github.com/MentalHealthInnovations/AI_Technical_Controls "$ai_governance_repo_dir"
else
  echo "Cloning AI_Technical_Controls repository..."
  git clone --quiet --depth 1 \
    https://github.com/MentalHealthInnovations/AI_Technical_Controls "$ai_governance_repo_dir"
fi

# Self-update: replace this script with the latest version from the repo before copying
# policy files. Uses cp (atomic inode replacement) so the running process is unaffected;
# the new version takes effect on the next invocation.
echo "Updating pull script..."
cp "$ai_governance_repo_dir/ClaudeCode/pull_claude_governance.sh" "$script_dest"
chmod +x "$script_dest"

echo "Copying managed-settings.json..."
cp "$ai_governance_repo_dir/ClaudeCode/managed-settings.json" "$claude_config_dir"

echo "Copying managed-mcp.json..."
# managed-mcp.json is read by Claude Code as the exclusive list of MCP servers
# when present at this path. managed-settings.json governs only the *policy*
# layer (allowlist + allowManagedMcpServersOnly). The server definitions live
# here. See https://code.claude.com/docs/en/mcp#managed-mcp-configuration.
cp "$ai_governance_repo_dir/ClaudeCode/managed-mcp.json" "$claude_config_dir"

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

echo "Copying audit-log uploader..."
# Same stale-file cleanup + recursive copy pattern as the hooks above. The uploader
# (upload-audit-logs.sh) is run by its own daily root cron; the AWS credentials it uses
# are written once by InstallClaudeGovernance.sh, not here.
find "$claude_bin_dir" -mindepth 1 -not -path '*/.*' -delete 2>/dev/null || true
cp -R "$ai_governance_repo_dir"/ClaudeCode/opt/claude/bin/. "$claude_bin_dir"
chmod +x "$claude_bin_dir"/*.sh 2>/dev/null || true

echo "Writing version stamp..."
# Record the deployed SHA so fleet operators can verify which policy version is
# active on a given machine without diffing files manually.
git -C "$ai_governance_repo_dir" rev-parse HEAD > "$claude_config_dir/VERSION"

echo "Cleaning up..."
rm -rf "$ai_governance_repo_dir"

deployed_sha="$(cat "$claude_config_dir/VERSION")"
echo "Governance files updated successfully. Deployed version: $deployed_sha"
