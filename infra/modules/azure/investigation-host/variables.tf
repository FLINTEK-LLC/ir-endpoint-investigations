variable "case_id" {
  description = "Case identifier - used to name and tag this host."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy into - the case-storage module's output, so the host lives alongside its case's storage."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "storage_account_id" {
  description = "This case's storage account resource ID (from the case-storage module) - the VM's managed identity is granted Storage Blob Data Reader scoped to exactly this account, nothing else."
  type        = string
}

variable "storage_account_name" {
  description = "This case's storage account name (from the case-storage module) - passed to the bootstrap script."
  type        = string
}

variable "container_name" {
  description = "This case's blob container name (from the case-storage module) - passed to the bootstrap script."
  type        = string
}

variable "vm_size" {
  description = <<-EOT
    Azure VM size. Meant to be spun up per case and destroyed when idle, not
    sized for the largest possible collection up front - size up per case if a
    specific investigation needs it.

    The default is deliberately a Bsv2 (burstable) size rather than a D-series
    one. Same 4 vCPU / 16 GiB as Standard_D4s_v5 at roughly half the hourly
    price, bursty CPU suits a parsing workload that idles between runs, the
    series has no local temp disk to collide with the D: evidence mount, and -
    the reason it is the default - D-series capacity is frequently restricted
    for new and trial subscriptions in busy regions, so a D-series default made
    the very first `terraform apply` fail with SkuNotAvailable.
  EOT
  type        = string
  default     = "Standard_B4s_v2" # 4 vCPU / 16 GiB burstable, ~$0.185/hr in
  # eastus vs ~$0.376 for Standard_D4s_v5.

  # Azure's own portal and docs frequently present sizes without their tier
  # prefix ("B4s_v2" under a Standard tier column), so it is very easy to
  # supply a name the API rejects. Catch it here, at plan time, instead of
  # two minutes into apply with a 900-line "valid sizes are..." dump.
  validation {
    condition     = can(regex("^(Standard|Basic)_", var.vm_size))
    error_message = "vm_size must include the tier prefix - e.g. \"Standard_B4s_v2\", not \"B4s_v2\"."
  }
}

variable "image_publisher" {
  description = "Marketplace publisher for the investigation host OS image."
  type        = string
  default     = "MicrosoftWindowsServer"
}

variable "image_offer" {
  description = "Marketplace offer for the investigation host OS image."
  type        = string
  default     = "WindowsServer"
}

variable "image_sku" {
  description = <<-EOT
    Marketplace SKU for the investigation host OS image. Defaults to Windows
    Server 2025 (Gen2), the direct analogue of the 2022-datacenter-g2 image
    this module used previously.

    VERIFY THIS STRING against your own subscription before a first run - it
    could not be confirmed from documentation while this was written, and a
    wrong SKU fails at apply time with "image not found". Check with:

      az vm image list --publisher MicrosoftWindowsServer --offer WindowsServer --all --output table --query "[?contains(sku,'2025')].{sku:sku,version:version}"

    Alternatives you may see: 2025-datacenter (Gen1),
    2025-datacenter-azure-edition (adds hotpatching - unnecessary for an
    ephemeral per-case host), 2025-datacenter-core-g2 (no desktop, which
    would break the GUI forensic tools this host is for).
  EOT
  type        = string
  default     = "2025-datacenter-g2"
}

variable "image_version" {
  description = "Image version - 'latest' keeps a fresh host on every respin, which is the point of destroying and recreating per case."
  type        = string
  default     = "latest"
}

variable "os_disk_size_gb" {
  description = "OS (C:) disk size in GB - holds the OS, the KAPE/EZ Tools/Sysinternals/Autopsy toolkit, and Windows temp/paging space. Case evidence itself lives on the separately-mounted case container, not this disk."
  type        = number
  default     = 150
}

variable "computer_name" {
  description = "Windows host name inside the OS. Leave empty to derive one automatically from case_id (hyphens stripped, \"ir\" prefixed, truncated to the 15-character NetBIOS limit). Set explicitly only if you need two similarly-named cases to have distinct host names."
  type        = string
  default     = ""

  validation {
    condition     = var.computer_name == "" || length(var.computer_name) <= 15
    error_message = "computer_name must be 15 characters or fewer - the Windows NetBIOS limit."
  }
}

