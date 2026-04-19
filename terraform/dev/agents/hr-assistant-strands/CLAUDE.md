# CLAUDE.md — HR Assistant Strands Agent Layer

**Scope:** `terraform/dev/agents/hr-assistant-strands/` only.
This is level 3 of the three-level CLAUDE.md hierarchy (ADR-021).
Read the project-root CLAUDE.md and `terraform/dev/agents/hr-assistant/CLAUDE.md`
before reading this file. Many patterns are documented there and not repeated here.

---

## Relationship to the boto3 HR Assistant

This layer is a **parallel implementation** of the HR Assistant using the AWS Strands
Agents SDK. The existing `terraform/dev/agents/hr-assistant/` layer (boto3) remains
fully operational as a regression baseline and is **never modified by this layer**.

The two agents share all policy-level resources. This layer **consumes** them as variables
but owns none of them:

| Shared resource | Owner |
| --- | --- |
| System prompt (Bedrock Prompt ARN) | `hr-assistant` layer |
| Guardrail (`hr-assistant-guardrail-dev`) | `hr-assistant` layer |
| HR Policies Knowledge Base (`BWJGUXDACJ`) | `hr-assistant` layer |
| Prompt Vault Lambda (`hr-assistant-prompt-vault-writer-dev`) | `hr-assistant` layer |
| Prompt Vault S3 bucket | Platform layer |
| Agent registry DynamoDB table | Platform layer |

The `hr-assistant` layer **must be applied before** this layer. Its `terraform output`
values populate this layer's `terraform.tfvars`.

---

## What This Layer Owns

- `aws_bedrockagentcore_agent_runtime.strands` — dedicated Strands runtime endpoint
- `aws_cloudwatch_log_group.strands_runtime` — imported at first apply (AgentCore
  pre-creates it; see Terraform State below)
- `terraform_data.hr_strands_manifest` — DynamoDB registry entry for `hr-assistant-strands-dev`
- Container image: `096305373014.dkr.ecr.us-east-2.amazonaws.com/ai-platform-dev-hr-assistant:strands-<sha>`

It does NOT own: VPC, KMS, ECR, S3 buckets, DynamoDB tables, guardrail, KB, system
prompt, or the Prompt Vault Lambda. Those are consumed from remote state or variables.

---

## Pre-Flight Checklist

### 1. Foundation + Platform layers applied

### 2. `hr-assistant` layer applied

The guardrail, KB, system prompt, and Prompt Vault Lambda must exist before applying
this layer. Read their ARNs/IDs with:

```bash
cd terraform/dev/agents/hr-assistant
terraform output guardrail_id
terraform output guardrail_version
terraform output knowledge_base_id
terraform output prompt_vault_writer_arn
terraform output prompt_vault_bucket
```

Set these values in `terraform/dev/agents/hr-assistant-strands/terraform.tfvars`.

### 3. Strands container image pushed to ECR

Build and push from `container/`. See Container Build below.
Set `agent_image_uri` in `terraform.tfvars` to the pushed ECR URI.

### 4. Platform IAM role has S3 Strands session write permission

The platform `agentcore_runtime` role must include the `S3StrandsSessionReadWrite`
statement (added in commit `cde715b`). This grants `s3:PutObject` to the
`strands-sessions/*` prefix on the prompt vault bucket, which `S3SessionManager`
requires. Without it, every invocation logs `invocation_error` with
`AccessDenied: s3:PutObject`. Verify the platform layer has been applied with
this statement before applying this layer.

### 5. CloudWatch `monitoring` VPC endpoint exists in foundation

`put_metric_data` calls go to `monitoring.amazonaws.com`. Without the `monitoring`
interface VPC endpoint (added in commit `69e059b`), all metric emission calls hang
silently in the private subnet until the container is recycled — no metrics appear in
CloudWatch and no error is logged. The foundation `terraform.tfstate` must include
`module.networking.aws_vpc_endpoint.cloudwatch_monitoring`.

---

## Container Build

**Always build for arm64/Graviton (ADR-004).**

The Strands container uses the same ECR repository as the boto3 agent
(`ai-platform-dev-hr-assistant`), differentiated by a `strands-` prefixed image tag.

