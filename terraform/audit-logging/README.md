# terraform/audit-logging

AWS infrastructure for the Claude Code audit log pipeline. Provisions the S3 bucket Vector ships logs to, plus the per-host writer IAM users and read-only investigation users.

This module is Phase 0 of the audit logging rollout. See the top-level `README.md` for the wider context.

## What it creates

| Resource | Purpose |
|---|---|
| `aws_s3_bucket.audit` | The log bucket. UK region. SSE-S3. Lifecycle policy. TLS-only. |
| `aws_s3_bucket_lifecycle_configuration.audit` | 30d hot → 120d IA → archive → 395d delete |
| `aws_iam_user.writer["<host>"]` | One IAM user per managed Mac, named `vector-<host>` |
| `aws_iam_user_policy.writer["<host>"]` | Scoped to write under `host=<host>/` only — leaked creds can't write elsewhere |
| `aws_iam_user.reader["<label>"]` | Read-only users for ad-hoc DuckDB investigation |

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars to add hostnames and reader principals
terraform init
terraform plan
terraform apply
```

Pull credentials out for distribution:

```bash
# Writer creds for one machine (used by Jamf to inject into the launchd plist)
terraform output -json writer_credentials | jq '."alice-mbp"'

# All reader creds (drop into your 1Password)
terraform output -json reader_credentials
```

## State and secrets

**Access keys live in Terraform state.** That's an unavoidable consequence of having Terraform manage them — the AWS API returns the secret exactly once, and Terraform stores it so it can show it via outputs. Implications:

- The remote state backend **must** be encrypted at rest (S3 with SSE, GCS with default encryption, Terraform Cloud's encrypted state — all fine).
- Access to state must be limited to operators who already have IAM admin in the same account. State access = credential access.
- `terraform output -raw` writes secrets to stdout; **never** redirect to a file in the repo. Use `jq` to pull a single value into your clipboard or 1Password CLI.

If you'd rather not have access keys in state, two alternatives:

1. **Generate keys outside Terraform** with `aws iam create-access-key`, store directly in a secrets manager, and remove the `aws_iam_access_key` resources from this module. More moving parts but state contains no secrets.
2. **Use AWS IAM Identity Center (SSO) for the reader role** and SSO-vended temporary credentials for writers via the AWS CLI. Doesn't work for Vector (it's a long-running daemon without an interactive session) — so writers still need static keys.

For Phase A, accepting keys in state is the pragmatic choice. Revisit if MHI gets serious about ISO 27001 KMS-of-keys controls.

## Adding a new managed Mac

1. Append the hostname (matching `hostname -s` on the machine) to `writer_hostnames` in `terraform.tfvars`.
2. `terraform apply`.
3. Pull the new credentials: `terraform output -json writer_credentials | jq '."<new-host>"'`.
4. Store in 1Password under that machine's entry.
5. Trigger the Jamf install policy on that machine.

## Removing / revoking a machine

1. Delete the hostname from `writer_hostnames`.
2. `terraform apply`. The IAM user and access keys are destroyed — Vector on that machine will start 403'ing within minutes.
3. (Optional) Remove the now-orphaned log data: `aws s3 rm s3://mhi-claude-audit/claude-audit/year=*/month=*/day=*/host=<host>/ --recursive`. Only do this if the machine genuinely shouldn't have data retained.

## Rotating credentials

Annual rotation, manual:

```bash
# Mark the existing key inactive
aws iam update-access-key --user-name vector-<host> --access-key-id <old-id> --status Inactive

# Taint the access key resource so terraform regenerates it
terraform apply -replace='aws_iam_access_key.writer["<host>"]'

# Push the new credential via Jamf
# Delete the inactive old key after 24h to confirm rollout
aws iam delete-access-key --user-name vector-<host> --access-key-id <old-id>
```

A future improvement: a Lambda + EventBridge schedule that rotates writer keys automatically every 90 days. Out of scope for Phase A.

## Validating the policy enforcement

The per-host scoping should be tested before rolling out. From an `alice-mbp` writer credential:

```bash
# This should succeed — writing to alice's partition
echo test | gzip | aws s3 cp - s3://mhi-claude-audit/claude-audit/year=2026/month=05/day=20/host=alice-mbp/test/file.log.gz

# These should both 403
echo test | gzip | aws s3 cp - s3://mhi-claude-audit/claude-audit/year=2026/month=05/day=20/host=bob-mbp/test/file.log.gz
aws s3 ls s3://mhi-claude-audit/
```

If either of the deny tests succeeds, the policy isn't doing its job — investigate before fleet rollout.

## Cost monitoring

Set a CloudWatch budget alert outside this module:

```bash
aws budgets create-budget --account-id <acct> --budget '{
  "BudgetName": "claude-audit-monthly",
  "BudgetLimit": {"Amount": "20", "Unit": "GBP"},
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST",
  "CostFilters": {"TagKeyValue": ["user:Project$claude-code-audit"]}
}'
```

£20/month is well above the expected ~£1–2/month for a fleet of this size. Any alert means something is wrong — investigate before paying it.
