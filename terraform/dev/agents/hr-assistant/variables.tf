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
  description = "Bedrock model ARN for the HR Assistant agent. Must use an approved model ARN."
  type        = string
  default     = "anthropic.claude-sonnet-4-6"
}

variable "tags" {
  description = "Map of tags to apply to all resources in this layer."
  type        = map(string)
  default = {
    Project   = "ai-platform"
    ManagedBy = "terraform"
    Layer     = "agents/hr-assistant"
  }
}
