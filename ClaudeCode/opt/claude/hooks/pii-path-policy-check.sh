#!/usr/bin/env bash
# PreToolUse hook for Read. Deterministic path/extension denylist for files
# whose names suggest they may contain PII (personally identifiable information).
#
# Layer 1 of the PII-handling controls. Matches the file path the agent is
# about to Read against a fixed list of patterns commonly used for data
# exports, member/user records, referrals, contact lists, and database dumps.
# A match denies the Read outright via hookSpecificOutput.
#
# This layer catches files by name only. Layer 2 (pii-content-sniff.sh) scans
# the file contents to catch misnamed files. The two layers are independent
# and registered separately in managed-settings.json so either can be tuned
# or audited without disturbing the other.
#
# To add a new pattern:
#   Append a glob to the deny_patterns array. The script uses bash glob
#   matching with extglob semantics and case-insensitive comparison, so
#   "users.*" matches "users.csv", "Users.CSV", "users.json", etc.
set -u
shopt -s extglob nocasematch

logtofile() {
  echo "[$(date)] [pii-path-policy] [$(pwd)] $1" >> "$HOME/.claude/debug/pii-path-policy.log"
}

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

# Filename glob patterns. Matched against the lowercased basename only.
# Order does not matter — first match wins for the log message.
deny_basename_patterns=(
  # User / member / contact records
  "users.@(csv|tsv|json|jsonl|ndjson|xlsx|xls|sql|sqlite|db|parquet|avro|xml|yaml|yml)"
  "members.@(csv|tsv|json|jsonl|ndjson|xlsx|xls|sql|sqlite|db|parquet|avro|xml|yaml|yml)"
  "customers.@(csv|tsv|json|jsonl|ndjson|xlsx|xls|sql|sqlite|db|parquet|avro|xml|yaml|yml)"
  "contacts.@(csv|tsv|json|jsonl|ndjson|xlsx|xls|sql|sqlite|db|parquet|avro|xml|yaml|yml)"
  "patients.@(csv|tsv|json|jsonl|ndjson|xlsx|xls|sql|sqlite|db|parquet|avro|xml|yaml|yml)"
  "subjects.@(csv|tsv|json|jsonl|ndjson|xlsx|xls|sql|sqlite|db|parquet|avro|xml|yaml|yml)"
  "service_users.@(csv|tsv|json|jsonl|ndjson|xlsx|xls|sql|sqlite|db|parquet|avro|xml|yaml|yml)"
  "service-users.@(csv|tsv|json|jsonl|ndjson|xlsx|xls|sql|sqlite|db|parquet|avro|xml|yaml|yml)"
  "referrals.@(csv|tsv|json|jsonl|ndjson|xlsx|xls|sql|sqlite|db|parquet|avro|xml|yaml|yml)"
  "applicants.@(csv|tsv|json|jsonl|ndjson|xlsx|xls|sql|sqlite|db|parquet|avro|xml|yaml|yml)"
  "donors.@(csv|tsv|json|jsonl|ndjson|xlsx|xls|sql|sqlite|db|parquet|avro|xml|yaml|yml)"

  # Common export / dump naming. Wildcards both sides of the token so dated
  # filenames like "members-export-2026-01.xlsx" still match.
  "*[-_]export*.@(csv|tsv|json|jsonl|ndjson|xlsx|xls|sql|sqlite|db|parquet|avro|xml|yaml|yml)"
  "*[-_]dump*.@(csv|tsv|json|jsonl|ndjson|xlsx|xls|sql|sqlite|db|parquet|avro)"
  "*[-_]backup*.@(csv|tsv|json|jsonl|ndjson|xlsx|xls|sql|sqlite|db|parquet|avro)"
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
  "exports"
  "dumps"
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
  logtofile "DENY $match: $file_path"
  # Use jq to safely escape the path/match into the reason field. Constructing
  # JSON with printf would mishandle quotes, backslashes, and newlines in paths.
  jq -n \
    --arg reason "$reason ($match). File path matches the PII path/extension denylist (pii-path-policy-check.sh). If this file genuinely does not contain PII, ask the user to rename it or move it out of a data folder; do not bypass." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
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
# Emitting an explicit allow short-circuits later permission checks, which we
# do not want here: this hook only adds denies on top of existing controls.
exit 0
