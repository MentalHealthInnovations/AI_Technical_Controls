# aws/audit-logging

Manual AWS setup for the Claude Code audit log pipeline. Provisions the S3 bucket Vector ships logs to, plus the per-host writer IAM users and read-only investigation users.

This is **Phase 0** of the audit logging rollout. See the top-level `README.md` for the wider context.

> **Status: manual setup.** This phase is delivered by hand via the AWS CLI / console steps below. It will be converted to infrastructure-as-code (Terraform) at a later date. Until then, treat this document as the source of truth for what exists in the account, and make changes by following these steps — not ad-hoc in the console — so the eventual IaC import is clean.

## What you create

| Resource | Purpose |
|---|---|
| S3 bucket `mhi-claude-audit` | The log bucket. UK region. SSE-S3. Lifecycle policy. TLS-only. |
| Bucket lifecycle rule `claude-audit-tiering` | 30d hot → 120d IA → 395d delete |
| IAM user `vector-<host>` (one per Mac) | Per-machine writer, scoped to write under `host=<host>/` only |
| IAM user (one per reader) | Read-only users for ad-hoc DuckDB investigation |

All commands assume the AWS CLI is configured with an admin profile for the target account and `eu-west-2` (London) as the region. Adjust `--region` / `--profile` to taste.

```bash
export AWS_REGION=eu-west-2          # UK region — required for GDPR data residency (see below)
export BUCKET=mhi-claude-audit       # must be globally unique; change if taken
```

---

## 1. Create and harden the S3 bucket

### 1.1 Create the bucket

**Region is pinned to the UK (`eu-west-2`) for UK GDPR data residency.** The logs contain prompt text and command lines, which can include personal data. Do not create this bucket in a non-EU region without DPO sign-off — the region is part of the lawful-basis assessment.

```bash
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"
```

### 1.2 Block all public access (account-plane defence in depth)

Blocks every form of public access at the bucket's control plane, regardless of any future bucket policy.

```bash
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

> Apply this **before** the bucket policy in step 1.5, otherwise the policy attempt can race the account-level restriction.

### 1.3 Enable encryption at rest (SSE-S3 / AES-256)

SSE-S3 is sufficient for Phase A. Move to SSE-KMS only if a compliance requirement asks for customer-managed key control over the logs at rest.

```bash
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": { "SSEAlgorithm": "AES256" },
      "BucketKeyEnabled": true
    }]
  }'
```

### 1.4 Leave versioning OFF (intentional)

Do **not** enable bucket versioning. Audit records are append-only per record, not per file — Vector writes one new gzipped blob per batch and never overwrites. Versioning would multiply storage cost for no benefit. New buckets default to versioning disabled, so there is nothing to do here; this note exists so nobody "helpfully" turns it on later.

### 1.5 Lifecycle policy (tiering + expiry)

30 days hot (Standard) → Standard-IA → Glacier Instant Retrieval → delete at 395 days.

**395 days = 13 months**, the default retention for security audit telemetry. Changing the expiry requires DPO sign-off — the retention figure is part of the lawful-basis assessment. Keep retention between 90 days and 7 years.

```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "claude-audit-tiering",
      "Status": "Enabled",
      "Filter": { "Prefix": "claude-audit/" },
      "Transitions": [
        { "Days": 30,  "StorageClass": "STANDARD_IA" },
        { "Days": 120, "StorageClass": "GLACIER_IR" }
      ],
      "Expiration": { "Days": 395 }
    }]
  }'
```

### 1.6 TLS-only bucket policy

Belt-and-braces alongside AWS's own TLS-only endpoint default — this denies plaintext attempts at the bucket layer too, so a misconfigured client can't accidentally write logs over HTTP. Substitute your bucket ARN (`arn:aws:s3:::mhi-claude-audit`).

```bash
aws s3api put-bucket-policy \
  --bucket "$BUCKET" \
  --policy '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::mhi-claude-audit",
        "arn:aws:s3:::mhi-claude-audit/*"
      ],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }]
  }'
```

---

## 2. Create a writer IAM user per managed Mac

Create **one IAM user per machine**, named `vector-<host>`, where `<host>` matches `hostname -s` on the machine — the same value Vector stamps into the JSONL `host` field. The user's inline policy is scoped so it can **only** write under its own `host=<host>/` partition: a leaked credential for `alice-mbp` cannot write to `bob-mbp`'s partition or read any data at all.

Repeat this whole section for each host. Below, `HOST` is the short hostname.

```bash
export HOST=alice-mbp                 # must match `hostname -s` on the machine
```

### 2.1 Create the user

```bash
aws iam create-user \
  --user-name "vector-$HOST" \
  --path /claude-audit/ \
  --tags Key=Hostname,Value="$HOST" Key=Role,Value=vector-writer
```

### 2.2 Attach the per-host inline write policy

Vector writes to:

```
claude-audit/year=YYYY/month=MM/day=DD/host=<host>/<hook>/<file>.log.gz
```

The partition path contains `host=<their-hostname>`, so the resource ARN is constrained with a wildcard either side of it. **Edit the `host=alice-mbp` segment to match `$HOST`** before running.

```bash
aws iam put-user-policy \
  --user-name "vector-$HOST" \
  --policy-name "vector-writer-$HOST" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "WriteOwnHostPartition",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:PutObjectAcl"],
      "Resource": "arn:aws:s3:::mhi-claude-audit/claude-audit/*/host=alice-mbp/*"
    }]
  }'
