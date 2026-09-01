output "bastion_name" {
  description = "Pass this to a case as -var bastion_name=... (Start-CloudConsole.ps1's [2] prompts for it and remembers it in the case record)."
  value       = azurerm_bastion_host.shared.name
}

output "bastion_resource_group_name" {
  description = "The VNet's resource group, NOT a per-case one - Connect-InvestigationHost.ps1 needs this for `az network bastion rdp --resource-group`."
  value       = azurerm_bastion_host.shared.resource_group_name
}

output "bastion_sku" {
  description = "Standard - which is what makes native-client RDP (a real mstsc session) work at all."
  value       = azurerm_bastion_host.shared.sku
}

output "hourly_cost_reminder" {
  description = "Shown by the TUI after apply."
  value       = "This Bastion bills hourly whether or not anyone is connected (~$0.29/hr Standard in eastus = ~$7/day). Destroy it when the engagement is over: Start-CloudConsole.ps1 option [9]."
}
