locals {
  repo_base_https  = trimsuffix(var.case_repo_git_url, ".git")
  repo_raw_base    = replace(local.repo_base_https, "github.com", "raw.githubusercontent.com")
  fetch_script_url = "${local.repo_raw_base}/main/infra/scripts/fetch-and-bootstrap.ps1"
  repo_zip_url     = "${local.repo_base_https}/archive/refs/heads/main.zip"
}

locals {
  # Windows NetBIOS host names are capped at 15 characters, and Azure derives
  # computer_name from the VM's `name` unless told otherwise - so the
  # descriptive resource name "ir-case-<case_id>" blows the limit for any
  # case_id longer than 7 characters ("ir-case-test-001" is 16). Keep the long,
  # searchable name on the Azure resource and give Windows its own short one:
  # hyphens stripped to pack more of the case id in, "ir" prefixed so the
  # result can never be all-numeric (which Windows rejects), truncated to 15.
  #
  # Truncation means two very long, similarly-prefixed case ids could produce
  # the same Windows hostname. That is cosmetic here - these hosts are never
  # domain-joined and each lives in its own resource group - but set
  # var.computer_name explicitly if you need them distinct.
  derived_computer_name = substr("ir${replace(var.case_id, "-", "")}", 0, 15)
  computer_name         = var.computer_name != "" ? var.computer_name : local.derived_computer_name

  use_rdp_allowlist = var.access_method == "rdp-allowlist"
  use_tools_storage = var.tools_storage_account_id != ""

  # "<account>/<container>", or "" when no tools storage is configured -
  # parsed by bootstrap-investigation-host.ps1 the same way the evidence
  # identifier is. The account name is the last segment of the resource ID.
  tools_identifier = local.use_tools_storage ? format(
    "%s/%s",
    element(split("/", var.tools_storage_account_id), length(split("/", var.tools_storage_account_id)) - 1),
    var.tools_container_name
  ) : ""
}

# Only for the rdp-allowlist access method. This public IP does double duty:
# it is the address you RDP to, AND it gives the VM outbound internet access.
# That second job matters more than it looks - Microsoft's default outbound
# access is being withdrawn ("for the API released after March 31, 2026, new
# virtual networks default to using private subnets"), so a VM with no public
# IP now needs an explicit egress path (NAT Gateway) or the bootstrap script
# cannot download anything. With the bastion access method you must provide
# that egress yourself; here the public IP covers it.
resource "azurerm_public_ip" "host" {
  count               = local.use_rdp_allowlist ? 1 : 0
  name                = "pip-ir-case-${var.case_id}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# An NSG is MANDATORY on the rdp-allowlist path, not optional hardening: a VM
# with a public IP and no NSG attached has no inbound filtering at all. Azure's
# built-in DenyAllInBound rule (priority 65500) then blocks everything, and the
# single allow rule is added out-of-band, just-in-time, by
# Connect-InvestigationHost.ps1.
#
# `security_rule` is deliberately NOT set here. Per the azurerm provider's own
# note, inline rules are only cleared when explicitly set to an empty slice -
# omitting the attribute leaves out-of-band rules alone. That is what lets the
# connect script add and remove the JIT rule in seconds via `az` without
# Terraform reverting it on the next apply.
resource "azurerm_network_security_group" "host" {
  count               = local.use_rdp_allowlist ? 1 : 0
  name                = "nsg-ir-case-${var.case_id}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Under the bastion access method the NIC gets no public IP at all - the
# shared Bastion reaches this VM over its private IP within the VNet, so
# nothing inbound is ever exposed.
resource "azurerm_network_interface" "host" {
  name                = "ir-case-${var.case_id}-nic"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = local.use_rdp_allowlist ? azurerm_public_ip.host[0].id : null
  }

  tags = var.tags
}

resource "azurerm_network_interface_security_group_association" "host" {
  count                     = local.use_rdp_allowlist ? 1 : 0
  network_interface_id      = azurerm_network_interface.host.id
  network_security_group_id = azurerm_network_security_group.host[0].id
}

resource "azurerm_windows_virtual_machine" "host" {
  name                = "ir-case-${var.case_id}"
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = var.vm_size
  computer_name       = local.computer_name
  admin_username      = var.admin_username
  admin_password      = var.admin_password

  network_interface_ids = [azurerm_network_interface.host.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }

  identity {
    type = "SystemAssigned"
  }

  tags = merge(var.tags, {
    CaseId  = var.case_id
    Purpose = "ir-investigation-host"
  })
}

# Read-only, and only on this one case's storage account - the investigation
# host never needs write access to case evidence, and never needs to see
# any other case's storage.
resource "azurerm_role_assignment" "case_storage_read" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_windows_virtual_machine.host.identity[0].principal_id
}

# Read-only on the shared tooling account, exactly as for case evidence -
# the host never writes to it. Separate assignment from the case-storage one
# so revoking either is independent.
resource "azurerm_role_assignment" "tools_storage_read" {
  count                = local.use_tools_storage ? 1 : 0
  scope                = var.tools_storage_account_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_windows_virtual_machine.host.identity[0].principal_id
}

# Windows VMs on Azure do not auto-run custom_data the way Linux cloud-init
# does - the Custom Script Extension is the actually-reliable mechanism.
# fileUris downloads the shared fetcher script; commandToExecute runs it
# with this case's parameters.
resource "azurerm_virtual_machine_extension" "bootstrap" {
  name                       = "bootstrap-investigation-host"
  virtual_machine_id         = azurerm_windows_virtual_machine.host.id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    fileUris = [local.fetch_script_url]
  })

  # Values are wrapped in ESCAPED DOUBLE quotes, not single quotes.
  # commandToExecute runs through cmd.exe, which does not treat the
  # apostrophe as a quote character - single-quoted values therefore arrive
  # at the script with the apostrophes still attached, and the first thing
  # that actually parses its input blows up. Confirmed directly: passing
  # -RepoZipUrl with single quotes yielded a URI whose Host was empty, i.e.
  # Invoke-WebRequest's "Invalid URI: The hostname could not be parsed".
  protected_settings = jsonencode({
    commandToExecute = "powershell -ExecutionPolicy Bypass -File fetch-and-bootstrap.ps1 -CaseId \"${var.case_id}\" -CloudProvider Azure -StorageIdentifier \"${var.storage_account_name}/${var.container_name}\" -Region \"${var.location}\" -RepoZipUrl \"${local.repo_zip_url}\" -ToolsStorageIdentifier \"${local.tools_identifier}\" -ToolsZipUrl \"${var.tools_zip_url}\""
  })

  # Both role assignments must exist before the script runs - it authenticates
  # to storage with the managed identity these grant.
  depends_on = [
    azurerm_role_assignment.case_storage_read,
    azurerm_role_assignment.tools_storage_read,
  ]
}

# NOTE: this module no longer creates a Bastion.
#
# Bastion is deployed ONCE per virtual network by
# infra/environments/azure-bastion/, not per case, because Azure allows
# only one Bastion per VNet (its subnet must be named exactly
# "AzureBastionSubnet", and subnet names are unique within a VNet). A
# per-case Bastion would therefore make a second concurrent case in the
# same VNet fail outright. See that environment's main.tf for the full
# rationale, including why it uses the Standard SKU (native-client RDP
# needs tunneling, which is Standard+) and what it costs per hour.
#
# This module just carries the shared Bastion's identity through to the
# outputs so Connect-InvestigationHost.ps1 knows what to connect through.

data "azurerm_client_config" "current" {}
