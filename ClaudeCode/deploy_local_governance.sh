#!/usr/bin/env bash
#
# deploy_local_governance.sh - Deploy this checkout's governance policies into the
# live managed locations for local testing.
#
# This is the local-testing counterpart to pull_claude_governance.sh. Where that
# script clones merged `main` from GitHub and deploys it (the production path, run
# by cron and the update_ai_governance setuid wrapper), this one copies the policy
# files straight from the current working tree — including uncommitted edits — so
# an admin can test an un-merged branch against the installed policy before opening
# a PR.
#
# Run it as root (or with sudo) from anywhere; it resolves the repo paths relative
# to its own location, not the caller's working directory:
#
#     sudo ClaudeCode/deploy_local_governance.sh
#
# It overwrites the live policy with this checkout's version. To restore the
# released version afterwards, run `update_ai_governance` (which re-pulls `main`).

set -euo pipefail

claude_config_dir="/Library/Application Support/ClaudeCode/"
claude_hooks_dir="/opt/claude/hooks/"

# Resolve the directory this script lives in, so the source files are found
# regardless of the caller's working directory. This is the ClaudeCode/ dir of the
# checkout being tested.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script writes to $claude_config_dir and $claude_hooks_dir, which require root." >&2
  echo "Re-run it as: sudo $0" >&2
  exit 1
fi

for f in managed-settings.json CLAUDE.md; do
  if [[ ! -f "$script_dir/$f" ]]; then
    echo "Expected $script_dir/$f but it is missing — is this the ClaudeCode/ directory of the repo?" >&2
    exit 1
  fi
done
if [[ ! -d "$script_dir/opt/claude/hooks" ]]; then
  echo "Expected $script_dir/opt/claude/hooks/ but it is missing — is this the ClaudeCode/ directory of the repo?" >&2
  exit 1
fi

echo "Creating directories..."
mkdir -p "$claude_config_dir" "$claude_hooks_dir"

echo "Copying managed-settings.json..."
cp "$script_dir/managed-settings.json" "$claude_config_dir"

echo "Copying CLAUDE.md..."
cp "$script_dir/CLAUDE.md" "$claude_config_dir"

echo "Copying hooks..."
# Mirror pull_claude_governance.sh exactly: recursive copy (hooks ship a lib/
# subdirectory of shared sourced libraries that hook scripts resolve relative to
# their own location), preceded by a stale-file cleanup so an orphaned hook from a
# previous deploy can't keep firing. Hidden files (e.g. .DS_Store) are left alone.
find "$claude_hooks_dir" -mindepth 1 -not -path '*/.*' -delete 2>/dev/null || true
cp -R "$script_dir"/opt/claude/hooks/. "$claude_hooks_dir"

echo "Writing version stamp..."
# Record provenance so an operator can tell this is a local test deploy, not a
# released version. Production pull_claude_governance.sh writes the bare deployed
# SHA; we prefix "local:" and append "-dirty" when the tree has uncommitted edits,
# so a stray test deploy is never mistaken for a clean main checkout.
#
# We run as root (via sudo) but the checkout is typically owned by the admin's
# normal login, not root and not necessarily the sudo-invoking account. Git then
# refuses to operate on the repo ("detected dubious ownership" — verified: it
# flags the repo top-level), which would leave every stamp reading "unknown".
# Trust the checkout for the duration of these two read-only commands only, via a
# per-invocation -c safe.directory=* . The wildcard avoids hard-coding where the
# repo root sits relative to this script; because it is passed with -c (not
# `git config`), it touches no persistent or global config — it applies to this
# process only.
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
