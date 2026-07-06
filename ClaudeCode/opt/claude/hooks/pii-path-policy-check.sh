#!/usr/bin/env bash
# PreToolUse hook for Read, Edit, Write, and MultiEdit. Deterministic
# path/extension denylist for files whose names suggest they may contain
# PII (personally identifiable information).
#
# Layer 1 of the PII-handling controls. Matches the file path the agent is
# about to access against a fixed list of patterns commonly used for data
# exports, member/user records, referrals, contact lists, and database dumps.
# A match denies the operation outright via hookSpecificOutput.
#
# Registering against Read, Edit, Write, and MultiEdit catches every tool
# whose tool_input carries a `file_path` field — so the hook fires whether
# the agent is trying to ingest the file's content (Read) or create/modify
# it under a PII-suggestive name (Write, Edit, MultiEdit). Tools that use a
# different field (e.g. NotebookEdit's `notebook_path`) are out of scope:
# the hook exits silently when `file_path` is empty.
#
# This layer catches files by name only. Layer 2 (pii-content-sniff.sh) scans
# the file contents to catch misnamed files — on Read it scans the on-disk
# file, and on Write/Edit/MultiEdit it scans the inline content/new_string
# payload being written (there is nothing on disk yet for those tools). The
# two layers are independent and registered separately in managed-settings.json
# so either can be tuned or audited without disturbing the other.
#
# To add a new pattern:
#   Append a glob to the deny_patterns array. The script uses bash glob
#   matching with extglob semantics and case-insensitive comparison, so
#   "users.*" matches "users.csv", "Users.CSV", "users.json", etc.
set -u
shopt -s extglob nocasematch

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=pii-patterns.sh
. "$script_dir/pii-patterns.sh"
# Only pii_deny_json() is used here — the pattern arrays and scan constants
# are Layer 2's concern — but sharing one deny-envelope builder keeps the
# PreToolUse response shape in a single place across both PII hooks.

# shellcheck source=lib/audit-log.sh
source "$script_dir/lib/audit-log.sh"
audit_init "pii-path-policy"
# Every allow/deny below is recorded as one JSON Lines record to
# ~/.claude/debug/pii-path-policy.jsonl via the shared helper — the same
# mechanism every other policy hook uses, including audit_init's mkdir -p for
# a first-run ~/.claude/debug/. This replaced an ad-hoc plain-text log file
# that every other hook's log/rotation/S3-upload tooling didn't know about.

payload="$(cat)"
file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"

if [[ -z "$file_path" ]]; then
  exit 0
fi

# Normalise: lowercase the basename for matching and keep the full path for
# directory-segment checks. The directory check catches data folders even if
# the file inside has an innocuous name (e.g. referrals/2026-01.txt).
basename_lc="$(printf '%s' "${file_path##*/}" | tr '[:upper:]' '[:lower:]')"
dir_lc="$(printf '%s' "${file_path%/*}" | tr '[:upper:]' '[:lower:]')"

# Extension alternations, factored out so adding/removing a data-file format
# is one edit instead of eleven+. A previous version repeated the same
# @(...) alternation inline on every stem pattern below — a missed line on
# a future edit would silently leave e.g. "patients.ods" denied while
# "donors.ods" was allowed, with nothing to catch the asymmetry.
data_exts="@(csv|tsv|json|jsonl|ndjson|xlsx|xls|sql|sqlite|db|parquet|avro|xml|yaml|yml)"
dump_backup_exts="@(csv|tsv|json|jsonl|ndjson|xlsx|xls|sql|sqlite|db|parquet|avro)"

# Filename glob patterns. Matched against the lowercased basename only.
# Order does not matter — first match wins for the log message.
deny_basename_patterns=(
  # User / member / contact records
  "users.$data_exts"
  "members.$data_exts"
  "customers.$data_exts"
  "contacts.$data_exts"
  "patients.$data_exts"
  "subjects.$data_exts"
  "service_users.$data_exts"
  "service-users.$data_exts"
  "referrals.$data_exts"
  "applicants.$data_exts"
  "donors.$data_exts"

  # Common export / dump naming. Wildcards both sides of the token so dated
  # filenames like "members-export-2026-01.xlsx" still match. Bare
  # "export.<ext>"/"dump.<ext>"/"backup.<ext>" (no separator before the
  # token) get their own entries below — the "*[-_]token*" globs above
  # require a leading "-" or "_" and so miss a plain "export.csv".
  "*[-_]export*.$data_exts"
  "*[-_]dump*.$dump_backup_exts"
  "*[-_]backup*.$dump_backup_exts"
  "export.$data_exts"
  "dump.@(sql|sqlite|db)"
  "backup.@(sql|sqlite|db)"

  # PII-suggestive filename tokens
  "*pii*"
  "*personal-data*"
  "*personal_data*"
  "*gdpr*"
  "*subject-access*"
  "*subject_access*"
  "*dsar*"        # Data Subject Access Request
)

# Directory segment patterns. Matched against any segment of the parent dir.
# A file inside any of these folders is denied regardless of its own name.
deny_dir_segments=(
  "referrals"
  "service-users"
  "service_users"
  "patients"
  "customers-export"
  "members-export"
  "export"
  "exports"
  "dump"
  "dumps"
  "backup"
  "backups"
  "pii"
  "personal-data"
  "personal_data"
  "dsar"
  "subject-access-requests"
  "subject_access_requests"
)

deny() {
  local reason="$1" match="$2"
  audit_emit "$payload" deny file_path "$file_path" match "$match" reason "$reason"
  pii_deny_json "$reason ($match). File path matches the PII path/extension denylist (pii-path-policy-check.sh). If this file genuinely does not contain PII, ask the user to rename it or move it out of a data folder; do not bypass."
  exit 0
}

# Filename match
for pattern in "${deny_basename_patterns[@]}"; do
  # shellcheck disable=SC2053  # intentional glob match, not string compare
  if [[ "$basename_lc" == $pattern ]]; then
    deny "Path matches PII filename pattern" "$pattern"
  fi
done

# Directory-segment match. Split dir on '/' and check each segment.
IFS='/' read -ra segments <<< "$dir_lc"
for seg in "${segments[@]}"; do
  for bad in "${deny_dir_segments[@]}"; do
    if [[ "$seg" == "$bad" ]]; then
      deny "Path is inside a PII data folder" "$bad"
    fi
  done
done

# No match — allow Claude Code's default permission handling to take over.
# Emitting an explicit allow in hookSpecificOutput would short-circuit later
# permission checks, which we do not want here: this hook only adds denies on
# top of existing controls. audit_emit only appends a log record; it does not
# touch the hook's stdout/exit behaviour.
audit_emit "$payload" allow file_path "$file_path"
exit 0
