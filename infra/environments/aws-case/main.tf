terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

locals {
  tags = {
    ManagedBy = "ir-endpoint-investigations-infra"
    CaseId    = var.case_id
  }
}

module "case_storage" {
  source = "../../modules/aws/case-storage"

  case_id             = var.case_id
  enable_immutability = var.enable_immutability
  retention_days      = var.retention_days
  retention_mode      = var.retention_mode
  archive_after_days  = var.archive_after_days
  access_log_bucket   = var.access_log_bucket
  tags                = local.tags
}

module "case_role" {
  source = "../../modules/aws/case-role"

  case_id    = var.case_id
  bucket_arn = module.case_storage.bucket_arn
  tags       = local.tags
}

# Generated, never hand-typed into a committed .tfvars file - there is no
# key pair on this instance (SSM Session Manager is the sole connection
# path), so this is set directly via user_data instead of the usual
# key-pair-encrypted GetPasswordData flow.
#
# override_special still excludes quote/backtick/dollar-sign/backslash. The
# password is no longer embedded in user_data (it goes to SSM Parameter Store
# and the host fetches it with its own role), but it still transits the AWS
# CLI and JSON on the way back out, so keeping the character set boring avoids
# a whole class of quoting problems for no practical loss of entropy at 24
# characters.
resource "random_password" "admin" {
  length           = 24
  special          = true
  override_special = "!#%*+,-./:;=?@^_~"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

# (case_storage is configured above; access logging is opt-in.)
module "investigation_host" {
  source = "../../modules/aws/investigation-host"

  case_id           = var.case_id
  bucket_name       = module.case_storage.bucket_name
  bucket_arn        = module.case_storage.bucket_arn
  vpc_id            = var.vpc_id
  subnet_id         = var.subnet_id
  instance_type     = var.instance_type
  tools_bucket_name = var.tools_bucket_name
  tools_zip_url     = var.tools_zip_url
  timezone_id       = var.timezone_id
  admin_password    = random_password.admin.result
  tags              = local.tags
}
