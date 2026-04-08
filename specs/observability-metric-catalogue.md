# Observability Metric Catalogue — Enterprise AI Platform

**Project ID:** ai-platform
**Display Name:** Enterprise AI Platform
**Owner:** platform-team
**Environment:** dev
**Version:** 1.1
**Last updated:** April 2026

---

## Overview

This catalogue documents every CloudWatch metric emitted by the Enterprise
AI Platform. It is the authoritative reference for the observability platform
registration and for engineers interpreting dashboards in AMG.

Custom metrics are emitted to two namespaces:

---

## PromQL Query Patterns — MUST READ before writing dashboard queries

**All CloudWatch metrics in AMP are gauges, not Prometheus counters.**
Each 1-minute CloudWatch aggregation period becomes a single independent
gauge sample in AMP. The value is NOT cumulative across periods.

This means `rate()` and `increase()` always return 0 on these metrics.
Never use them for CloudWatch-sourced data. The correct patterns are:

| What you want | Correct PromQL |
|---|---|
| Count of events in a window | `sum(sum_over_time(metric_sum{...}[window]))` |
| Average score or latency | `metric_sum{...} / metric_count{...}` |
| Maximum document count | `metric_max{...}` |

### Why `_sum / _count` for scores

The quality scorer emits one `QualityScore` data point per scored record per
dimension. If 24 records are scored, CloudWatch aggregates all 24 values into
`_sum` (~10.5 for correctness) and `_count` (24). Displaying raw `_sum` shows
the batch total (10.5), not the per-record average. The correct query is:

```
cloudwatch_AIPlatform_Quality_QualityScore_sum{..., Dimension="correctness"}
  / cloudwatch_AIPlatform_Quality_QualityScore_count{..., Dimension="correctness"}
```

This returns the average score (~0.44), which is in the expected 0.0–1.0 range.

### Prometheus staleness (batch metrics)

The quality scorer runs hourly via EventBridge. Stat panels using `lastNotNull`
show "No data" when the last scorer run was >5 minutes ago — this is expected
Prometheus staleness behaviour. Timeseries panels display historical data
correctly regardless of how long ago the scorer last ran.

---

- `AIPlatform/Quality` — emitted by the LLM-as-Judge quality scorer Lambda
  (`ai-platform-dev-quality-scorer`) via explicit `put_metric_data` calls.
- `AIPlatform/AgentCore` — emitted via CloudWatch Metric Filters on the
  AgentCore runtime log group. Filters are owned by the agent and tool layers
  that define the log event schemas (not the platform layer).

---

## Custom Metrics

### AIPlatform/AgentCore

```yaml
metrics:
  - name: AgentInvocationLatency
    namespace: AIPlatform/AgentCore
    source: CloudWatch Metric Filter (hr-assistant-agent-invocation-latency-dev) on
            AgentCore runtime log group. Matches agent_invoke log events emitted by
            the HR Assistant container (container/app/agent.py). Value extracted
            from the latency_ms field — end-to-end agent invocation time in
            milliseconds, measured from request receipt to response ready.
            Owned by: agents/hr-assistant layer.
    visualisation: line
    dashboard: agent-operational-health
    description: End-to-end HR Assistant agent invocation latency in milliseconds.
                 Measures wall-clock time from request receipt to response ready,
                 including Bedrock model invocation, KB retrieval, and tool calls.
                 P95 above 15 000 ms indicates the agent is approaching the user
                 experience SLO defined in the agent manifest.

  - name: AgentInvocationCount
    namespace: AIPlatform/AgentCore
    source: CloudWatch Metric Filter (hr-assistant-agent-invocation-count-dev) on
            AgentCore runtime log group. Matches agent_invoke log events. Emits 1
            per completed invocation. Default value 0 when no invocations occur.
            Owned by: agents/hr-assistant layer.
    visualisation: line
    dashboard: agent-operational-health
    description: Count of completed HR Assistant agent invocations per period.
                 Tracks agent utilisation volume. A drop while Prompt Vault writer
                 invocations continue indicates invocations are failing before
                 completion and not reaching the vault write path.

  - name: KBRetrievalCount
    namespace: AIPlatform/AgentCore
    source: CloudWatch Metric Filter (hr-assistant-kb-retrieval-count-dev) on
            AgentCore runtime log group. Matches kb_retrieve log events emitted by
            the HR Assistant container (container/app/agent.py). Dimension:
            KnowledgeBaseId extracted from the kb_id field.
            Owned by: agents/hr-assistant layer.
            Note: AWS CloudWatch does not allow default_value and dimensions
            together — this filter has no default value; zero-retrieval periods
            produce no data points.
    visualisation: bar
    dashboard: agent-operational-health
    description: Count of Knowledge Base retrieval operations per period, broken
                 down by KnowledgeBaseId. Each agent invocation that reaches the KB
                 retrieval step emits one data point. A sustained zero value while
                 AgentInvocationCount is non-zero indicates KB retrieval is being
                 skipped — check the agent's grounding_score_min threshold and
                 whether the KB contains documents.

  - name: AgentInvocationErrors
    namespace: AIPlatform/AgentCore
    source: CloudWatch Metric Filter (hr-assistant-agent-invocation-errors-dev) on
            AgentCore runtime log group. Matches invocation_error log events emitted
            by main.py when the agent.invoke() call raises an unhandled exception.
            Default value 0 when no errors occur.
            Owned by: agents/hr-assistant layer.
    visualisation: bar
    dashboard: agent-operational-health
    description: Count of unhandled HR Assistant agent invocation errors per period.
                 Any non-zero value warrants immediate investigation — the agent
                 returned HTTP 500 to the caller. Check the AgentCore runtime log
                 group for the invocation_error event and accompanying traceback.

  - name: GleanCallCount
    namespace: AIPlatform/AgentCore
    source: CloudWatch Metric Filter (glean-call-count-dev) on AgentCore runtime
            log group. Matches glean_search log events emitted by the HR Assistant
            container (container/app/agent.py) when the Glean MCP tool is invoked.
            Named GleanCallCount rather than ToolCallCount because this filter only
            matches glean_search events — future MCP tools will have different event
            names and should define their own filters in their respective tool layers.
            Default value 0 when Glean is not called.
            Owned by: tools/glean layer.
    visualisation: bar
    dashboard: agent-operational-health
    description: Count of Glean Search MCP tool invocations per period. Tracks how
                 often the HR Assistant escalates to enterprise search. A sustained
                 zero while AgentInvocationCount is high indicates the KB is
                 satisfying all queries without tool use — expected for HR policy
                 questions well-covered by the indexed documents.
```

