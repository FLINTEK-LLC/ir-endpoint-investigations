variable "case_id" {
  description = "Case identifier - used to name the resource group and blob container (ir-case-<case_id>). Keep it short, lowercase, DNS-safe (letters, numbers, hyphens)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$", var.case_id))
    error_message = "case_id must be 3-42 chars, lowercase letters/numbers/hyphens only, and not start or end with a hyphen."
  }
}

variable "location" {
  description = "Azure region, e.g. eastus."
  type        = string
}

variable "enable_immutability" {
  description = "Enable a time-based immutability (WORM) policy on this case's blob container. Decide per case; there is no safe default that fits every case."
  type        = bool
}

variable "retention_days" {
  description = "Immutability retention period in days. Only used when enable_immutability is true."
  type        = number
  default     = 90
}

variable "retention_mode" {
  description = "GOVERNANCE (unlocked policy - an authorized principal can still shorten or remove it; recoverable if you lock yourself out) or COMPLIANCE (locked policy - irreversible once Azure's 24-hour grace period elapses, nobody can shorten or remove it before retention_days). GOVERNANCE is the safer default while you're still getting comfortable with this; switch to COMPLIANCE per case if your chain-of-custody requirements call for it. Named to match the AWS module's equivalent variable, not native Azure terminology."
  type        = string
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.retention_mode)
    error_message = "retention_mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "archive_after_days" {
  description = "Days after object creation before transitioning to the Archive tier (cold storage) - the 'archive when the case closes' step. Set well beyond your expected active-investigation window; rehydrating from Archive is slow and has its own cost."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}

variable "diagnostic_workspace_id" {
  description = <<-EOT
    OPTIONAL Log Analytics workspace resource ID to send blob data-plane
    diagnostics to. Empty (the default) means no diagnostic logging.

    Blob versioning and the immutability policy protect the evidence from
    being changed; they do not record who read it. StorageRead/StorageWrite/
    StorageDelete on the blob service is what answers that, and it has to be
    enabled before the access happens.

    Off by default because it requires a workspace that outlives the case -
    sending a case's audit trail to a workspace destroyed with the case would
    be pointless.
  EOT
  type        = string
  default     = ""
}
