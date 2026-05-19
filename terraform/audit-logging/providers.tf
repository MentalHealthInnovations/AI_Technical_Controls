provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "claude-code-audit"
      Owner     = "security"
      Module    = "terraform/audit-logging"
      ManagedBy = "terraform"
    }
  }
}
