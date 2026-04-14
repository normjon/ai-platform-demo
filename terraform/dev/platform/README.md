# Platform Layer — `terraform/dev/platform/`

Core platform services. Freely destroyable and reapplyable. Foundation must
be applied first. Tools and agents depend on this layer.

---

## Purpose

Platform provisions the runtime and shared services that all agents and tools
run on top of:

- **AgentCore runtime** — the managed agent execution environment. Runs the
  HR Assistant container in VPC-private mode on arm64/Graviton.
- **MCP Gateway** — brokers tool calls from the AgentCore runtime to registered
  MCP tool endpoints. Authorises callers via AWS IAM.
- **Storage** — DynamoDB tables for session memory and agent registry; S3
  buckets for document landing and the Prompt Vault.
- **Observability** — CloudWatch log groups and metric alarms for the AgentCore
  runtime and Bedrock Knowledge Base.
- **Platform IAM** — the AgentCore runtime role and Bedrock KB role. Each is
  scoped to this layer's resources. Tool and agent roles are owned by their
  respective layers.

---

## Resources

| Resource | What it creates |
| --- | --- |
| `aws_iam_role.agentcore_runtime` | Runtime role assumed by `bedrock-agentcore.amazonaws.com` |
| `aws_iam_role.bedrock_kb` | KB ingestion role assumed by `bedrock.amazonaws.com` |
| `module.storage` | 2 S3 buckets + 2 DynamoDB tables (KMS encrypted) |
| `module.observability` | 2 CloudWatch log groups + 2 metric alarms |
| `module.agentcore` | AgentCore runtime endpoint + MCP Gateway |
| `aws_opensearchserverless_collection.kb` | Shared AOSS VECTORSEARCH collection (`ai-platform-kb-dev`) |
| `aws_opensearchserverless_security_policy.kb_encryption` | AWS-managed KMS encryption policy |
| `aws_opensearchserverless_security_policy.kb_network` | Public endpoint network policy (required by Bedrock) |
| `aws_opensearchserverless_access_policy.kb_platform_access` | Platform-level index management access for Terraform caller (`ai-platform-kb-platform-dev`) |

### Storage Resources

| Resource | Name | Purpose |
| --- | --- | --- |
| S3 | `ai-platform-dev-document-landing-<account>` | Source documents for Knowledge Base ingestion |
| S3 | `ai-platform-dev-prompt-vault-<account>` | Structured interaction records written by the Prompt Vault Lambda after every live agent invocation — versioned, KMS encrypted |
| DynamoDB | `ai-platform-dev-session-memory` | AgentCore session state (partition: `session_id`, sort: `timestamp`) |
| DynamoDB | `ai-platform-dev-agent-registry` | Agent manifest registry |
| DynamoDB | `ai-platform-dev-quality-records` | Quality scores written by the scorer Lambda. PK: `record_id`, SK: `scored_at`. GSI `agent-threshold-index` for human review queue. 90-day TTL. |

### Observability Resources

| Resource | Name | Purpose |
| --- | --- | --- |
| CloudWatch Log Group | `/aws/agentcore/ai-platform-dev` | Platform-managed log group (provisioned by `module.observability`). AgentCore container runtime logs go to the AWS-managed path `/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT` — see the agent layer README for the correct query path. |
| CloudWatch Log Group | `/aws/bedrock/knowledge-base/ai-platform-dev` | Bedrock KB ingestion logs |
| CloudWatch Alarm | `ai-platform-dev-agentcore-errors` | Fires on AgentCore error count > 5 in a 5-minute window |
| CloudWatch Alarm | `ai-platform-dev-agentcore-p99-latency` | Fires on p99 invocation latency threshold |

---

## Dependencies

Reads the following outputs from foundation via `terraform_remote_state`:

| Foundation output | Used for |
| --- | --- |
| `vpc_id` | Re-exported in platform outputs |
| `subnet_ids` | AgentCore runtime VPC placement |
| `agentcore_sg_id` | AgentCore runtime security group |
| `storage_kms_key_arn` | Encrypts S3, DynamoDB, CloudWatch log groups |
| `ecr_repository_url` | AgentCore runtime container image source |

---

## Platform API (Outputs)

