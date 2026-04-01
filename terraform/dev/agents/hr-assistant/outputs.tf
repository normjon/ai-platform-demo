# ---------------------------------------------------------------------------
# Component 1 — System Prompt
# ---------------------------------------------------------------------------

output "system_prompt_version_arn" {
  description = "ARN of the versioned Bedrock Prompt for the HR Assistant system prompt."
  value       = aws_bedrock_prompt_version.hr_assistant_system.arn
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
