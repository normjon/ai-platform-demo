# Module: networking

Provisions the VPC, private subnets, security groups, and VPC endpoints that
keep all platform traffic on the AWS network.

## Resources

| Resource | Purpose |
| --- | --- |
| `aws_vpc` | Platform VPC with DNS resolution enabled. |
| `aws_subnet.private` | One private subnet per AZ. AgentCore and Lambda run here. No public subnets — no public internet exposure. |
| `aws_security_group.agentcore` | HTTPS-only egress via VPC endpoints. Self-referencing HTTPS ingress required for container-to-interface-endpoint traffic. |
| `aws_security_group_rule.agentcore_egress_https_vpc` | HTTPS egress to VPC CIDR — covers all interface endpoint ENIs. |
| `aws_security_group_rule.agentcore_egress_https_s3` | HTTPS egress to S3 prefix list — required because gateway endpoints route via public IPs outside the VPC CIDR. |
| `aws_security_group_rule.agentcore_egress_https_dynamodb` | HTTPS egress to DynamoDB prefix list — same reason as S3. |
| `aws_security_group_rule.agentcore_ingress_https_self` | Self-referencing HTTPS ingress — required so containers in this SG can reach interface endpoint ENIs that share the same SG. |
| `aws_vpc_endpoint.s3` | Gateway endpoint — S3 reads/writes via route table, no NAT. |
| `aws_vpc_endpoint.dynamodb` | Gateway endpoint — DynamoDB session memory and agent registry, no NAT. |
| `aws_vpc_endpoint.bedrock_runtime` | Interface endpoint — Bedrock model invocations stay within VPC. |
| `aws_vpc_endpoint.cloudwatch_logs` | Interface endpoint — CloudWatch log writes stay within VPC. |
| `aws_vpc_endpoint.bedrock_agent` | Interface endpoint — Bedrock Prompt Management (GetPrompt) and agent control plane. |
| `aws_vpc_endpoint.bedrock_agent_runtime` | Interface endpoint — Knowledge Base retrieve() calls from agent container. |
| `aws_vpc_endpoint.lambda` | Interface endpoint — agent container invokes Glean stub and Prompt Vault Lambda. |
| `aws_vpc_endpoint.ecr_api` | Interface endpoint — ECR control plane (GetAuthorizationToken) for image pull. |
| `aws_vpc_endpoint.ecr_dkr` | Interface endpoint — ECR Docker registry (image layer download). |

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
- Nine VPC endpoints (2 gateway + 7 interface) cover all services the AgentCore
  container and Lambdas need to reach without a NAT gateway.
- **Security groups evaluate before gateway endpoint routing.** Egress rules that
  cover only the VPC CIDR silently block S3 and DynamoDB gateway endpoint traffic
  because those services route to public IPs. S3 and DynamoDB egress use
  AWS-managed prefix lists (`aws_vpc_endpoint.s3.prefix_list_id` and
  `aws_vpc_endpoint.dynamodb.prefix_list_id`) — not CIDR blocks.
- Interface endpoint ENIs share the AgentCore security group. A self-referencing
  HTTPS ingress rule is required so containers can reach those ENIs.
