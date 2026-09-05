output "bucket_name" {
  value = module.case_storage.bucket_name
}

output "region" {
  description = "Fed to New-CaseCollector.ps1 so it doesn't have to re-derive the region this case's bucket was created in."
  value       = module.case_storage.region
}

output "instance_id" {
  description = "Connect with: aws ssm start-session --target <this> --profile <aws_profile>"
  value       = module.investigation_host.instance_id
}

output "admin_username" {
  description = "Local account to sign in as on the investigation host."
  value       = module.investigation_host.admin_username
}

output "admin_password" {
  description = "Local Administrator password for RDP login, fetched live by Connect-InvestigationHost.ps1 - sensitive, never written to infra\\.cases\\ bookkeeping (Start-CloudConsole.ps1 strips it before saving a case record)."
  value       = random_password.admin.result
  sensitive   = true
}

output "uploader_role_arn" {
  description = "Fed to New-CaseCollector.ps1 -RoleArn when building this case's offline collector."
  value       = module.case_role.role_arn
}
