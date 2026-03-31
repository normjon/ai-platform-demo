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
# HR Assistant agent — placeholder layer.
#
# The HR Assistant AgentCore runtime is currently managed by the platform/
# layer as the sole runtime endpoint. This layer is reserved for agent-
# specific configuration that the HR Assistant team owns independently:
#
#   - Agent manifest and prompt templates (Prompt Vault references)
#   - Knowledge Base configuration (when Bedrock KB is in scope)
#   - Agent-specific IAM grants (e.g. access to specific S3 prefixes)
#   - Agent test harness configuration
#
# When the platform team separates per-agent runtimes from the shared
# platform runtime, the AgentCore runtime resource and its IAM role will
# move here.
#
# No resources are deployed from this layer yet.
# ---------------------------------------------------------------------------
