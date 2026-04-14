# Module: observability

CloudWatch log groups, metric alarms, and X-Ray tracing configuration for
the dev environment. All agents must write structured JSON logs to stdout,
which CloudWatch Logs Insights can then query (ADR-003).

## Resources

| Resource | Purpose |
| --- | --- |
| `aws_cloudwatch_log_group.agentcore` | Receives all AgentCore invocation logs. |
| `aws_cloudwatch_log_group.bedrock_kb` | Receives Bedrock Knowledge Base ingestion and retrieval logs. |
| `aws_cloudwatch_metric_alarm.agentcore_errors` | Fires when AgentCore error count exceeds 5 in a 5-minute window. |
| `aws_cloudwatch_metric_alarm.agentcore_latency` | Fires when p99 invocation latency exceeds 30 seconds. |
| `aws_xray_sampling_rule.platform` | 5% sampling rate for all platform services; 1 trace/sec guaranteed. |
| `aws_xray_group.platform` | CloudWatch ServiceMap group scoped to platform Lambda traces. |

## X-Ray tracing

The sampling rule and group are defined here centrally. Tracing is activated
per Lambda in the layer that owns it:

- `tracing_config { mode = "Active" }` on the `aws_lambda_function` resource
- `xray:PutTraceSegments` and `xray:PutTelemetryRecords` added to the Lambda execution role

Current Lambda functions with tracing enabled:

| Function | Layer |
| --- | --- |
| `ai-platform-dev-glean-stub` | `terraform/dev/tools/glean/` |
| `hr-assistant-prompt-vault-writer-dev` | `terraform/dev/agents/hr-assistant/` |
| `ai-platform-dev-quality-scorer` | `terraform/dev/platform/` |

**X-Ray group population:** The group filter is `annotation.Platform = "<name_prefix>"`.
Traces are sampled and visible in the X-Ray console regardless of annotation. To appear
in the platform group's filtered ServiceMap view, a subsegment annotation is needed —
but do NOT call `xray_recorder.put_annotation()` directly in a Lambda handler.
Lambda's X-Ray runtime creates a `FacadeSegment` before the handler executes, and
`FacadeSegments` cannot be mutated — the call raises `FacadeSegmentMutationException`
and crashes the handler silently (the function returns HTTP 500 with no useful log).
The `tracing_config { mode = "Active" }` and `patch_all()` are sufficient for Lambda
X-Ray instrumentation without annotations.

## Log format requirement

All agents must emit logs as structured JSON. Example minimal record:

```json
{
  "timestamp": "2026-03-30T12:00:00Z",
  "level": "INFO",
  "agent_id": "hr-assistant-dev",
  "session_id": "sess_abc123",
  "event": "tool_call",
  "tool": "glean_search",
  "latency_ms": 412
}
```

Do not emit unstructured text — it breaks CloudWatch Logs Insights queries.
