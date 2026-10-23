terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region              = "eu-west-2"
  allowed_account_ids = [var.account_id]
  default_tags {
    tags = { Project = "iseeyou", Purpose = "TerraformBootstrap" }
  }
}

variable "account_id" {
  type    = string
  default = "885625664603"
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Use a twelve-digit AWS account ID."
  }
}

locals {
  bucket_name = "iseeyou-terraform-state-${var.account_id}-eu-west-2"
  bucket_arn  = "arn:aws:s3:::${local.bucket_name}"
  subject     = "repo:abdulsalamk@6270608/iseeyou@1427983832:ref:refs/heads/main"
}

resource "aws_s3_bucket" "state" {
  bucket        = local.bucket_name
  force_destroy = false
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport", Effect = "Deny", Principal = "*", Action = "s3:*"
      Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  lifecycle { prevent_destroy = true }
}

resource "aws_iam_role" "github" {
  name                 = "iseeyou-github-terraform"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = local.subject
      } }
    }]
  })
}

resource "aws_iam_role_policy" "state" {
  name = "TerraformStateAccess"
  role = aws_iam_role.github.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "ReadStateBucketConfiguration", Effect = "Allow", Resource = local.bucket_arn,
      Action = ["s3:GetBucketLocation", "s3:GetBucketVersioning", "s3:GetEncryptionConfiguration", "s3:GetBucketPublicAccessBlock"] },
      { Sid = "ListProjectState", Effect = "Allow", Action = "s3:ListBucket", Resource = local.bucket_arn,
      Condition = { StringLike = { "s3:prefix" = ["bootstrap/*", "states/iseeyou/*"] } } },
      { Sid = "ReadWriteState", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"],
      Resource = ["${local.bucket_arn}/bootstrap/terraform.tfstate", "${local.bucket_arn}/states/iseeyou/*"] },
      { Sid = "ManageStateLocksAndSmokeTest", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      Resource = ["${local.bucket_arn}/bootstrap/terraform.tfstate.tflock", "${local.bucket_arn}/states/iseeyou/*.tflock", "${local.bucket_arn}/bootstrap/checks/*"] }
    ]
  })
}

output "state_bucket" { value = aws_s3_bucket.state.id }
output "github_role_arn" { value = aws_iam_role.github.arn }
