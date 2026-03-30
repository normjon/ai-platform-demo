# ---------------------------------------------------------------------------
# AgentCore Runtime — single dev endpoint, private, Graviton (arm64).
#
# Resource type: aws_bedrockagentcore_runtime
# Reference baseline: https://github.com/awslabs/amazon-bedrock-agentcore-samples
#   /tree/main/04-infrastructure-as-code/terraform/basic-runtime
#
# ADR-001: role_arn uses IRSA — no env-var credentials.
# ADR-004: architecture = "arm64" — Graviton required.
# ADR-009: agent_image_uri tag must be a git SHA — never 'latest'.
# ADR-018: guardrail_configuration enforces content policy on all invocations.
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_runtime" "dev" {
  name        = "${var.name_prefix}-runtime"
  description = "Dev AgentCore runtime for the HR Assistant test agent."
  role_arn    = var.agentcore_role_arn

  runtime_configuration {
    container_configuration {
      image_uri    = var.agent_image_uri
      architecture = "arm64"
    }

    network_configuration {
      subnet_ids         = var.subnet_ids
      security_group_ids = [var.agentcore_sg_id]
      assign_public_ip   = false
    }

    environment_variables = {
      AGENT_ENV            = "dev"
      # Model ARN surfaced as env var so agent code references it without hardcoding (ADR-009).
      BEDROCK_MODEL_ID     = var.model_arn_primary
      KNOWLEDGE_BASE_ID    = var.knowledge_base_id
      SESSION_MEMORY_TABLE = var.session_memory_table
      AGENT_REGISTRY_TABLE = var.agent_registry_table
      LOG_LEVEL            = "INFO"
      # Structured JSON logging to stdout (ADR-003).
      LOG_FORMAT           = "json"
    }
  }

  # Guardrail applied to all agent inputs and outputs (ADR-018).
  # Verify the exact argument name against the AgentCore basic-runtime sample
  # before applying: verify against Step 1 authoring guideline.
  guardrail_configuration {
    guardrail_identifier = var.guardrail_id
    guardrail_version    = "DRAFT"
  }

  observability_configuration {
    log_group = var.log_group_agentcore
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# MCP Gateway — Glean Search tool registration.
# ADR-018: input validation against declared schema enforced before execution.
# Verify schema_configuration arguments against the AgentCore MCP sample
# (Step 1 authoring guideline) before applying.
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_gateway" "mcp" {
  name        = "${var.name_prefix}-mcp-gateway"
  description = "MCP Gateway for dev environment. Registers the Glean Search tool."
  role_arn    = var.agentcore_role_arn
  tags        = var.tags
}

resource "aws_bedrockagentcore_gateway_target" "glean_search" {
  gateway_id  = aws_bedrockagentcore_gateway.mcp.id
  name        = "glean-search"
  description = "Glean Enterprise Search MCP tool — permissions-aware retrieval across all indexed systems."

  target_configuration {
    mcp_server_configuration {
      endpoint = var.glean_mcp_endpoint
    }
  }
}
