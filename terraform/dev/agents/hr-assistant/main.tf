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

# Current caller identity and session context — used to grant index-creation
# access in OpenSearch Serverless data access policy so null_resource local-exec
# can create the vector index before Bedrock KB is provisioned.
# aws_iam_session_context derives the IAM role ARN (with path) from the session
# ARN, which is stable across SSO refreshes. Using the session ARN directly in
# AOSS data access policies fails when the SSO token is refreshed (new session).
data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

# ---------------------------------------------------------------------------
# Platform state — reads AgentCore endpoint and shared platform outputs.
# ---------------------------------------------------------------------------

data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "ai-platform-terraform-state-dev-096305373014"
    key    = "dev/platform/terraform.tfstate"
    region = "us-east-2"
  }
}

# ---------------------------------------------------------------------------
# Component 1 — System Prompt (Bedrock Prompt Management)
# ---------------------------------------------------------------------------

resource "aws_bedrockagent_prompt" "hr_assistant_system" {
  name        = "hr-assistant-system-prompt-dev"
  description = "System prompt for the HR Assistant agent - dev environment."

  default_variant = "default"

  variant {
    name          = "default"
    template_type = "TEXT"
    model_id      = var.model_arn
    template_configuration {
      text {
        text = file("${path.module}/prompts/hr-assistant-system-prompt.txt")
      }
    }
  }

  tags = merge(var.tags, { Component = "system-prompt" })
}

# NOTE: aws_bedrockagent_prompt does not have a separate version resource in
# provider v6. The prompt ARN is available directly as a computed attribute.
# Use aws_bedrockagent_prompt.hr_assistant_system.arn throughout.

# ---------------------------------------------------------------------------
# Component 2 — Guardrails (Bedrock Guardrails)
# ---------------------------------------------------------------------------

resource "aws_bedrock_guardrail" "hr_assistant" {
  name                      = "hr-assistant-guardrail-dev"
  description               = "Guardrail for the HR Assistant agent - dev environment."
  blocked_input_messaging   = "I'm not able to help with that request. For assistance, please\ncontact the HR team directly at hr@example.com or speak with your\nHR Business Partner."
  blocked_outputs_messaging = "I'm not able to help with that request. For assistance, please\ncontact the HR team directly at hr@example.com or speak with your\nHR Business Partner."

  # Topic policies — deny out-of-scope topics
  topic_policy_config {
    topics_config {
      name       = "Legal Advice"
      definition = "Requests for legal opinions, interpretation of laws or contracts, advice on legal rights or obligations, or guidance on legal proceedings."
      examples   = ["Is my employer breaking the law?", "Can I sue the company?", "What are my legal rights here?"]
      type       = "DENY"
    }

    topics_config {
      name       = "Medical Advice"
      definition = "Requests for medical diagnosis, treatment recommendations, interpretation of medical test results, or advice on medications."
      examples   = ["Should I see a doctor about this?", "What does my diagnosis mean?", "Is this medication safe?"]
      type       = "DENY"
    }

    topics_config {
      name       = "Financial Planning Advice"
      definition = "Requests for personal investment advice, tax planning strategies, retirement fund allocation recommendations, or specific financial product recommendations."
      examples   = ["Should I put more in my pension?", "How should I invest my bonus?", "Which fund should I choose?"]
      type       = "DENY"
    }

    topics_config {
      name       = "Employee Personal Information"
      definition = "Requests for information about other employees' salary, performance ratings, disciplinary history, personal contact details, or any other personal data about a named individual."
      examples   = ["What does Sarah earn?", "Why was John let go?", "Give me Jane's phone number"]
      type       = "DENY"
    }
  }

  # Content filters
  content_policy_config {
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }

    filters_config {
      type            = "INSULTS"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }

    filters_config {
      type            = "SEXUAL"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }

    filters_config {
      type            = "VIOLENCE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }

    filters_config {
      type            = "MISCONDUCT"
      input_strength  = "MEDIUM"
      output_strength = "MEDIUM"
    }
  }

  # PII handling — anonymize rather than block
  sensitive_information_policy_config {
    pii_entities_config {
      type   = "NAME"
      action = "ANONYMIZE"
    }

    pii_entities_config {
      type   = "EMAIL"
      action = "ANONYMIZE"
    }

    pii_entities_config {
      type   = "PHONE"
      action = "ANONYMIZE"
    }

    pii_entities_config {
      type   = "ADDRESS"
      action = "ANONYMIZE"
    }

    pii_entities_config {
      type   = "AGE"
      action = "ANONYMIZE"
    }

    pii_entities_config {
      type   = "US_SOCIAL_SECURITY_NUMBER"
      action = "ANONYMIZE"
    }

    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_NUMBER"
      action = "ANONYMIZE"
    }

    pii_entities_config {
      type   = "US_BANK_ACCOUNT_NUMBER"
      action = "ANONYMIZE"
    }
  }

  # Contextual grounding — block responses below 0.75 grounding threshold
  contextual_grounding_policy_config {
    filters_config {
      type      = "GROUNDING"
      threshold = 0.75
    }
  }

  tags = merge(var.tags, { Component = "guardrail" })
}

