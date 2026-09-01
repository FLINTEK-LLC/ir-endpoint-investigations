# Always the current Windows Server AMI in this region, not a hardcoded ID
# that goes stale and eventually gets deprecated out from under this module.
data "aws_ssm_parameter" "windows_ami" {
  name = var.windows_ami_ssm_parameter
}

data "aws_region" "current" {}

locals {
  # Derived once so both the "fetch the tiny bootstrapper" URL and the "repo
  # zip the bootstrapper itself downloads" URL stay consistent for a fork -
  # override just case_repo_git_url and both follow.
  repo_base_https = trimsuffix(var.case_repo_git_url, ".git")
  repo_raw_base   = replace(local.repo_base_https, "github.com", "raw.githubusercontent.com")
  repo_zip_url    = "${local.repo_base_https}/archive/refs/heads/main.zip"
}

# --- IAM: instance role scoped to exactly this case's bucket, nothing else ---
resource "aws_iam_role" "host" {
  name = "ir-case-${var.case_id}-host"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

# SSM Session Manager access - this is what makes the "no open RDP port"
# connection model work. No other AWS-managed policy is attached; every
# other permission this role has is the narrowly-scoped inline policy below.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Read-only, and only on this one case's bucket - the investigation host
# never needs write access to case evidence, and never needs to see any
# other case's bucket.
resource "aws_iam_role_policy" "case_bucket_read" {
  name = "case-bucket-read"
  role = aws_iam_role.host.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [var.bucket_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${var.bucket_arn}/*"]
      }
    ]
  })
}

# Read-only on the shared tooling bucket, exactly as for case evidence. A
# separate policy from the case-bucket one so revoking either is independent.
resource "aws_iam_role_policy" "tools_bucket_read" {
  count = var.tools_bucket_name != "" ? 1 : 0
  name  = "tools-bucket-read"
  role  = aws_iam_role.host.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = ["arn:aws:s3:::${var.tools_bucket_name}"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["arn:aws:s3:::${var.tools_bucket_name}/*"]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "host" {
  name = "ir-case-${var.case_id}-host"
  role = aws_iam_role.host.name
}

# No inbound rules at all - SSM's connection is outbound-only from the
# instance, so there is nothing to open. Standard egress-all for the
# bootstrap script's downloads and the SSM agent's own outbound calls.
resource "aws_security_group" "host" {
  name        = "ir-case-${var.case_id}-host"
  description = "Investigation host for case ${var.case_id} - no inbound rules; access is via SSM Session Manager only"
  vpc_id      = var.vpc_id

  egress {
    description = "All outbound - SSM agent, toolkit downloads, case data access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_instance" "host" {
  ami                    = data.aws_ssm_parameter.windows_ami.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.host.id]
  iam_instance_profile   = aws_iam_instance_profile.host.name

  # No public IP - SSM does not need one, and this host has no business
  # being directly reachable from the internet.
  associate_public_ip_address = false

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true # This disk only ever holds the OS + toolkit,
    # never case evidence - nothing here needs to
    # survive the instance being destroyed.
  }

  user_data = templatefile("${path.module}/user_data.ps1.tftpl", {
    fetch_script_url = "${local.repo_raw_base}/main/infra/scripts/fetch-and-bootstrap.ps1"
    repo_zip_url     = local.repo_zip_url
    case_id          = var.case_id
    bucket_name      = var.bucket_name
    region           = data.aws_region.current.name
    admin_password   = var.admin_password
    tools_bucket     = var.tools_bucket_name
    tools_zip_url    = var.tools_zip_url
    timezone_id      = var.timezone_id
  })

  tags = merge(var.tags, {
    Name    = "ir-case-${var.case_id}-investigation-host"
    CaseId  = var.case_id
    Purpose = "ir-investigation-host"
  })
}
