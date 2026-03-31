terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Networking — VPC, private subnets, security groups, VPC endpoints.
# ---------------------------------------------------------------------------

module "networking" {
  source = "../../modules/networking"

  name_prefix          = local.name_prefix
  vpc_cidr             = var.vpc_cidr
  private_subnet_cidrs = var.private_subnet_cidrs
  tags                 = local.common_tags
}

# ---------------------------------------------------------------------------
# KMS — Platform storage encryption key.
# Lives in foundation so it survives platform/tools/agents destroy cycles.
# ---------------------------------------------------------------------------

module "kms" {
  source = "../../modules/kms"

  project_name   = var.project_name
  environment    = var.environment
  aws_region     = var.aws_region
  aws_account_id = var.account_id
  tags           = local.common_tags
}

# ---------------------------------------------------------------------------
# ECR Repository — lives in foundation so the image survives app layer
# destroy/apply cycles. The platform layer receives the repository URL as
# an input variable rather than managing the resource directly.
# ADR-009: IMMUTABLE tag mutability enforces git SHA tagging.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "agent" {
  name                 = "${local.name_prefix}-hr-assistant"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}