# ---------------------------------------------------------------------------
# Component 3 — Agent Manifest and AgentCore Configuration
#
# NOTE: As of the AWS provider v6 (October 2025 GA), there is no native
# Terraform resource for registering a declarative agent manifest with a
# system prompt ARN, guardrail, and tool policy against an existing
# AgentCore runtime endpoint. The aws_bedrockagentcore_agent_runtime resource
# manages container-based runtimes (ECR-backed) and is not applicable here.
#
# This component uses terraform_data + local-exec to call the AgentCore API
# via the AWS CLI. Replace with a native Terraform resource when the
# hashicorp/aws provider adds aws_bedrockagentcore_agent_configuration or
# equivalent support.
#
# AgentCore Agent Registry API reference:
# https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agentcore_CreateAgentRuntime.html
# ---------------------------------------------------------------------------

locals {
  agent_manifest = jsonencode({
    agentId            = "hr-assistant-dev"
    displayName        = "HR Assistant (Dev)"
    modelArn           = var.model_arn
    systemPromptArn    = aws_bedrockagent_prompt.hr_assistant_system.arn
    guardrailId        = aws_bedrock_guardrail.hr_assistant.guardrail_id
    guardrailVersion   = aws_bedrock_guardrail.hr_assistant.version
    endpointId         = data.terraform_remote_state.platform.outputs.agentcore_endpoint_id
    gatewayId          = data.terraform_remote_state.platform.outputs.agentcore_gateway_id
    memoryConfig = {
      sessionTtlHours       = 24
      longTermMemoryEnabled = false
    }
    toolPolicy = {
      allowedTools = ["glean-search"]
      deniedTools  = ["all-write-tools"]
    }
    dataClassificationCeiling = "INTERNAL"
    qualitySla = {
      groundingScoreMin     = 0.75
      responseLatencyP95Ms  = 5000
    }
    costBudget = {
      monthlyUsdLimit    = 50
      alertThresholdPct  = 80
    }
  })
}

