variable "case_id" {
  description = "Case identifier - names every resource (ir-case-<case_id>)."
  type        = string
}

variable "location" {
  description = "Azure region to deploy into."
  type        = string
  default     = "eastus"
}

variable "subnet_id" {
  description = "Existing subnet for the investigation host's network interface. Must have internet egress for the bootstrap script's downloads, and must be in the same VNet the shared Bastion below serves. NOT the AzureBastionSubnet - that one is Bastion's alone and cannot hold other resources."
  type        = string
}

variable "access_method" {
  description = "\"rdp-allowlist\" (default - public IP + deny-by-default NSG, opened just-in-time to your own IP; ~$0.005/hr and supplies the host's outbound egress) or \"bastion\" (no public IP, connect through the shared Standard Bastion; ~$0.29/hr and you must supply your own egress). See infra/README.md's \"Connecting on Azure\"."
  type        = string
  default     = "rdp-allowlist"

  validation {
    condition     = contains(["rdp-allowlist", "bastion"], var.access_method)
    error_message = "access_method must be \"rdp-allowlist\" or \"bastion\"."
  }
}

variable "bastion_name" {
  description = "Only when access_method = \"bastion\": name of the shared Bastion serving this VNet, deployed once with Start-CloudConsole.ps1 option [8]. Bastion is per-VNet, not per-case: Azure permits only one per VNet."
  type        = string
  default     = ""
}

variable "bastion_resource_group_name" {
  description = "Only when access_method = \"bastion\": resource group of that shared Bastion (the VNet's resource group)."
  type        = string
  default     = ""
}

variable "tools_storage_account_id" {
  description = "OPTIONAL resource ID of a long-lived private storage account holding licensed tooling (KAPE) the host cannot download itself. Blank (default) means the host comes up without KAPE. Must NOT be this case's evidence account - see infra/README.md's \"Getting KAPE onto the host\". Get it with: az storage account show --name <acct> --query id -o tsv"
  type        = string
  default     = ""
}

variable "tools_container_name" {
  description = "Container in tools_storage_account_id holding kape.zip."
  type        = string
  default     = "irtools"
}

variable "tools_zip_url" {
  description = "OPTIONAL fallback to tools_storage_account_id: any URL the host can fetch kape.zip from without interactive sign-in (a OneDrive \"Anyone with the link\" share, an internal artifact repo, a SAS URL). Weaker than the storage-account path - see infra/README.md's \"Can I just use OneDrive?\". Ignored when tools_storage_account_id is set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "enable_immutability" {
  description = "Enable a time-based immutability policy on this case's blob container. No default - decide deliberately per case."
  type        = bool
}

variable "retention_days" {
  description = "Immutability retention period in days, if enable_immutability is true."
  type        = number
  default     = 90
}

variable "retention_mode" {
  description = "GOVERNANCE (recoverable) or COMPLIANCE (irreversible) - see the case-storage module's variable description."
  type        = string
  default     = "GOVERNANCE"
}

variable "archive_after_days" {
  description = "Days of case-open activity before evidence transitions to the Archive tier."
  type        = number
  default     = 30
}

variable "vm_size" {
  description = "Investigation host VM size."
  type        = string
  default     = "Standard_D4s_v5"
}
