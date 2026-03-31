# ---------------------------------------------------------------------------
# S3 buckets - public access blocked, versioning enabled on all (CLAUDE.md).
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "document_landing" {
  bucket = "${var.name_prefix}-document-landing-${var.account_id}"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-document-landing" })
}

resource "aws_s3_bucket_versioning" "document_landing" {
  bucket = aws_s3_bucket.document_landing.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "document_landing" {
  bucket                  = aws_s3_bucket.document_landing.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "document_landing" {
  bucket = aws_s3_bucket.document_landing.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket" "prompt_vault" {
  bucket = "${var.name_prefix}-prompt-vault-${var.account_id}"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-prompt-vault" })
}

resource "aws_s3_bucket_versioning" "prompt_vault" {
  bucket = aws_s3_bucket.prompt_vault.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "prompt_vault" {
  bucket                  = aws_s3_bucket.prompt_vault.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "prompt_vault" {
  bucket = aws_s3_bucket.prompt_vault.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

# ---------------------------------------------------------------------------
# DynamoDB tables - KMS encryption required on all (CLAUDE.md).
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "session_memory" {
  name         = "${var.name_prefix}-session-memory"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "session_id"
  range_key    = "timestamp"

  attribute {
    name = "session_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-session-memory" })
}

resource "aws_dynamodb_table" "agent_registry" {
  name         = "${var.name_prefix}-agent-registry"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "agent_id"

  attribute {
    name = "agent_id"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-agent-registry" })
}
