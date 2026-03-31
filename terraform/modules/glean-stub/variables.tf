variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
}

variable "lambda_role_arn" {
  description = "IAM role ARN for the Lambda execution role (IRSA - ADR-001)."
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
