variable "case_id" {
  description = "Case identifier - used to name the bucket (ir-case-<case_id>). Keep it short, lowercase, DNS-safe (letters, numbers, hyphens)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$", var.case_id))
    error_message = "case_id must be 3-42 chars, lowercase letters/numbers/hyphens only, and not start or end with a hyphen (S3 bucket naming rules)."
  }
}

variable "enable_immutability" {
  description = "Enable S3 Object Lock (WORM) on this case's bucket. Must be decided at creation - Object Lock cannot be added to an existing bucket. Decide per case; there is no safe default that fits every case."
  type        = bool
}

variable "retention_days" {
  description = "Default Object Lock retention period in days, applied to every object version. Only used when enable_immutability is true."
  type        = number
  default     = 90
}

variable "retention_mode" {
  description = "Object Lock mode: GOVERNANCE (an authorized principal with s3:BypassGovernanceRetention can override it - recoverable if you lock yourself out) or COMPLIANCE (nobody, including the account root, can shorten or remove it before retention_days elapses - stricter chain-of-custody guarantee, no undo). GOVERNANCE is the safer default while you're still getting comfortable with this; switch to COMPLIANCE per case if your chain-of-custody requirements call for it."
  type        = string
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.retention_mode)
    error_message = "retention_mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "archive_after_days" {
  description = "Days after object creation before transitioning to Glacier (cold storage) - the 'archive when the case closes' step. Set well beyond your expected active-investigation window; the transition is a one-way trip back to slow/expensive retrieval."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}

variable "access_log_bucket" {
  description = <<-EOT
    OPTIONAL name of an existing bucket to write S3 server access logs to.
    Empty (the default) means no access logging.

    Versioning and Object Lock already make this bucket tamper-resistant, but
    neither records who READ the evidence. If you ever need to answer "who
    pulled this collection, and when", that answer has to be written down at
    the time; it cannot be reconstructed afterwards.

    Off by default because it needs a second bucket with a log-delivery policy
    already in place, which not every deployment will have, and because the
    log bucket must NOT be this bucket (S3 rejects same-bucket logging that
    would recurse). Point it at a long-lived audit bucket you control.
  EOT
  type        = string
  default     = ""
}

variable "access_log_prefix" {
  description = "Key prefix for access logs when access_log_bucket is set."
  type        = string
  default     = ""
}
