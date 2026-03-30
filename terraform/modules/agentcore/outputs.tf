output "endpoint_id" {
  description = "AgentCore runtime endpoint ID."
  value       = aws_bedrockagentcore_runtime.dev.id
}

output "endpoint_arn" {
  description = "AgentCore runtime endpoint ARN."
  value       = aws_bedrockagentcore_runtime.dev.arn
}

output "gateway_id" {
  description = "MCP Gateway ID."
  value       = aws_bedrockagentcore_gateway.mcp.id
}
