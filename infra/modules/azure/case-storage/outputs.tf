output "resource_group_name" {
  description = "Resource group this case's storage lives in - the investigation-host module also deploys into this group."
  value       = azurerm_resource_group.case.name
}

output "storage_account_name" {
  description = "Storage account name for this case."
  value       = azurerm_storage_account.case.name
}

output "storage_account_id" {
  description = "Storage account resource ID - used to scope the investigation host's managed identity role assignment to exactly this account."
  value       = azurerm_storage_account.case.id
}

output "container_name" {
  description = "Blob container name for this case's evidence."
  value       = azurerm_storage_container.case.name
}
