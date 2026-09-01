# Assumable by any authenticated principal in the same account (this is a
# single-operator, own-account workflow, not cross-account) - New-CaseCollector.ps1
# calls sts:AssumeRole against this role to mint the short-lived, write-only
# credential baked into that case's offline collector. See infra/SECURITY.md
# for why this is the credential model instead of a long-lived IAM user key.
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "case_uploader" {
  name = "ir-case-${var.case_id}-uploader"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "sts:AssumeRole"
    }]
  })

  # Short by design - New-CaseCollector.ps1 mints a new session (via
  # sts:AssumeRole's own DurationSeconds) each time it builds a collector,
  # rather than relying on a long session lifetime here.
  max_session_duration = 3600

  tags = var.tags
}

# Write-only, and only to this one case's bucket - a collector binary
# carrying this credential, run on a possibly-compromised endpoint, can
# never read back what it uploaded, list other objects, or touch any other
# case's bucket.
resource "aws_iam_role_policy" "write_only" {
  name = "case-bucket-write-only"
  role = aws_iam_role.case_uploader.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = ["${var.bucket_arn}/*"]
    }]
  })
}