These outputs are the interface contract consumed by tools and agents via
`terraform_remote_state`. Do not remove or rename outputs without updating
all downstream layers.

| Output | Description |
| --- | --- |
| `agentcore_endpoint_id` | AgentCore runtime endpoint ID |
| `agentcore_gateway_id` | MCP Gateway ID — tools register targets against this |
| `vpc_id` | Re-exported from foundation |
| `subnet_ids` | Re-exported from foundation |
| `agentcore_sg_id` | Re-exported from foundation |
| `kms_key_arn` | Re-exported from foundation |
| `document_landing_bucket` | S3 bucket name |
| `prompt_vault_bucket` | S3 bucket name |
| `session_memory_table` | DynamoDB table name |
| `agent_registry_table` | DynamoDB table name |
| `log_group_agentcore` | CloudWatch log group name |
| `opensearch_collection_id` | AOSS collection ID |
| `opensearch_collection_arn` | AOSS collection ARN — used in `aws_bedrockagent_knowledge_base` |
| `opensearch_collection_endpoint` | AOSS collection endpoint URL — used by index creation scripts |
| `opensearch_collection_name` | AOSS collection name — used in agent data access policy resource strings |
| `quality_records_table` | Quality scores DynamoDB table name |
| `quality_scorer_function_name` | Scorer Lambda function name — for manual invocation |
| `quality_scorer_log_group` | Scorer Lambda CloudWatch log group name |

---

## Prerequisites

- Foundation layer applied. Run `terraform output` in `terraform/dev/foundation/`
  to confirm outputs are available.
- Agent container image pushed to ECR. See `terraform/dev/agents/hr-assistant/README.md`.
- `terraform.tfvars` created with `agent_image_uri` set to the ECR URI of the
  pushed arm64 image.

---

## First-Time Setup

```bash
cd terraform/dev/platform

# One-time per machine
terraform init

# Create tfvars
cp terraform.tfvars.example terraform.tfvars
# Set agent_image_uri to the ECR URI from foundation output:
#   terraform -chdir=../foundation output -raw ecr_repository_url

terraform plan -out=tfplan
# Review — expect ~15 resources to add
terraform apply tfplan
```

---

## Iterative Cycle

Platform can be destroyed and reapplied freely. Foundation stays up.

```bash
cd terraform/dev/platform

# Destroy (purge S3 first — see Known Issues)
terraform destroy -auto-approve

# Reapply
terraform plan -out=tfplan
terraform apply tfplan
```

After reapply, redeploy any tools that registered gateway targets, as the
gateway ID changes on each apply.

---

## Destroy

Purge S3 versions before destroying — Terraform cannot delete non-empty
versioned buckets.

```bash
for BUCKET in \
  ai-platform-dev-document-landing-096305373014 \
  ai-platform-dev-prompt-vault-096305373014; do

  VERSIONS=$(aws s3api list-object-versions --bucket "$BUCKET" --region us-east-2 \
    --query 'Versions[].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null)
  if [ "$VERSIONS" != "null" ] && [ "$VERSIONS" != "[]" ] && [ -n "$VERSIONS" ]; then
    DELETE_JSON=$(echo "$VERSIONS" | python3 -c \
      "import sys,json; v=json.load(sys.stdin); print(json.dumps({'Objects':v,'Quiet':True}))")
    aws s3api delete-objects --bucket "$BUCKET" --region us-east-2 --delete "$DELETE_JSON"
  fi

  MARKERS=$(aws s3api list-object-versions --bucket "$BUCKET" --region us-east-2 \
    --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null)
  if [ "$MARKERS" != "null" ] && [ "$MARKERS" != "[]" ] && [ -n "$MARKERS" ]; then
    DELETE_JSON=$(echo "$MARKERS" | python3 -c \
      "import sys,json; v=json.load(sys.stdin); print(json.dumps({'Objects':v,'Quiet':True}))")
    aws s3api delete-objects --bucket "$BUCKET" --region us-east-2 --delete "$DELETE_JSON"
  fi

done

cd terraform/dev/platform
terraform destroy -auto-approve
```

---

## Tests

Run after every apply to confirm the platform is operational.

```bash
cd terraform/dev/platform
./smoke-test.sh
```

