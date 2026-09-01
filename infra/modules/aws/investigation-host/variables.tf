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

variable "vpc_id" {
  description = "VPC to launch into."
  type        = string
}

variable "subnet_id" {
  description = "Subnet to launch into - must have a route to the internet (NAT or IGW) for the SSM agent, and for the bootstrap script to reach GitHub/this repo/Chocolatey-style downloads. No public IP is assigned regardless (see main.tf) - SSM's outbound connection doesn't need one, but the bootstrap script's downloads do need real internet egress, so this cannot be a fully isolated subnet."
  type        = string
}

variable "admin_password" {
  description = "Local Administrator password, generated once by the root module (random_password) and set directly via user_data - this host launches with no EC2 key pair (SSM Session Manager is the sole connection path, so a key pair for the usual GetPasswordData decryption flow would be unused overhead). The root module restricts this to a safe character set (see its own random_password.admin comment) specifically because it gets embedded literally inside a double-quoted PowerShell string in user_data.ps1.tftpl - an unrestricted special character (particularly a literal quote) would break that script outright."
  type        = string
  sensitive   = true
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
