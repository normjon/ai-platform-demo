# ---------------------------------------------------------------------------
# Foundation outputs — consumed by the platform layer via terraform_remote_state.
# These are long-lived values that survive platform/tools/agents destroy cycles.
#
# Platform API contract: platform/outputs.tf re-exports vpc_id, subnet_ids,
# agentcore_sg_id, and kms_key_arn so that tools/ and agents/ layers only
# need to read from platform remote state, not foundation directly.
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "ID of the platform VPC."
  value       = module.networking.vpc_id
}

output "subnet_ids" {
  description = "IDs of the private subnets used by AgentCore."
  value       = module.networking.subnet_ids
}

output "agentcore_sg_id" {
  description = "Security group ID for the AgentCore runtime."
  value       = module.networking.agentcore_sg_id
}

output "storage_kms_key_arn" {
  description = "ARN of the KMS CMK used to encrypt S3, DynamoDB, and CloudWatch resources."
  value       = module.kms.kms_key_arn
}

output "ecr_repository_url" {
  description = "ECR repository URL for the HR Assistant agent. Push images here before running platform layer apply."
  value       = aws_ecr_repository.agent.repository_url
}
