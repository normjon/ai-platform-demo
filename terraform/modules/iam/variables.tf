variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
}

variable "aws_region" {
  description = "AWS region."
  type        = string
}

variable "account_id" {
  description = "AWS account ID used in IAM policy ARN conditions."
  type        = string
}

# ---------------------------------------------------------------------------
# Resource ARNs — passed from dev/main.tf locals so iam/ never reconstructs
# storage naming conventions internally (Step 3 module boundary rule).
# ---------------------------------------------------------------------------

variable "document_landing_bucket_arn" {
  description = "ARN of the S3 document landing bucket. Used in the KB ingestion role policy."
  type        = string
}

variable "session_memory_table_arn" {
  description = "ARN of the DynamoDB session memory table. Used in the AgentCore role policy."
  type        = string
}

variable "agent_registry_table_arn" {
  description = "ARN of the DynamoDB agent registry table. Used in the AgentCore role policy."
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
