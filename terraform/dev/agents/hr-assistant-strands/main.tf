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
# Platform state — reads shared platform outputs.
# ---------------------------------------------------------------------------

data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "ai-platform-terraform-state-dev-096305373014"
    key    = "dev/platform/terraform.tfstate"
    region = "us-east-2"
  }
}

locals {
  tags = merge(var.tags, { Environment = var.environment })
}

# ---------------------------------------------------------------------------
# AgentCore runtime role — look up by name; platform layer owns it.
# Not exported as a platform output so resolved via data source.
# ---------------------------------------------------------------------------

data "aws_iam_role" "agentcore_runtime" {
  name = "${var.project_name}-agentcore-runtime-${var.environment}"
}

# ---------------------------------------------------------------------------
# AgentCore runtime — dedicated endpoint for the Strands container.
#
# Separate from the platform's existing runtime so the boto3 agent remains
# fully operational as a regression baseline throughout Phase 2.
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_agent_runtime" "strands" {
  # Underscores required — provider rejects hyphens in agent_runtime_name.
  agent_runtime_name = replace("${var.project_name}-${var.environment}-hr-assistant-strands", "-", "_")
  description        = "HR Assistant Strands agent runtime — dev environment."
  role_arn           = data.aws_iam_role.agentcore_runtime.arn

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
    SESSION_MEMORY_TABLE = data.terraform_remote_state.platform.outputs.session_memory_table
    AGENT_REGISTRY_TABLE = data.terraform_remote_state.platform.outputs.agent_registry_table
    PROMPT_VAULT_BUCKET  = data.terraform_remote_state.platform.outputs.prompt_vault_bucket
    APP_LOG_GROUP        = aws_cloudwatch_log_group.strands_app.name
    LOG_LEVEL            = "INFO"
    LOG_FORMAT           = "json"
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# DynamoDB agent registry entry.
#
# The container reads this item at startup to load its configuration.
# Reuses the existing system prompt, guardrail, and KB from the hr-assistant
# layer — values are passed as variables sourced from that layer's outputs.
# ---------------------------------------------------------------------------

resource "terraform_data" "hr_strands_manifest" {
  triggers_replace = [
    var.agent_image_uri,
    var.system_prompt_arn,
    var.guardrail_id,
    var.knowledge_base_id,
    var.prompt_vault_lambda_arn,
    var.model_arn,
    aws_bedrockagentcore_agent_runtime.strands.agent_runtime_arn,
    # Orchestrator discovery fields.
    "hr.policy,hr.escalation",
    "conversational",
    "true",
    "hr-platform",
  ]

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      echo 'Registering HR Assistant Strands agent manifest...'
      aws dynamodb put-item \
        --region "${var.aws_region}" \
        --table-name "${data.terraform_remote_state.platform.outputs.agent_registry_table}" \
        --item '{
          "agent_id":                    {"S": "hr-assistant-strands-dev"},
          "display_name":                {"S": "HR Assistant Strands (Dev)"},
          "agent_description":           {"S": "an enterprise HR Assistant that answers employee questions about HR policies, benefits, and workplace procedures"},
          "model_arn":                   {"S": "${var.model_arn}"},
          "system_prompt_arn":           {"S": "${var.system_prompt_arn}"},
          "guardrail_id":                {"S": "${var.guardrail_id}"},
          "guardrail_version":           {"S": "${var.guardrail_version}"},
          "knowledge_base_id":           {"S": "${var.knowledge_base_id}"},
          "prompt_vault_lambda_arn":     {"S": "${var.prompt_vault_lambda_arn}"},
          "endpoint_id":                 {"S": "${aws_bedrockagentcore_agent_runtime.strands.agent_runtime_id}"},
          "runtime_arn":                 {"S": "${aws_bedrockagentcore_agent_runtime.strands.agent_runtime_arn}"},
          "gateway_id":                  {"S": "${data.terraform_remote_state.platform.outputs.agentcore_gateway_id}"},
          "allowed_tools":               {"SS": ["glean-search"]},
          "data_classification_ceiling": {"S": "INTERNAL"},
          "session_ttl_hours":           {"N": "24"},
          "grounding_score_min":         {"N": "0.75"},
          "response_latency_p95_ms":     {"N": "5000"},
          "monthly_usd_limit":           {"N": "50"},
          "alert_threshold_pct":         {"N": "80"},
          "domains":                     {"SS": ["hr.policy", "hr.escalation"]},
          "tier":                        {"S": "conversational"},
          "enabled":                     {"BOOL": true},
          "owner_team":                  {"S": "hr-platform"},
          "environment":                 {"S": "${var.environment}"},
          "registered_at":               {"S": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
        }'
      echo 'Agent manifest registered successfully.'
    SCRIPT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-SCRIPT
      aws dynamodb delete-item \
        --region "us-east-2" \
        --table-name "ai-platform-dev-agent-registry" \
        --key '{"agent_id": {"S": "hr-assistant-strands-dev"}}'
    SCRIPT
  }
}

# ---------------------------------------------------------------------------
# CloudWatch log group — pre-create with 30-day retention and KMS encryption.
# AgentCore writes to this path automatically once the runtime is READY.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "strands_runtime" {
  name              = "/aws/bedrock-agentcore/runtimes/${aws_bedrockagentcore_agent_runtime.strands.agent_runtime_id}-DEFAULT"
  retention_in_days = 30
  kms_key_id        = data.terraform_remote_state.platform.outputs.kms_key_arn

  tags = merge(local.tags, { Component = "runtime-logs" })
}

# ---------------------------------------------------------------------------
# Direct-write app log group — bypasses the AgentCore stdout-capture sidecar.
# Platform IAM policy covers this via the /ai-platform/*/app-dev wildcard.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "strands_app" {
  name              = "/ai-platform/hr-assistant-strands/app-${var.environment}"
  retention_in_days = 30
  kms_key_id        = data.terraform_remote_state.platform.outputs.kms_key_arn

  tags = merge(local.tags, { Component = "strands-app" })
}
