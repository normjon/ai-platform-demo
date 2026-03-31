# ---------------------------------------------------------------------------
# CloudWatch log groups - structured JSON to stdout (ADR-003).
# KMS encrypted (kms_key_arn from iam/ module).
# Retention set to 90 days for dev; tighten for production.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "agentcore" {
  name              = "/aws/agentcore/${var.name_prefix}"
  retention_in_days = 90
  kms_key_id        = var.kms_key_arn
  tags              = merge(var.tags, { Name = "${var.name_prefix}-agentcore-logs" })
}

resource "aws_cloudwatch_log_group" "bedrock_kb" {
  name              = "/aws/bedrock/knowledge-base/${var.name_prefix}"
  retention_in_days = 90
  kms_key_id        = var.kms_key_arn
  tags              = merge(var.tags, { Name = "${var.name_prefix}-bedrock-kb-logs" })
}

# ---------------------------------------------------------------------------
# Basic alarms - dev baseline. Add detail in later phases.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "agentcore_errors" {
  alarm_name          = "${var.name_prefix}-agentcore-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "InvocationClientErrors"
  namespace           = "AWS/Bedrock"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "AgentCore invocation error rate exceeded threshold."
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "agentcore_latency" {
  alarm_name          = "${var.name_prefix}-agentcore-p99-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "InvocationLatency"
  namespace           = "AWS/Bedrock"
  period              = 300
  extended_statistic  = "p99"
  threshold           = 30000
  alarm_description   = "AgentCore p99 invocation latency exceeded 30 seconds."
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}
