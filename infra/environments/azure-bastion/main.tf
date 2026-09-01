# Shared Azure Bastion (Standard SKU) for one virtual network.
#
# WHY THIS IS SEPARATE FROM A CASE, and not created per case:
#
#   1. Azure requires the Bastion subnet to be named exactly
#      "AzureBastionSubnet". Subnet names are unique within a virtual
#      network, so a VNet can host exactly ONE Bastion. If each case
#      created its own, the second concurrent case in the same VNet would
#      fail on a duplicate subnet - which would break the whole per-case
#      workspace model this project is built around.
#   2. Bastion is VNet-level shared infrastructure by design - one Bastion
#      already serves every VM in the VNet, which is exactly what a
#      multi-case workflow wants.
#   3. It bills hourly whether or not anyone is connected ($0.29/hr for
#      Standard in eastus per Azure's retail pricing API at time of
#      writing - roughly $7/day, ~$212/month if left running). Keeping it
#      in its own state makes "turn it on for the engagement, turn it off
#      after" a single explicit action instead of something buried in a
#      case's lifecycle. Start-CloudConsole.ps1's [8]/[9] do exactly that.
#
# Standard SKU (not the free Developer SKU) is deliberate: native-client
# RDP - `az network bastion rdp`, i.e. a real mstsc session - requires
# tunneling_enabled, which the provider only supports on Standard/Premium.
# Microsoft's own native-client docs: "Native client support requires the
# Standard SKU or higher." The free Developer SKU is browser-only.

terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

locals {
  # Azure requires the Bastion host, its subnet, and the VNet to share a
  # resource group ("The subnet must be in the same virtual network and
  # resource group as the bastion host" - Bastion configuration-settings
  # docs). A subnet always lives in its VNet's resource group, so the
  # Bastion and its public IP are deployed into the VNet's resource group
  # too - NOT into a per-case resource group.
  #
  # VNet resource ID shape:
  #   /subscriptions/S/resourceGroups/RG/providers/Microsoft.Network/virtualNetworks/NAME
  #    [0]        [1]    [2]      [3]  [4]   [5]        [6]              [7]        [8]
  vnet_parts               = split("/", var.virtual_network_id)
  vnet_resource_group_name = local.vnet_parts[4]
  vnet_name                = local.vnet_parts[8]

  tags = merge(var.tags, {
    ManagedBy = "ir-endpoint-investigations-infra"
    Purpose   = "ir-shared-bastion"
  })
}

# Name is mandated by Azure - it cannot be anything else.
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = local.vnet_resource_group_name
  virtual_network_name = local.vnet_name
  address_prefixes     = [var.bastion_subnet_prefix]
}

# Standard SKU Bastion requires a Standard, statically-allocated public IP.
# This is the Bastion service's own front door, NOT a public IP on the
# investigation host - that VM still has no public IP and no inbound rule.
resource "azurerm_public_ip" "bastion" {
  name                = "pip-ir-bastion-${local.vnet_name}"
  resource_group_name = local.vnet_resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_bastion_host" "shared" {
  name                = "bast-ir-${local.vnet_name}"
  resource_group_name = local.vnet_resource_group_name
  location            = var.location
  sku                 = "Standard"

  # THE reason this is Standard rather than the free Developer SKU. Without
  # it, `az network bastion rdp` does not work and Connect-InvestigationHost.ps1
  # falls back to a browser-only portal link.
  tunneling_enabled = true

  # 2 is the provider minimum and the cheapest Standard configuration;
  # additional scale units bill separately ($0.14/hr each in eastus).
  # One analyst on one case does not need more.
  scale_units = 2

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }

  tags = local.tags
}
