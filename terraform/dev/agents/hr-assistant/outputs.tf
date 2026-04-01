# ---------------------------------------------------------------------------
# Component 1 — System Prompt
# ---------------------------------------------------------------------------

output "system_prompt_version_arn" {
  description = "ARN of the versioned Bedrock Prompt for the HR Assistant system prompt."
  value       = aws_bedrockagent_prompt.hr_assistant_system.arn
}

# ---------------------------------------------------------------------------
# Component 2 — Guardrails
# ---------------------------------------------------------------------------

output "guardrail_id" {
  description = "Bedrock Guardrail ID for the HR Assistant."
  value       = aws_bedrock_guardrail.hr_assistant.guardrail_id
}

output "guardrail_version" {
  description = "Bedrock Guardrail version for the HR Assistant."
  value       = aws_bedrock_guardrail.hr_assistant.version
}

# ---------------------------------------------------------------------------
# Component 4 — Prompt Vault Lambda
# ---------------------------------------------------------------------------

output "prompt_vault_writer_arn" {
  description = "ARN of the Prompt Vault writer Lambda function."
  value       = aws_lambda_function.prompt_vault_writer.arn
}

# ---------------------------------------------------------------------------
# Component 7 — Re-exported platform values for smoke test
# ---------------------------------------------------------------------------

output "agentcore_endpoint_id" {
  description = "AgentCore runtime endpoint ID — re-exported from platform for smoke test use."
  value       = data.terraform_remote_state.platform.outputs.agentcore_endpoint_id
}

output "prompt_vault_bucket" {
  description = "Prompt Vault S3 bucket name — re-exported from platform for smoke test use."
  value       = data.terraform_remote_state.platform.outputs.prompt_vault_bucket
}

# ---------------------------------------------------------------------------
# Component 3 — HR Policies Knowledge Base
# ---------------------------------------------------------------------------

output "knowledge_base_id" {
  description = "Bedrock Knowledge Base ID for the HR Policies KB."
  value       = aws_bedrockagent_knowledge_base.hr_policies.id
}

output "knowledge_base_data_source_id" {
  description = "Bedrock Knowledge Base data source ID."
  value       = aws_bedrockagent_data_source.hr_policies.data_source_id
}

output "opensearch_collection_endpoint" {
  description = "OpenSearch Serverless collection endpoint."
  value       = aws_opensearchserverless_collection.hr_policies.collection_endpoint
}
