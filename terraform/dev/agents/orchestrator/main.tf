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

# ---------------------------------------------------------------------------
# Remote state — foundation + platform + both HR agents.
# Reads only; this layer never writes to other state files.
# ---------------------------------------------------------------------------

data "terraform_remote_state" "foundation" {
  backend = "s3"
  config = {
    bucket = "ai-platform-terraform-state-dev-096305373014"
    key    = "dev/foundation/terraform.tfstate"
    region = "us-east-2"
  }
}

data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "ai-platform-terraform-state-dev-096305373014"
    key    = "dev/platform/terraform.tfstate"
    region = "us-east-2"
  }
}

locals {
  tags              = merge(var.tags, { Environment = var.environment })
  name_prefix       = "${var.project_name}-${var.environment}"
  runtime_enabled   = var.agent_image_uri != "" ? 1 : 0
  ecr_repository    = "${var.project_name}-${var.environment}-orchestrator"
  audit_log_group   = "/ai-platform/orchestrator/audit-${var.environment}"
  app_log_group     = "/ai-platform/orchestrator/app-${var.environment}"
}

# ---------------------------------------------------------------------------
# ECR repository — this layer owns the orchestrator image repo.
# Separate from hr-assistant ECR repo to keep orchestrator images isolated
# for tag hygiene, lifecycle policies, and retention.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "orchestrator" {
  name                 = local.ecr_repository
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = data.terraform_remote_state.foundation.outputs.storage_kms_key_arn
  }

  tags = merge(local.tags, { Component = "orchestrator-ecr" })
}

resource "aws_ecr_lifecycle_policy" "orchestrator" {
  repository = aws_ecr_repository.orchestrator.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 7 days."
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------------------
# Audit log group — structured JSON audit records from the orchestrator
# middleware. Hashes only, no plaintext prompts or responses.
# Retention longer than runtime logs (runtime logs = 30d).
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "orchestrator_audit" {
  name              = local.audit_log_group
  retention_in_days = var.audit_log_retention_days
  kms_key_id        = data.terraform_remote_state.foundation.outputs.storage_kms_key_arn

  tags = merge(local.tags, { Component = "orchestrator-audit" })
}

resource "aws_cloudwatch_log_group" "orchestrator_app" {
  name              = local.app_log_group
  retention_in_days = 30
  kms_key_id        = data.terraform_remote_state.foundation.outputs.storage_kms_key_arn

  tags = merge(local.tags, { Component = "orchestrator-app" })
}

# ---------------------------------------------------------------------------
# IAM — inline per ADR-017. Orchestrator has a very different permission
# surface from sub-agents (cross-runtime invoke, no KB, no tool Lambdas)
# so it gets its own execution role rather than reusing the platform
# agentcore_runtime role.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "orchestrator_runtime" {
  name        = "${local.name_prefix}-orchestrator-runtime"
  description = "Orchestrator AgentCore runtime execution role - cross-runtime invoke, registry read, audit writes."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowAgentCoreAssumeRole"
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })

  tags = merge(local.tags, { Name = "${local.name_prefix}-orchestrator-runtime" })
}

