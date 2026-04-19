variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-2"
}

variable "account_id" {
  description = "AWS account ID."
  type        = string
}

variable "environment" {
  description = "Deployment environment. Only 'dev' is in scope for this repository."
  type        = string
  default     = "dev"

  validation {
    condition     = var.environment == "dev"
    error_message = "This repository provisions the dev environment only."
  }
}

variable "project_name" {
  description = "Project name used as a prefix on all named resources."
  type        = string
  default     = "ai-platform"
}

variable "model_arn" {
  description = "Bedrock model inference profile ID. Claude 4.x requires a cross-region inference profile (us.*) for on-demand throughput."
  type        = string
  default     = "us.anthropic.claude-sonnet-4-6"
}

variable "agent_image_uri" {
  description = "ECR image URI for the Strands agent container. Tag must be a git SHA (ADR-009). Set after container build and push."
  type        = string
}

variable "system_prompt_arn" {
  description = "Bedrock Prompt ARN for the HR Assistant system prompt. Get from: terraform output -raw system_prompt_version_arn in agents/hr-assistant."
  type        = string
}

variable "guardrail_id" {
  description = "Bedrock Guardrail ID. Get from: terraform output -raw guardrail_id in agents/hr-assistant."
  type        = string
}

variable "guardrail_version" {
  description = "Bedrock Guardrail version."
  type        = string
  default     = "DRAFT"
}

variable "knowledge_base_id" {
  description = "Bedrock Knowledge Base ID. Get from: terraform output -raw knowledge_base_id in agents/hr-assistant."
  type        = string
}

variable "prompt_vault_lambda_arn" {
  description = "Prompt Vault writer Lambda ARN. Get from: terraform output -raw prompt_vault_writer_arn in agents/hr-assistant."
  type        = string
}

variable "tags" {
  description = "Map of tags to apply to all resources in this layer."
  type        = map(string)
  default = {
    Project   = "ai-platform"
    ManagedBy = "terraform"
    Layer     = "agents/hr-assistant-strands"
  }
}
