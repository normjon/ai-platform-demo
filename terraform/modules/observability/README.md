# Module: observability

CloudWatch log groups and metric alarms for the dev environment. All agents
must write structured JSON logs to stdout, which CloudWatch Logs Insights can
then query (ADR-003).

## Resources

| Resource | Purpose |
| --- | --- |
| `aws_cloudwatch_log_group.agentcore` | Receives all AgentCore invocation logs. |
| `aws_cloudwatch_log_group.bedrock_kb` | Receives Bedrock Knowledge Base ingestion and retrieval logs. |
| `aws_cloudwatch_metric_alarm.agentcore_errors` | Fires when AgentCore error count exceeds 5 in a 5-minute window. |
| `aws_cloudwatch_metric_alarm.agentcore_latency` | Fires when p99 invocation latency exceeds 30 seconds. |

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
