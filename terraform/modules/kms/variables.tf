variable "project_name" {
  description = "Project name. Used in KMS key and alias naming."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, production). Used in KMS key and alias naming."
  type        = string
}

variable "aws_region" {
  description = "AWS region. Used in the CloudWatch Logs key policy condition."
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID. Used in the key policy root delegation statement."
  type        = string
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
