# ---------------------------------------------------------------------------
# KMS key for storage encryption (DynamoDB, S3 SSE, CloudWatch Logs).
# ---------------------------------------------------------------------------
resource "aws_kms_key" "storage" {
  description             = "${var.name_prefix} storage encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-storage-kms" })
}

resource "aws_kms_alias" "storage" {
  name          = "alias/${var.name_prefix}-storage"
  target_key_id = aws_kms_key.storage.key_id
}

# Key policy: grants account root full access (enabling IAM delegation) and
# allows CloudWatch Logs to use the key for log group encryption (ADR-003).
resource "aws_kms_key_policy" "storage" {
  key_id = aws_kms_key.storage.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableAccountRootIAMDelegation"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }
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
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${var.account_id}:*"
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# AgentCore execution role (IRSA pattern — ADR-001).
# ---------------------------------------------------------------------------
resource "aws_iam_role" "agentcore" {
  name = "${var.name_prefix}-agentcore-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:bedrock:${var.aws_region}:${var.account_id}:*" }
      }
    }]
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-agentcore-role" })
}

resource "aws_iam_role_policy" "agentcore" {
  name = "${var.name_prefix}-agentcore-policy"
  role = aws_iam_role.agentcore.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BedrockModelInvoke"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = ["arn:aws:bedrock:${var.aws_region}::foundation-model/*"]
      },
      {
        Sid      = "BedrockKnowledgeBaseRetrieve"
        Effect   = "Allow"
        Action   = ["bedrock:Retrieve", "bedrock:RetrieveAndGenerate"]
        Resource = ["arn:aws:bedrock:${var.aws_region}:${var.account_id}:knowledge-base/*"]
      },
      {
        Sid    = "DynamoDBSessionMemory"
        Effect = "Allow"
        Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
        # ARNs passed from dev/main.tf — iam/ does not reconstruct storage naming (Step 3).
        Resource = [var.session_memory_table_arn, var.agent_registry_table_arn]
      },
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/agentcore/${var.name_prefix}:*"]
      },
      {
        Sid    = "KMSStorageAccess"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey", "kms:ReEncrypt*"]
        Resource = [aws_kms_key.storage.arn]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Bedrock Knowledge Base ingestion role (IRSA pattern — ADR-001).
# ---------------------------------------------------------------------------
resource "aws_iam_role" "bedrock_kb" {
  name = "${var.name_prefix}-bedrock-kb-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.account_id }
      }
    }]
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-bedrock-kb-role" })
}

resource "aws_iam_role_policy" "bedrock_kb" {
  name = "${var.name_prefix}-bedrock-kb-policy"
  role = aws_iam_role.bedrock_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3DocumentLanding"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        # ARN passed from dev/main.tf — iam/ does not reconstruct storage naming (Step 3).
        Resource = [var.document_landing_bucket_arn, "${var.document_landing_bucket_arn}/*"]
      },
      {
        Sid      = "TitanEmbeddings"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = ["arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0"]
      },
      {
        Sid      = "OpenSearchServerless"
        Effect   = "Allow"
        Action   = ["aoss:APIAccessAll"]
        Resource = ["arn:aws:aoss:${var.aws_region}:${var.account_id}:collection/*"]
      },
      {
        Sid    = "KMSStorageAccess"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey", "kms:ReEncrypt*"]
        Resource = [aws_kms_key.storage.arn]
      }
    ]
  })
}
