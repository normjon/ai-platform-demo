output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "subnet_ids" {
  description = "List of private subnet IDs."
  value       = aws_subnet.private[*].id
}

output "agentcore_sg_id" {
  description = "Security group ID for the AgentCore runtime."
  value       = aws_security_group.agentcore.id
}
