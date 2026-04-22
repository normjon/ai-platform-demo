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
# Remote state — foundation (KMS) + platform (subnets, SG, registry table).
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
  tags            = merge(var.tags, { Environment = var.environment })
  name_prefix     = "${var.project_name}-${var.environment}"
  runtime_enabled = var.agent_image_uri != "" ? 1 : 0
  ecr_repository  = "${var.project_name}-${var.environment}-stub-agent"
}

# ---------------------------------------------------------------------------
# ECR repository — stub-agent has its own repo for image isolation.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "stub" {
  name                 = local.ecr_repository
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = data.terraform_remote_state.foundation.outputs.storage_kms_key_arn
  }

  tags = merge(local.tags, { Component = "stub-agent-ecr" })
}

resource "aws_ecr_lifecycle_policy" "stub" {
  repository = aws_ecr_repository.stub.name

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
# IAM — inline per ADR-017. Minimal surface: ECR pull, CloudWatch logs +
# metrics, KMS decrypt, AgentCore workload identity. No Bedrock, no KB, no
# Comprehend, no DynamoDB — the stub is a pure echo.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "stub_runtime" {
  name        = "${local.name_prefix}-stub-agent-runtime"
  description = "Stub-agent AgentCore runtime execution role - deterministic echo only."

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

  tags = merge(local.tags, { Name = "${local.name_prefix}-stub-agent-runtime" })
}

resource "aws_iam_role_policy" "stub_runtime" {
  name = "${local.name_prefix}-stub-agent-runtime-policy"
  role = aws_iam_role.stub_runtime.id

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
        Sid    = "ECRPullStubImage"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = aws_ecr_repository.stub.arn
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
        ]
      },
      {
        Sid      = "CloudWatchMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "bedrock-agentcore" }
        }
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
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [data.terraform_remote_state.foundation.outputs.storage_kms_key_arn]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# AgentCore runtime — count-gated. Initial apply creates ECR + IAM only.
# Push container image, set agent_image_uri in terraform.tfvars, re-apply
# to land the runtime + registry manifest entry.
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_agent_runtime" "stub" {
  count = local.runtime_enabled

  # Underscores required — provider rejects hyphens in agent_runtime_name.
  agent_runtime_name = replace("${local.name_prefix}-stub-agent", "-", "_")
  description        = "Stub-agent deterministic echo runtime - dispatch validation only."
  role_arn           = aws_iam_role.stub_runtime.arn

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
    AGENT_ENV  = var.environment
    LOG_LEVEL  = "INFO"
    LOG_FORMAT = "json"
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Runtime CloudWatch log group — pre-create with KMS + retention.
# AgentCore auto-creates this on first runtime deploy (Pitfall 5 from the
# Strands layer). May require `terraform import` on first apply.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "stub_runtime" {
  count = local.runtime_enabled

  name              = "/aws/bedrock-agentcore/runtimes/${aws_bedrockagentcore_agent_runtime.stub[0].agent_runtime_id}-DEFAULT"
  retention_in_days = 30
  kms_key_id        = data.terraform_remote_state.foundation.outputs.storage_kms_key_arn

  tags = merge(local.tags, { Component = "stub-agent-runtime-logs" })
}

# ---------------------------------------------------------------------------
# DynamoDB registry entry. Onboarding a new sub-agent is a registry put —
# the orchestrator discovers it on the next cache miss with zero redeploy.
# ---------------------------------------------------------------------------

resource "terraform_data" "stub_manifest" {
  count = local.runtime_enabled

  triggers_replace = [
    var.agent_image_uri,
    aws_bedrockagentcore_agent_runtime.stub[0].agent_runtime_arn,
    "test.echo",
    "workflow",
    "true",
    "platform",
  ]

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      echo 'Registering stub-agent manifest...'
      aws dynamodb put-item \
        --region "${var.aws_region}" \
        --table-name "${data.terraform_remote_state.platform.outputs.agent_registry_table}" \
        --item '{
          "agent_id":                    {"S": "stub-agent-dev"},
          "display_name":                {"S": "Stub Agent (Dev)"},
          "agent_description":           {"S": "Deterministic echo agent for dispatch validation — use for prompts that explicitly request an echo test"},
          "endpoint_id":                 {"S": "${aws_bedrockagentcore_agent_runtime.stub[0].agent_runtime_id}"},
          "runtime_arn":                 {"S": "${aws_bedrockagentcore_agent_runtime.stub[0].agent_runtime_arn}"},
          "allowed_tools":               {"SS": ["none"]},
          "data_classification_ceiling": {"S": "INTERNAL"},
          "session_ttl_hours":           {"N": "1"},
          "response_latency_p95_ms":     {"N": "500"},
          "monthly_usd_limit":           {"N": "5"},
          "alert_threshold_pct":         {"N": "80"},
          "domains":                     {"SS": ["test.echo"]},
          "tier":                        {"S": "workflow"},
          "enabled":                     {"BOOL": true},
          "owner_team":                  {"S": "platform"},
          "environment":                 {"S": "${var.environment}"},
          "registered_at":               {"S": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
        }'
      echo 'Stub-agent manifest registered successfully.'
    SCRIPT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-SCRIPT
      aws dynamodb delete-item \
        --region "us-east-2" \
        --table-name "ai-platform-dev-agent-registry" \
        --key '{"agent_id": {"S": "stub-agent-dev"}}'
    SCRIPT
  }
}
