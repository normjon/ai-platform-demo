# ---------------------------------------------------------------------------
# Role ARNs and names — consumed by agentcore/, bedrock/, storage/,
# observability/ modules. Never hardcode these ARNs in other modules.
# ---------------------------------------------------------------------------

output "agentcore_runtime_role_arn" {
  description = "ARN of the AgentCore runtime IAM role."
  value       = aws_iam_role.agentcore_runtime.arn
}

output "agentcore_runtime_role_name" {
  description = "Name of the AgentCore runtime IAM role."
  value       = aws_iam_role.agentcore_runtime.name
}

output "bedrock_kb_role_arn" {
  description = "ARN of the Bedrock Knowledge Base ingestion IAM role."
  value       = aws_iam_role.bedrock_kb.arn
}

output "bedrock_kb_role_name" {
  description = "Name of the Bedrock Knowledge Base ingestion IAM role."
  value       = aws_iam_role.bedrock_kb.name
}

output "lambda_execution_role_arn" {
  description = "ARN of the Lambda execution IAM role."
  value       = aws_iam_role.lambda_execution.arn
}

output "lambda_execution_role_name" {
  description = "Name of the Lambda execution IAM role."
  value       = aws_iam_role.lambda_execution.name
}

# Kept for consumption by storage/, observability/, and bedrock/ modules.
output "storage_kms_key_arn" {
  description = "ARN of the KMS key used to encrypt S3, DynamoDB, and CloudWatch log groups."
  value       = aws_kms_key.storage.arn
}
