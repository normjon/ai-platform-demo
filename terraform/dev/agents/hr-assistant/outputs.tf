# ---------------------------------------------------------------------------
# Component 1 — System Prompt
# ---------------------------------------------------------------------------

output "system_prompt_version_arn" {
  description = "ARN of the versioned Bedrock Prompt for the HR Assistant system prompt."
  value       = aws_bedrock_prompt_version.hr_assistant_system.arn
}
