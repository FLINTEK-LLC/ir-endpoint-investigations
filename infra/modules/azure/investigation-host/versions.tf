terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    # azapi is no longer needed here: it existed solely to create the
    # Developer-SKU Bastion, which has moved to
    # infra/environments/azure-bastion/ and uses the native
    # azurerm_bastion_host resource (which does support Standard).
  }
}
