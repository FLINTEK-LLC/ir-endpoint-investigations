variable "case_id" {
  description = "Case identifier - used to name and tag this host."
  type        = string
}

variable "bucket_name" {
  description = "This case's S3 bucket name (from the case-storage module) - the instance role is scoped to read-only access on exactly this bucket, nothing else."
  type        = string
}

variable "bucket_arn" {
  description = "This case's S3 bucket ARN (from the case-storage module)."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. Small/burstable by default - this is meant to be spun up per case and destroyed when idle, not sized for the largest possible collection up front. Size up per case if a specific investigation needs it."
  type        = string
  default     = "t3.xlarge" # 4 vCPU / 16 GiB - enough headroom for KAPE/EZ Tools/
  # Hayabusa/Chainsaw against a typical collection
  # without paying for a bigger box by default.
}

variable "windows_ami_ssm_parameter" {
  description = <<-EOT
    AWS-managed SSM public parameter naming the Windows AMI to launch.
    Defaults to Windows Server 2025. Using the parameter rather than a
    hardcoded AMI ID means the host always launches on the current patched
    image for the region.

    VERIFY before a first run - AWS's 2025 parameter list could not be fully
    confirmed from documentation while this was written (the 2025
    Core-Base and STIG variants are documented; Full-Base follows AWS's
    consistent naming but was not seen verbatim). Check with:

      aws ssm get-parameters-by-path --path /aws/service/ami-windows-latest --query "Parameters[?contains(Name,'2025-English-Full')].Name" --output text

    Fall back to Windows_Server-2022-English-Full-Base if 2025 is not yet
    published in your region.
  EOT
  type        = string
  default     = "/aws/service/ami-windows-latest/Windows_Server-2025-English-Full-Base"
}

variable "root_volume_size_gb" {
  description = "Root (C:) volume size in GB - holds the OS, the KAPE/EZ Tools/Sysinternals/Autopsy toolkit, and Windows temp/paging space. Case evidence itself lives on the separately-mounted case bucket, not this volume."
  type        = number
  default     = 150
}

variable "tools_bucket_name" {
  description = "OPTIONAL S3 bucket holding licensed tooling this host cannot download itself - in practice KAPE, which Kroll gates behind licence acceptance. Blank (the default) means the host comes up without KAPE and without the parsing toolchain that depends on it. Deliberately NOT this case's evidence bucket: tooling in an evidence bucket muddies chain of custody, inherits any Object Lock retention, and gets lifecycle-transitioned to Glacier. The instance role is granted read-only on this bucket alone."
  type        = string
  default     = ""
}

variable "tools_zip_url" {
  description = "OPTIONAL fallback to tools_bucket_name: any URL the host can fetch kape.zip from without interactive sign-in (an internal artifact repo, a pre-signed S3 URL). If the URL carries its own authorisation it lands in Terraform state, so prefer tools_bucket_name where you can."
  type        = string
  default     = ""
  sensitive   = true
}

variable "timezone_id" {
  description = "Windows time zone ID. UTC by default, and deliberately so - a forensic host should record in UTC so timelines from endpoints in different zones line up and report timestamps are unambiguous. `tzutil /l` lists valid IDs."
  type        = string
  default     = "UTC"
}

variable "vpc_id" {
  description = "VPC to launch into."
  type        = string
}

variable "subnet_id" {
  description = "Subnet to launch into - must have a route to the internet (NAT or IGW) for the SSM agent, and for the bootstrap script to reach GitHub/this repo/Chocolatey-style downloads. No public IP is assigned regardless (see main.tf) - SSM's outbound connection doesn't need one, but the bootstrap script's downloads do need real internet egress, so this cannot be a fully isolated subnet."
  type        = string
}

variable "admin_password" {
  description = "Password for the local interactive account, generated once by the root module (random_password). Written to SSM Parameter Store as a SecureString and fetched by the instance at first boot using its own role - NOT embedded in user_data, which any process on the host can read from the metadata service. This host launches with no EC2 key pair, since SSM Session Manager is the sole connection path and a key pair for the usual GetPasswordData flow would be unused overhead."
  type        = string
  sensitive   = true
}

variable "admin_username" {
  description = "Local account created for interactive sign-in, added to Administrators. Deliberately NOT the built-in Administrator: a named account keeps the built-in one disabled, makes 4624/4625 logon events on the host attributable to this toolkit rather than blending into a well-known SID, and avoids the automated password-guessing that targets the built-in name."
  type        = string
  default     = "iranalyst"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,19}$", var.admin_username))
    error_message = "admin_username must be 3-20 chars, lowercase letters/digits/hyphens, starting with a letter."
  }
}

variable "repo_ref" {
  description = <<-EOT
    Git ref the investigation host fetches its bootstrap from: a commit SHA
    (recommended), a tag, or a branch name.

    Defaults to a pinned commit, NOT to "main", on purpose. The host downloads
    this code at first boot and runs it as SYSTEM, so whatever the ref points
    at is what executes on a machine that then mounts case evidence. A mutable
    branch means anyone who can push to it changes that code for every host
    built afterwards, with nothing to detect it. It also means two hosts built
    a week apart from identical case settings can run different code, which
    defeats the point of a reproducible investigation environment.

    Bump this deliberately when you want new hosts to pick up repo changes.
    A branch name still works if you accept those trade-offs.
  EOT
  type        = string
  default     = "b7f8d5333de7d7d340fb00237af86a26ec564acf"
}

variable "case_repo_git_url" {
  description = "Git URL for ir-endpoint-investigations, cloned by the bootstrap script so it can call Setup-Workstation.ps1. Override if you maintain a fork."
  type        = string
  default     = "https://github.com/FLINTEK-LLC/ir-endpoint-investigations.git"
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
