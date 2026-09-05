variable "case_id" {
  description = "Case identifier - names every resource (ir-case-<case_id>)."
  type        = string

  # Same rule Start-CloudConsole.ps1's Read-CaseId enforces, repeated here
  # because the console is not the only supported entry point - the docs
  # explicitly invite running terraform directly. case_id is interpolated
  # into code that executes as SYSTEM on the investigation host (AWS
  # user_data, Azure commandToExecute), so an unvalidated value is a template
  # injection vector, not just a naming problem.
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$", var.case_id))
    error_message = "case_id must be 3-42 chars, lowercase letters/digits/hyphens only, and may not start or end with a hyphen."
  }
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to authenticate with - see infra/README.md's \"Accounts, tokens, and secrets\" section. Defaults to the profile Test-Prerequisites.ps1/Start-CloudConsole.ps1 guide you to create."
  type        = string
  default     = "ir-cloud"
}

variable "vpc_id" {
  description = "VPC to launch the investigation host into. Must have a subnet with internet egress (NAT/IGW) - see the investigation-host module's subnet_id description for why."
  type        = string
}

variable "subnet_id" {
  description = "Subnet (within vpc_id) to launch the investigation host into."
  type        = string
}

variable "tools_bucket_name" {
  description = "OPTIONAL S3 bucket holding your licensed KAPE as kape.zip. Blank means the host comes up without KAPE and without the parsing toolchain. Must NOT be this case's evidence bucket - see infra/README.md's Getting KAPE onto the host."
  type        = string
  default     = ""
}

variable "tools_zip_url" {
  description = "OPTIONAL fallback to tools_bucket_name: any URL reachable without interactive sign-in."
  type        = string
  default     = ""
  sensitive   = true
}

variable "timezone_id" {
  description = "Windows time zone for the investigation host. UTC by default - the right default for forensic work."
  type        = string
  default     = "UTC"
}

variable "enable_immutability" {
  description = "Enable S3 Object Lock (WORM) on this case's bucket. No default - decide deliberately per case."
  type        = bool
}

variable "retention_days" {
  description = "Object Lock retention period in days, if enable_immutability is true."
  type        = number
  default     = 90
}

variable "retention_mode" {
  description = "GOVERNANCE (recoverable) or COMPLIANCE (irreversible) - see the case-storage module's variable description."
  type        = string
  default     = "GOVERNANCE"
}

variable "archive_after_days" {
  description = "Days of case-open activity before evidence transitions to Glacier."
  type        = number
  default     = 30
}

variable "instance_type" {
  description = "Investigation host EC2 instance type."
  type        = string
  default     = "t3.xlarge"
}

variable "access_log_bucket" {
  description = "OPTIONAL existing bucket for S3 server access logs on this case's evidence bucket. Empty disables access logging - see the case-storage module variable for the trade-off."
  type        = string
  default     = ""
}
