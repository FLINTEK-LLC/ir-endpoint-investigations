variable "virtual_network_id" {
  description = "Resource ID of the existing VNet this Bastion serves. The Bastion, its AzureBastionSubnet, and its public IP are all created in THIS VNet's resource group (Azure requires them to share one). Every case whose investigation host lives in this VNet connects through this single Bastion."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+$", var.virtual_network_id))
    error_message = "virtual_network_id must be a full VNet resource ID: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>"
  }
}

variable "bastion_subnet_prefix" {
  description = "CIDR for the AzureBastionSubnet this creates, e.g. 10.20.2.0/26. Must be free (non-overlapping) space inside the VNet above, and /26 or larger - Azure rejects anything smaller for Bastion resources created after 2021-11-02. No default: the correct value depends entirely on your VNet's addressing, and guessing would either fail or silently collide with a subnet you already use."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.bastion_subnet_prefix)) && tonumber(split("/", var.bastion_subnet_prefix)[1]) <= 26
    error_message = "bastion_subnet_prefix must be valid CIDR with a prefix length of /26 or larger (i.e. <= 26, so /26, /25, /24 ...)."
  }
}

variable "location" {
  description = "Azure region for the Bastion and its public IP. Should match the region of the VNet (and therefore of your investigation hosts)."
  type        = string
  default     = "eastus"
}

variable "tags" {
  description = "Extra tags applied to the Bastion and its public IP."
  type        = map(string)
  default     = {}
}
