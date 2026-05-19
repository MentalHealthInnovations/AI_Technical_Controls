resource "aws_s3_bucket" "audit" {
  bucket = var.bucket_name
}

# Defence in depth — block all forms of public access at the account-level
# control plane, regardless of bucket policy.
resource "aws_s3_bucket_public_access_block" "audit" {
  bucket = aws_s3_bucket.audit.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# SSE-S3 (AES-256). Sufficient for Phase A. Move to SSE-KMS only if a
# compliance requirement asks for customer-managed key control over the
# logs at rest.
resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Versioning is intentionally off. Audit records are append-only per record,
# not per file — Vector writes one new blob per batch, never overwrites. Bucket
# versioning would multiply storage cost for no benefit here.
resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id

  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "claude-audit-tiering"
    status = "Enabled"

    filter {
      prefix = "claude-audit/"
    }

    transition {
      days          = var.lifecycle_transition_to_ia_days
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = var.lifecycle_transition_to_glacier_days
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = var.lifecycle_expiration_days
    }
  }
}

# Bucket-level policy enforcing TLS on all requests. Belt-and-braces alongside
# AWS's own default of TLS-only via the endpoint — this denies plaintext
# attempts at the bucket layer too, so a misconfigured client can't accidentally
# write logs over HTTP.
resource "aws_s3_bucket_policy" "audit_tls_only" {
  bucket = aws_s3_bucket.audit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.audit.arn,
        "${aws_s3_bucket.audit.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })

  # Public access block must apply first, otherwise the bucket policy attempt
  # can race with the account-level restriction.
  depends_on = [aws_s3_bucket_public_access_block.audit]
}
