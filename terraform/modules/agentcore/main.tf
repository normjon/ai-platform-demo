# ---------------------------------------------------------------------------
# AgentCore Runtime - single dev endpoint, VPC-private, Graviton (arm64).
#
# Resource type: aws_bedrockagentcore_agent_runtime (requires hashicorp/aws ~> 6.0)
# Reference baseline: https://github.com/awslabs/amazon-bedrock-agentcore-samples
#   /tree/main/04-infrastructure-as-code/terraform/basic-runtime
#
# ADR-001: role_arn uses IRSA - no env-var credentials.
# ADR-004: container image must be built for arm64/Graviton (CLAUDE.md).
#          Architecture is enforced at image build time (uv + aarch64 target),
#          not as a provider attribute on this resource.
# ADR-009: agent_image_uri tag must be a git SHA - never 'latest'.
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_agent_runtime" "dev" {
  # Underscores required - the provider rejects hyphens in agent_runtime_name.
  agent_runtime_name = replace("${var.name_prefix}-runtime", "-", "_")
  description        = "Dev AgentCore runtime for the HR Assistant test agent."
  role_arn           = var.agentcore_role_arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = var.agent_image_uri
    }
  }

  # VPC mode keeps the runtime private - no public internet exposure (CLAUDE.md security rules).
  network_configuration {
    network_mode = "VPC"
    network_mode_config {
      security_groups = [var.agentcore_sg_id]
      subnets         = var.subnet_ids
    }
  }

  environment_variables = {
    AGENT_ENV = "dev"
    # Model ARN surfaced as env var so agent code references it without hardcoding (ADR-009).
    BEDROCK_MODEL_ID     = var.model_arn_primary
    SESSION_MEMORY_TABLE = var.session_memory_table
    AGENT_REGISTRY_TABLE = var.agent_registry_table
    LOG_LEVEL            = "INFO"
    # Structured JSON logging to stdout (ADR-003).
    LOG_FORMAT           = "json"
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# MCP Gateway - registers the Glean Search MCP tool.
#
# authorizer_type = "AWS_IAM": access is controlled by IAM policies on the
# calling principal. No Cognito user pool is required in the dev environment.
# ADR-018: input validation against declared schema is enforced in agent code,
# not at the gateway infrastructure layer.
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_gateway" "mcp" {
  name            = "${var.name_prefix}-mcp-gateway"
  description     = "MCP Gateway for dev environment. Registers the Glean Search tool."
  role_arn        = var.agentcore_role_arn
  protocol_type   = "MCP"
  authorizer_type = "AWS_IAM"
  tags            = var.tags
}

# ---------------------------------------------------------------------------
# Gateway Target (Glean Search) — managed by terraform/dev/tools/glean/main.tf.
#
# The target is defined in the tools/glean layer so that it can be destroyed
# and reapplied independently of the platform and this module.
# See terraform/dev/tools/glean/README.md for the operational runbook.
# ---------------------------------------------------------------------------
