# Case evidence bucket. One bucket per case (not a shared bucket with
# per-case prefixes) so each case gets its own clean IAM boundary, its own
# Object Lock decision, and can be archived/deleted as a single unit when
# the case closes - see infra/SECURITY.md for the full rationale.
#
# Object Lock must be decided at bucket creation and cannot be added later,
# which is why enable_immutability has no default - every case should make
# this choice deliberately, not inherit one.
resource "aws_s3_bucket" "case" {
  bucket              = "ir-case-${var.case_id}"
  object_lock_enabled = var.enable_immutability

  tags = merge(var.tags, {
    CaseId  = var.case_id
    Purpose = "ir-case-evidence"
  })
}

# Versioning is required for Object Lock, and worth having even when
# immutability is off - protects against an accidental overwrite either way.
resource "aws_s3_bucket_versioning" "case" {
  bucket = aws_s3_bucket.case.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "case" {
  bucket = aws_s3_bucket.case.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# No public access, full stop - case evidence is never a public-read use case.
resource "aws_s3_bucket_public_access_block" "case" {
  bucket                  = aws_s3_bucket.case.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enforce HTTPS for every request to this bucket.
#
# depends_on the public access block is deliberate: with
# block_public_policy = true, S3 rejects any bucket policy it evaluates as
# granting public access. This policy is a pure Deny (never public by that
# definition) so it is accepted either way, but without an explicit
# ordering Terraform is free to apply these two in either order, and
# relying on that evaluation subtlety to hold under a racing apply is not
# worth the flakiness it would cause.
resource "aws_s3_bucket_policy" "require_tls" {
  bucket = aws_s3_bucket.case.id

  depends_on = [aws_s3_bucket_public_access_block.case]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.case.arn,
        "${aws_s3_bucket.case.arn}/*",
      ]
      Condition = {
        Bool = {
          "aws:SecureTransport" = "false"
        }
      }
    }]
  })
}

# Object Lock default retention - only created when immutability is enabled
# for this case. GOVERNANCE vs COMPLIANCE is a real, documented trade-off -
# see the retention_mode variable description and infra/SECURITY.md.
resource "aws_s3_bucket_object_lock_configuration" "case" {
  count  = var.enable_immutability ? 1 : 0
  bucket = aws_s3_bucket.case.id

  rule {
    default_retention {
      mode = var.retention_mode
      days = var.retention_days
    }
  }

  # Object Lock configuration itself can only be set once alongside bucket
  # creation when object_lock_enabled=true at creation time; this resource
  # just supplies the default retention rule on top of that.
  depends_on = [aws_s3_bucket_versioning.case]
}

# Cheap-while-active, cheaper-once-archived: standard storage during the
# case, Glacier after archive_after_days. Object Lock (if enabled) still
# applies to Glacier-tier objects - the retention clock isn't reset by the
# storage-class transition.
resource "aws_s3_bucket_lifecycle_configuration" "case" {
  bucket = aws_s3_bucket.case.id
  rule {
    id     = "archive-to-glacier"
    status = "Enabled"

    filter {}

    transition {
      days          = var.archive_after_days
      storage_class = "GLACIER"
    }

    noncurrent_version_transition {
      noncurrent_days = var.archive_after_days
      storage_class   = "GLACIER"
    }
  }

  depends_on = [aws_s3_bucket_versioning.case]
}