The script reads all values from `terraform output` — no arguments needed. It exits 0
if all nine tests pass and 1 if any fail, making it suitable for CI/CD pipelines.

**Tests covered:**

| Test | What it checks | Pass condition |
| --- | --- | --- |
| 1 | AgentCore runtime status | `READY` |
| 2 | MCP Gateway status, auth, protocol | `READY` + `AWS_IAM` + `MCP` |
| 3 | Bedrock model invocation | Response contains `PASS` |
| 4 | DynamoDB session memory write/read/delete | Read returns written value |
| 5 | S3 document bucket KMS encryption | `ServerSideEncryption = aws:kms` |
| 6 | Quality records DynamoDB write/read/delete | Read returns written value |
| 7 | Quality scorer Lambda invocation | `scoring_batch_complete` log confirmed |
| 8 | EventBridge schedule enabled | Rule state = `ENABLED` |
| 9 | Quality scorer CloudWatch alarms present | Both alarms found |

---

## Quality Pipeline

The platform runs an LLM-as-Judge quality scorer that automatically evaluates
every interaction record written to the Prompt Vault. It fires hourly via
EventBridge, invokes Claude Haiku to score each interaction on five quality
dimensions, and writes results to DynamoDB.

### Resources

| Resource | Name | Purpose |
| --- | --- | --- |
| DynamoDB | `ai-platform-dev-quality-records` | Quality score records (PK: `record_id`, SK: `scored_at`) |
| Lambda | `ai-platform-dev-quality-scorer` | Scorer function (arm64, 512MB, 5min timeout) |
| CloudWatch Log Group | `/aws/lambda/ai-platform-dev-quality-scorer` | Scorer logs (30 day retention) |
| EventBridge Rule | `ai-platform-dev-quality-scorer-schedule` | Hourly trigger |
| CloudWatch Alarm | `ai-platform-dev-quality-below-threshold` | BelowThreshold > 3 per hour |
| CloudWatch Alarm | `ai-platform-dev-quality-scorer-errors` | Lambda Errors >= 1 per hour |

### Invoke manually

```bash
aws lambda invoke \
  --function-name ai-platform-dev-quality-scorer \
  --region us-east-2 \
  --log-type Tail \
  --query 'LogResult' --output text \
  /tmp/scorer-response.json | base64 -d
```

### Query quality records

```bash
# All records for a specific agent
aws dynamodb query \
  --table-name ai-platform-dev-quality-records \
  --index-name agent-threshold-index \
  --key-condition-expression "agent_id = :aid" \
  --expression-attribute-values '{":aid": {"S": "hr-assistant-dev"}}' \
  --region us-east-2 \
  --query 'Items[*].{id:record_id.S,score:score_overall.S,below:below_threshold.BOOL}'

# Below-threshold records only
aws dynamodb query \
  --table-name ai-platform-dev-quality-records \
  --index-name agent-threshold-index \
  --key-condition-expression "agent_id = :aid AND below_threshold_str = :bt" \
  --expression-attribute-values '{":aid": {"S": "hr-assistant-dev"}, ":bt": {"S": "true"}}' \
  --region us-east-2
```

### Scoring dimensions

| Dimension | What it measures |
| --- | --- |
| correctness | Factual accuracy — penalises hallucinations and contradictions with retrieved content |
| relevance | Addresses the question asked — penalises off-topic responses |
| groundedness | Grounded in retrieved docs/tool output — penalises parametric knowledge responses |
| completeness | Fully answers the question — penalises partial answers |
| tone | Professional and concise — penalises jargon, excessive length, or casual register |

Overall score is the mean of the five dimensions. Records with `score_overall < 0.70` are
flagged `below_threshold = true` and queryable via the `agent-threshold-index` GSI.

### CloudWatch metrics emitted

The scorer emits to the `AIPlatform/Quality` namespace after each scored record:

| Metric | Stat to use in PromQL | Description |
| --- | --- | --- |
| `QualityScore` | `_sum / _count` | Per-record average score per dimension (0.0–1.0) |
| `BelowThreshold` | `sum_over_time(_sum[window])` | 1 if overall score < 0.70, 0 otherwise |
| `GuardrailFired` | `sum_over_time(_sum[window])` | 1 if the Bedrock Guardrail intervened |
| `ScorerLatency` | `_sum / _count` | Haiku Converse API round-trip in ms |

