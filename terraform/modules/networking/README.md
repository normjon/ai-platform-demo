# Module: networking

Provisions the VPC, private subnets, security groups, and VPC endpoints that
keep all platform traffic on the AWS network.

## Resources

| Resource | Purpose |
| --- | --- |
| `aws_vpc` | Platform VPC with DNS resolution enabled. |
| `aws_subnet.private` | One private subnet per AZ. AgentCore and Lambda run here. No public subnets — no public internet exposure. |
| `aws_security_group.agentcore` | Restricts AgentCore runtime to HTTPS egress only. No inbound rules. |
| `aws_vpc_endpoint.s3` | Gateway endpoint so S3 traffic never traverses the public internet. |
| `aws_vpc_endpoint.bedrock_runtime` | Interface endpoint for Bedrock Runtime API calls. Required for private AgentCore endpoints (ADR-001). |

## Inputs

| Name | Description |
| --- | --- |
| `name_prefix` | Prefix for all resource names. |
| `vpc_cidr` | VPC CIDR block. |
| `private_subnet_cidrs` | One CIDR per AZ (minimum two). |
| `tags` | Common tags applied to all resources. |

## Outputs

| Name | Description |
| --- | --- |
| `vpc_id` | VPC ID consumed by other modules. |
| `subnet_ids` | Subnet IDs passed to the agentcore module. |
| `agentcore_sg_id` | Security group ID passed to the AgentCore module. |

## Design decisions

- No public subnets or internet gateway are provisioned. Dev environment AgentCore
  endpoints are private (CLAUDE.md security requirement).
- VPC endpoints for S3 and Bedrock Runtime are created at module init time so
  resources in private subnets can reach AWS services without NAT.
