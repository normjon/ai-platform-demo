# LLM-as-Judge Quality Scorer — Specification

**Version:** 1.0  
**Status:** Implemented (April 2026)  
**Layer:** Platform (`terraform/dev/platform/`)  
**Author:** Platform Architecture  
**Last updated:** April 2026

---

## 1. Overview

The LLM-as-Judge quality scorer is a platform-layer component that
automatically evaluates every interaction record written to the Prompt
Vault. It uses Claude Haiku to score each interaction across five quality
dimensions, writes results to DynamoDB, emits CloudWatch custom metrics,
and flags below-threshold records for human review.

The scorer is agent-agnostic. It processes Prompt Vault records from any
agent deployed on the platform using the same evaluation rubric. Adding a
new agent to the platform automatically brings it into the quality pipeline
with no scorer changes required.

### 1.1 Goals

- Provide continuous, automated quality measurement for all platform agents
- Produce per-dimension scores that identify specific failure modes
- Feed quality metrics into the observability dashboards
- Surface below-threshold interactions for human review and agent tuning
- Establish a quality baseline against which future agent versions are compared

### 1.2 Non-Goals

- Real-time scoring (hourly batch is sufficient for dev)
- Per-user quality segmentation (deferred to Phase 2)
- Automated agent retraining or prompt updates (human decision required)
- Scoring of guardrail-blocked responses (these are scored separately)

### 1.3 Architecture Position

```
Prompt Vault (S3)
      │
      ▼
Quality Scorer Lambda  ←── EventBridge (hourly)
      │
      ├──► DynamoDB (quality-records-dev)
      │
      ├──► CloudWatch (AIPlatform/Quality namespace)
      │
      └──► CloudWatch Logs (structured JSON)
```

The scorer reads from the Prompt Vault S3 bucket (platform-owned).
It writes to a dedicated DynamoDB quality records table (platform-owned).
It emits custom CloudWatch metrics consumed by the observability dashboards.
It never modifies Prompt Vault records.

---

## 2. Components

### 2.1 DynamoDB Quality Records Table

**Table name:** `ai-platform-quality-records-dev`  
**Billing:** PAY_PER_REQUEST  
**Encryption:** KMS using platform KMS key  
**TTL attribute:** `ttl` — 90 days from `scored_at`

#### Primary Key

| Attribute  | Type   | Role          |
|------------|--------|---------------|
| record_id  | String | Partition key |
| scored_at  | String | Sort key      |

`record_id` matches the `record_id` field in the Prompt Vault record.  
`scored_at` is ISO 8601 UTC timestamp of when scoring occurred.

#### Item Schema

| Attribute              | Type    | Description                                      |
|------------------------|---------|--------------------------------------------------|
| record_id              | String  | From Prompt Vault record                         |
| scored_at              | String  | ISO 8601 UTC — when scoring occurred             |
| agent_id               | String  | From Prompt Vault record                         |
| session_id             | String  | From Prompt Vault record                         |
| environment            | String  | From Prompt Vault record                         |
| score_correctness      | Number  | 0.0–1.0                                          |
| score_relevance        | Number  | 0.0–1.0                                          |
| score_groundedness     | Number  | 0.0–1.0                                          |
| score_completeness     | Number  | 0.0–1.0                                          |
| score_tone             | Number  | 0.0–1.0                                          |
| score_overall          | Number  | Mean of five dimensions                          |
| below_threshold        | Boolean | true if score_overall < 0.70 (application logic) |
| below_threshold_str    | String  | "true"/"false" — GSI sort key only               |
| guardrail_fired        | Boolean | true if guardrail_result.action = INTERVENED     |
| guardrail_skipped      | Boolean | true if record skipped due to guardrail block    |
| scorer_model           | String  | Haiku model ARN used for evaluation              |
| evaluation_latency_ms  | Number  | Wall clock time for Haiku invocation             |
| prompt_vault_key       | String  | S3 key of the source Prompt Vault record         |
| reasoning              | String  | One-sentence scorer explanation                  |
| ttl                    | Number  | Unix timestamp — 90 days from scored_at          |

#### Global Secondary Index

| Attribute           | Role          | Purpose                              |
|---------------------|---------------|--------------------------------------|
| agent_id            | Partition key | Query all records for a given agent  |
| below_threshold_str | Sort key      | Filter to below-threshold records    |

