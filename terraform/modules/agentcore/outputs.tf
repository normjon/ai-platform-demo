output "ecr_repository_url" {
  description = "ECR repository URL for the HR Assistant agent image. Passed through from foundation layer."
  value       = var.ecr_repository_url
}

output "endpoint_id" {
  description = "AgentCore runtime endpoint ID."
  value       = aws_bedrockagentcore_agent_runtime.dev.agent_runtime_id
}

output "endpoint_arn" {
  description = "AgentCore runtime endpoint ARN."
  value       = aws_bedrockagentcore_agent_runtime.dev.agent_runtime_arn
}

output "gateway_id" {
  description = "MCP Gateway ID."
  value       = aws_bedrockagentcore_gateway.mcp.gateway_id
}