### AIPlatform/Quality

```yaml
metrics:
  - name: QualityScore
    namespace: AIPlatform/Quality
    source: LLM-as-Judge quality scorer Lambda (explicit put_metric_data in
            terraform/dev/platform/quality-scorer/handler.py). Emitted once
            per scored record per dimension. Six Dimension values per record:
            correctness, relevance, groundedness, completeness, tone, overall.
            Dimensions on each datapoint: AgentId (agent identifier string),
            Dimension (dimension name string).
    visualisation: line
    dashboard: quality-trending
    description: Per-dimension quality score (0.0–1.0) for each scored agent
                 interaction. The overall dimension is the mean of the five
                 content dimensions. Scores below 0.70 trigger the
                 BelowThreshold alarm.

  - name: BelowThreshold
    namespace: AIPlatform/Quality
    source: LLM-as-Judge quality scorer Lambda (explicit put_metric_data in
            terraform/dev/platform/quality-scorer/handler.py). Emitted 1 if
            score_overall < 0.70, 0 otherwise. Dimension: AgentId.
    visualisation: bar
    dashboard: quality-trending
    description: Count of agent interactions whose overall quality score fell
                 below the 0.70 threshold in a given period. Used to drive the
                 CloudWatch alarm and human review queue. A sustained non-zero
                 value indicates a quality regression requiring investigation.

  - name: GuardrailFired
    namespace: AIPlatform/Quality
    source: LLM-as-Judge quality scorer Lambda (explicit put_metric_data in
            terraform/dev/platform/quality-scorer/handler.py). Emitted 1 when
            a Prompt Vault record has guardrail_result.action =
            GUARDRAIL_INTERVENED. Dimension: AgentId.
    visualisation: bar
    dashboard: quality-trending
    description: Count of interactions where the Bedrock Guardrail intervened
                 before the agent response was delivered. Guardrail-fired records
                 are not scored for quality — they are tracked separately to
                 distinguish blocked interactions from quality failures.

  - name: ScorerLatency
    namespace: AIPlatform/Quality
    source: LLM-as-Judge quality scorer Lambda (explicit put_metric_data in
            terraform/dev/platform/quality-scorer/handler.py). Measures wall
            clock time for the Haiku Converse API call in milliseconds.
            Dimension: AgentId.
    visualisation: line
    dashboard: quality-trending
    description: End-to-end latency in milliseconds for the Haiku model
                 invocation during quality scoring. Used to monitor scorer
                 performance and detect Bedrock throttling. Elevated values
                 (above 8 000 ms) indicate throttling or model availability
                 issues affecting the scoring pipeline.
```

---

## AWS-Native Metrics