**Critical PromQL note:** These are CloudWatch gauges in AMP, not Prometheus counters.
Never use `rate()` or `increase()` — they return 0. Use `sum_over_time()` for totals
and `_sum / _count` for averages. See `specs/observability-metric-catalogue.md` for
full PromQL pattern guidance.

**Why raw `QualityScore_sum` is wrong:** The scorer batches all unscored records.
If a batch of 24 records is scored, CloudWatch aggregates all 24 `QualityScore` values
into `_sum` (~10.5 for correctness) and `_count` (24). Displaying `_sum` gives the
batch total, not the per-record score. Always divide: `QualityScore_sum / QualityScore_count`.

### Metric staleness in Grafana stat panels

The scorer runs hourly. Prometheus applies a 5-minute staleness window to instant queries.
Stat panels (`lastNotNull`) will show "No data" between scorer runs — this is expected
behaviour. Timeseries panels display historical data regardless of staleness. If a stat
panel shows "No data", invoke the scorer manually (command above) to get a fresh sample.

---

## Observability

### CloudWatch Log Groups

| Log group | Content |
| --- | --- |
| `/aws/agentcore/ai-platform-dev` | Platform-managed log group provisioned by `module.observability`. **AgentCore container runtime logs do not go here** — they go to the AWS-managed path below. |
| `/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT` | AWS-managed log group where AgentCore writes all container runtime logs: agent invocations, tool calls, KB retrievals, and errors. Resolve `<runtime-id>` from `terraform output -raw agentcore_endpoint_id` in the platform layer. |
| `/aws/bedrock/knowledge-base/ai-platform-dev` | Bedrock KB ingestion job results. |

Query the AgentCore runtime log group for recent errors:

```bash
RUNTIME_ID=$(terraform -chdir=terraform/dev/platform output -raw agentcore_endpoint_id)
aws logs filter-log-events \
  --log-group-name "/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT" \
  --region us-east-2 \
  --filter-pattern '{ $.level = "ERROR" }' \
  --start-time $(date -v-1H +%s000) \
  --query 'events[].message' \
  --output text
```

### CloudWatch Alarms

| Alarm | Condition | Action |
| --- | --- | --- |
| `ai-platform-dev-agentcore-errors` | Error count > 5 in a 5-minute window | Investigate `/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT` |
| `ai-platform-dev-agentcore-p99-latency` | p99 latency above threshold | Check runtime configuration and model |

Check alarm states:

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix ai-platform-dev \
  --region us-east-2 \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue}' \
  --output table
```

### X-Ray Tracing

The platform layer provisions a sampling rule (`ai-platform-dev-default`) and a
service group (`ai-platform-dev`) via `module.observability`. X-Ray tracing is
active on all three platform Lambdas via `tracing_config { mode = "Active" }`. The
Lambda SDK (`aws_xray_sdk`) is packaged in each ZIP for botocore call patching via
`patch_all()`.

| Function | Tracing mode | Notes |
| --- | --- | --- |
| `ai-platform-dev-glean-stub` | Active | SDK patches botocore calls |
| `hr-assistant-prompt-vault-writer-dev` | Active | SDK patches botocore calls |
| `ai-platform-dev-quality-scorer` | Active | SDK patches botocore calls including Bedrock Converse |

> **Pitfall:** Do NOT call `xray_recorder.put_annotation()` directly in a Lambda handler. Lambda's X-Ray runtime creates a `FacadeSegment` before the handler executes, and `FacadeSegments` cannot be mutated — the call raises `FacadeSegmentMutationException` and crashes the handler silently (the function returns HTTP 500 with no useful log). The `tracing_config { mode = "Active" }` and `patch_all()` are sufficient for Lambda X-Ray instrumentation.

View traces:

```bash
aws xray get-trace-summaries \
  --start-time $(date -v-1H +%s) \
  --end-time $(date +%s) \
  --region us-east-2 \
  --query 'TraceSummaries[*].{id:Id,duration:Duration,status:ResponseTime}' \
  --output table