# Write manifest to S3 agent registry for auditability and runtime reference.
# The manifest JSON is stored alongside the agent registry DynamoDB table.
resource "terraform_data" "hr_assistant_manifest" {
  # Re-register when any manifest input changes.
  triggers_replace = [
    aws_bedrockagent_prompt.hr_assistant_system.arn,
    aws_bedrock_guardrail.hr_assistant.guardrail_id,
    aws_bedrock_guardrail.hr_assistant.version,
    data.terraform_remote_state.platform.outputs.agentcore_endpoint_id,
    data.terraform_remote_state.platform.outputs.agentcore_gateway_id,
    var.model_arn,
    aws_bedrockagent_knowledge_base.hr_policies.id,
  ]

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      echo 'Registering HR Assistant agent manifest in agent registry table...'
      aws dynamodb put-item \
        --region "${var.aws_region}" \
        --table-name "${data.terraform_remote_state.platform.outputs.agent_registry_table}" \
        --item '{
          "agent_id":        {"S": "hr-assistant-dev"},
          "display_name":    {"S": "HR Assistant (Dev)"},
          "model_arn":       {"S": "${var.model_arn}"},
          "system_prompt_arn": {"S": "${aws_bedrockagent_prompt.hr_assistant_system.arn}"},
          "guardrail_id":    {"S": "${aws_bedrock_guardrail.hr_assistant.guardrail_id}"},
          "guardrail_version": {"S": "${aws_bedrock_guardrail.hr_assistant.version}"},
          "endpoint_id":     {"S": "${data.terraform_remote_state.platform.outputs.agentcore_endpoint_id}"},
          "gateway_id":      {"S": "${data.terraform_remote_state.platform.outputs.agentcore_gateway_id}"},
          "allowed_tools":   {"SS": ["glean-search"]},
          "data_classification_ceiling": {"S": "INTERNAL"},
          "session_ttl_hours": {"N": "24"},
          "grounding_score_min": {"N": "0.75"},
          "response_latency_p95_ms": {"N": "5000"},
          "monthly_usd_limit": {"N": "50"},
          "alert_threshold_pct": {"N": "80"},
          "knowledge_base_id": {"S": "${aws_bedrockagent_knowledge_base.hr_policies.id}"},
          "environment":     {"S": "${var.environment}"},
          "registered_at":   {"S": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
        }'
      echo 'Agent manifest registered successfully.'
    SCRIPT
  }
}

# ---------------------------------------------------------------------------
# Component 4 — Prompt Vault Lambda Write Path
# ---------------------------------------------------------------------------

# Package the Lambda handler from the local prompt-vault/ directory.
data "archive_file" "prompt_vault_writer" {
  type        = "zip"
  source_file = "${path.module}/prompt-vault/handler.py"
  output_path = "${path.module}/prompt-vault/handler.zip"
}

# IAM execution role for the Prompt Vault writer — inline in agents/hr-assistant
# per Option B (ADR-017). Platform does not own Lambda IAM for agent layers.
resource "aws_iam_role" "prompt_vault_writer" {
  name        = "hr-assistant-prompt-vault-writer-dev"
  description = "Execution role for the HR Assistant Prompt Vault writer Lambda."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "LambdaAssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Component = "prompt-vault-iam" })
}

resource "aws_iam_role_policy" "prompt_vault_writer" {
  name = "PromptVaultWriterPolicy"
  role = aws_iam_role.prompt_vault_writer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # S3 write to Prompt Vault — scoped to hr-assistant prefix only
      {
        Sid    = "PromptVaultWrite"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = [
          "arn:aws:s3:::${data.terraform_remote_state.platform.outputs.prompt_vault_bucket}/prompt-vault/hr-assistant/*"
        ]
      },
      # KMS — required to write to the KMS-encrypted Prompt Vault bucket.
      # Without these actions the Lambda receives AccessDenied at runtime,
      # not at plan time. The failure is silent until first invocation.
      {
        Sid    = "PromptVaultKMS"
        Effect = "Allow"
        Action = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = [data.terraform_remote_state.platform.outputs.kms_key_arn]
      },
      # CloudWatch Logs — scoped to this Lambda's log group only
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/lambda/hr-assistant-prompt-vault-writer-dev:*"
        ]
      }
    ]
  })
}

# CloudWatch log group — provisioned explicitly for 30-day retention.
resource "aws_cloudwatch_log_group" "prompt_vault_writer" {
  name              = "/aws/lambda/hr-assistant-prompt-vault-writer-dev"
  retention_in_days = 30
  kms_key_id        = data.terraform_remote_state.platform.outputs.kms_key_arn

  tags = merge(var.tags, { Component = "prompt-vault-logs" })
}

# Lambda function — arm64/Graviton, python3.12 (ADR-004)
resource "aws_lambda_function" "prompt_vault_writer" {
  function_name    = "hr-assistant-prompt-vault-writer-dev"
  description      = "Writes HR Assistant interaction records to the Prompt Vault S3 bucket."
  role             = aws_iam_role.prompt_vault_writer.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  timeout          = 30
  filename         = data.archive_file.prompt_vault_writer.output_path
  source_code_hash = data.archive_file.prompt_vault_writer.output_base64sha256

  environment {
    variables = {
      PROMPT_VAULT_BUCKET = data.terraform_remote_state.platform.outputs.prompt_vault_bucket
      AGENT_ID            = "hr-assistant-dev"
      ENVIRONMENT         = var.environment
    }
  }

  depends_on = [
    aws_iam_role_policy.prompt_vault_writer,
    aws_cloudwatch_log_group.prompt_vault_writer,
  ]

  tags = merge(var.tags, { Component = "prompt-vault-lambda" })
}

