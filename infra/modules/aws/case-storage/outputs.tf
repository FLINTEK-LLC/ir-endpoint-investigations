output "bucket_name" {
  description = "S3 bucket name for this case's evidence."
  value       = aws_s3_bucket.case.id
}

output "bucket_arn" {
  description = "S3 bucket ARN - used by case-role to scope the collector's upload permissions to exactly this bucket."
  value       = aws_s3_bucket.case.arn
}

output "region" {
  description = "Region the bucket was created in."
  value       = aws_s3_bucket.case.region
}
