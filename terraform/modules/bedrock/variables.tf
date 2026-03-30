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
  description = "Primary reasoning model ARN."
  type        = string
}

variable "model_arn_embeddings" {
  description = "Embedding model ARN used by the Knowledge Base."
  type        = string
}

variable "document_landing_bucket" {
  description = "Name of the S3 bucket used as the Knowledge Base data source."
  type        = string
}

variable "kb_role_arn" {
  description = "IAM role ARN that the Knowledge Base assumes for ingestion."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN used to encrypt the OpenSearch Serverless collection."
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
