output "log_group_agentcore" {
  description = "CloudWatch log group name for AgentCore invocations."
  value       = aws_cloudwatch_log_group.agentcore.name
}

output "log_group_bedrock_kb" {
  description = "CloudWatch log group name for Bedrock Knowledge Base operations."
  value       = aws_cloudwatch_log_group.bedrock_kb.name
}
