variable "case_id" {
  description = "Case identifier - names this role (ir-case-<case_id>-uploader)."
  type        = string
}

variable "bucket_arn" {
  description = "This case's S3 bucket ARN (from the case-storage module) - the role's permission policy is scoped to exactly this bucket, write-only."
  type        = string
}

variable "tags" {
  description = "Tags applied to this role."
  type        = map(string)
  default     = {}
}
