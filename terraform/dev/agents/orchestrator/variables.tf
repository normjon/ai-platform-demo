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
  description = "Bedrock model inference profile ID. Claude 4.x requires a cross-region inference profile (us.*) for on-demand throughput. Haiku 4.5 is used for routing: orchestrator's only LLM job is picking a domain and calling dispatch_agent — Sonnet-level reasoning is unnecessary and adds 2-3s of latency per turn."
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "agent_image_uri" {
  description = "ECR image URI for the orchestrator container. Tag must be a git SHA (ADR-009). Set after O.3 container build and push. Leave empty during initial O.2 scaffold apply — runtime and registry entry are count-gated and will not be created until this value is set."
  type        = string
  default     = ""
}

variable "audit_log_retention_days" {
  description = "Retention period for the orchestrator audit log group. Audit records are hashes only (no plaintext); retention can be longer than runtime logs."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Map of tags to apply to all resources in this layer."
  type        = map(string)
  default = {
    Project   = "ai-platform"
    ManagedBy = "terraform"
    Layer     = "agents/orchestrator"
  }
}
