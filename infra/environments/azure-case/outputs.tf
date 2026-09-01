output "resource_group_name" {
  value = module.case_storage.resource_group_name
}

output "storage_account_name" {
  description = "Fed to New-CaseCollector.ps1 to mint this case's SAS URL."
  value       = module.case_storage.storage_account_name
}

output "container_name" {
  description = "Fed to New-CaseCollector.ps1 to mint this case's SAS URL."
  value       = module.case_storage.container_name
}

output "admin_password" {
  description = "Local Administrator password for RDP login, fetched live by Connect-InvestigationHost.ps1 - sensitive, never written to infra\\.cases\\ bookkeeping (Start-CloudConsole.ps1 strips it before saving a case record)."
  value       = random_password.admin.result
  sensitive   = true
}

output "vm_name" {
  description = "Connect with: az network bastion rdp --name <bastion_name> --resource-group <this resource group> --target-resource-id <vm_id>"
  value       = module.investigation_host.vm_name
}

output "vm_id" {
  description = "Fed to Connect-InvestigationHost.ps1 as --target-resource-id."
  value       = module.investigation_host.vm_id
}

output "admin_username" {
  value = module.investigation_host.admin_username
}

output "bastion_name" {
  value = module.investigation_host.bastion_name
}

output "bastion_resource_group_name" {
  description = "Connect-InvestigationHost.ps1 uses this, not resource_group_name - the shared Bastion lives in the VNet's resource group, not the case's."
  value       = module.investigation_host.bastion_resource_group_name
}

output "access_method" {
  description = "Connect-InvestigationHost.ps1 branches on this."
  value       = module.investigation_host.access_method
}

output "public_ip_address" {
  description = "RDP target when access_method is rdp-allowlist."
  value       = module.investigation_host.public_ip_address
}

output "nsg_name" {
  description = "NSG the connect script opens/closes just-in-time."
  value       = module.investigation_host.nsg_name
}

output "bastion_sku" {
  description = "Connect-InvestigationHost.ps1 branches on this - Standard supports native-client RDP, Developer would not."
  value       = module.investigation_host.bastion_sku
}

output "subscription_id" {
  description = "Used to build an Azure portal deep link as a fallback if native RDP is unavailable."
  value       = module.investigation_host.subscription_id
}
