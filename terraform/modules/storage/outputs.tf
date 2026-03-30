output "document_landing_bucket" {
  description = "Name of the S3 bucket used as the Knowledge Base document landing zone."
  value       = aws_s3_bucket.document_landing.bucket
}

output "prompt_vault_bucket" {
  description = "Name of the S3 bucket used as the Prompt Vault."
  value       = aws_s3_bucket.prompt_vault.bucket
}

output "session_memory_table" {
  description = "Name of the DynamoDB table used for AgentCore session memory."
  value       = aws_dynamodb_table.session_memory.name
}

output "agent_registry_table" {
  description = "Name of the DynamoDB table used as the agent registry."
  value       = aws_dynamodb_table.agent_registry.name
}
