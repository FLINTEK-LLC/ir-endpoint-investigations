output "role_arn" {
  description = "IAM role ARN - New-CaseCollector.ps1 assumes this via STS to mint the collector's upload credential."
  value       = aws_iam_role.case_uploader.arn
}
