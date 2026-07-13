# Fixtures

These files are **deliberately innocuous**. They exist only so the `/test-guardrails` skill can attempt to Read them and trigger the `pii-path-policy-check.sh` hook based on the path. None of them contain real PII — the hook should deny based on filename/folder, *before* the Read returns any content.

`innocuous.md` is the negative-control fixture: a file with no PII-suggestive name in a non-data folder, used to confirm the hook is not blanket-denying every Read under this tree.
