# Wild-corpus fixtures — false-positive guard

Real-world-shaped files that should **not** trip any PII detector. Used by [run_wild_corpus_cases.sh](../../../tests/run_wild_corpus_cases.sh) to detect threshold drift: every entry must score below the trip thresholds, and the runner prints per-pattern counts so a future PR that tightens a regex shows exactly which fixtures it would start tripping.

Unlike `../pii-content/` (which is excluded from the pre-commit scanner because it contains synthetic PII), this directory is **not** excluded. These files are scanned normally; if any one of them ever needs to be excluded, the regex set has drifted and the fix belongs in [pii-patterns.sh](../../../opt/claude/hooks/pii-patterns.sh), not in an exclude list.

## Files

| File | Source | Cleaned? | Stresses |
|---|---|---|---|
| `terraform.lock.hcl.fragment` | Pasted from local workspace, 2026-05-22 | No PII in source; stored verbatim | Long base64 hashes, 64-char hex sequences (IBAN / card-grouped detector noise floor) |
| `tsconfig.fragment.json` | Pasted from local workspace, 2026-05-22 | No PII in source; stored verbatim | `[A-Z]{2}[0-9]{4}` shapes (`ES2022`) — brushes IBAN prefix without matching length |
| `package.fragment.json` | Pasted from local workspace, 2026-05-22 | Org-internal identifiers replaced with generic placeholders | Maintainer fields, version strings with dotted numerics (DOB detector noise floor) |

## Known sub-threshold scores

The runner records every fixture's per-pattern counts. Entries below are scores worth being aware of — they don't fail the suite, but they consume budget against the thresholds.

_None currently._ The previous `terraform.lock.hcl.fragment` `UK_PHONE` hit was resolved by tightening the regex to require a non-alphanumeric boundary before the prefix and constraining inter-digit whitespace to single space/tab.

## Adding a new fixture

1. Drop the file in this directory with a `.fragment.<ext>` suffix.
2. Add a row to the table above with source, cleaning notes, and which detector(s) it exercises.
3. Run `ClaudeCode/tests/run_all.sh` — the wild-corpus runner picks up new files automatically.
4. If a new fixture trips a detector, that is a signal to either: tune the regex in `pii-patterns.sh`, or pick a different fixture. Do **not** add it to an exclude list.
