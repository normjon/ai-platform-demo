variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
}

variable "aws_region" {
  description = "AWS region."
  type        = string
}

variable "account_id" {
  description = "AWS account ID."
  type        = string
}

variable "model_arn_primary" {
  description = "Primary reasoning model ARN passed to the agent runtime as the BEDROCK_MODEL_ID env var."
  type        = string
}

variable "agent_image_uri" {
  description = "ECR image URI for the agent container. Tag must be a git SHA - never 'latest' (ADR-009)."
  type        = string
}

variable "ecr_repository_url" {
  description = "ECR repository URL (without tag). Passed from foundation layer output. Used for image push reference only - not consumed by runtime resource."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs where the AgentCore runtime runs."
  type        = list(string)
}

variable "agentcore_sg_id" {
  description = "Security group ID for the AgentCore runtime."
  type        = string
}

variable "session_memory_table" {
  description = "DynamoDB table name for session memory."
  type        = string
}

variable "agent_registry_table" {
  description = "DynamoDB table name for the agent registry."
  type        = string
}

variable "agentcore_role_arn" {
  description = "IAM role ARN assumed by the AgentCore runtime (IRSA - ADR-001)."
  type        = string
}

variable "log_group_agentcore" {
  description = "CloudWatch log group name for AgentCore invocation logs."
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
