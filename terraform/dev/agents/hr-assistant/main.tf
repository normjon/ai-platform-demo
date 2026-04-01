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