```bash
cd terraform/dev/agents/hr-assistant-strands/container

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com/ai-platform-dev-hr-assistant"
GIT_SHA=$(git rev-parse --short HEAD)

# Step 1: authenticate to public ECR first (base image source)
aws ecr-public get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin public.ecr.aws

# Step 2: authenticate to private ECR (push destination)
aws ecr get-login-password --region us-east-2 | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com"

# Step 3: build for arm64 with strands- prefix on tag
docker build --platform linux/arm64 \
  -t "${ECR_URI}:strands-${GIT_SHA}" \
  .

# Step 4: push
docker push "${ECR_URI}:strands-${GIT_SHA}"
```

After pushing, set `agent_image_uri` in `terraform.tfvars` to
`${ECR_URI}:strands-${GIT_SHA}` and run `terraform apply`.

---

## Bedrock Model ID

Same rule as the `hr-assistant` layer. Claude 4.x requires the cross-region inference
profile prefix. Use `us.anthropic.claude-sonnet-4-6` everywhere — in `terraform.tfvars`,
the DynamoDB manifest item, and `agent_strands.py`. Do not use the bare model ID.

---

## Session Management — S3SessionManager

The Strands agent uses `strands.session.S3SessionManager` (not DynamoDB). There is
no `DynamoDBSessionManager` in the Strands SDK. Session history is persisted to:

```
s3://ai-platform-dev-prompt-vault-096305373014/strands-sessions/hr-assistant/session_<session_id>/session.json
```

Key behaviours:
- A new `S3SessionManager` and `Agent` are instantiated **per request** in `invoke()`.
  Object creation is lightweight — latency cost is negligible vs the Bedrock API call.
- `BedrockModel` and `@tool` functions are created once at startup (module-level).
- The boto3 `ai-platform-dev-session-memory` DynamoDB table is **not used** by this agent.
- Session history grows across invocations. A `SlidingWindowConversationManager(window_size=10)`
  caps the context window at 10 turns.

**IAM requirement (platform layer):** The `agentcore_runtime` role must have
`s3:PutObject` on `strands-sessions/*`. See Pre-Flight Check 4.

---

## CloudWatch Custom Metrics

The container emits three custom metrics to the `bedrock-agentcore` namespace after
every successful invocation:

| Metric | Unit | Description |
| --- | --- | --- |
| `InvocationLatency` | Milliseconds | Wall-clock latency of the Strands agent loop |
| `InputTokens` | Count | Input tokens from the last agent invocation cycle |
| `OutputTokens` | Count | Output tokens from the last agent invocation cycle |

**Dimensions:** `AgentId=hr-assistant-strands-dev`, `Environment=dev`

**BackgroundTasks pattern (critical):** Metric emission calls `cloudwatch.put_metric_data()`,
which is a synchronous boto3 call. Calling it directly inside an `async def` FastAPI
handler blocks the asyncio event loop. AgentCore's periodic health check arrives during
that blocked window, gets no response, and raises:
`RuntimeClientError: Runtime health check failed or timed out (max retries: 2)`

The fix — and the only correct pattern — is FastAPI `BackgroundTasks`:

```python
@app.post("/invocations")
async def invocations(request: Request, background_tasks: BackgroundTasks) -> Response:
    ...
    result = agent_strands.invoke(...)
    background_tasks.add_task(_emit_invocation_metrics, ...)   # runs AFTER response
    return JSONResponse(content={"response": result["response"]})
```

`BackgroundTasks` runs sync functions in a thread pool after the HTTP response is
sent — it does not block the event loop.

**VPC endpoint requirement:** The `monitoring` interface VPC endpoint must exist in the
foundation layer. Without it, `put_metric_data` connects to `monitoring.amazonaws.com`
(a public endpoint) with no route from the private subnet. The connection hangs until
the container is recycled — no error is logged, no metrics appear. See Pre-Flight Check 5.

**IAM condition:** The `agentcore_runtime` role policy allows `cloudwatch:PutMetricData`
with condition `cloudwatch:namespace = "bedrock-agentcore"`. All custom metrics must
use this exact namespace or the call will be denied.

---

## Structured Log Events

Every log line is JSON. Useful events for debugging:

