output "vm_id" {
  description = "Azure VM resource ID."
  value       = azurerm_windows_virtual_machine.host.id
}

output "admin_username" {
  description = "Local administrator username - fed through to Connect-InvestigationHost.ps1 so it never has to hardcode (and risk drifting out of sync with) var.admin_username's default."
  value       = azurerm_windows_virtual_machine.host.admin_username
}

output "vm_name" {
  description = "Azure VM name - used with `az network bastion rdp` to connect."
  value       = azurerm_windows_virtual_machine.host.name
}

output "bastion_name" {
  description = "The shared Bastion this case connects through (created once by infra/environments/azure-bastion/, not by this module)."
  value       = var.bastion_name
}

output "bastion_resource_group_name" {
  description = "Resource group of the shared Bastion - the VNet's resource group, NOT this case's. Connect-InvestigationHost.ps1 passes it to `az network bastion rdp --resource-group`; using the case resource group here would fail."
  value       = var.bastion_resource_group_name
}

# Connect-InvestigationHost.ps1 branches on this. Native-client RDP
# (`az network bastion rdp` / `az network bastion tunnel`) requires the
# Standard SKU or higher - verified against Microsoft's own native-client
# documentation, which states "Native client support requires the Standard
# SKU or higher (Standard or Premium)." The shared Bastion environment
# deploys Standard with tunneling_enabled, so native RDP works.
output "access_method" {
  description = "Connect-InvestigationHost.ps1 branches on this: rdp-allowlist vs bastion."
  value       = var.access_method
}

output "public_ip_address" {
  description = "Public IP to RDP to when access_method is rdp-allowlist; null under bastion."
  value       = local.use_rdp_allowlist ? azurerm_public_ip.host[0].ip_address : null
}

output "nsg_name" {
  description = "NSG whose inbound rule the connect script opens/closes just-in-time. Null under bastion."
  value       = local.use_rdp_allowlist ? azurerm_network_security_group.host[0].name : null
}

output "bastion_sku" {
  description = "SKU of the shared Bastion. Standard means Connect-InvestigationHost.ps1 can launch a real mstsc session."
  value       = "Standard"
}

output "subscription_id" {
  description = "Used to build the Azure portal deep link for a Developer-SKU Bastion connection."
  value       = data.azurerm_client_config.current.subscription_id
}
