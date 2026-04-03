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

# ---------------------------------------------------------------------------
# X-Ray — sampling rule and service group for distributed tracing.
#
# The sampling rule applies to all services in the account at 5% for dev
# (reservoir_size = 1 guarantees one trace per second regardless of rate).
# Priority 1000 sits below the X-Ray default rule (9999), so this rule
# takes precedence for matching requests.
#
# The group scopes the CloudWatch ServiceMap view to platform Lambda traces.
# Lambda functions enable tracing with tracing_config { mode = "Active" }
# and must add xray:PutTraceSegments + xray:PutTelemetryRecords to their
# execution roles. Those changes live in the tools/ and agents/ layers
# that own the Lambda execution roles (ADR-017).
#
# To populate the group filter, Lambda handlers should call:
#   xray_recorder.put_annotation("Platform", "<name_prefix>")
# Without the annotation, traces are still sampled — they appear in the
# X-Ray console but not in this group's ServiceMap view.
# ---------------------------------------------------------------------------

resource "aws_xray_sampling_rule" "platform" {
  rule_name      = "${var.name_prefix}-default"
  priority       = 1000
  reservoir_size = 1
  fixed_rate     = 0.05
  url_path       = "*"
  host           = "*"
  http_method    = "*"
  service_type   = "*"
  service_name   = "*"
  resource_arn   = "*"
  version        = 1
  tags           = var.tags
}

resource "aws_xray_group" "platform" {
  group_name        = var.name_prefix
  filter_expression = "annotation.Platform = \"${var.name_prefix}\""
  tags              = var.tags
}
