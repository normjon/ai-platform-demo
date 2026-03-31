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

  # Deterministic resource name computation for IAM policy scoping.
  # These names are stable across destroy/apply cycles, so IAM policies
  # can reference them without a circular dependency on the storage module.
  document_landing_bucket_name = "${local.name_prefix}-document-landing-${var.account_id}"
  prompt_vault_bucket_name     = "${local.name_prefix}-prompt-vault-${var.account_id}"
  session_memory_table_name    = "${local.name_prefix}-session-memory"
  agent_registry_table_name    = "${local.name_prefix}-agent-registry"
  agentcore_log_group_arn      = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/agentcore/${local.name_prefix}"
}

# ---------------------------------------------------------------------------
# Foundation state — reads long-lived VPC, KMS, and ECR outputs.
# Run `terraform apply` in foundation/ before applying this layer.
# ---------------------------------------------------------------------------

data "terraform_remote_state" "foundation" {
  backend = "s3"
  config = {
    bucket = "ai-platform-terraform-state-dev-096305373014"
    key    = "dev/foundation/terraform.tfstate"
    region = "us-east-2"
  }
}

# ---------------------------------------------------------------------------
# Platform IAM — AgentCore runtime and Bedrock KB roles.
#
# Option B: each deployment layer owns IAM for its own resources.
# These roles live in the platform layer so they are destroyed and recreated
# with the platform, not the foundation.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "agentcore_runtime" {
  name        = "${var.project_name}-agentcore-runtime-${var.environment}"
  description = "AgentCore runtime role - Bedrock model invocation and MCP gateway target management."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowAgentCoreAssumeRole"
      Effect = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.project_name}-agentcore-runtime-${var.environment}" })
}

resource "aws_iam_role_policy" "agentcore_runtime" {
  name = "${var.project_name}-agentcore-runtime-${var.environment}-policy"
  role = aws_iam_role.agentcore_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockModelInvoke"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        # Scoped to approved model ARNs only (CLAUDE.md / ADR-001).
        Resource = [
          "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-haiku-4-5-20251001",
          "arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0",
        ]
      },
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["${local.agentcore_log_group_arn}:*"]
      },
      {
        # Gateway target management — tools/ layers register their targets against
        # the platform gateway. These actions allow the runtime role and operators
        # to manage targets out-of-band when AWS validates live connectivity at
        # create time (making Terraform management unreliable for some targets).
        Sid    = "GatewayTargetManagement"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:CreateGatewayTarget",
          "bedrock-agentcore:DeleteGatewayTarget",
          "bedrock-agentcore:GetGatewayTarget",
          "bedrock-agentcore:ListGatewayTargets",
          "bedrock-agentcore:UpdateGatewayTarget",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "bedrock_kb" {
  name        = "${var.project_name}-bedrock-kb-${var.environment}"
  description = "Bedrock Knowledge Base role - S3 document reads for KB ingestion."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowBedrockKBAssumeRole"
      Effect = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.project_name}-bedrock-kb-${var.environment}" })
}

resource "aws_iam_role_policy" "bedrock_kb" {
  name = "${var.project_name}-bedrock-kb-${var.environment}-policy"
  role = aws_iam_role.bedrock_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "S3DocumentLandingRead"
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        "arn:aws:s3:::${local.document_landing_bucket_name}",
        "arn:aws:s3:::${local.document_landing_bucket_name}/*",
      ]
    }]
  })
}

# ---------------------------------------------------------------------------
# Platform services
# ---------------------------------------------------------------------------

module "storage" {
  source = "../../modules/storage"

  name_prefix = local.name_prefix
  account_id  = var.account_id
  kms_key_arn = data.terraform_remote_state.foundation.outputs.storage_kms_key_arn
  tags        = local.common_tags
}

module "observability" {
  source = "../../modules/observability"

  name_prefix = local.name_prefix
  kms_key_arn = data.terraform_remote_state.foundation.outputs.storage_kms_key_arn
  tags        = local.common_tags
}

module "agentcore" {
  source = "../../modules/agentcore"

  name_prefix          = local.name_prefix
  aws_region           = var.aws_region
  account_id           = var.account_id
  model_arn_primary    = var.model_arn_primary
  agent_image_uri      = var.agent_image_uri
  ecr_repository_url   = data.terraform_remote_state.foundation.outputs.ecr_repository_url
  subnet_ids           = data.terraform_remote_state.foundation.outputs.subnet_ids
  agentcore_sg_id      = data.terraform_remote_state.foundation.outputs.agentcore_sg_id
  session_memory_table = module.storage.session_memory_table
  agent_registry_table = module.storage.agent_registry_table
  agentcore_role_arn   = aws_iam_role.agentcore_runtime.arn
  log_group_agentcore  = module.observability.log_group_agentcore
  tags                 = local.common_tags
}
