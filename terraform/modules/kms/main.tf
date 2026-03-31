# ---------------------------------------------------------------------------
# KMS Module — Platform storage encryption key.
#
# Creates the KMS Customer Managed Key (CMK) used by the platform layer to
# encrypt S3 buckets, DynamoDB tables, and CloudWatch log groups. Lives in
# the foundation layer so the key survives platform/tools/agents destroy
# cycles — objects in versioned S3 buckets cannot be decrypted if the key
# is deleted with data in place.
#
# Key policy grants:
# - Root account IAM delegation (required for IAM policy-based key control)
# - CloudWatch Logs service principal (required for encrypted log groups)
# ---------------------------------------------------------------------------

locals {
  module_tags = merge(var.tags, {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
    Module      = "kms"
  })
}

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
