output "log_group_agentcore" {
  description = "CloudWatch log group name for AgentCore invocations."
  value       = aws_cloudwatch_log_group.agentcore.name
}

output "log_group_bedrock_kb" {
  description = "CloudWatch log group name for Bedrock Knowledge Base operations."
  value       = aws_cloudwatch_log_group.bedrock_kb.name
}

output "xray_sampling_rule_name" {
  description = "X-Ray sampling rule name applied to all platform services."
  value       = aws_xray_sampling_rule.platform.rule_name
}

output "xray_group_name" {
  description = "X-Ray group name for the platform ServiceMap view."
  value       = aws_xray_group.platform.group_name
}
