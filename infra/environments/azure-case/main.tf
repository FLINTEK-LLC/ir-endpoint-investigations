terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
}

locals {
  tags = {
    ManagedBy = "ir-endpoint-investigations-infra"
    CaseId    = var.case_id
  }
}

module "case_storage" {
  source = "../../modules/azure/case-storage"

  case_id                 = var.case_id
  location                = var.location
  enable_immutability     = var.enable_immutability
  retention_days          = var.retention_days
  retention_mode          = var.retention_mode
  archive_after_days      = var.archive_after_days
  diagnostic_workspace_id = var.diagnostic_workspace_id
  tags                    = local.tags
}

# Generated, never hand-typed into a committed .tfvars file. This IS the
# credential you sign in to Windows with - Bastion brokers the network path
# but does not authenticate you to the VM - so Connect-InvestigationHost.ps1
# reads it back out of state and prints it at connect time. See
# infra/SECURITY.md ("The initial Windows login itself").
#
# override_special mirrors the AWS module's conservative set. Azure takes
# this over the ARM API rather than through a shell, so it has none of the
# AWS side's PowerShell-embedding hazard, but Azure does reject a handful of
# characters in VM admin passwords and keeping one shared, known-safe set
# across both clouds is cheaper than reasoning about two.
resource "random_password" "admin" {
  length           = 24
  special          = true
  override_special = "!#%*+,-./:;=?@^_~"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

module "investigation_host" {
  source = "../../modules/azure/investigation-host"

  case_id                     = var.case_id
  resource_group_name         = module.case_storage.resource_group_name
  location                    = var.location
  storage_account_id          = module.case_storage.storage_account_id
  storage_account_name        = module.case_storage.storage_account_name
  container_name              = module.case_storage.container_name
  vm_size                     = var.vm_size
  admin_password              = random_password.admin.result
  subnet_id                   = var.subnet_id
  access_method               = var.access_method
  timezone_id                 = var.timezone_id
  tools_storage_account_id    = var.tools_storage_account_id
  tools_container_name        = var.tools_container_name
  tools_zip_url               = var.tools_zip_url
  bastion_name                = var.bastion_name
  bastion_resource_group_name = var.bastion_resource_group_name
  tags                        = local.tags
}