# Allow AgentCore to invoke the Prompt Vault writer.
resource "aws_lambda_permission" "agentcore_invoke_prompt_vault_writer" {
  statement_id  = "AllowAgentCoreInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.prompt_vault_writer.function_name
  principal     = "bedrock-agentcore.amazonaws.com"
  source_arn    = "arn:aws:bedrock-agentcore:${var.aws_region}:${var.account_id}:*"
}

# ---------------------------------------------------------------------------
# Component 3 — HR Policies Knowledge Base
#
# Architecture: OpenSearch Serverless (vector engine) + Bedrock Knowledge Base.
# Scoped to agents/hr-assistant layer per Option B — the HR Policies KB is
# specific to this agent and is not a shared platform resource.
# IAM role created inline (not in platform), scoped to hr-policies/ S3 prefix
# and this specific OpenSearch Serverless collection.
# ---------------------------------------------------------------------------

locals {
  kb_collection_name = "hr-policies-kb-dev"
  kb_index_name      = "hr-policies-index"
  # S3 prefix under the document landing bucket where HR policy docs live.
  hr_policies_s3_prefix = "hr-policies/"
  document_landing_bucket = "ai-platform-dev-document-landing-${var.account_id}"
}

# ---------------------------------------------------------------------------
# OpenSearch Serverless — encryption, network, and data access policies.
# Public network access is required because Bedrock is a managed service that
# accesses OpenSearch from outside the customer VPC. Data access is restricted
# to the KB IAM role via the data access policy.
# ---------------------------------------------------------------------------

resource "aws_opensearchserverless_security_policy" "hr_policies_encryption" {
  name        = "hr-policies-enc-dev"
  type        = "encryption"
  description = "AWS-managed encryption for HR Policies KB collection."
  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.kb_collection_name}"]
    }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "hr_policies_network" {
  name        = "hr-policies-net-dev"
  type        = "network"
  description = "Public endpoint access for HR Policies KB collection."
  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "collection"
        Resource     = ["collection/${local.kb_collection_name}"]
      },
      {
        ResourceType = "dashboard"
        Resource     = ["collection/${local.kb_collection_name}"]
      }
    ]
    AllowFromPublic = true
  }])
}

resource "aws_opensearchserverless_access_policy" "hr_policies_data" {
  name        = "hr-policies-data-dev"
  type        = "data"
  description = "Allow Bedrock KB role to manage hr-policies index and documents."
  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "collection"
        Resource     = ["collection/${local.kb_collection_name}"]
        Permission   = [
          "aoss:CreateCollectionItems",
          "aoss:DeleteCollectionItems",
          "aoss:UpdateCollectionItems",
          "aoss:DescribeCollectionItems",
        ]
      },
      {
        ResourceType = "index"
        Resource     = ["index/${local.kb_collection_name}/*"]
        Permission   = [
          "aoss:CreateIndex",
          "aoss:DeleteIndex",
          "aoss:UpdateIndex",
          "aoss:DescribeIndex",
          "aoss:ReadDocument",
          "aoss:WriteDocument",
        ]
      }
    ]
    # Include the KB service role AND the Terraform caller's IAM role so
    # null_resource local-exec can create the vector index before Bedrock KB
    # is provisioned. The role ARN (not session ARN) is used so the policy
    # remains valid across SSO token refreshes.
    Principal = [
      aws_iam_role.hr_policies_kb.arn,
      data.aws_iam_session_context.current.issuer_arn,
    ]
  }])
}

resource "aws_opensearchserverless_collection" "hr_policies" {
  name        = local.kb_collection_name
  description = "Vector store for HR Policies Knowledge Base."
  type        = "VECTORSEARCH"

  depends_on = [
    aws_opensearchserverless_security_policy.hr_policies_encryption,
    aws_opensearchserverless_security_policy.hr_policies_network,
    aws_opensearchserverless_access_policy.hr_policies_data,
  ]

  tags = merge(var.tags, { Component = "hr-policies-kb" })
}