variable "admin_username" {
  description = "Local administrator username created on the VM. Bastion brokers the network path only - it does NOT authenticate you to Windows - so this account and its generated password are what you actually sign in with. Connect-InvestigationHost.ps1 prints both."
  type        = string
  default     = "iranalyst"
}

variable "admin_password" {
  description = "Local administrator password. Generate one (e.g. via a `random_password` resource in the calling environment) rather than hardcoding it in any committed .tfvars file - see infra/SECURITY.md."
  type        = string
  sensitive   = true
}

variable "access_method" {
  description = <<-EOT
    How this case's investigation host is reached.

      "rdp-allowlist" - the host gets a public IP and an NSG that denies all
        inbound by default. Connect-InvestigationHost.ps1 opens port 3389 to
        your current public IP alone, just-in-time, and closes it when you
        disconnect. Costs about $0.005/hr for the public IP, and that IP also
        provides the outbound internet the bootstrap needs.

      "bastion" - no public IP and no inbound port on the host at all; you
        connect through the shared Standard Bastion (see
        infra/environments/azure-bastion/). Strongest network posture, but
        Bastion costs about $0.29/hr, and because the host then has no public
        IP you must supply your own outbound egress (NAT Gateway) for the
        bootstrap to work.

    See infra/README.md's "Connecting on Azure" for the full trade-off.
  EOT
  type        = string
  default     = "rdp-allowlist"

  validation {
    condition     = contains(["rdp-allowlist", "bastion"], var.access_method)
    error_message = "access_method must be \"rdp-allowlist\" or \"bastion\"."
  }
}

variable "bastion_name" {
  description = "Name of the SHARED Bastion that serves this VNet, created once by infra/environments/azure-bastion/ (its bastion_name output). Only used when access_method is \"bastion\". This module never creates a Bastion - Azure allows only one per VNet."
  type        = string
  default     = ""
}

variable "bastion_resource_group_name" {
  description = "Resource group holding that shared Bastion - the VNet's resource group, not this case's (Azure requires the Bastion, its subnet, and the VNet to share one). Only used when access_method is \"bastion\"."
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Existing subnet for the VM's network interface, in the same VNet the shared Bastion serves. Must have internet egress. Never the AzureBastionSubnet - Azure reserves that one for Bastion and it cannot contain other resources."
  type        = string
}

variable "tools_storage_account_id" {
  description = <<-EOT
    OPTIONAL. Resource ID of a long-lived, private storage account holding
    licensed tooling this host cannot download for itself - in practice KAPE,
    which Kroll gates behind licence acceptance so it can never be fetched
    unattended.

    Leave empty (the default) and the host simply comes up without KAPE, and
    without the parsing toolchain that depends on it. Set it and the bootstrap
    pulls tools_container_name/kape.zip down using the VM's own managed
    identity - no key, no SAS, nothing written to disk.

    Deliberately NOT this case's evidence storage: tooling in an evidence
    container muddies chain of custody, inherits any WORM retention you set,
    and gets lifecycle-archived to cold tier out from under you. Use a
    separate account, created once and shared by every case. See
    infra/README.md's "Getting KAPE onto the host".

    Get it with: az storage account show --name <acct> --query id -o tsv
  EOT
  type        = string
  default     = ""
}

variable "tools_zip_url" {
  description = <<-EOT
    OPTIONAL fallback when tools_storage_account_id is not used: any URL the
    host can fetch kape.zip from without interactive sign-in. Covers a
    OneDrive/SharePoint "Anyone with the link" share, an internal artifact
    repo, a pre-signed SAS URL, or a file server.

    Less preferred than tools_storage_account_id, for two concrete reasons:
      * If the URL carries its own authorisation (a share link or SAS), that
        secret lands in Terraform state and is only as private as the link.
        A OneDrive "Anyone" link makes a LICENSED binary downloadable by
        anyone who obtains the URL, and many tenants block such links by
        policy anyway.
      * It cannot be scoped the way a managed-identity role assignment can.
        The storage-account path grants read on exactly one container and
        nothing else.

    Ignored when tools_storage_account_id is set.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "tools_container_name" {
  description = "Container within tools_storage_account_id holding kape.zip. Only used when tools_storage_account_id is set."
  type        = string
  default     = "irtools"
}

variable "case_repo_git_url" {
  description = "Git URL for ir-endpoint-investigations, fetched by the bootstrap script so it can call Setup-Workstation.ps1. Override if you maintain a fork."
  type        = string
  default     = "https://github.com/FLINTEK-LLC/ir-endpoint-investigations.git"
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