```yaml
  - name: Invocations
    namespace: AWS/Lambda
    source: AWS native — emitted automatically by Lambda service for every
            function invocation. Relevant functions: ai-platform-dev-quality-scorer,
            hr-assistant-prompt-vault-writer-dev, glean-stub Lambda.
    visualisation: line
    dashboard: agent-operational-health
    description: Total number of Lambda invocations per function per period.
                 For the Prompt Vault writer this proxies agent invocation
                 volume since the writer is called after every live interaction.

  - name: Errors
    namespace: AWS/Lambda
    source: AWS native — emitted automatically by Lambda service when a
            function invocation throws an unhandled exception. Relevant
            functions: ai-platform-dev-quality-scorer,
            hr-assistant-prompt-vault-writer-dev.
    visualisation: line
    dashboard: agent-operational-health
    description: Count of Lambda invocations that ended with an error. Any
                 non-zero value for the quality scorer warrants immediate
                 investigation — errors prevent interactions from being scored
                 and create gaps in the quality record.

  - name: Duration
    namespace: AWS/Lambda
    source: AWS native — emitted automatically by Lambda service. Measures
            execution duration in milliseconds per invocation.
    visualisation: line
    dashboard: agent-operational-health
    description: Lambda execution duration in milliseconds. Used to monitor
                 quality scorer execution time relative to the 5-minute
                 timeout. P95 values above 240 000 ms indicate the scorer
                 may be close to timeout under load.

  - name: Throttles
    namespace: AWS/Lambda
    source: AWS native — emitted automatically by Lambda service when
            concurrent invocation limit is reached.
    visualisation: stat
    dashboard: agent-operational-health
    description: Count of Lambda invocations throttled due to concurrency
                 limits. Non-zero values indicate the scorer or prompt vault
                 writer is being throttled and interactions may be delayed.

  - name: InvocationClientErrors
    namespace: AWS/Bedrock
    source: AWS native — emitted automatically by Bedrock service for
            client-side invocation errors (4xx). Covers both HR Assistant
            (claude-sonnet-4-6 via cross-region inference profile) and
            quality scorer (claude-haiku-4-5-20251001) invocations.
    visualisation: stat
    dashboard: agent-operational-health
    description: Count of Bedrock invocations that returned a client error.
                 Elevated values typically indicate throttling, invalid model
                 IDs, or permission issues on the agentcore_runtime role.

  - name: InvocationLatency
    namespace: AWS/Bedrock
    source: AWS native — emitted automatically by Bedrock service.
            Measures end-to-end Bedrock model invocation latency in
            milliseconds per call.
    visualisation: line
    dashboard: agent-operational-health
    description: End-to-end Bedrock model invocation latency in milliseconds.
                 Directly impacts HR Assistant response time seen by users.
                 P95 above 15 000 ms indicates model latency is degrading
                 the user experience.

  - name: InputTokenCount
    namespace: AWS/Bedrock
    source: AWS native — emitted automatically by Bedrock service. Counts
            input tokens per invocation across all models. Covers HR Assistant
            (claude-sonnet-4-6) and quality scorer (claude-haiku-4-5-20251001).
    visualisation: bar
    dashboard: cost-token-consumption
    description: Input tokens consumed per Bedrock model invocation. Combined
                 with OutputTokenCount for cost estimation. The HR Assistant
                 input includes system prompt, conversation history, and KB
                 context — expected to be 2 000–8 000 tokens per invocation.

  - name: OutputTokenCount
    namespace: AWS/Bedrock
    source: AWS native — emitted automatically by Bedrock service. Counts
            output tokens generated per invocation.
    visualisation: bar
    dashboard: cost-token-consumption
    description: Output tokens generated per Bedrock model invocation.
                 Combined with InputTokenCount for cost estimation. HR
                 Assistant responses are typically 200–600 output tokens.

  - name: InvocationThrottles
    namespace: AWS/Bedrock
    source: AWS native — emitted automatically by Bedrock service when
            on-demand throughput limit is reached.
    visualisation: stat
    dashboard: cost-token-consumption
    description: Count of Bedrock invocations throttled due to on-demand
                 throughput limits. Non-zero values degrade user experience
                 and scoring pipeline throughput.

  - name: 2xx
    namespace: AWS/AOSS
    source: AWS native — emitted automatically by OpenSearch Serverless
            for the ai-platform-kb-dev collection. Counts successful HTTP
            2xx API calls (search and index operations).
            AMP metric name: cloudwatch_AWS_AOSS_2xx_sum
            IMPORTANT: This metric is named "2xx" in CloudWatch, NOT
            "SuccessfulRequestCount". Any panel using
            cloudwatch_AWS_AOSS_SuccessfulRequestCount_sum will show
            "No data" — that metric name does not exist in AOSS.
    visualisation: line
    dashboard: cost-token-consumption
    description: Count of successful API calls (HTTP 2xx) to the OpenSearch
                 Serverless KB collection. Primarily KB retrieve operations
                 from the HR Assistant during invocation. Tracks KB utilisation
                 and scales with agent invocation volume. Filter by
                 CollectionName="ai-platform-kb-dev" to scope to the KB collection.

  - name: SearchableDocuments
    namespace: AWS/AOSS
    source: AWS native — emitted automatically by OpenSearch Serverless.
            Reports number of indexed documents in the collection.
    visualisation: stat
    dashboard: cost-token-consumption
    description: Number of searchable documents in the HR Policies Knowledge
                 Base. Expected value is 8 (the 8 HR policy documents). A
                 drop below 8 indicates an ingestion failure or unintended
                 deletion and requires immediate investigation.
```
