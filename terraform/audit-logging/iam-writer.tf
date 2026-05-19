locals {
  # Map form for for_each iteration. The set-of-strings shape is what callers
  # provide; we convert here so resource keys are deterministic and stable.
  writers = { for h in var.writer_hostnames : h => h }
}

resource "aws_iam_user" "writer" {
  for_each = local.writers

  name = "vector-${each.value}"
  path = "/claude-audit/"

  tags = {
    Hostname = each.value
    Role     = "vector-writer"
  }
}

resource "aws_iam_access_key" "writer" {
  for_each = aws_iam_user.writer

  user = each.value.name
}

# Per-host inline policy. The Resource ARN includes the hostname so this user
# can ONLY write under its own host partition. A leaked credential for
# alice-mbp cannot write to bob-mbp's partition or read any data at all.
resource "aws_iam_user_policy" "writer" {
  for_each = aws_iam_user.writer

  name = "vector-writer-${each.key}"
  user = each.value.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "WriteOwnHostPartition"
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:PutObjectAcl",
      ]
      # Vector writes to:
      #   claude-audit/year=YYYY/month=MM/day=DD/host=<host>/<hook>/<file>.log.gz
      # The partition path includes "host=<their-hostname>", so we can
      # constrain the resource ARN with a wildcard either side.
      Resource = "${aws_s3_bucket.audit.arn}/claude-audit/*/host=${each.key}/*"
    }]
  })
}
