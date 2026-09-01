variable "case_id" {
  description = "Case identifier - names every resource (ir-case-<case_id>)."
  type        = string
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