# ---------------------------------------------------------------------------
# IAM role for the HR Policies Knowledge Base (Option B: inline in this layer).
# Separate from the platform bedrock_kb role — scoped to hr-policies/ prefix
# and this specific OpenSearch Serverless collection.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "hr_policies_kb" {
  name        = "hr-policies-kb-role-dev"
  description = "Bedrock KB service role for HR Policies KB. Scoped to hr-policies/ S3 prefix and OpenSearch Serverless collection."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "BedrockKBAssumeRole"
      Effect = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })

  tags = merge(var.tags, { Component = "hr-policies-kb-iam" })
}

resource "aws_iam_role_policy" "hr_policies_kb" {
  name = "HRPoliciesKBPolicy"
  role = aws_iam_role.hr_policies_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # S3: read HR policy documents from the document landing bucket.
        Sid    = "S3HRPoliciesRead"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${local.document_landing_bucket}",
          "arn:aws:s3:::${local.document_landing_bucket}/hr-policies/*",
        ]
      },
      {
        # OpenSearch Serverless: write embeddings to the vector index.
        Sid    = "OpenSearchServerlessAccess"
        Effect = "Allow"
        Action = ["aoss:APIAccessAll"]
        Resource = ["arn:aws:aoss:${var.aws_region}:${var.account_id}:collection/*"]
      },
      {
        # Bedrock: invoke embedding model to generate vectors.
        Sid    = "BedrockEmbeddingModel"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0"
        ]
      },
      {
        # KMS: decrypt S3 objects in the document landing bucket, which is
        # encrypted with the platform KMS key. Without this, the KB role
        # receives AccessDenied when reading documents during ingestion.
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [data.terraform_remote_state.platform.outputs.kms_key_arn]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# OpenSearch vector index pre-creation.
#
# Bedrock KB does not auto-create the vector index — it expects the index to
# exist before the knowledge base resource is provisioned. This null_resource
# runs create-os-index.py via local-exec after the collection is ACTIVE and
# the data access policy (which includes the Terraform caller ARN) is applied.
#
# The script is idempotent: it exits 0 if the index already exists.
# ---------------------------------------------------------------------------

resource "null_resource" "create_hr_policies_index" {
  # Re-run if the collection is replaced.
  triggers = {
    collection_id = aws_opensearchserverless_collection.hr_policies.id
  }

  provisioner "local-exec" {
    # Sleep 60s to allow the AOSS data access policy to propagate before the
    # index creation request. AOSS data access policies have eventual consistency.
    # uv run creates an ephemeral venv — does not modify system Python.
    command = "sleep 60 && uv run --with boto3 --with opensearch-py python3 ${path.module}/scripts/create-os-index.py ${aws_opensearchserverless_collection.hr_policies.collection_endpoint} ${var.aws_region}"
  }

  depends_on = [
    aws_opensearchserverless_collection.hr_policies,
    aws_opensearchserverless_access_policy.hr_policies_data,
  ]
}

# ---------------------------------------------------------------------------
# Bedrock Knowledge Base
# ---------------------------------------------------------------------------

resource "aws_bedrockagent_knowledge_base" "hr_policies" {
  name        = "hr-policies-kb-dev"
  description = "HR policy documents for the HR Assistant agent. Dev environment placeholder documents."
  role_arn    = aws_iam_role.hr_policies_kb.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0"
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.hr_policies.arn
      vector_index_name = local.kb_index_name
      field_mapping {
        vector_field   = "embedding"
        text_field     = "text"
        metadata_field = "metadata"
      }
    }
  }

  tags = merge(var.tags, { Component = "hr-policies-kb" })

  depends_on = [
    aws_iam_role_policy.hr_policies_kb,
    aws_opensearchserverless_access_policy.hr_policies_data,
    null_resource.create_hr_policies_index,
  ]
}

# ---------------------------------------------------------------------------
# Knowledge Base data source — reads from hr-policies/ prefix in the
# document landing S3 bucket (provisioned by the platform layer).
# ---------------------------------------------------------------------------

