output "kms_key_arn" {
  description = "ARN of the KMS CMK used to encrypt S3, DynamoDB, and CloudWatch resources."
  value       = aws_kms_key.storage.arn
}

output "kms_key_id" {
  description = "ID of the KMS CMK. Used when referencing the key in resource-level policies."
  value       = aws_kms_key.storage.key_id
}
