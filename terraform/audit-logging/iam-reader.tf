resource "aws_iam_user" "reader" {
  for_each = var.reader_principals

  name = each.value
  path = "/claude-audit/"

  tags = {
    Role  = "audit-reader"
    Label = each.key
  }
}

resource "aws_iam_access_key" "reader" {
  for_each = aws_iam_user.reader

  user = each.value.name
}

resource "aws_iam_user_policy" "reader" {
  for_each = aws_iam_user.reader

  name = "audit-reader-${each.key}"
  user = each.value.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.audit.arn
      },
      {
        Sid      = "ReadObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.audit.arn}/*"
      },
    ]
  })
}
