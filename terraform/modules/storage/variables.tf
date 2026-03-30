variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
}

variable "account_id" {
  description = "AWS account ID appended to S3 bucket names for global uniqueness."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN used for S3 SSE and DynamoDB encryption."
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
