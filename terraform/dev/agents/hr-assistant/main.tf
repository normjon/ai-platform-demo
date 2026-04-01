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

resource "aws_bedrock_prompt" "hr_assistant_system" {
  name        = "hr-assistant-system-prompt-dev"
  description = "System prompt for the HR Assistant agent - dev environment."

  default_variant = "default"

  variant {
    name          = "default"
    template_type = "TEXT"
    template_configuration {
      text {
        text = file("${path.module}/prompts/hr-assistant-system-prompt.txt")
      }
    }
  }

  tags = merge(var.tags, { Component = "system-prompt" })
}

resource "aws_bedrock_prompt_version" "hr_assistant_system" {
  prompt_arn  = aws_bedrock_prompt.hr_assistant_system.arn
  description = "Phase 1 baseline — dev environment."
}

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
      type   = "DATE_OF_BIRTH"
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
      type   = "BANK_ACCOUNT_NUMBER"
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
    systemPromptArn    = aws_bedrock_prompt_version.hr_assistant_system.arn
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
    aws_bedrock_prompt_version.hr_assistant_system.arn,
    aws_bedrock_guardrail.hr_assistant.guardrail_id,
    aws_bedrock_guardrail.hr_assistant.version,
    data.terraform_remote_state.platform.outputs.agentcore_endpoint_id,
    data.terraform_remote_state.platform.outputs.agentcore_gateway_id,
    var.model_arn,
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
          "system_prompt_arn": {"S": "${aws_bedrock_prompt_version.hr_assistant_system.arn}"},
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
          "environment":     {"S": "${var.environment}"},
          "registered_at":   {"S": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
        }'
      echo 'Agent manifest registered successfully.'
    SCRIPT
  }
}
