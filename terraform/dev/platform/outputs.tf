# ---------------------------------------------------------------------------
# Platform API — the interface contract for tools/ and agents/ layers.
#
# All tools and agents read these outputs via terraform_remote_state.
# Tools and agents depend only on platform outputs — they do not read from
# foundation directly. Platform re-exports the foundation values they need.
#
# Do not remove or rename outputs without updating all downstream layers.
# ---------------------------------------------------------------------------

output "agentcore_endpoint_id" {
  description = "AgentCore runtime endpoint ID."
  value       = module.agentcore.endpoint_id
}

output "agentcore_gateway_id" {
  description = "MCP Gateway ID — consumed by tools/ layers to register gateway targets."
  value       = module.agentcore.gateway_id
}

# Foundation values re-exported so tools/agents only need one remote_state read.
output "vpc_id" {
  description = "Platform VPC ID."
  value       = data.terraform_remote_state.foundation.outputs.vpc_id
}

output "subnet_ids" {
  description = "Private subnet IDs."
  value       = data.terraform_remote_state.foundation.outputs.subnet_ids
}

output "agentcore_sg_id" {
  description = "AgentCore security group ID."
  value       = data.terraform_remote_state.foundation.outputs.agentcore_sg_id
}

output "kms_key_arn" {
  description = "KMS key ARN for tools/agents that need encryption."
  value       = data.terraform_remote_state.foundation.outputs.storage_kms_key_arn
}

# Storage outputs
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

# OpenSearch Serverless — shared collection consumed by agent KB layers.
output "opensearch_collection_id" {
  description = "AOSS collection ID — used by agents to confirm ACTIVE status before applying."
  value       = aws_opensearchserverless_collection.kb.id
}

output "opensearch_collection_arn" {
  description = "AOSS collection ARN — referenced in aws_bedrockagent_knowledge_base storage config."
  value       = aws_opensearchserverless_collection.kb.arn
}

output "opensearch_collection_endpoint" {
  description = "AOSS collection endpoint URL — used by null_resource index creation scripts."
  value       = aws_opensearchserverless_collection.kb.collection_endpoint
}

output "opensearch_collection_name" {
  description = "AOSS collection name — referenced in agent data access policy resource strings."
  value       = aws_opensearchserverless_collection.kb.name
}

# Quality scorer outputs
output "quality_records_table" {
  description = "DynamoDB table name for LLM-as-Judge quality scores."
  value       = aws_dynamodb_table.quality_records.name
}