| Event key | When emitted | Key fields |
| --- | --- | --- |
| `strands_agent_initialized` | Container startup | `model_id`, `guardrail_id`, `system_prompt_chars` |
| `container_ready` | Container startup complete | `agent_id` |
| `otel_disabled` | Startup (expected) | OTEL collector not deployed; safe to ignore |
| `glean_search` | Tool call | `query`, `result_chars` |
| `glean_search_error` | Tool failure | `query`, `error` |
| `kb_retrieve` | Tool call | `kb_id`, `passages` |
| `kb_retrieve_error` | Tool failure | `kb_id`, `error` |
| `strands_invoke` | Every invocation | `session_id`, `stop_reason`, `cycle_count`, `input_tokens`, `output_tokens`, `latency_ms`, `tool_calls` |
| `vault_write_dispatched` | After every invocation | `session_id` |
| `metric_emit_failed` | CloudWatch error | `error` — if this appears, check the `monitoring` VPC endpoint |
| `invocation_error` | Agent exception | `session_id`, `error` — most commonly S3 permission errors |

Query recent events:

```bash
RUNTIME_ID=$(terraform output -raw agentcore_endpoint_id)
LOG_GROUP="/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT"

aws logs filter-log-events \
  --region us-east-2 \
  --log-group-name "${LOG_GROUP}" \
  --start-time $(python3 -c "import time; print(int((time.time()-600)*1000))") \
  --query 'events[*].message' --output text | tr '\t' '\n'
```

---

## Known Pitfalls — Strands-Specific

These were all encountered during the Phase 1 build. Each one is non-obvious
and will re-occur if the fix is reverted.

### Pitfall 1 — S3 `PutObject` missing from platform IAM role

**Symptom:** Every invocation logs `invocation_error` with:
`AccessDenied when calling the PutObject operation: ... no identity-based policy allows the s3:PutObject action`

**Root cause:** `S3SessionManager` writes session history to the prompt vault bucket
under `strands-sessions/hr-assistant/`. The platform `agentcore_runtime` role had
no S3 write permission — it previously only needed to READ the registry and invoke
Lambda functions.

**Fix:** The `S3StrandsSessionReadWrite` IAM statement must exist in the platform
`aws_iam_role_policy.agentcore_runtime`. It grants `s3:GetObject`, `s3:PutObject`,
`s3:DeleteObject`, `s3:ListBucket` scoped to `strands-sessions/*` on the prompt vault
bucket. Verify in the platform layer, not this layer.

### Pitfall 2 — Synchronous boto3 call blocks asyncio event loop

**Symptom:** Container starts successfully, but every invocation returns:
`RuntimeClientError: Runtime health check failed or timed out (max retries: 2)`

The container logs may show `strands_invoke` completing successfully immediately
before the error — the agent ran, but the response was never delivered.

**Root cause:** A synchronous boto3 API call (e.g. `cloudwatch.put_metric_data()`)
inside an `async def` FastAPI handler blocks the asyncio event loop for ~200ms.
AgentCore's health check arrives during that window and times out.

**Fix:** Move ALL synchronous I/O that can be deferred to `FastAPI BackgroundTasks`.
Never add blocking boto3 calls before `return JSONResponse(...)` in an `async def`
handler. The vault uses `InvocationType="Event"` to be non-blocking — metrics
require `BackgroundTasks` because CloudWatch has no async invocation mode.

**How to diagnose:** If the container health check is failing but the agent is
responding, add `logger.info(json.dumps({"event": "pre_return"}))` immediately
before `return JSONResponse(...)`. If you see `strands_invoke` in logs but not
`pre_return`, a blocking call between them is the culprit.

### Pitfall 3 — CloudWatch `monitoring` endpoint missing → silent metric loss

**Symptom:** No `metric_emit_failed` log events, but CloudWatch `list-metrics` in the
`bedrock-agentcore` namespace returns 0 results even after multiple successful invocations.

**Root cause:** `cloudwatch.put_metric_data()` resolves `monitoring.amazonaws.com`.
In a private subnet with no NAT gateway, there is no route to this public endpoint.
The TCP connection hangs until the default boto3 socket timeout fires (60s by default),
but if the container is recycled before the timeout, the exception is never caught and
`metric_emit_failed` is never logged. The call silently disappears.

**Fix:** Add `aws_vpc_endpoint.cloudwatch_monitoring` (`com.amazonaws.us-east-2.monitoring`)
as an Interface endpoint in the networking module. Once active, `put_metric_data` routes
through the VPC endpoint and succeeds.

