data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(var.tags, { Name = "${var.name_prefix}-vpc" })
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = merge(var.tags, { Name = "${var.name_prefix}-private-${count.index + 1}" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# Security group for AgentCore runtime - no public ingress.
# Egress scoped to VPC CIDR: all traffic flows through VPC endpoints.
# ---------------------------------------------------------------------------
resource "aws_security_group" "agentcore" {
  name        = "${var.name_prefix}-agentcore-sg"
  description = "AgentCore runtime - internal traffic only. Egress via VPC endpoints."
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-agentcore-sg" })
}

# Interface VPC endpoint ENIs are in the VPC CIDR. Egress to VPC CIDR covers all
# interface endpoints (bedrock-runtime, ecr.api, ecr.dkr, bedrock-agent, lambda, logs, monitoring).
resource "aws_security_group_rule" "agentcore_egress_https_vpc" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.agentcore.id
  description       = "HTTPS egress to VPC CIDR - covers all interface VPC endpoints."
}

# S3 Gateway endpoint: security groups evaluate before route-table gateway routing,
# so traffic to S3 public IPs must be explicitly allowed (they are outside VPC CIDR).
resource "aws_security_group_rule" "agentcore_egress_https_s3" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  prefix_list_ids   = [aws_vpc_endpoint.s3.prefix_list_id]
  security_group_id = aws_security_group.agentcore.id
  description       = "HTTPS egress to S3 prefix list - required for ECR layer downloads via gateway endpoint."
}

# DynamoDB Gateway endpoint: same reason as S3 above.
resource "aws_security_group_rule" "agentcore_egress_https_dynamodb" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  prefix_list_ids   = [aws_vpc_endpoint.dynamodb.prefix_list_id]
  security_group_id = aws_security_group.agentcore.id
  description       = "HTTPS egress to DynamoDB prefix list - required for session memory and agent registry."
}

# Interface VPC endpoint ENIs share this security group. Without a self-referencing
# inbound rule, containers using this SG cannot reach any interface endpoint ENI.
resource "aws_security_group_rule" "agentcore_ingress_https_self" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  self                     = true
  security_group_id        = aws_security_group.agentcore.id
  description              = "HTTPS ingress from same SG - required for container-to-endpoint traffic."
}

# ---------------------------------------------------------------------------
# VPC Endpoints - all required AWS services for private subnet operation.
# Gateway endpoints (S3, DynamoDB): free, route-table based.
# Interface endpoints (Bedrock, CloudWatch Logs, OpenSearch): ENI-based.
# ---------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = merge(var.tags, { Name = "${var.name_prefix}-s3-endpoint" })
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = merge(var.tags, { Name = "${var.name_prefix}-dynamodb-endpoint" })
}

resource "aws_vpc_endpoint" "bedrock_runtime" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.agentcore.id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.name_prefix}-bedrock-runtime-endpoint" })
}

resource "aws_vpc_endpoint" "cloudwatch_logs" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.agentcore.id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.name_prefix}-logs-endpoint" })
}

# bedrock-agent: Bedrock Prompt Management (get_prompt) and agent control plane.
resource "aws_vpc_endpoint" "bedrock_agent" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.bedrock-agent"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.agentcore.id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.name_prefix}-bedrock-agent-endpoint" })
}

# bedrock-agent-runtime: Knowledge Base retrieve() calls from the agent container.
resource "aws_vpc_endpoint" "bedrock_agent_runtime" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.bedrock-agent-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.agentcore.id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.name_prefix}-bedrock-agent-runtime-endpoint" })
}

# lambda: required for agent container to invoke Glean stub and Prompt Vault Lambda.
resource "aws_vpc_endpoint" "lambda" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.lambda"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.agentcore.id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.name_prefix}-lambda-endpoint" })
}

# ecr.api: ECR control plane (GetAuthorizationToken). Required by AgentCore to pull
# container images from ECR when the runtime runs in private subnets.
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.agentcore.id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.name_prefix}-ecr-api-endpoint" })
}

# ecr.dkr: ECR Docker registry (image layer pull). Required alongside ecr.api.
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.agentcore.id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.name_prefix}-ecr-dkr-endpoint" })
}

# monitoring: CloudWatch Metrics API (put_metric_data). Required for agent containers
# to emit custom CloudWatch metrics from private subnets — monitoring.amazonaws.com
# is a public endpoint with no route from private subnets without this endpoint.
resource "aws_vpc_endpoint" "cloudwatch_monitoring" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.monitoring"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.agentcore.id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.name_prefix}-monitoring-endpoint" })
}
