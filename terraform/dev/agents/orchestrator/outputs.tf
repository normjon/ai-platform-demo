output "iam_role_arn" {
  description = "Orchestrator runtime execution role ARN."
  value       = aws_iam_role.orchestrator_runtime.arn
}

output "iam_role_name" {
  description = "Orchestrator runtime execution role name."
  value       = aws_iam_role.orchestrator_runtime.name
}

output "guardrail_id" {
  description = "Orchestrator guardrail ID."
  value       = aws_bedrock_guardrail.orchestrator.guardrail_id
}

output "guardrail_arn" {
  description = "Orchestrator guardrail ARN."
  value       = aws_bedrock_guardrail.orchestrator.guardrail_arn
}

output "guardrail_version" {
  description = "Orchestrator guardrail version (pinned to DRAFT in dev)."
  value       = "DRAFT"
}

output "ecr_repository_url" {
  description = "ECR repository URL for the orchestrator container image."
  value       = aws_ecr_repository.orchestrator.repository_url
}

output "audit_log_group_name" {
  description = "CloudWatch log group for orchestrator audit records."
  value       = aws_cloudwatch_log_group.orchestrator_audit.name
}

output "agentcore_endpoint_id" {
  description = "AgentCore runtime endpoint ID for the orchestrator. Null until agent_image_uri is set and the runtime is created."
  value       = try(aws_bedrockagentcore_agent_runtime.orchestrator[0].agent_runtime_id, null)
}

output "agentcore_runtime_arn" {
  description = "AgentCore runtime ARN for the orchestrator. Null until agent_image_uri is set and the runtime is created."
  value       = try(aws_bedrockagentcore_agent_runtime.orchestrator[0].agent_runtime_arn, null)
}
