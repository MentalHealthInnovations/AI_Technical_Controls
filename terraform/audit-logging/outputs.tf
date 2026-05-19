output "bucket_name" {
  description = "Name of the audit log S3 bucket."
  value       = aws_s3_bucket.audit.id
}

output "bucket_arn" {
  description = "ARN of the audit log S3 bucket."
  value       = aws_s3_bucket.audit.arn
}

output "bucket_region" {
  description = "Region the bucket is hosted in (GDPR-relevant)."
  value       = var.aws_region
}

# Writer credentials. Sensitive — these are the access key + secret pairs
# Vector uses on each Mac. Pulled from state with `terraform output -json`
# at deploy time and never written to disk in plaintext beyond state.
output "writer_credentials" {
  description = <<-EOT
    Map of hostname -> { access_key_id, secret_access_key } for Vector
    writer IAM users. Inject into the Jamf policy's parameters 4 and 5 at
    install time. Treat as secrets — keep state encrypted and access-
    controlled.
  EOT
  sensitive   = true
  value = {
    for h, user in aws_iam_user.writer : h => {
      access_key_id     = aws_iam_access_key.writer[h].id
      secret_access_key = aws_iam_access_key.writer[h].secret
      iam_user_name     = user.name
    }
  }
}

output "reader_credentials" {
  description = <<-EOT
    Map of label -> { access_key_id, secret_access_key } for read-only IAM
    users. Drop into the operator's 1Password vault for DuckDB queries.
  EOT
  sensitive   = true
  value = {
    for label, user in aws_iam_user.reader : label => {
      access_key_id     = aws_iam_access_key.reader[label].id
      secret_access_key = aws_iam_access_key.reader[label].secret
      iam_user_name     = user.name
    }
  }
}
