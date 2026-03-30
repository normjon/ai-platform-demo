variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "account_id" {
  description = "AWS account ID. Used in resource names that require global uniqueness (e.g. S3 state bucket)."
  type        = string
}

variable "environment" {
  description = "Deployment environment. Only 'dev' is in scope for this repository."
  type        = string
  default     = "dev"

  validation {
    condition     = var.environment == "dev"
    error_message = "This repository provisions the dev environment only. Do not provision staging or production here."
  }
}

variable "project_name" {
  description = "Project name used as a prefix on all named resources."
  type        = string
  default     = "ai-platform"
}

variable "vpc_cidr" {
  description = "CIDR block for the platform VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ, minimum two for HA)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

# ---------------------------------------------------------------------------
# Approved Bedrock model ARNs — reference through variables only.
# Never hardcode ARNs in module code (CLAUDE.md / ADR-009).
# ---------------------------------------------------------------------------

variable "model_arn_primary" {
  description = "Primary reasoning model ARN. Used by AgentCore agents for complex multi-step tasks."
  type        = string
  default     = "anthropic.claude-sonnet-4-6"
}

variable "model_arn_evaluation" {
  description = "Evaluation/scoring model ARN. Used for LLM-as-Judge and classification tasks."
  type        = string
  default     = "anthropic.claude-haiku-4-5-20251001"
}

variable "model_arn_embeddings" {
  description = "Embedding model ARN. Used by the Bedrock Knowledge Base for vector indexing."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "agent_image_uri" {
  description = "ECR image URI for the HR Assistant agent container. Tag must be a git SHA (ADR-009)."
  type        = string
}

variable "glean_mcp_endpoint" {
  description = "Glean MCP server endpoint registered in the AgentCore MCP Gateway."
  type        = string
  sensitive   = true
}
