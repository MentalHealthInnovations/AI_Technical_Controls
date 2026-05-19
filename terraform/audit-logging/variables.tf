variable "aws_region" {
  description = "AWS region. Pinned to UK for GDPR data residency."
  type        = string
  default     = "eu-west-2"

  validation {
    condition     = startswith(var.aws_region, "eu-")
    error_message = "Audit logs must remain in an EU region for UK GDPR. Override only with DPO sign-off."
  }
}

variable "bucket_name" {
  description = "S3 bucket name. Must be globally unique."
  type        = string
  default     = "mhi-claude-audit"
}

variable "writer_hostnames" {
  description = <<-EOT
    Short hostnames of managed Macs that should be given write credentials.
    One IAM user + access key is created per entry. Names become part of the
    IAM user name (vector-<host>) so they must match `hostname -s` on the
    machine — that's the same value Vector stamps into the JSONL host field.
    Add machines here as they're onboarded; remove to revoke.
  EOT
  type        = list(string)
  default     = []
}

variable "reader_principals" {
  description = <<-EOT
    Map of label -> IAM user name for read-only access to the audit bucket.
    Used for ad-hoc investigation via DuckDB. Keep this small (typically
    one or two named individuals on the security/IT team).
  EOT
  type        = map(string)
  default     = {}
}

variable "lifecycle_transition_to_ia_days" {
  description = "Days before transitioning to Standard-IA storage."
  type        = number
  default     = 30
}

variable "lifecycle_transition_to_glacier_days" {
  description = "Days before transitioning to Glacier Instant Retrieval."
  type        = number
  default     = 120
}

variable "lifecycle_expiration_days" {
  description = <<-EOT
    Days before objects are deleted. 395 = 13 months, the default retention
    for security audit telemetry. Change requires DPO sign-off — the
    retention figure is part of the lawful-basis assessment.
  EOT
  type        = number
  default     = 395

  validation {
    condition     = var.lifecycle_expiration_days >= 90 && var.lifecycle_expiration_days <= 2555
    error_message = "Retention must be between 90 days and 7 years."
  }
}
