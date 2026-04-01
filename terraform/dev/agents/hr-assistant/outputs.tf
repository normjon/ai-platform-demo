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
