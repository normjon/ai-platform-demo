output "agentcore_role_arn" {
  description = "IAM role ARN for the AgentCore runtime."
  value       = aws_iam_role.agentcore.arn
}

output "bedrock_kb_role_arn" {
  description = "IAM role ARN for Bedrock Knowledge Base ingestion."
  value       = aws_iam_role.bedrock_kb.arn
}

output "storage_kms_key_arn" {
  description = "KMS key ARN used to encrypt DynamoDB tables and S3 SSE."
  value       = aws_kms_key.storage.arn
}
