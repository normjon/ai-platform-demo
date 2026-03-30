variable "project_name" {
  description = "Project name. Used as part of all IAM resource names."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, production). Used as part of all IAM resource names."
  type        = string
}

variable "aws_region" {
  description = "AWS region. Used when constructing model ARNs and log group ARNs in IAM policies."
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID. Used in trust policy conditions and IAM policy resource ARNs."
  type        = string
}

variable "document_bucket_arn" {
  description = "ARN of the S3 document landing bucket. Granted to the Bedrock KB role for source document reads and the Lambda role for document access."
  type        = string
}

variable "prompt_vault_bucket_arn" {
  description = "ARN of the S3 Prompt Vault bucket. Granted to the Lambda role for prompt template reads and writes."
  type        = string
}

variable "agentcore_log_group_arn" {
  description = "ARN of the CloudWatch log group for AgentCore invocations. Granted to the AgentCore runtime role for log writes."
  type        = string
}

variable "session_table_arn" {
  description = "ARN of the DynamoDB session memory table. Granted to the Lambda role for session read/write."
  type        = string
}

variable "registry_table_arn" {
  description = "ARN of the DynamoDB agent registry table. Granted to the Lambda role for registry read/write."
  type        = string
}

variable "tags" {
  description = "Additional tags merged onto all resources. ManagedBy, Module, Environment, and Project are always added."
  type        = map(string)
  default     = {}
}
