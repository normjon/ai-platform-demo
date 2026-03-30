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
# Security group for AgentCore runtime — no public ingress.
# Egress scoped to VPC CIDR: all traffic flows through VPC endpoints.
# ---------------------------------------------------------------------------
resource "aws_security_group" "agentcore" {
  name        = "${var.name_prefix}-agentcore-sg"
  description = "AgentCore runtime — internal traffic only. Egress via VPC endpoints."
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-agentcore-sg" })
}

resource "aws_security_group_rule" "agentcore_egress_https" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  # Scoped to VPC CIDR — traffic reaches AWS services via VPC endpoints, not internet.
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.agentcore.id
  description       = "HTTPS egress to VPC CIDR for VPC endpoint traffic."
}

# ---------------------------------------------------------------------------
# VPC Endpoints — all required AWS services for private subnet operation.
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