resource "aws_bedrockagent_data_source" "hr_policies" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.hr_policies.id
  name              = "hr-policies-s3-source"
  description       = "HR policy documents in the platform document landing bucket."

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn         = "arn:aws:s3:::${local.document_landing_bucket}"
      inclusion_prefixes = ["hr-policies/"]
    }
  }
}

# ---------------------------------------------------------------------------
# Sample HR policy documents — upload to S3 for dev KB testing.
# These are dev placeholders. Production documents ingest via the Glue/Macie
# pipeline (Phase 3). Content is consistent with smoke test golden dataset.
# ---------------------------------------------------------------------------

resource "aws_s3_object" "hr_doc_annual_leave" {
  bucket       = local.document_landing_bucket
  key          = "hr-policies/annual-leave-policy.md"
  source       = "${path.module}/kb-docs/annual-leave-policy.md"
  content_type = "text/markdown"
  etag         = filemd5("${path.module}/kb-docs/annual-leave-policy.md")
  tags         = merge(var.tags, { Component = "hr-policies-kb-docs" })
}

resource "aws_s3_object" "hr_doc_sick_leave" {
  bucket       = local.document_landing_bucket
  key          = "hr-policies/sick-leave-policy.md"
  source       = "${path.module}/kb-docs/sick-leave-policy.md"
  content_type = "text/markdown"
  etag         = filemd5("${path.module}/kb-docs/sick-leave-policy.md")
  tags         = merge(var.tags, { Component = "hr-policies-kb-docs" })
}

resource "aws_s3_object" "hr_doc_parental_leave" {
  bucket       = local.document_landing_bucket
  key          = "hr-policies/parental-leave-policy.md"
  source       = "${path.module}/kb-docs/parental-leave-policy.md"
  content_type = "text/markdown"
  etag         = filemd5("${path.module}/kb-docs/parental-leave-policy.md")
  tags         = merge(var.tags, { Component = "hr-policies-kb-docs" })
}

resource "aws_s3_object" "hr_doc_remote_working" {
  bucket       = local.document_landing_bucket
  key          = "hr-policies/remote-working-policy.md"
  source       = "${path.module}/kb-docs/remote-working-policy.md"
  content_type = "text/markdown"
  etag         = filemd5("${path.module}/kb-docs/remote-working-policy.md")
  tags         = merge(var.tags, { Component = "hr-policies-kb-docs" })
}

resource "aws_s3_object" "hr_doc_expenses" {
  bucket       = local.document_landing_bucket
  key          = "hr-policies/expenses-policy.md"
  source       = "${path.module}/kb-docs/expenses-policy.md"
  content_type = "text/markdown"
  etag         = filemd5("${path.module}/kb-docs/expenses-policy.md")
  tags         = merge(var.tags, { Component = "hr-policies-kb-docs" })
}

resource "aws_s3_object" "hr_doc_performance_review" {
  bucket       = local.document_landing_bucket
  key          = "hr-policies/performance-review-process.md"
  source       = "${path.module}/kb-docs/performance-review-process.md"
  content_type = "text/markdown"
  etag         = filemd5("${path.module}/kb-docs/performance-review-process.md")
  tags         = merge(var.tags, { Component = "hr-policies-kb-docs" })
}

resource "aws_s3_object" "hr_doc_eap" {
  bucket       = local.document_landing_bucket
  key          = "hr-policies/employee-assistance-programme.md"
  source       = "${path.module}/kb-docs/employee-assistance-programme.md"
  content_type = "text/markdown"
  etag         = filemd5("${path.module}/kb-docs/employee-assistance-programme.md")
  tags         = merge(var.tags, { Component = "hr-policies-kb-docs" })
}

resource "aws_s3_object" "hr_doc_benefits" {
  bucket       = local.document_landing_bucket
  key          = "hr-policies/benefits-enrolment-guide.md"
  source       = "${path.module}/kb-docs/benefits-enrolment-guide.md"
  content_type = "text/markdown"
  etag         = filemd5("${path.module}/kb-docs/benefits-enrolment-guide.md")
  tags         = merge(var.tags, { Component = "hr-policies-kb-docs" })
}