**GSI name:** `agent-threshold-index`  
**Projection:** ALL  
**Purpose:** Human review queue — retrieve all below-threshold records
for a specific agent ordered by threshold status.

`below_threshold` (Boolean) is kept for application logic. `below_threshold_str`
(String, values `"true"`/`"false"`) is a separate attribute used exclusively as
the GSI sort key, since DynamoDB GSI sort keys require String, Number, or Binary.
The handler sets both attributes on every write.

---

### 2.2 Scorer Lambda

**Function name:** `ai-platform-quality-scorer-dev`  
**Runtime:** python3.12  
**Architecture:** arm64 (Graviton — ADR-004)  
**Memory:** 512 MB  
**Timeout:** 5 minutes  
**Handler:** `handler.lambda_handler`  
**Source:** `terraform/dev/platform/quality-scorer/handler.py`

#### Environment Variables

| Variable            | Value                                                                                                         | Source              |
|---------------------|---------------------------------------------------------------------------------------------------------------|---------------------|
| PROMPT_VAULT_BUCKET | ai-platform-dev-prompt-vault-096305373014                                                                     | Platform output     |
| QUALITY_TABLE       | ai-platform-dev-quality-records                                                                               | Hardcoded           |
| SCORER_MODEL_ARN    | us.anthropic.claude-haiku-4-5-20251001-v1:0                                                                   | Cross-region inference profile (required for Claude 4.x on-demand throughput) |
| SCORE_THRESHOLD     | 0.70                                                                                                          | Hardcoded           |
| ENVIRONMENT         | dev                                                                                                           | Hardcoded           |
| AWS_REGION          | us-east-2                                                                                                     | Runtime provided    |

#### Processing Flow

The handler executes this sequence on every invocation:

**Step 1 — Discover unscored records**

List all objects under `prompt-vault/` in the Prompt Vault bucket
using an S3 paginator. For each object derive the `record_id` from
the S3 key (UUID filename without `.json` extension).

Query DynamoDB using `record_id` as the partition key only (do not
supply `scored_at` — it varies per run and a GetItem would never
find an existing record). If the Query returns any items the record
has already been scored — skip it. This makes the scorer idempotent
— re-running it never double-scores.

**Step 1b — Load agent descriptions from registry**

After collecting the list of unscored records, determine the unique
set of `agent_id` values present. For each unique `agent_id`, call
`GetItem` on the agent registry table (`ai-platform-dev-agent-registry`,
partition key `agent_id`) and extract the `agent_description` field.

Cache results in a dict keyed on `agent_id` — do not call the registry
once per record. If an `agent_id` is not found in the registry or
`agent_description` is missing, fall back to `"an enterprise AI assistant"`
and log a structured warning:

```json
{
  "event": "agent_description_missing",
  "agent_id": "...",
  "fallback": "an enterprise AI assistant"
}
```

Add `dynamodb:GetItem` on the agent registry table ARN to the IAM
permissions (see Section 2.3).

**Step 2 — Read and validate**

Fetch each unscored record from S3 and parse the JSON. Validate that
these required fields are present:

```
record_id, agent_id, session_id, user_input,
agent_response, guardrail_result, environment
```

If required fields are missing: log a structured warning and skip.
Do not fail the entire batch for a single malformed record.

**Step 3 — Handle guardrail-blocked records**

If `guardrail_result.action = "GUARDRAIL_INTERVENED"` and
`agent_response` is empty or a standard blocked message:

Write a quality record with:
- All five dimension scores omitted (not set)
- `guardrail_fired = true`
- `guardrail_skipped = true`
- `below_threshold = false` (guardrail blocks are not quality failures)
- `reasoning = "Record skipped — guardrail intervention"`

Do not invoke Haiku for these records.

**Step 4 — Build evaluation prompt**

Construct the evaluation prompt using the template in Section 3.
Interpolate `agent_id` from the Prompt Vault record and
`agent_description` from the registry cache populated in Step 1b.
Format `tool_calls` as:
- No tools called: `"No tools called — response from model knowledge
  or KB context only"`
- Tools called: `"Called {tool_name} with query '{input}' —
  returned: {output[:200]}"`

**Step 5 — Invoke Haiku**

```python
response = bedrock.converse(
    modelId=os.environ["SCORER_MODEL_ARN"],
    messages=[{
        "role": "user",
        "content": [{"text": evaluation_prompt}]
    }],
    inferenceConfig={
        "maxTokens": 500,
        "temperature": 0.0
    }
)
```

