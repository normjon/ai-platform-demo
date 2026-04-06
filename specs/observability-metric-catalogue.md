# Observability Metric Catalogue — Enterprise AI Platform

**Project ID:** ai-platform
**Display Name:** Enterprise AI Platform
**Owner:** platform-team
**Environment:** dev
**Version:** 1.0
**Last updated:** April 2026

---

## Overview

This catalogue documents every CloudWatch metric emitted by the Enterprise
AI Platform. It is the authoritative reference for the observability platform
registration and for engineers interpreting dashboards in AMG.

All custom metrics are emitted to the `AIPlatform/Quality` namespace by
the LLM-as-Judge quality scorer Lambda (`ai-platform-dev-quality-scorer`).
No custom metrics are emitted by the HR Assistant container — operational
signals for the agent runtime are derived from AWS-native namespaces.

---

## Custom Metrics

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

  - name: SuccessfulRequestCount
    namespace: AWS/AOSS
    source: AWS native — emitted automatically by OpenSearch Serverless
            for the ai-platform-kb-dev collection. Counts successful
            search and index API calls.
    visualisation: line
    dashboard: cost-token-consumption
    description: Count of successful API calls to the OpenSearch Serverless
                 KB collection. Primarily KB retrieve operations from the
                 HR Assistant during invocation. Tracks KB utilisation
                 and scales with agent invocation volume.

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
