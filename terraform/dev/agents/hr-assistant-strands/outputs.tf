output "agentcore_endpoint_id" {
  description = "AgentCore runtime endpoint ID for the Strands agent."
  value       = aws_bedrockagentcore_agent_runtime.strands.agent_runtime_id
}

output "agentcore_runtime_arn" {
  description = "AgentCore runtime ARN — use in smoke test invocations."
  value       = aws_bedrockagentcore_agent_runtime.strands.agent_runtime_arn
}
