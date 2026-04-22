output "iam_role_arn" {
  description = "Stub-agent runtime execution role ARN."
  value       = aws_iam_role.stub_runtime.arn
}

output "iam_role_name" {
  description = "Stub-agent runtime execution role name."
  value       = aws_iam_role.stub_runtime.name
}

output "ecr_repository_url" {
  description = "ECR repository URL for the stub-agent container image."
  value       = aws_ecr_repository.stub.repository_url
}

output "agentcore_endpoint_id" {
  description = "AgentCore runtime endpoint ID for the stub-agent. Null until agent_image_uri is set and the runtime is created."
  value       = try(aws_bedrockagentcore_agent_runtime.stub[0].agent_runtime_id, null)
}

output "agentcore_runtime_arn" {
  description = "AgentCore runtime ARN for the stub-agent. Null until agent_image_uri is set and the runtime is created."
  value       = try(aws_bedrockagentcore_agent_runtime.stub[0].agent_runtime_arn, null)
}