Use `temperature=0.0` for deterministic scoring. The same interaction
scored twice must produce the same scores.

Parse the response text as JSON. If JSON parsing fails:
- Log the raw response as a structured warning
- Skip this record
- Do not retry

**Step 6 — Calculate scores**

```python
dimensions = [
    "correctness", "relevance", "groundedness",
    "completeness", "tone"
]
scores = {d: float(parsed[d]) for d in dimensions}
overall = sum(scores.values()) / len(scores)
below_threshold = overall < float(os.environ["SCORE_THRESHOLD"])
```

Reject any score outside [0.0, 1.0] with a structured warning and
skip the record. Do not clamp — an out-of-range value signals a
broken evaluation prompt response and must not be silently corrected.

**Step 7 — Write quality record to DynamoDB**

Write the complete item per the schema in Section 2.1.
Set TTL to 90 days from now:

```python
import time
ttl = int(time.time()) + (90 * 24 * 60 * 60)
```

**Step 8 — Emit CloudWatch custom metrics**

Emit to namespace `AIPlatform/Quality`. Batch metrics in groups
of 20 per PutMetricData call.

Per record emit:

| Metric name      | Dimensions                        | Value              | Unit         |
|------------------|-----------------------------------|--------------------|--------------|
| QualityScore     | AgentId, Dimension=correctness    | score_correctness  | None         |
| QualityScore     | AgentId, Dimension=relevance      | score_relevance    | None         |
| QualityScore     | AgentId, Dimension=groundedness   | score_groundedness | None         |
| QualityScore     | AgentId, Dimension=completeness   | score_completeness | None         |
| QualityScore     | AgentId, Dimension=tone           | score_tone         | None         |
| QualityScore     | AgentId, Dimension=overall        | score_overall      | None         |
| BelowThreshold   | AgentId                           | 1 or 0             | Count        |
| GuardrailFired   | AgentId                           | 1 or 0             | Count        |
| ScorerLatency    | AgentId                           | evaluation_latency_ms | Milliseconds |

**Step 9 — Structured logging**

Per-record log after scoring:

```json
{
  "event": "record_scored",
  "record_id": "...",
  "agent_id": "...",
  "score_overall": 0.85,
  "below_threshold": false,
  "guardrail_fired": false,
  "evaluation_latency_ms": 1250,
  "scorer_model": "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}
```

Batch summary log at invocation end:

```json
{
  "event": "scoring_batch_complete",
  "records_found": 6,
  "records_scored": 4,
  "records_skipped_already_scored": 1,
  "records_skipped_guardrail": 1,
  "records_failed": 0,
  "below_threshold_count": 0,
  "batch_duration_ms": 12500
}
```

#### X-Ray Instrumentation

Follow the X-Ray instrumentation pattern established in PR #17:

```python
try:
    from aws_xray_sdk.core import xray_recorder, patch_all
    patch_all()
except ImportError:
    pass
```

Call `patch_all()` at module level after the import, wrapped in
`try/except ImportError` for graceful degradation if the SDK is
absent. Apply the `@xray_recorder.capture()` decorator to the main
scoring function (`score_record` or equivalent).

#### Packaging

Follow the `null_resource` build pattern established in PR #17:

```
quality-scorer/
  handler.py
  requirements.txt    # aws-xray-sdk only — boto3 available in runtime
```

The `null_resource` installs dependencies with the ARM64 platform flag:

```bash
uv pip install \
  --python-platform aarch64-manylinux2014 \
  --python-version "3.12" \
  --target=build/ \
  --only-binary=:all: \
  -r requirements.txt
```

`archive_file` packages `build/` as `source_dir`. See
`modules/glean-stub/main.tf` for the exact pattern to follow.

---

### 2.3 IAM Role

**Role name:** `ai-platform-quality-scorer-dev`  
**Ownership:** Inline in `terraform/dev/platform/main.tf` per Option B  
**Trust policy:** `lambda.amazonaws.com`

#### Permissions