```

---

## OpenSearch Serverless Collection

The platform provisions one shared AOSS collection (`ai-platform-kb-dev`) used
by all agents with Knowledge Bases. Agents own their index within this collection
— they do not own the collection itself.

| Property | Value |
| --- | --- |
| Collection name | `ai-platform-kb-dev` |
| Collection type | `VECTORSEARCH` |
| Encryption | AWS-managed KMS |
| Network | Public endpoint (required by Bedrock managed service — see note below) |
| Creation time | ~9 minutes on first apply |

### Adding a new agent Knowledge Base

Each agent that needs a Knowledge Base must add to its own agent layer:

1. An `aws_opensearchserverless_access_policy` granting its KB IAM role access to
   its specific index only. Pattern: `index/ai-platform-kb-dev/<agent-name>-index`
2. A `null_resource` with `sleep 60` to pre-create the index using
   `scripts/create-os-index.py`, reading the collection endpoint from platform
   remote state: `data.terraform_remote_state.platform.outputs.opensearch_collection_endpoint`
3. An `aws_bedrockagent_knowledge_base` referencing the collection ARN from
   platform remote state: `data.terraform_remote_state.platform.outputs.opensearch_collection_arn`

Never modify the platform-level data access policy (`ai-platform-kb-platform-dev`).
Each agent's access policy is independent — no agent can read another agent's index.

### Network policy note

The AOSS network policy allows public endpoint access. This is required by the
Bedrock managed service — Bedrock KB cannot reach AOSS through a VPC endpoint.
This is intentional. Data in transit is encrypted (TLS). Data at rest uses
AWS-managed KMS.

### Pre-flight check before applying an agent layer with a Knowledge Base

Confirm the collection is ACTIVE before applying any agent layer that includes a KB:

```bash
aws opensearchserverless get-collection \
  --id $(terraform output -raw opensearch_collection_id) \
  --region us-east-2 \
  --query 'collectionDetails.status'
