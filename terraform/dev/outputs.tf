output "vpc_id" {
  description = "ID of the platform VPC."
  value       = module.networking.vpc_id
}

output "subnet_ids" {
  description = "IDs of the private subnets used by AgentCore and Lambda."
  value       = module.networking.subnet_ids
}

output "ecr_repository_url" {
  description = "ECR repository URL for the HR Assistant agent. Push images here before invoking the runtime."
  value       = module.agentcore.ecr_repository_url
}

output "agentcore_endpoint_id" {
  description = "AgentCore runtime endpoint ID."
  value       = module.agentcore.endpoint_id
}

output "document_landing_bucket" {
  description = "S3 bucket name for Knowledge Base document ingestion."
  value       = module.storage.document_landing_bucket
}

output "prompt_vault_bucket" {
  description = "S3 bucket name for the Prompt Vault."
  value       = module.storage.prompt_vault_bucket
}

output "session_memory_table" {
  description = "DynamoDB table name for AgentCore session memory."
  value       = module.storage.session_memory_table
}

output "agent_registry_table" {
  description = "DynamoDB table name for the agent registry."
  value       = module.storage.agent_registry_table
}

output "log_group_agentcore" {
  description = "CloudWatch log group name for AgentCore invocations."
  value       = module.observability.log_group_agentcore
}