```

### 2.3 Create an access key

The secret is returned **exactly once** — capture it now. Pipe straight into 1Password / your secrets manager; never redirect to a file in the repo.

```bash
aws iam create-access-key --user-name "vector-$HOST"
```

Store the `AccessKeyId` + `SecretAccessKey` under that machine's 1Password entry, then inject them into the Jamf install policy's parameters 4 and 5 at install time.

---

## 3. Create read-only investigation users

One IAM user per named individual on the security/IT team who needs ad-hoc query access (via DuckDB). Keep this small — typically one or two people. Below, `READER` is the IAM user name.

```bash
export READER=claude-audit-reader-max
```

### 3.1 Create the user

```bash
aws iam create-user \
  --user-name "$READER" \
  --path /claude-audit/ \
  --tags Key=Role,Value=audit-reader
```

### 3.2 Attach the read-only policy

List + get across the whole bucket; no write permissions.

```bash
aws iam put-user-policy \
  --user-name "$READER" \
  --policy-name "audit-reader" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "ListBucket",
        "Effect": "Allow",
        "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
        "Resource": "arn:aws:s3:::mhi-claude-audit"
      },
      {
        "Sid": "ReadObjects",
        "Effect": "Allow",
        "Action": ["s3:GetObject"],
        "Resource": "arn:aws:s3:::mhi-claude-audit/*"
      }
    ]
  }'
```

### 3.3 Create an access key

```bash
aws iam create-access-key --user-name "$READER"
```

Drop the credential into the operator's 1Password vault for DuckDB queries.

---

## Secrets handling

These IAM access keys are long-lived static credentials. The AWS API returns each secret exactly once, at creation.

- Never commit a secret. There is no state file in this phase, so nothing on disk holds them — keep it that way. Store every key directly in 1Password / a secrets manager.
- Vector needs static keys because it's a long-running daemon with no interactive session (SSO-vended temporary credentials don't work for it).
- Limit who can run `iam create-access-key` against these users to operators who already hold IAM admin in the account — key-creation access *is* credential access.

When this phase is converted to Terraform, the access keys will end up in Terraform state; at that point the remote state backend must be encrypted at rest and access-controlled. That trade-off is deferred until the IaC conversion.

---

## Adding a new managed Mac

1. Set `HOST` to the new machine's `hostname -s`.
2. Run section 2 (create user → attach per-host policy → create access key).
3. Store the credentials in 1Password under that machine's entry.
4. Trigger the Jamf install policy on that machine.

## Removing / revoking a machine

1. Delete the access key(s), then the inline policy, then the user:
   ```bash
   aws iam list-access-keys --user-name vector-$HOST          # find the key IDs
   aws iam delete-access-key --user-name vector-$HOST --access-key-id <id>
   aws iam delete-user-policy --user-name vector-$HOST --policy-name vector-writer-$HOST
   aws iam delete-user --user-name vector-$HOST
   ```
   Vector on that machine will start 403'ing within minutes.
2. (Optional) Remove the now-orphaned log data — only if the machine genuinely shouldn't have data retained:
   ```bash
   aws s3 rm "s3://$BUCKET/claude-audit/" --recursive \
     --exclude "*" --include "*/host=$HOST/*"
   ```

## Rotating credentials

Annual rotation, manual:

```bash
# 1. Create the replacement key (machine now has two active keys)
aws iam create-access-key --user-name vector-$HOST

# 2. Push the new credential via Jamf, confirm Vector is writing with it

# 3. Mark the old key inactive
aws iam update-access-key --user-name vector-$HOST --access-key-id <old-id> --status Inactive

# 4. After 24h with no errors, delete the old key
aws iam delete-access-key --user-name vector-$HOST --access-key-id <old-id>
```

A future improvement (post-IaC): a Lambda + EventBridge schedule that rotates writer keys automatically every 90 days. Out of scope for Phase A.

---

## Validating the policy enforcement

Test the per-host scoping **before** fleet rollout. Configure the AWS CLI with an `alice-mbp` writer credential, then:

```bash
# This should succeed — writing to alice's own partition
echo test | gzip | aws s3 cp - s3://mhi-claude-audit/claude-audit/year=2026/month=05/day=20/host=alice-mbp/test/file.log.gz

# These should BOTH 403
echo test | gzip | aws s3 cp - s3://mhi-claude-audit/claude-audit/year=2026/month=05/day=20/host=bob-mbp/test/file.log.gz
aws s3 ls s3://mhi-claude-audit/
```

If either deny test succeeds, the policy isn't doing its job — investigate before rolling out.

---

## Cost monitoring

Set a CloudWatch budget alert (substitute your account ID):

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

> The cost filter keys on a `Project=claude-code-audit` tag. The Terraform applied that tag automatically via `default_tags`; in the manual flow there's no provider to do it for you, so the budget filter is best-effort. When you convert to IaC, restore the `default_tags` block (`Project=claude-code-audit`, `Owner=security`, `ManagedBy=terraform`) so the filter becomes reliable.
