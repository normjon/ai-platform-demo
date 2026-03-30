locals {
  # Mandatory tags applied to every resource in this module (CLAUDE.md tagging rule).
  module_tags = merge(var.tags, {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
    Module      = "iam"
  })

  # Approved Bedrock foundation model ARNs scoped to the deployment region.
  # These are the only model ARNs permitted by the platform SCP (CLAUDE.md).
  model_arns = [
    "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-sonnet-4-6",
    "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-haiku-4-5-20251001",
    "arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0",
  ]

  haiku_model_arn = "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-haiku-4-5-20251001"
}

# ---------------------------------------------------------------------------
# KMS key — encrypts S3 buckets, DynamoDB tables, and CloudWatch log groups.
# Created here so its ARN can be passed to storage/, observability/, bedrock/
# without circular dependencies.
# ---------------------------------------------------------------------------

resource "aws_kms_key" "storage" {
  description             = "${var.project_name}-${var.environment} storage encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = merge(local.module_tags, { Name = "${var.project_name}-${var.environment}-storage-kms" })
}

resource "aws_kms_alias" "storage" {
  name          = "alias/${var.project_name}-${var.environment}-storage"
  target_key_id = aws_kms_key.storage.key_id
}

# Key policy: root account delegation (enables IAM policy control) and
# CloudWatch Logs service principal grant (required for encrypted log groups).
resource "aws_kms_key_policy" "storage" {
  key_id = aws_kms_key.storage.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableAccountRootIAMDelegation"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.aws_account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogsEncryption"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:*"
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Role 1 — AgentCore Runtime Role
#
# Assumed by the AgentCore runtime to invoke Bedrock models and read from
# the Knowledge Base. Trust principal: bedrock-agentcore.amazonaws.com.
# aws:SourceAccount condition prevents confused deputy attacks (ADR-001 /
# Section 8.1).
# ---------------------------------------------------------------------------

resource "aws_iam_role" "agentcore_runtime" {
  name        = "${var.project_name}-agentcore-runtime-${var.environment}"
  description = "AgentCore runtime role — Bedrock model invocation and Knowledge Base retrieval."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowAgentCoreAssumeRole"
      Effect = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.aws_account_id }
      }
    }]
  })

  tags = merge(local.module_tags, { Name = "${var.project_name}-agentcore-runtime-${var.environment}" })
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
        # Scoped to the three approved model ARNs only (CLAUDE.md / platform SCP).
        Resource = local.model_arns
      },
      {
        Sid    = "BedrockKnowledgeBaseRetrieve"
        Effect = "Allow"
        Action = ["bedrock:Retrieve", "bedrock:RetrieveAndGenerate"]
        Resource = [var.kb_arn]
      },
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [var.agentcore_log_group_arn]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Role 2 — Bedrock Knowledge Base Role
#
# Assumed by the Bedrock Knowledge Base service to read source documents
# from S3 and write vectors to OpenSearch Serverless.
# Trust principal: bedrock.amazonaws.com.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "bedrock_kb" {
  name        = "${var.project_name}-bedrock-kb-${var.environment}"
  description = "Bedrock Knowledge Base role — S3 document reads and OpenSearch vector writes."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowBedrockKBAssumeRole"
      Effect = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.aws_account_id }
      }
    }]
  })

  tags = merge(local.module_tags, { Name = "${var.project_name}-bedrock-kb-${var.environment}" })
}

resource "aws_iam_role_policy" "bedrock_kb" {
  name = "${var.project_name}-bedrock-kb-${var.environment}-policy"
  role = aws_iam_role.bedrock_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3DocumentLandingRead"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          var.document_bucket_arn,
          "${var.document_bucket_arn}/*",
        ]
      },
      {
        Sid      = "OpenSearchServerlessWrite"
        Effect   = "Allow"
        Action   = ["aoss:APIAccessAll"]
        Resource = [var.opensearch_collection_arn]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Role 3 — Lambda Execution Role
#
# Assumed by all Lambda functions in the platform — ingestion orchestrator,
# quality scorer, and event handlers. Trust principal: lambda.amazonaws.com.
# Haiku only: Lambda evaluation tasks never use Sonnet (cost control and
# least-privilege per Section 8).
# ---------------------------------------------------------------------------

resource "aws_iam_role" "lambda_execution" {
  name        = "${var.project_name}-lambda-${var.environment}"
  description = "Lambda execution role — evaluation, ingestion orchestration, and event handling."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowLambdaAssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(local.module_tags, { Name = "${var.project_name}-lambda-${var.environment}" })
}

resource "aws_iam_role_policy" "lambda_execution" {
  name = "${var.project_name}-lambda-${var.environment}-policy"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockHaikuOnly"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        # Lambda evaluation tasks use Haiku only — never Sonnet (cost control).
        Resource = [local.haiku_model_arn]
      },
      {
        Sid    = "PromptVaultReadWrite"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject"]
        Resource = [
          var.prompt_vault_bucket_arn,
          "${var.prompt_vault_bucket_arn}/*",
        ]
      },
      {
        Sid    = "DocumentBucketRead"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = [
          var.document_bucket_arn,
          "${var.document_bucket_arn}/*",
        ]
      },
      {
        Sid    = "DynamoDBSessionAndRegistry"
        Effect = "Allow"
        Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
        Resource = [
          var.session_table_arn,
          var.registry_table_arn,
        ]
      },
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        # Covers all Lambda log groups in the account (/aws/lambda/*).
        Resource = ["arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/lambda/*:*"]
      },
      {
        Sid    = "SQSAccountScoped"
        Effect = "Allow"
        Action = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
        # Scoped to all queues within this account and region — no cross-account access.
        Resource = ["arn:aws:sqs:${var.aws_region}:${var.aws_account_id}:*"]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Role 4 — OpenSearch Serverless Access Role
#
# Assumed by services that need direct read/write access to the OpenSearch
# Serverless vector index beyond what the KB ingestion role covers.
# Dual trust: bedrock.amazonaws.com and bedrock-agentcore.amazonaws.com.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "opensearch_access" {
  name        = "${var.project_name}-opensearch-${var.environment}"
  description = "OpenSearch Serverless direct-access role — vector index read/write for Bedrock and AgentCore."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowBedrockAndAgentCoreAssumeRole"
      Effect = "Allow"
      Principal = {
        Service = [
          "bedrock.amazonaws.com",
          "bedrock-agentcore.amazonaws.com",
        ]
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.aws_account_id }
      }
    }]
  })

  tags = merge(local.module_tags, { Name = "${var.project_name}-opensearch-${var.environment}" })
}

resource "aws_iam_role_policy" "opensearch_access" {
  name = "${var.project_name}-opensearch-${var.environment}-policy"
  role = aws_iam_role.opensearch_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "OpenSearchServerlessAccess"
        Effect   = "Allow"
        Action   = ["aoss:APIAccessAll"]
        Resource = [var.opensearch_collection_arn]
      }
    ]
  })
}