| Action                          | Resource                                    | Reason                    |
|---------------------------------|---------------------------------------------|---------------------------|
| s3:GetObject                    | Prompt Vault bucket ARN/*                   | Read Prompt Vault records  |
| s3:ListBucket                   | Prompt Vault bucket ARN                     | Discover unscored records  |
| dynamodb:GetItem                | Agent registry table ARN                    | Look up agent_description  |
| dynamodb:PutItem                | Quality table ARN                           | Write quality records      |
| dynamodb:Query                  | Quality table ARN and ARN/index/*           | Idempotency check and GSI queries |
| bedrock:InvokeModel             | arn:aws:bedrock:REGION:ACCOUNT:inference-profile/* and arn:aws:bedrock:*::foundation-model/* | Score with Haiku  |
| cloudwatch:PutMetricData        | * (service restriction — no resource scope) | Emit quality metrics       |
| logs:CreateLogGroup             | Scorer log group ARN                        | Lambda logging             |
| logs:CreateLogStream            | Scorer log group ARN:*                      | Lambda logging             |
| logs:PutLogEvents               | Scorer log group ARN:*                      | Lambda logging             |
| kms:Decrypt                     | Platform KMS key ARN                        | Decrypt S3 and DynamoDB    |
| kms:GenerateDataKey             | Platform KMS key ARN                        | Encrypt DynamoDB writes    |
| xray:PutTraceSegments           | *                                           | X-Ray tracing              |
| xray:PutTelemetryRecords        | *                                           | X-Ray tracing              |

Note on Haiku model ARN: Claude Haiku 4.5 requires the cross-region
inference profile format, same as Claude Sonnet 4.x. Use:
`us.anthropic.claude-haiku-4-5-20251001-v1:0`

The IAM policy must include both `inference-profile/*` and
`foundation-model/*` ARNs. Using the bare model ID causes
`ValidationException: The provided model identifier is invalid`.
Confirm the exact identifier against available inference profiles:
```bash
aws bedrock list-inference-profiles --region us-east-2 \
  --query 'inferenceProfileSummaries[?contains(inferenceProfileId,`haiku`)].inferenceProfileId'
```

---

### 2.3a Agent Registry — `agent_description` Column

`agent_description` is a platform-level agent registration requirement.
Every agent deployed on this platform must include it in its registry
`put-item` manifest. The scorer uses it to frame the evaluation prompt
correctly for each agent's domain — without it the scorer falls back to
a generic description that reduces scoring accuracy.

**New required column in `ai-platform-dev-agent-registry`:**

| Attribute           | Type   | Description                                                     |
|---------------------|--------|-----------------------------------------------------------------|
| agent_description   | String | One-sentence plain-English description of the agent's purpose, used to frame the LLM-as-Judge evaluation prompt |

**Platform documentation update required.**

Add `agent_description` to the agent registration contract in
`terraform/dev/platform/README.md` under the agent onboarding section.
Document it as a mandatory field alongside `agent_id`, `display_name`,
and `model_arn`. All current and future agent layers must include it in
their registry `put-item` block.

Example (HR Assistant):
```json
"agent_description": {"S": "an enterprise HR Assistant that answers employee questions about HR policies, benefits, and workplace procedures"}
```

Each agent team is responsible for writing an accurate description that
reflects their agent's domain and task type. The description is read by
Haiku at scoring time — it should be specific enough to anchor the
correctness and groundedness dimensions correctly.

Agent layers that do not yet include `agent_description` will receive a
graceful fallback (`"an enterprise AI assistant"`) with a structured
warning log until they are updated (see Step 1b).

---

### 2.4 EventBridge Schedule

**Rule name:** `ai-platform-quality-scorer-schedule-dev`  
**Schedule:** `rate(1 hour)`  
**State:** ENABLED  
**Description:** Triggers quality scorer to evaluate new Prompt Vault
records hourly

Required resources:
- `aws_cloudwatch_event_rule` — the schedule rule
- `aws_cloudwatch_event_target` — targets the scorer Lambda
- `aws_iam_role` — EventBridge role with `lambda:InvokeFunction`
  on the scorer Lambda ARN
- `aws_lambda_permission` — allows `events.amazonaws.com` to invoke
  the scorer Lambda, source ARN scoped to the event rule

---

### 2.5 CloudWatch Log Group

**Log group:** `/aws/lambda/ai-platform-quality-scorer-dev`  
**Retention:** 30 days  
**Encryption:** Platform KMS key

---

### 2.6 CloudWatch Alarms

#### Alarm 1 — High below-threshold rate

| Field       | Value                                                    |
|-------------|----------------------------------------------------------|
| Name        | ai-platform-quality-below-threshold-dev                  |
| Namespace   | AIPlatform/Quality                                       |
| Metric      | BelowThreshold                                           |
| Statistic   | Sum                                                      |
| Period      | 3600 seconds                                             |
| Threshold   | 3                                                        |
| Comparison  | GreaterThanThreshold                                     |
| Description | More than 3 responses below quality threshold in 1 hour  |

#### Alarm 2 — Scorer Lambda errors

| Field       | Value                                                    |
|-------------|----------------------------------------------------------|
| Name        | ai-platform-quality-scorer-errors-dev                    |
| Namespace   | AWS/Lambda                                               |
| Metric      | Errors                                                   |
| Dimensions  | FunctionName=ai-platform-quality-scorer-dev              |
| Statistic   | Sum                                                      |
| Period      | 3600 seconds                                             |
| Threshold   | 1                                                        |
| Comparison  | GreaterThanOrEqualToThreshold                            |
| Description | Quality scorer Lambda encountered errors                 |

---

## 3. Evaluation Rubric

### 3.1 Evaluation Prompt Template

The scorer sends this prompt to Haiku for every interaction.
The prompt instructs Haiku to return structured JSON only —
no preamble, no markdown fences, no explanation outside the
JSON object.

```
You are a quality evaluator for an enterprise AI agent.
The agent being evaluated is: {agent_id} — {agent_description}
Evaluate the following interaction and score it on five dimensions.

USER INPUT:
{user_input}

AGENT RESPONSE:
{agent_response}

TOOL CALLS MADE:
{tool_calls_summary}

GUARDRAIL RESULT:
{guardrail_result}

Score each dimension from 0.0 to 1.0 where:
1.0 = excellent, 0.8 = good, 0.6 = acceptable,
0.4 = poor, 0.2 = very poor, 0.0 = completely wrong

DIMENSIONS:

correctness (0.0-1.0):
Is the information factually accurate? Does it correctly answer
the question asked? Penalise hallucinated facts, wrong figures,
or content that contradicts retrieved policy documents.

relevance (0.0-1.0):
Does the response directly address what the user asked?
Penalise responses that are technically correct but answer
a different question, or that contain large amounts of
irrelevant content.

groundedness (0.0-1.0):
Is the response grounded in retrieved content rather than
the model's parametric knowledge? If tool calls were made,
does the response reflect what those tools returned?
Penalise responses that ignore retrieved documentation or
contradict it.

completeness (0.0-1.0):
Does the response fully address the question or does it
leave important aspects unanswered? Penalise partial answers
that require follow-up for basic information retrieved
documentation would contain.

tone (0.0-1.0):
Is the response professional, clear, and appropriately concise
for an enterprise assistant context? Penalise responses that
are overly long, use excessive jargon, are condescending, or
inappropriately casual.

Respond with ONLY this JSON object and nothing else:
{
  "correctness": 0.0,
  "relevance": 0.0,
  "groundedness": 0.0,
  "completeness": 0.0,
  "tone": 0.0,
  "reasoning": "One sentence identifying the most significant
                quality issue, or 'No significant issues
                identified' if all scores are above 0.8"
}
```

> **Implementation note:** Despite the "no markdown fences" instruction, Haiku
> frequently wraps its JSON response in ` ```json ... ``` ` code fences. The
> handler strips these before calling `json.loads()`. Do not remove the fence-
> stripping logic — without it every scoring attempt raises `json.JSONDecodeError`
> and the record is skipped.

### 3.2 Score Interpretation

| Range     | Label       | Action                                    |
|-----------|-------------|-------------------------------------------|
| 0.90–1.00 | Excellent   | No action required                        |
| 0.80–0.89 | Good        | No action required                        |
| 0.70–0.79 | Acceptable  | Monitor for trend — no immediate action   |
| 0.50–0.69 | Poor        | Flag for human review — below_threshold   |
| 0.00–0.49 | Very poor   | Flag for human review — priority review   |

### 3.3 Overall Score Threshold

**Threshold:** 0.70 (configurable via SCORE_THRESHOLD env var)

Records with `score_overall < 0.70` are flagged as `below_threshold = true`
and appear in the human review queue via the `agent-threshold-index` GSI.

The threshold applies to the overall score only. Individual dimension
scores below 0.70 are visible in the DynamoDB record and CloudWatch
metrics but do not independently trigger the below_threshold flag.

---

## 4. Platform Outputs

Add to `terraform/dev/platform/outputs.tf`:

| Output name                  | Value                                  | Description                              |
|------------------------------|----------------------------------------|------------------------------------------|
| quality_records_table        | DynamoDB table name                    | Quality scores table                     |
| quality_scorer_function_name | Lambda function name                   | For manual invocation                    |
| quality_scorer_log_group     | /aws/lambda/ai-platform-dev-quality-scorer | CloudWatch log group              |

---

## 5. File Structure

```
terraform/dev/platform/
  quality-scorer/
    handler.py          # Scorer Lambda handler
    requirements.txt    # aws-xray-sdk
  main.tf               # All new resources added here
  outputs.tf            # New outputs added here
```

No new modules. All resources are defined inline in the platform
layer per the existing pattern for platform-level infrastructure.

---

## 6. Validation Checklist

The implementation is complete when all of the following pass:

### Terraform
- [x] `terraform validate` returns zero errors and zero warnings
- [x] `terraform plan` shows expected resources — no unexpected
      destroy or replace operations
- [x] `terraform apply` completes with zero errors

### Functional
- [x] Manual Lambda invocation processes all existing Prompt Vault
      records without errors
- [x] DynamoDB quality records table contains one item per scored
      Prompt Vault record
- [x] Each DynamoDB item contains all five dimension scores,
      overall score, below_threshold flag, and TTL
- [x] Guardrail-blocked records produce items with guardrail_skipped=true
      and no dimension scores
- [x] Re-running the scorer does not create duplicate records
      (idempotency confirmed)

### Observability
- [x] CloudWatch namespace `AIPlatform/Quality` contains all four
      metric names: QualityScore, BelowThreshold, GuardrailFired,
      ScorerLatency
- [x] QualityScore metric has six Dimension values: correctness,
      relevance, groundedness, completeness, tone, overall
- [x] CloudWatch log group contains structured JSON batch summary
      with records_failed = 0
- [x] Both CloudWatch alarms are in OK state after initial run

### Integration
- [x] All 6 HR Assistant smoke tests still pass after platform changes
- [x] EventBridge rule is ENABLED and correctly targets scorer Lambda
- [x] Lambda permission allows events.amazonaws.com invocation

---

## 7. Commit Strategy

| Commit message                                                                       | Contents                                                          |
|--------------------------------------------------------------------------------------|-------------------------------------------------------------------|
| feat(platform): add quality records DynamoDB table                                  | Table resource and output                                         |
| feat(platform): add LLM-as-Judge scorer Lambda and IAM role                         | Lambda, role, log group, packaging                                |
| feat(platform): add EventBridge hourly schedule for scorer                          | Rule, target, permission                                          |
| feat(platform): add quality scorer CloudWatch alarms                                | Both alarm resources                                              |
| docs(platform): add agent_description to registration contract and README           | README agent onboarding section — mandatory field for all agents  |
| feat(agents/hr-assistant): add agent_description to registry manifest               | First implementation of platform agent registration contract      |

One commit per line. Do not combine. The `docs(platform)` commit establishes
the contract before any agent implements it. The `feat(agents/hr-assistant)`
commit belongs in the agents layer and is applied after the platform layer.
Do not commit terraform.tfvars, tfplan files, or build/ directories.

---

## 8. Open Questions

The following decisions are deferred and should be revisited before
promoting to staging:

**Q1 — Human review queue interface**
The GSI enables querying below-threshold records but there is no
interface for reviewers to action them. A simple S3 export or
DynamoDB Streams-triggered notification is the likely Phase 2
addition.

**Q2 — Multi-agent scoring rubric differentiation**
The current rubric is tuned for the HR Assistant. A customer
service agent or a data analysis agent may require different
dimension weightings or additional dimensions. The AGENT_ID_FILTER
environment variable allows per-agent scorer instances if needed.

**Q3 — Staging threshold calibration**
The 0.70 threshold is set without baseline data. After the first
two weeks of dev operation review the score distribution and
adjust the threshold to the appropriate percentile for staging.

**Q4 — Cost of Haiku scoring**
Each scoring invocation consumes approximately 800–1200 input tokens
and 100–200 output tokens. At dev volumes (tens of records per day)
the cost is negligible. Monitor as volume grows. If cost becomes
material at scale, reduce invocation frequency from hourly to every
6 hours rather than batching multiple records into a single Haiku
invocation. Batching would cause records to be scored in mutual
context, violating the determinism guarantee.
