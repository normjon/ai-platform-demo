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

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Tool        = "glean"
  }
}

# ---------------------------------------------------------------------------
# Platform state — reads gateway ID and shared platform outputs.
# Run `terraform apply` in platform/ before applying this layer.
# Tools read from platform remote state only — not from foundation directly.
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
# Glean tool IAM — Lambda execution role scoped to this tool's needs only.
#
# Option B: tools/ layer owns IAM for its own resources.
# The Glean stub Lambda only needs CloudWatch log writes — no Bedrock,
# DynamoDB, or S3 access is required for the stub implementation.
# Scope here; expand only when a real Glean endpoint requires additional
# permissions.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "glean_lambda" {
  name        = "${var.project_name}-glean-lambda-${var.environment}"
  description = "Execution role for the Glean stub Lambda MCP server. Scoped to CloudWatch logs only."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowLambdaAssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.project_name}-glean-lambda-${var.environment}" })
}

resource "aws_iam_role_policy" "glean_lambda" {
  name = "${var.project_name}-glean-lambda-${var.environment}-policy"
  role = aws_iam_role.glean_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/lambda/*:*"]
      },
      {
        Sid      = "XRayWrite"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = ["*"]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Glean stub Lambda — Lambda-backed MCP server for dev environment testing.
# Provides a real HTTPS endpoint so the gateway target registers as READY.
# Replace the gateway target endpoint with the real Glean MCP URL when
# a live Glean endpoint is available. See modules/glean-stub/README.md.
# ---------------------------------------------------------------------------

module "glean_stub" {
  source = "../../../modules/glean-stub"

  name_prefix     = local.name_prefix
  lambda_role_arn = aws_iam_role.glean_lambda.arn
  tags            = local.common_tags
}

# Gateway target — registered against the platform MCP gateway.
# AWS validates live connectivity to the MCP endpoint at create time,
# which is why this resource is managed by Terraform here (real endpoint)
# rather than manually out-of-band.
resource "aws_bedrockagentcore_gateway_target" "glean_stub" {
  name               = "glean-stub"
  description        = "Glean Search stub — Lambda MCP server for dev testing. Replace endpoint with real Glean URL when available."
  gateway_identifier = data.terraform_remote_state.platform.outputs.agentcore_gateway_id

  target_configuration {
    mcp {
      mcp_server {
        endpoint = module.glean_stub.function_url
      }
    }
  }
}

# ---------------------------------------------------------------------------
# AgentCore CloudWatch Metric Filter — Glean Tool
#
# Transforms glean_search log events from the HR Assistant container into
# a CloudWatch Metric in the AIPlatform/AgentCore namespace.
#
# Ownership: This layer owns this filter because the glean_search event is
# emitted by the Glean tool integration code in the HR Assistant container
# (agent.py:175). When a real Glean endpoint replaces the stub, the event
# name and schema remain the same — no filter change required.
#
# Named GleanCallCount (not ToolCallCount) because this filter only matches
# glean_search events. When additional MCP tools are added they will have
# different event names — each tool layer should define its own filter.
#
# Log source: /aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT
# Runtime ID is read from platform remote state, which this layer already
# consumes for the gateway registration.
# ---------------------------------------------------------------------------

data "aws_cloudwatch_log_group" "agentcore_runtime" {
  name = "/aws/bedrock-agentcore/runtimes/${data.terraform_remote_state.platform.outputs.agentcore_endpoint_id}-DEFAULT"
}

# Filter 5 — GleanCallCount
# Source event: {"event":"glean_search","query":"...","result_chars":<int>}
resource "aws_cloudwatch_log_metric_filter" "glean_call_count" {
  name           = "glean-call-count-dev"
  log_group_name = data.aws_cloudwatch_log_group.agentcore_runtime.name
  pattern        = "{ $.event = \"glean_search\" }"

  metric_transformation {
    name          = "GleanCallCount"
    namespace     = "AIPlatform/AgentCore"
    value         = "1"
    unit          = "Count"
    default_value = 0
  }
}