resource "aws_iam_role_policy" "orchestrator_runtime" {
  name = "${local.name_prefix}-orchestrator-runtime-policy"
  role = aws_iam_role.orchestrator_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRTokenAccess"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPullOrchestratorImage"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = aws_ecr_repository.orchestrator.arn
      },
      {
        # Claude 4.x requires both the inference profile ARN and the foundation
        # model ARN. ApplyGuardrail scoped to this layer's guardrail.
        Sid    = "BedrockModelInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:ApplyGuardrail",
        ]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:${var.aws_region}:${var.account_id}:inference-profile/*",
          "arn:aws:bedrock:*::foundation-model/*",
          aws_bedrock_guardrail.orchestrator.guardrail_arn,
        ]
      },
      {
        # Cross-runtime invoke — prefix-based on account runtimes. Covers
        # current and future sub-agents without policy edits. See
        # IAM Scoping Pattern in specs/orchestrator-plan.md.
        Sid      = "AgentCoreInvokeSubAgents"
        Effect   = "Allow"
        Action   = ["bedrock-agentcore:InvokeAgentRuntime"]
        Resource = "arn:aws:bedrock-agentcore:${var.aws_region}:${var.account_id}:runtime/*"
      },
      {
        # Registry read-only. Orchestrator scans at invocation time and
        # caches in-process with a 60s TTL.
        Sid    = "DynamoDBRegistryRead"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:Scan",
          "dynamodb:Query",
        ]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${var.account_id}:table/${data.terraform_remote_state.platform.outputs.agent_registry_table}"
      },
      {
        # Session memory — orchestrator request/turn state (plan D1).
        Sid    = "DynamoDBSessionMemoryReadWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
        ]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${var.account_id}:table/${data.terraform_remote_state.platform.outputs.session_memory_table}"
      },
      {
        # PII detection for inbound/outbound middleware. Comprehend has
        # no resource-level scoping.
        Sid      = "ComprehendPiiDetect"
        Effect   = "Allow"
        Action   = ["comprehend:DetectPiiEntities"]
        Resource = "*"
      },
      {
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
          "${aws_cloudwatch_log_group.orchestrator_audit.arn}:*",
          "${aws_cloudwatch_log_group.orchestrator_app.arn}:*",
        ]
      },
      {
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "bedrock-agentcore" }
        }
      },
      {
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
        # KMS decrypt for registry + session tables + audit log group +
        # prompt vault bucket (all encrypted with the foundation KMS key).
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [data.terraform_remote_state.foundation.outputs.storage_kms_key_arn]
      },
      {
        # S3SessionManager — Strands persists session history to the prompt
        # vault bucket under strands-sessions/orchestrator/*.
        Sid    = "S3StrandsSessionReadWrite"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::${data.terraform_remote_state.platform.outputs.prompt_vault_bucket}",
          "arn:aws:s3:::${data.terraform_remote_state.platform.outputs.prompt_vault_bucket}/strands-sessions/orchestrator/*",
        ]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Guardrail — orchestrator-specific. Blocks out-of-scope topics at the
# front door before dispatch. Sub-agents retain their own guardrails.
# Version pinned to DRAFT in dev; version-pinned for staging/prod later.
# ---------------------------------------------------------------------------

resource "aws_bedrock_guardrail" "orchestrator" {
  name                      = "${local.name_prefix}-orchestrator-guardrail"
  description               = "Orchestrator front-door guardrail — denies legal/medical/financial advice; PII anonymization; content filters."
  blocked_input_messaging   = "I'm not able to help with that request. If this is something the HR team can help with, please contact them directly."
  blocked_outputs_messaging = "I'm not able to help with that request. If this is something the HR team can help with, please contact them directly."

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
  }

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

  # PII anonymization at the front door. Comprehend middleware (O.3) provides
  # richer entity-type coverage and structured audit records; the guardrail
  # is a defense-in-depth backstop.
  sensitive_information_policy_config {
    pii_entities_config {
      type   = "EMAIL"
      action = "ANONYMIZE"
    }
    pii_entities_config {
      type   = "PHONE"
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

  tags = merge(local.tags, { Component = "orchestrator-guardrail" })
}

# ---------------------------------------------------------------------------
# AgentCore runtime — count-gated on agent_image_uri. During initial O.2
# scaffold apply, agent_image_uri = "" and the runtime is not created.
# Phase O.3 builds and pushes the container, sets agent_image_uri in
# terraform.tfvars, and re-applies to create the runtime + registry entry.
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_agent_runtime" "orchestrator" {
  count = local.runtime_enabled

  # Underscores required — provider rejects hyphens in agent_runtime_name.
  agent_runtime_name = replace("${local.name_prefix}-orchestrator", "-", "_")
  description        = "Orchestrator supervisor agent runtime — dev environment."
  role_arn           = aws_iam_role.orchestrator_runtime.arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = var.agent_image_uri
    }
  }

  network_configuration {
    network_mode = "VPC"
    network_mode_config {
      security_groups = [data.terraform_remote_state.platform.outputs.agentcore_sg_id]
      subnets         = data.terraform_remote_state.platform.outputs.subnet_ids
    }
  }

  environment_variables = {
    AGENT_ENV            = var.environment
    BEDROCK_MODEL_ID     = var.model_arn
    GUARDRAIL_ID         = aws_bedrock_guardrail.orchestrator.guardrail_id
    GUARDRAIL_VERSION    = "DRAFT"
    SESSION_MEMORY_TABLE = data.terraform_remote_state.platform.outputs.session_memory_table
    AGENT_REGISTRY_TABLE = data.terraform_remote_state.platform.outputs.agent_registry_table
    PROMPT_VAULT_BUCKET  = data.terraform_remote_state.platform.outputs.prompt_vault_bucket
    AUDIT_LOG_GROUP      = aws_cloudwatch_log_group.orchestrator_audit.name
    APP_LOG_GROUP        = aws_cloudwatch_log_group.orchestrator_app.name
    LOG_LEVEL            = "INFO"
    LOG_FORMAT           = "json"
    LOG_DELIVERY_NONCE   = "2"
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Runtime CloudWatch log group — pre-create with KMS + retention.
# AgentCore auto-creates this on first runtime deploy (Pitfall 5 from the
# Strands layer). May require `terraform import` on first apply.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "orchestrator_runtime" {
  count = local.runtime_enabled

  name              = "/aws/bedrock-agentcore/runtimes/${aws_bedrockagentcore_agent_runtime.orchestrator[0].agent_runtime_id}-DEFAULT"
  retention_in_days = 30
  kms_key_id        = data.terraform_remote_state.foundation.outputs.storage_kms_key_arn

  tags = merge(local.tags, { Component = "orchestrator-runtime-logs" })
}

# ---------------------------------------------------------------------------
# DynamoDB registry self-entry. Gives operators one-table visibility of
# all agents including the front door. Uses the special domain
# "_orchestrator" — sub-agents never claim this domain.
# ---------------------------------------------------------------------------

resource "terraform_data" "orchestrator_manifest" {
  count = local.runtime_enabled

  triggers_replace = [
    var.agent_image_uri,
    aws_bedrock_guardrail.orchestrator.guardrail_id,
    aws_bedrock_guardrail.orchestrator.version,
    aws_bedrockagentcore_agent_runtime.orchestrator[0].agent_runtime_arn,
    var.model_arn,
    "_orchestrator",
    "orchestrator",
    "true",
    "platform",
  ]

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      echo 'Registering orchestrator manifest...'
      aws dynamodb put-item \
        --region "${var.aws_region}" \
        --table-name "${data.terraform_remote_state.platform.outputs.agent_registry_table}" \
        --item '{
          "agent_id":                    {"S": "orchestrator-dev"},
          "display_name":                {"S": "Orchestrator (Dev)"},
          "agent_description":           {"S": "Front-door orchestrator that routes employee requests to the appropriate sub-agent based on topic domain"},
          "model_arn":                   {"S": "${var.model_arn}"},
          "guardrail_id":                {"S": "${aws_bedrock_guardrail.orchestrator.guardrail_id}"},
          "guardrail_version":           {"S": "DRAFT"},
          "endpoint_id":                 {"S": "${aws_bedrockagentcore_agent_runtime.orchestrator[0].agent_runtime_id}"},
          "runtime_arn":                 {"S": "${aws_bedrockagentcore_agent_runtime.orchestrator[0].agent_runtime_arn}"},
          "audit_log_group":             {"S": "${aws_cloudwatch_log_group.orchestrator_audit.name}"},
          "allowed_tools":               {"SS": ["dispatch_agent"]},
          "data_classification_ceiling": {"S": "INTERNAL"},
          "session_ttl_hours":           {"N": "24"},
          "response_latency_p95_ms":     {"N": "8000"},
          "monthly_usd_limit":           {"N": "100"},
          "alert_threshold_pct":         {"N": "80"},
          "domains":                     {"SS": ["_orchestrator"]},
          "tier":                        {"S": "orchestrator"},
          "enabled":                     {"BOOL": true},
          "owner_team":                  {"S": "platform"},
          "environment":                 {"S": "${var.environment}"},
          "registered_at":               {"S": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
        }'
      echo 'Orchestrator manifest registered successfully.'
    SCRIPT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-SCRIPT
      aws dynamodb delete-item \
        --region "us-east-2" \
        --table-name "ai-platform-dev-agent-registry" \
        --key '{"agent_id": {"S": "orchestrator-dev"}}'
    SCRIPT
  }
}
