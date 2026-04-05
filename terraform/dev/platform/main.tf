terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
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
  quality_records_table_name   = "${local.name_prefix}-quality-records"
  agentcore_log_group_arn           = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/agentcore/${local.name_prefix}"
  quality_scorer_log_group_name     = "/aws/lambda/${local.name_prefix}-quality-scorer"
  quality_scorer_log_group_arn      = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/lambda/${local.name_prefix}-quality-scorer"
}

# ---------------------------------------------------------------------------
# Foundation state — reads long-lived VPC, KMS, and ECR outputs.
# Run `terraform apply` in foundation/ before applying this layer.
# ---------------------------------------------------------------------------

# Current caller identity and session context — used to grant the Terraform
# caller access to the AOSS collection for index management operations.
# aws_iam_session_context derives the stable IAM role ARN from the session ARN,
# which remains valid across SSO token refreshes. Using the session ARN directly
# in AOSS data access policies fails when the SSO token is refreshed (new session).
data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

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

resource "aws_iam_role_policy_attachment" "agentcore_runtime_managed" {
  role       = aws_iam_role.agentcore_runtime.name
  policy_arn = "arn:aws:iam::aws:policy/BedrockAgentCoreFullAccess"
}

resource "aws_iam_role_policy" "agentcore_runtime" {
  name = "${var.project_name}-agentcore-runtime-${var.environment}-policy"
  role = aws_iam_role.agentcore_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRTokenAccess"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPullImage"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/ai-platform-dev-hr-assistant"
      },
      {
        Sid    = "BedrockModelInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:ApplyGuardrail",
        ]
        # Claude 4.x models require cross-region inference profiles (us.* or global.*).
        # IAM must allow both the inference profile ARN and the underlying foundation model.
        Resource = [
          "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-haiku-4-5-20251001",
          "arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0",
          "arn:aws:bedrock:${var.aws_region}:${var.account_id}:inference-profile/*",
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:${var.aws_region}:${var.account_id}:guardrail/*",
        ]
      },
      {
        # Prompt Management: load system prompt text at container startup.
        Sid    = "BedrockPromptRead"
        Effect = "Allow"
        Action = ["bedrock:GetPrompt"]
        Resource = "arn:aws:bedrock:${var.aws_region}:${var.account_id}:prompt/*"
      },
      {
        # Knowledge Base: retrieve HR policy passages for context injection.
        Sid    = "BedrockKBRetrieve"
        Effect = "Allow"
        Action = ["bedrock:Retrieve"]
        Resource = "arn:aws:bedrock:${var.aws_region}:${var.account_id}:knowledge-base/*"
      },
      {
        # AgentCore writes container logs to /aws/bedrock-agentcore/runtimes/* (service default).
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*",
          "${local.agentcore_log_group_arn}:*",
        ]
      },
      {
        # X-Ray tracing (required by AgentCore runtime per reference sample).
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
        ]
        Resource = "*"
      },
      {
        # CloudWatch metrics (required by AgentCore runtime per reference sample).
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "bedrock-agentcore" }
        }
      },
      {
        # Workload identity tokens — required for container to authenticate as AgentCore workload.
        Sid    = "WorkloadIdentityTokens"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:GetWorkloadAccessToken",
          "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
          "bedrock-agentcore:GetWorkloadAccessTokenForUserId",
        ]
        Resource = [
          "arn:aws:bedrock-agentcore:${var.aws_region}:${var.account_id}:workload-identity-directory/default",
          "arn:aws:bedrock-agentcore:${var.aws_region}:${var.account_id}:workload-identity-directory/default/workload-identity/*",
        ]
      },
      {
        # DynamoDB: agent registry (read-only at startup) and session memory (read/write).
        Sid    = "DynamoDBSessionAndRegistry"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
        ]
        Resource = [
          "arn:aws:dynamodb:${var.aws_region}:${var.account_id}:table/${local.agent_registry_table_name}",
          "arn:aws:dynamodb:${var.aws_region}:${var.account_id}:table/${local.session_memory_table_name}",
        ]
      },
      {
        # Lambda: invoke Glean stub MCP tool and Prompt Vault writer.
        Sid    = "LambdaInvoke"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          "arn:aws:lambda:${var.aws_region}:${var.account_id}:function:ai-platform-dev-glean-stub",
          "arn:aws:lambda:${var.aws_region}:${var.account_id}:function:hr-assistant-prompt-vault-writer-dev",
        ]
      },
      {
        # KMS: decrypt DynamoDB and S3 data encrypted with the platform KMS key.
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [data.terraform_remote_state.foundation.outputs.storage_kms_key_arn]
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

# ---------------------------------------------------------------------------
# OpenSearch Serverless — shared collection for all agent Knowledge Bases.
#
# The platform owns the collection. Each agent owns its index within the
# collection via its own supplementary data access policy (agent layer).
#
# Network policy allows public endpoint access — this is required because
# Bedrock is a managed service that accesses AOSS from outside the customer
# VPC. Data in transit is encrypted (TLS). Data at rest uses AWS-managed KMS.
# ---------------------------------------------------------------------------

resource "aws_opensearchserverless_security_policy" "kb_encryption" {
  name        = "ai-platform-kb-enc-dev"
  type        = "encryption"
  description = "AWS-managed encryption for the shared AI Platform KB collection."
  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/ai-platform-kb-dev"]
    }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "kb_network" {
  name        = "ai-platform-kb-net-dev"
  type        = "network"
  description = "Public endpoint access for the shared AI Platform KB collection (required by Bedrock managed service)."
  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "collection"
        Resource     = ["collection/ai-platform-kb-dev"]
      },
      {
        ResourceType = "dashboard"
        Resource     = ["collection/ai-platform-kb-dev"]
      }
    ]
    AllowFromPublic = true
  }])
}

# Platform-level data access policy — grants the Terraform caller full access
# to the collection so it can create indexes via null_resource local-exec.
# Each agent adds its own supplementary policy for its KB role (agent layer).
# Agents never modify this policy.
resource "aws_opensearchserverless_access_policy" "kb_platform_access" {
  name        = "ai-platform-kb-platform-dev"
  type        = "data"
  description = "Platform-level AOSS access for Terraform caller (index management)."
  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "index"
        Resource     = ["index/ai-platform-kb-dev/*"]
        Permission   = ["aoss:*"]
      },
      {
        ResourceType = "collection"
        Resource     = ["collection/ai-platform-kb-dev"]
        Permission   = ["aoss:*"]
      }
    ]
    Principal = [data.aws_iam_session_context.current.issuer_arn]
  }])
}

resource "aws_opensearchserverless_collection" "kb" {
  name        = "ai-platform-kb-dev"
  description = "Shared vector store for all AI Platform agent Knowledge Bases."
  type        = "VECTORSEARCH"

  depends_on = [
    aws_opensearchserverless_security_policy.kb_encryption,
    aws_opensearchserverless_security_policy.kb_network,
    aws_opensearchserverless_access_policy.kb_platform_access,
  ]

  tags = merge(local.common_tags, { Component = "opensearch" })
}

# Prompt Vault Lambda — owned by agents/hr-assistant layer.
# Read via data source so the platform layer never imports agent remote state
# (dependency direction is always platform ← agents, never platform → agents).
data "aws_lambda_function" "prompt_vault_writer" {
  function_name = "hr-assistant-prompt-vault-writer-dev"
}

module "agentcore" {
  source = "../../modules/agentcore"

  name_prefix             = local.name_prefix
  aws_region              = var.aws_region
  account_id              = var.account_id
  model_arn_primary       = var.model_arn_primary
  agent_image_uri         = var.agent_image_uri
  ecr_repository_url      = data.terraform_remote_state.foundation.outputs.ecr_repository_url
  subnet_ids              = data.terraform_remote_state.foundation.outputs.subnet_ids
  agentcore_sg_id         = data.terraform_remote_state.foundation.outputs.agentcore_sg_id
  session_memory_table    = module.storage.session_memory_table
  agent_registry_table    = module.storage.agent_registry_table
  agentcore_role_arn      = aws_iam_role.agentcore_runtime.arn
  log_group_agentcore     = module.observability.log_group_agentcore
  prompt_vault_lambda_arn = data.aws_lambda_function.prompt_vault_writer.arn
  tags                    = local.common_tags
}

# ---------------------------------------------------------------------------
# Quality Scorer — LLM-as-Judge pipeline
#
# Processes Prompt Vault records hourly via EventBridge, invokes Haiku to
# score each interaction across five dimensions, and writes results here.
# All quality scorer resources are inline in this layer per the spec —
# no new modules.
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "quality_records" {
  name         = local.quality_records_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "record_id"
  range_key    = "scored_at"

  attribute {
    name = "record_id"
    type = "S"
  }

  attribute {
    name = "scored_at"
    type = "S"
  }

  attribute {
    name = "agent_id"
    type = "S"
  }

  attribute {
    name = "below_threshold_str"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  global_secondary_index {
    name            = "agent-threshold-index"
    hash_key        = "agent_id"
    range_key       = "below_threshold_str"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = data.terraform_remote_state.foundation.outputs.storage_kms_key_arn
  }

  tags = merge(local.common_tags, { Name = local.quality_records_table_name })
}

# ---------------------------------------------------------------------------
# Quality Scorer Lambda — IAM role, log group, build, and function.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "quality_scorer" {
  name              = local.quality_scorer_log_group_name
  retention_in_days = 30
  kms_key_id        = data.terraform_remote_state.foundation.outputs.storage_kms_key_arn

  tags = merge(local.common_tags, { Name = local.quality_scorer_log_group_name })
}

resource "aws_iam_role" "quality_scorer" {
  name        = "${local.name_prefix}-quality-scorer"
  description = "Quality scorer Lambda role — reads Prompt Vault, scores with Haiku, writes quality records."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowLambdaAssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-quality-scorer" })
}

resource "aws_iam_role_policy" "quality_scorer" {
  name = "${local.name_prefix}-quality-scorer-policy"
  role = aws_iam_role.quality_scorer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PromptVaultRead"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${local.prompt_vault_bucket_name}",
          "arn:aws:s3:::${local.prompt_vault_bucket_name}/*",
        ]
      },
      {
        Sid    = "AgentRegistryRead"
        Effect = "Allow"
        Action = ["dynamodb:GetItem"]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${var.account_id}:table/${local.agent_registry_table_name}"
      },
      {
        Sid    = "QualityRecordsWrite"
        Effect = "Allow"
        Action = ["dynamodb:PutItem", "dynamodb:Query"]
        Resource = [
          "arn:aws:dynamodb:${var.aws_region}:${var.account_id}:table/${local.quality_records_table_name}",
          "arn:aws:dynamodb:${var.aws_region}:${var.account_id}:table/${local.quality_records_table_name}/index/*",
        ]
      },
      {
        Sid    = "BedrockHaikuInvoke"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-haiku-4-5-20251001"
      },
      {
        Sid      = "CloudWatchMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          local.quality_scorer_log_group_arn,
          "${local.quality_scorer_log_group_arn}:*",
        ]
      },
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = data.terraform_remote_state.foundation.outputs.storage_kms_key_arn
      },
      {
        Sid      = "XRayTracing"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      },
    ]
  })
}

resource "null_resource" "quality_scorer_build" {
  triggers = {
    requirements = filemd5("${path.module}/quality-scorer/requirements.txt")
    handler      = filemd5("${path.module}/quality-scorer/handler.py")
  }

  provisioner "local-exec" {
    command = <<-CMD
      uv pip install \
        --python-platform aarch64-manylinux2014 \
        --python-version "3.12" \
        --target "${path.module}/quality-scorer/build" \
        --only-binary=:all: \
        --quiet \
        -r "${path.module}/quality-scorer/requirements.txt"
      cp "${path.module}/quality-scorer/handler.py" "${path.module}/quality-scorer/build/handler.py"
    CMD
  }
}

data "archive_file" "quality_scorer" {
  type        = "zip"
  source_dir  = "${path.module}/quality-scorer/build"
  output_path = "${path.module}/quality-scorer/quality-scorer.zip"
  depends_on  = [null_resource.quality_scorer_build]
}

resource "aws_lambda_function" "quality_scorer" {
  function_name    = "${local.name_prefix}-quality-scorer"
  filename         = data.archive_file.quality_scorer.output_path
  source_code_hash = data.archive_file.quality_scorer.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  role             = aws_iam_role.quality_scorer.arn
  memory_size      = 512
  timeout          = 300
  description      = "LLM-as-Judge quality scorer — evaluates Prompt Vault records hourly using Haiku."

  environment {
    variables = {
      PROMPT_VAULT_BUCKET  = local.prompt_vault_bucket_name
      QUALITY_TABLE        = local.quality_records_table_name
      SCORER_MODEL_ARN     = "anthropic.claude-haiku-4-5-20251001"
      SCORE_THRESHOLD      = "0.70"
      ENVIRONMENT          = var.environment
      AGENT_REGISTRY_TABLE = local.agent_registry_table_name
    }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.quality_scorer]

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-quality-scorer" })
}