**How to verify the endpoint is missing:** Run:
```bash
aws ec2 describe-vpc-endpoints \
  --region us-east-2 \
  --filters "Name=service-name,Values=com.amazonaws.us-east-2.monitoring" \
  --query 'VpcEndpoints[*].State' --output text
```
Expected: `available`. If no output, the endpoint is missing — apply the foundation layer.

### Pitfall 4 — `agent_runtime_name` rejects hyphens

**Symptom:** `terraform apply` fails with a provider validation error on the
`aws_bedrockagentcore_agent_runtime` resource.

**Root cause:** The AgentCore provider rejects hyphens in `agent_runtime_name`.

**Fix:** Use `replace("-", "_")` on the name string:
```hcl
agent_runtime_name = replace("${var.project_name}-${var.environment}-hr-assistant-strands", "-", "_")
```

### Pitfall 5 — AgentCore pre-creates the CloudWatch log group

**Symptom:** `terraform apply` fails with `ResourceAlreadyExistsException` on
`aws_cloudwatch_log_group.strands_runtime`.

**Root cause:** AgentCore creates the log group automatically when the runtime is
provisioned. If Terraform also tries to create it, the apply fails.

**Fix:** Import the existing log group before applying:
```bash
RUNTIME_ID=$(terraform output -raw agentcore_endpoint_id)
terraform import \
  aws_cloudwatch_log_group.strands_runtime \
  "/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT"
```
Then re-apply — Terraform will adopt the existing group and apply retention/KMS config.

### Pitfall 6 — `stop_reason: guardrail_intervened` on annual-leave query

**Symptom:** Smoke test 8a passes (response contains "25"), but `strands_invoke` logs
show `stop_reason: guardrail_intervened`. Confusing: the guardrail intervened but the
test passed.

**Root cause:** The guardrail applies PII anonymization to the system prompt template
(it contains placeholder text like `{ADDRESS}` which may trigger the ADDRESS PII type).
The guardrail fires on content modification, not a block — the response still flows
through. `guardrail_intervened` does not mean the response was blocked.

**This is expected behaviour.** It only indicates an actual topic block when
`topicPolicyResult` is non-empty (e.g. `Legal Advice`). The `guardrail_result.action`
field in vault records distinguishes modification from blocking.

---

## Terraform State

State key: `dev/agents/hr-assistant-strands/terraform.tfstate`

This layer reads platform state (never writes to it):
```hcl
data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "ai-platform-terraform-state-dev-096305373014"
    key    = "dev/platform/terraform.tfstate"
    region = "us-east-2"
  }
}
```

**Log group import:** The `aws_cloudwatch_log_group.strands_runtime` resource may
need to be imported after the first runtime apply. See Pitfall 5 above.

---

## Teardown Notes

```bash
terraform destroy -auto-approve
```

After destroy, the following require manual cleanup:

**DynamoDB agent registry item** — the `terraform_data + local-exec` provisioner
has no `when = destroy` handler. The `hr-assistant-strands-dev` item persists:
```bash
aws dynamodb delete-item \
  --region us-east-2 \
  --table-name ai-platform-dev-agent-registry \
  --key '{"agent_id": {"S": "hr-assistant-strands-dev"}}'
```

**S3 session and prompt vault objects** — written to the prompt vault bucket under:
- `strands-sessions/hr-assistant/` (session history)
- `prompt-vault/hr-assistant/` (Prompt Vault records)

These must be purged before destroying the platform layer.

---

## Files in This Layer

```
container/          arm64 FastAPI container — Strands SDK implementation
  app/
    agent_strands.py  Strands agentic loop (S3SessionManager, @tool functions)
    main.py           FastAPI entry point (startup, /invocations, BackgroundTasks)
    vault.py          Prompt Vault write path — identical to hr-assistant
  Dockerfile          Copied from hr-assistant — no changes needed
  requirements.txt    Pins strands-agents[otel]==1.35.0 + fastapi + uvicorn + boto3
backend.tf          Remote state backend
main.tf             AgentCore runtime, log group, DynamoDB registry entry
variables.tf        Input variables
outputs.tf          agentcore_endpoint_id (used by smoke-test.sh)
terraform.tfvars    git-ignored — copy from .example and populate
smoke-test.sh       6 integration tests (8a–8f) — run after every apply
```
