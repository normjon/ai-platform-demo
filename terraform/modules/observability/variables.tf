variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN used to encrypt CloudWatch log groups."
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