```

Expected: `"ACTIVE"`. If `"CREATING"`: wait — collection creation takes ~9 minutes.

### Propagation delay note

The platform-level AOSS data access policy (`ai-platform-kb-platform-access-dev`)
takes ~60 seconds to propagate after apply. Agent layer null_resource scripts
include `sleep 60` for the agent-level policy propagation. In practice, the ~9
minute collection creation time means the platform policy will have fully
propagated before any agent layer is applied. If platform and agent layers are
ever applied in rapid automated succession, add an explicit wait between them.

---

## Agent Onboarding — Registration Contract

The platform owns the agent registry table (`ai-platform-dev-agent-registry`).
Each agent layer owns exactly one item in that table, keyed on its `agent_id`.
The item is written by a `terraform_data` + `local-exec` `put-item` block in
the agent layer's `main.tf` — the platform layer never writes agent items.

The registry is read at runtime by:
- **The AgentCore container** — loads `model_arn`, `guardrail_id`, `knowledge_base_id`,
  and related configuration at agent startup
- **The quality scorer Lambda** — reads `agent_description` to frame the
  LLM-as-Judge evaluation prompt correctly for each agent's domain

### Mandatory fields

Every agent `put-item` block must include all of the following:

| Field                        | DynamoDB type | Description |
|------------------------------|---------------|-------------|
| `agent_id`                   | S             | Unique identifier. Convention: `<name>-<env>` (e.g. `hr-assistant-dev`) |
| `display_name`               | S             | Human-readable name shown in observability dashboards |
| `model_arn`                  | S             | Inference profile ARN. Must use `us.*` prefix for Claude 4.x models |
| `system_prompt_arn`          | S             | Bedrock Prompt ARN for the agent's system prompt |
| `guardrail_id`               | S             | Bedrock Guardrail ID |
| `guardrail_version`          | S             | Bedrock Guardrail version |
| `endpoint_id`                | S             | AgentCore runtime endpoint ID (from platform output `agentcore_endpoint_id`) |
| `gateway_id`                 | S             | MCP Gateway ID (from platform output `agentcore_gateway_id`) |
| `allowed_tools`              | SS            | Set of MCP tool names the agent is authorised to call (e.g. `["glean-search"]`) |
| `data_classification_ceiling`| S             | Maximum data classification the agent may handle (`INTERNAL`, `CONFIDENTIAL`) |
| `session_ttl_hours`          | N             | Session memory TTL in hours |
| `grounding_score_min`        | N             | Minimum acceptable Bedrock grounding score (0.0–1.0) |
| `response_latency_p95_ms`    | N             | p95 latency SLO in milliseconds — used by observability alarms |
| `monthly_usd_limit`          | N             | Monthly Bedrock spend limit in USD — used by cost alarms |
| `alert_threshold_pct`        | N             | Percentage of monthly limit that triggers a cost alert (0–100) |
| `environment`                | S             | Deployment environment (`dev`, `staging`, `production`) |
| `registered_at`              | S             | ISO 8601 UTC timestamp of registration — use `$(date -u +%Y-%m-%dT%H:%M:%SZ)` |
| `agent_description`          | S             | **Required by quality scorer.** One-sentence plain-English description of the agent's purpose and domain. Used to frame the LLM-as-Judge evaluation prompt — be specific enough to anchor the correctness and groundedness dimensions correctly. |

### Optional fields

| Field              | DynamoDB type | Description |
|--------------------|---------------|-------------|
| `knowledge_base_id`| S             | Bedrock Knowledge Base ID. Include if the agent uses a KB for retrieval. Omit for agents that do not use a KB. |

### Reference `put-item` template

```bash
aws dynamodb put-item \
  --region "${var.aws_region}" \
  --table-name "${data.terraform_remote_state.platform.outputs.agent_registry_table}" \
  --item '{
    "agent_id":                    {"S": "<name>-<env>"},
    "display_name":                {"S": "<Human-Readable Name> (<Env>)"},
    "agent_description":           {"S": "<one sentence describing what this agent does and for whom>"},
    "model_arn":                   {"S": "${var.model_arn}"},
    "system_prompt_arn":           {"S": "<bedrock prompt arn>"},
    "guardrail_id":                {"S": "<guardrail id>"},
    "guardrail_version":           {"S": "<guardrail version>"},
    "endpoint_id":                 {"S": "${data.terraform_remote_state.platform.outputs.agentcore_endpoint_id}"},
    "gateway_id":                  {"S": "${data.terraform_remote_state.platform.outputs.agentcore_gateway_id}"},
    "allowed_tools":               {"SS": ["<tool-name>"]},
    "data_classification_ceiling": {"S": "INTERNAL"},
    "session_ttl_hours":           {"N": "24"},
    "grounding_score_min":         {"N": "0.75"},
    "response_latency_p95_ms":     {"N": "5000"},
    "monthly_usd_limit":           {"N": "50"},
    "alert_threshold_pct":         {"N": "80"},
    "environment":                 {"S": "${var.environment}"},
    "registered_at":               {"S": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
  }'
```

### Writing `agent_description`

The description is read by Haiku at quality scoring time. Write it as a single
sentence that accurately names the agent's role, its primary user, and the
domain it operates in. The quality scorer uses it to correctly anchor
`correctness` and `groundedness` dimensions — a vague description produces
less accurate scores.

Good: `"an enterprise HR Assistant that answers employee questions about HR policies, benefits, and workplace procedures"`  
Too vague: `"an AI assistant that helps users"`

### Teardown note

The `terraform_data + local-exec` provisioner does not have a `when = destroy`
handler. Registry items persist after `terraform destroy`. Delete manually:

```bash
aws dynamodb delete-item \
  --region us-east-2 \
  --table-name ai-platform-dev-agent-registry \
  --key '{"agent_id": {"S": "<agent-id>"}}'
```

---

## Known Issues

**AgentCore VPC-mode ENIs block subnet deletion on destroy**

After destroying the AgentCore runtime, AWS releases `agentic_ai` ENIs
asynchronously. If platform destroy completes but foundation destroy
subsequently fails on subnet deletion with `DependencyViolation`, wait
15-30 minutes and re-run `terraform destroy -auto-approve` in foundation/.

**Gateway ID changes on every apply**

The MCP Gateway ID is regenerated each time the platform layer is destroyed
and reapplied. Any tools that registered gateway targets must be redeployed
after a platform cycle to register against the new gateway ID.
