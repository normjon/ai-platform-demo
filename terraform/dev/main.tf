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

  # ---------------------------------------------------------------------------
  # Resource identifiers — single source of truth for cross-module ARN refs.
  # Matches naming conventions in modules/storage/main.tf.
  # Passed to iam/ so it never reconstructs storage names internally (Step 3).
  # ---------------------------------------------------------------------------
  document_landing_bucket_name = "${local.name_prefix}-document-landing-${var.account_id}"
  prompt_vault_bucket_name     = "${local.name_prefix}-prompt-vault-${var.account_id}"
  session_memory_table_name    = "${local.name_prefix}-session-memory"
  agent_registry_table_name    = "${local.name_prefix}-agent-registry"
}

module "networking" {
  source = "../modules/networking"

  name_prefix          = local.name_prefix
  vpc_cidr             = var.vpc_cidr
  private_subnet_cidrs = var.private_subnet_cidrs
  tags                 = local.common_tags
}

module "iam" {
  source = "../modules/iam"

  project_name   = var.project_name
  environment    = var.environment
  aws_region     = var.aws_region
  aws_account_id = var.account_id

  # Resource ARNs computed from locals — iam/ never reconstructs storage naming (Step 3).
  document_bucket_arn     = "arn:aws:s3:::${local.document_landing_bucket_name}"
  prompt_vault_bucket_arn = "arn:aws:s3:::${local.prompt_vault_bucket_name}"
  session_table_arn       = "arn:aws:dynamodb:${var.aws_region}:${var.account_id}:table/${local.session_memory_table_name}"
  registry_table_arn      = "arn:aws:dynamodb:${var.aws_region}:${var.account_id}:table/${local.agent_registry_table_name}"
  agentcore_log_group_arn = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/agentcore/${local.name_prefix}"

  tags = local.common_tags
}

module "storage" {
  source = "../modules/storage"

  name_prefix = local.name_prefix
  account_id  = var.account_id
  kms_key_arn = module.iam.storage_kms_key_arn
  tags        = local.common_tags
}

module "observability" {
  source = "../modules/observability"

  name_prefix = local.name_prefix
  kms_key_arn = module.iam.storage_kms_key_arn
  tags        = local.common_tags
}

module "agentcore" {
  source = "../modules/agentcore"

  name_prefix          = local.name_prefix
  aws_region           = var.aws_region
  account_id           = var.account_id
  model_arn_primary    = var.model_arn_primary
  agent_image_uri      = var.agent_image_uri
  glean_mcp_endpoint   = var.glean_mcp_endpoint
  subnet_ids           = module.networking.subnet_ids
  agentcore_sg_id      = module.networking.agentcore_sg_id
  session_memory_table = module.storage.session_memory_table
  agent_registry_table = module.storage.agent_registry_table
  agentcore_role_arn   = module.iam.agentcore_runtime_role_arn
  log_group_agentcore  = module.observability.log_group_agentcore
  tags                 = local.common_tags
}
