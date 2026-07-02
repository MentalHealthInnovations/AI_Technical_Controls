#!/usr/bin/env bash
#
# deploy_local_governance.sh: deploy this checkout's governance policies into the
# live managed locations for local testing.
#
# Local-testing counterpart to pull_claude_governance.sh. That script clones
# merged main from GitHub and deploys it (the production path run by cron and the
# update_ai_governance setuid wrapper). This one copies the policy files from the
# current working tree, including uncommitted edits, so an admin can test an
# un-merged branch against the installed policy before opening a PR.
#
# Run as root from any directory. Paths are resolved relative to this script:
#
#     sudo ClaudeCode/deploy_local_governance.sh
#
# Overwrites the live policy with this checkout's version. Restore the released
# version with update_ai_governance, which re-pulls main.

set -euo pipefail

claude_config_dir="/Library/Application Support/ClaudeCode/"
claude_hooks_dir="/opt/claude/hooks/"

# Directory this script lives in. Source files are resolved against it so the
# script works from any working directory. This is the checkout's ClaudeCode/ dir.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script writes to $claude_config_dir and $claude_hooks_dir, which require root." >&2
  echo "Re-run it as: sudo $0" >&2
  exit 1
fi

for f in managed-settings.json CLAUDE.md; do
  if [[ ! -f "$script_dir/$f" ]]; then
    echo "Expected $script_dir/$f but it is missing. Is this the ClaudeCode/ directory of the repo?" >&2
    exit 1
  fi
done
if [[ ! -d "$script_dir/opt/claude/hooks" ]]; then
  echo "Expected $script_dir/opt/claude/hooks/ but it is missing. Is this the ClaudeCode/ directory of the repo?" >&2
  exit 1
fi

echo "Creating directories..."
mkdir -p "$claude_config_dir" "$claude_hooks_dir"

echo "Copying managed-settings.json..."
cp "$script_dir/managed-settings.json" "$claude_config_dir"

echo "Copying CLAUDE.md..."
cp "$script_dir/CLAUDE.md" "$claude_config_dir"

echo "Copying hooks..."
# Mirrors pull_claude_governance.sh. Recursive copy because hooks ship a lib/
# subdirectory of shared libraries that hook scripts source relative to their own
# location. Delete first so an orphaned hook from a previous deploy stops firing.
# Hidden files such as .DS_Store are left alone.
find "$claude_hooks_dir" -mindepth 1 -not -path '*/.*' -delete 2>/dev/null || true
cp -R "$script_dir"/opt/claude/hooks/. "$claude_hooks_dir"

echo "Writing version stamp..."
# Provenance stamp. Production pull_claude_governance.sh writes the bare deployed
# SHA. This script prefixes "local:" and appends "-dirty" for uncommitted edits,
# so a test deploy is distinguishable from a released main checkout.
#
# The script runs as root via sudo, but the checkout is usually owned by the
# admin's normal login, so git refuses with "detected dubious ownership" and the
# stamp falls through to "unknown". safe.directory=* trusts the checkout for these
# read-only commands only. Passed with -c, it changes no persistent or global
# config and applies to this process only. The wildcard avoids hard-coding the
# repo root path relative to this script.
git_repo() {
  git -c "safe.directory=*" -C "$script_dir" "$@"
}
repo_sha="$(git_repo rev-parse HEAD 2>/dev/null || echo unknown)"
if ! git_repo diff --quiet HEAD 2>/dev/null; then
  repo_sha="${repo_sha}-dirty"
fi
echo "local:${repo_sha}" > "$claude_config_dir/VERSION"

deployed_version="$(cat "$claude_config_dir/VERSION")"
echo "Local governance files deployed. Deployed version: $deployed_version"
echo "Restore the released version with: update_ai_governance"
