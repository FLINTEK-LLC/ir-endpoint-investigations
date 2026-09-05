# One resource group + storage account per case, mirroring the AWS module's
# one-bucket-per-case isolation - see infra/SECURITY.md for the rationale.
resource "azurerm_resource_group" "case" {
  name     = "rg-ir-case-${var.case_id}"
  location = var.location

  tags = merge(var.tags, {
    CaseId  = var.case_id
    Purpose = "ir-case-evidence"
  })
}

# Storage account names are globally unique across ALL of Azure, 3-24 chars,
# lowercase letters/numbers only (no hyphens) - a short case_id like "case1"
# is very plausible to collide with someone else's account somewhere, so a
# random suffix is appended rather than relying on case_id alone.
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  # Strip anything a storage account name can't contain, then truncate so
  # "st" + sanitized case_id + 8-char hex suffix stays within 24 chars.
  sanitized_case_id    = substr(replace(lower(var.case_id), "/[^a-z0-9]/", ""), 0, 14)
  storage_account_name = "st${local.sanitized_case_id}${random_id.suffix.hex}"
}

resource "azurerm_storage_account" "case" {
  name                = local.storage_account_name
  resource_group_name = azurerm_resource_group.case.name
  location            = azurerm_resource_group.case.location

  account_tier             = "Standard"
  account_replication_type = "LRS" # Cheapest viable option - single-region is fine for
  # working case storage; the archive tier transition
  # below is the actual long-term durability story.
  account_kind = "StorageV2"

  min_tls_version            = "TLS1_2"
  https_traffic_only_enabled = true
  # Reachable from the public internet, because the collector uploads from
  # wherever the compromised endpoint is and the investigation host mounts
  # over the public endpoint. Access is gated by Entra ID RBAC and the
  # collector's short-lived user-delegation SAS - NOT by any network
  # restriction. There are deliberately no network_rules here: locking the
  # data plane to a VNet or IP range would break collector uploads from
  # arbitrary networks, which is the whole point of an offline collector.
  #
  # If your collectors only ever run inside known networks, adding a
  # network_rules block with default_action = "Deny" plus explicit
  # ip_rules/virtual_network_subnet_ids is a real hardening win. It is not
  # the default because it cannot be made to fit every deployment.
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false

  # NOTE: this is NOT required by the collector's upload SAS.
  # New-CaseCollector.ps1 mints a *user-delegation* SAS
  # (`az storage container generate-sas --auth-mode login --as-user`),
  # which is signed with an Entra ID key, not the storage account key -
  # so the collector path works with shared keys disabled.
  # Setting this to false is a real hardening win (it removes the
  # account-key credential entirely), but it can break Terraform's own
  # management of azurerm_storage_container / management policy depending
  # on provider version and the operator's data-plane role assignments,
  # which cannot be verified here without a live subscription. Left
  # enabled as the safe default; see infra/SECURITY.md for how to turn it
  # off once you have a working deployment to test against.
  shared_access_key_enabled = true

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }
  }

  tags = merge(var.tags, {
    CaseId  = var.case_id
    Purpose = "ir-case-evidence"
  })
}

resource "azurerm_storage_container" "case" {
  name                  = "ir-case-${var.case_id}"
  storage_account_id    = azurerm_storage_account.case.id
  container_access_type = "private"
}

# Time-based immutability policy - the Azure equivalent of S3 Object Lock.
# Only created when this case opts into it. An "unlocked" policy (state
# starts as Unlocked) can still be shortened/deleted by an authorized
# principal - promoting it to Locked (irreversible) is a separate, deliberate
# action outside Terraform, matching the GOVERNANCE/COMPLIANCE split
# documented on the retention_mode variable.
resource "azurerm_storage_container_immutability_policy" "case" {
  count                                 = var.enable_immutability ? 1 : 0
  storage_container_resource_manager_id = azurerm_storage_container.case.id
  immutability_period_in_days           = var.retention_days
  protected_append_writes_enabled       = false
}

# Cheap-while-active, cheaper-once-archived: Hot tier during the case,
# Archive after archive_after_days.
resource "azurerm_storage_management_policy" "case" {
  storage_account_id = azurerm_storage_account.case.id

  rule {
    name    = "archive-after-close"
    enabled = true
    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["${azurerm_storage_container.case.name}/"]
    }
    actions {
      base_blob {
        tier_to_archive_after_days_since_modification_greater_than = var.archive_after_days
      }
    }
  }
}

# Off unless diagnostic_workspace_id is set - see that variable for why.
# Scoped to the blob service, not the account: the account-level resource
# emits control-plane events, and the question here is who touched the data.
resource "azurerm_monitor_diagnostic_setting" "case_blob" {
  count = var.diagnostic_workspace_id == "" ? 0 : 1

  name                       = "ir-case-${var.case_id}-blob-audit"
  target_resource_id         = "${azurerm_storage_account.case.id}/blobServices/default"
  log_analytics_workspace_id = var.diagnostic_workspace_id

  enabled_log {
    category = "StorageRead"
  }
  enabled_log {
    category = "StorageWrite"
  }
  enabled_log {
    category = "StorageDelete"
  }
}
