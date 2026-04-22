# Orchestrator Agent Layer — `terraform/dev/agents/orchestrator/`

Front-door supervisor agent that routes employee requests to the appropriate
sub-agent runtime. Reads the DynamoDB agent registry on every invocation,
injects the live sub-agent list into the Strands system prompt, and dispatches
via `bedrock-agentcore:InvokeAgentRuntime`. Authoritative plan:
`specs/orchestrator-plan.md`.

---

## Purpose

The orchestrator is the only agent a user-facing caller invokes directly. It:

- Generates a per-request `trace_id` / `request_id` and propagates them to the
  sub-agent in the dispatch payload (OTEL-compatible widths; correlated logs).
- Applies Amazon Comprehend PII redaction on **both** the inbound prompt and
  the outbound response, layered on top of a Bedrock guardrail.
- Runs a Strands agent loop whose only tool is `dispatch_agent`. The LLM
  picks one domain from the registry-derived vocabulary, calls the tool once,
  and returns the sub-agent's response with minimal rewording — or refuses if
  no domain matches.
- Writes a hash-only audit record (request + response) to a dedicated audit
  log group. Prompts and responses themselves are stored only in each
  sub-agent's Prompt Vault.
- Emits CloudWatch metrics to the `bedrock-agentcore` namespace with base
  dimensions `AgentId=orchestrator-dev`, `Environment=dev`, plus per-dispatch
  `DispatchedAgent` breakouts.

In dev, the only `enabled=true` sub-agent in the registry is
`hr-assistant-strands-dev`. The boto3 `hr-assistant-dev` entry is present
with `enabled=false` (regression baseline, excluded from routing).

---

## Resources

| Resource | Name | Purpose |
| --- | --- | --- |
| `aws_iam_role.orchestrator_runtime` | `ai-platform-dev-orchestrator-runtime` | Execution role. Distinct from the platform `agentcore_runtime` role — only this role has `bedrock-agentcore:InvokeAgentRuntime`. |
| `aws_bedrock_guardrail.orchestrator` | `ai-platform-dev-orchestrator-guardrail` | Front-door guardrail (version pinned to `DRAFT` in dev). Blocks before dispatch. |
| `aws_ecr_repository.orchestrator` | `ai-platform-dev-orchestrator` | Separate from the `ai-platform-dev-hr-assistant` repo used by the HR agents. |
| `aws_cloudwatch_log_group.orchestrator_audit` | `/ai-platform/orchestrator/audit-dev` | Hash-only audit records, 90-day retention, KMS encrypted. |
| `aws_bedrockagentcore_agent_runtime.orchestrator` | `ai_platform_dev_orchestrator` | Runtime endpoint. **Count-gated** on `var.agent_image_uri` — created only once an image exists. |
| `aws_cloudwatch_log_group.orchestrator_runtime` | `/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT` | Container stdout + runtime-logs. Import on first apply (AgentCore pre-creates it). |
| `terraform_data.orchestrator_manifest` | — | Registers `orchestrator-dev` in the agent registry with `domains=["_orchestrator"]` as a self-marker. |

### Consumed from other layers

| Value | Source | Used for |
| --- | --- | --- |
| Private subnets + SG | `data.terraform_remote_state.platform` | Runtime VPC wiring |
| Agent registry table | `data.terraform_remote_state.platform` | DynamoDB scan in `registry.py` |
| Prompt vault bucket | `data.terraform_remote_state.platform` | `strands-sessions/orchestrator/` prefix |
| KMS key ARN | `data.terraform_remote_state.foundation` | Audit log group encryption |

No variables from the HR agent layers are needed — the orchestrator discovers
sub-agents entirely through the registry at runtime.

---

## Container

**Location:** `container/`

**Image tag convention:** `orchestrator-<git-sha>` (e.g. `orchestrator-a4c1378-prod2`),
per ADR-009. Distinct from the `strands-` prefix used by the HR agents so the
two images can never be mistakenly pushed to each other's repositories.

**Runtime dependencies (`requirements.txt`):**

| Package | Version |
| --- | --- |
| `fastapi` | `0.115.6` |
| `uvicorn[standard]` | `0.32.1` |
| `boto3` | `1.42.0` |
| `strands-agents[otel]` | `1.35.0` |

**Source layout (`container/app/`):**

| File | Responsibility |
| --- | --- |
| `main.py` | FastAPI `/invocations` handler — `asyncio.to_thread` for blocking calls, `BackgroundTasks` for fire-and-forget |
| `orchestrator.py` | Strands `Agent` + `BedrockModel` + supervisor system prompt (registry-injected) |
| `dispatch.py` | `dispatch_agent` `@tool` — single-dispatch enforcement, cross-runtime invoke, trace propagation |
| `registry.py` | DynamoDB scan + 60s TTL cache + LLM-facing summary + domain lookup |
| `middleware.py` | Comprehend `DetectPiiEntities` + placeholder redaction |
| `metrics.py` | CloudWatch `PutMetricData` — 11 metrics to `bedrock-agentcore` namespace |
| `tracing.py` | Per-request `trace_id`/`span_id` + propagation helpers |
| `audit.py` | Hash-only audit log writer (CloudWatch Logs `PutLogEvents`) |
| `config.py` | Environment-variable contract (region, registry table, bucket, model, guardrail) |

**Build and push:**

```bash
cd terraform/dev/agents/orchestrator/container

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com/ai-platform-dev-orchestrator"
GIT_SHA=$(git rev-parse --short HEAD)

aws ecr-public get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin public.ecr.aws
aws ecr get-login-password --region us-east-2 | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com"

docker build --platform linux/arm64 -t "${ECR_URI}:orchestrator-${GIT_SHA}" .
docker push "${ECR_URI}:orchestrator-${GIT_SHA}"
```

Then set `agent_image_uri = "${ECR_URI}:orchestrator-${GIT_SHA}"` in
`terraform.tfvars` and run `terraform apply`.

---

## Two-Step Apply Model

The runtime and registry entry are **count-gated** on `var.agent_image_uri`
so the layer can be scaffolded before a container image exists:

**Apply 1** — leave `agent_image_uri = ""`. Creates IAM role, guardrail, ECR
repo, audit log group only. No runtime, no registry entry.

**Apply 2** — set `agent_image_uri` to the pushed ECR URI. Runtime + registry
entry land on this apply.

Do not set `agent_image_uri` before the image is in ECR. The runtime resource
will fail to create and Terraform will leave partial state.

---

## Prerequisites

1. Foundation layer applied — including these VPC interface endpoints:
   `ecr.api`, `ecr.dkr`, `bedrock-agent`, `bedrock-agent-runtime`,
   **`bedrock-agentcore`**, `bedrock-runtime`, `monitoring`, `logs`, `lambda`,
   **`comprehend`**, plus S3 + DynamoDB gateway endpoints. Missing
   `bedrock-agentcore` or `comprehend` is silent and fatal — see Known
   Issues below.
2. Platform layer applied — provides the registry table, prompt vault bucket,
   and shared subnets / security group.
3. `hr-assistant` and `hr-assistant-strands` layers applied — both register
   into the agent registry. `hr-assistant-strands-dev` must have
   `enabled=true` and `domains=["hr.policy","hr.escalation"]` or the router
   will refuse every HR request as `no_agent_for_domain`.
4. Orchestrator container image pushed to ECR (Apply 2 only).
5. `terraform.tfvars` populated — the orchestrator needs only
   `account_id` and (for Apply 2) `agent_image_uri`.

Verify prerequisite 3:

```bash
aws dynamodb scan \
  --region us-east-2 \
  --table-name ai-platform-dev-agent-registry \
  --filter-expression "enabled = :t" \
  --expression-attribute-values '{":t":{"BOOL":true}}' \
  --query 'Items[*].{agent_id:agent_id.S,domains:domains.SS}'
```

---

## First-Time Setup

```bash
cd terraform/dev/agents/orchestrator

terraform init

cp terraform.tfvars.example terraform.tfvars
# Leave agent_image_uri = "" for Apply 1

terraform plan -out=tfplan
terraform apply tfplan
# Apply 1 — no runtime yet

# Build and push the container (see Container section)

# Edit terraform.tfvars: set agent_image_uri to the pushed URI
terraform plan -out=tfplan
terraform apply tfplan
# Apply 2 — runtime + registry entry land
# If ResourceAlreadyExistsException on log group, see Known Issues
```

---

## Live Invocation

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
RUNTIME_ARN=$(terraform output -raw agentcore_runtime_arn)
SESSION_ID="orchestrator-$(uuidgen | tr '[:upper:]' '[:lower:]')"

PAYLOAD=$(python3 -c "
import json, base64
print(base64.b64encode(json.dumps({
    'prompt': 'How many days of annual leave am I entitled to?',
    'sessionId': '${SESSION_ID}',
    'user_role': 'employee'
}).encode()).decode())
")

aws bedrock-agentcore invoke-agent-runtime \
  --region us-east-2 \
  --agent-runtime-arn "${RUNTIME_ARN}" \
  --runtime-session-id "${SESSION_ID}" \
  --payload "${PAYLOAD}" \
  /tmp/response.json

python3 <<'PY'
import json
body = json.load(open('/tmp/response.json'))
print("dispatched_agent :", body.get('dispatched_agent'))
print("trace_id         :", body.get('trace_id'))
print("request_id       :", body.get('request_id'))
print()
print(body.get('response'))
PY
```

Expected shape on success:

```json
{
  "response": "...sub-agent's answer, minimally rewrapped...",
  "dispatched_agent": "hr-assistant-strands-dev",
  "request_id": "7a8b...",
  "trace_id": "238aa6619bc8db0a6faadc51490f891a"
}
```

On an out-of-scope request (e.g. "What's the weather?"), `dispatched_agent`
is `null` and `response` is a short polite refusal.

> **`sessionId` must be in the payload body.** `--runtime-session-id` is used
> by the AgentCore control plane for routing but is NOT forwarded to the
> container.

---

## Observability

### CloudWatch Custom Metrics — `bedrock-agentcore` namespace

Emitted via `cloudwatch:PutMetricData` after every invocation. Full catalogue
in `specs/observability-metric-catalogue.md`; dashboard in
`specs/dashboards/orchestrator.json`.

| Metric | Dimensions |
| --- | --- |
| `OrchestratorInvocationLatency` | `AgentId`, `Environment` |
| `OrchestratorInputTokens` | `AgentId`, `Environment` |
| `OrchestratorOutputTokens` | `AgentId`, `Environment` |
| `PiiDetectedInbound` | `AgentId`, `Environment` |
| `PiiDetectedOutbound` | `AgentId`, `Environment` |
| `DispatchLatency` | `AgentId`, `DispatchedAgent`, `Environment` |
| `DispatchCount` | `AgentId`, `DispatchedAgent`, `Environment` |
| `DispatchSuccess` | `AgentId`, `DispatchedAgent`, `Environment` |
| `DispatchFailure` | `AgentId`, `DispatchedAgent`, `Environment` (+ `ErrorClass`) |
| `RoutingFailureUnknownDomain` | `AgentId`, `Environment` |
| `RoutingFailureAgentDisabled` | `AgentId`, `Environment` |

### Structured log events (runtime log group)

`/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT`

| Event key | When | Useful fields |
| --- | --- | --- |
| `container_ready` | Startup | `agent_id` |
| `supervisor_initialized` | Startup | `model_id`, `guardrail_id` |
| `supervisor_invoke` | Every invocation | `session_id`, `stop_reason`, `cycle_count`, `input_tokens`, `output_tokens`, `latency_ms`, `dispatched_agent`, `trace_id` |
| `dispatch_succeeded` | On successful dispatch | `agent_id`, `domain`, `latency_ms`, `response_chars`, `trace_id` |
| `dispatch_rejected` | Second dispatch in same turn | `reason=single_dispatch_only` |
| `dispatch_unknown_domain` | LLM chose a non-registry domain | `domain` |
| `dispatch_invoke_failed` | Sub-agent runtime error | `agent_id`, `error` |
| `dispatch_missing_runtime_arn` | Registry entry is missing `runtime_arn` | `agent_id`, `domain` |
| `registry_stale` | Registry scan failed, cache reused | `error`, `cached_count` |
| `pii_scan_failed` | Comprehend error (non-fatal) | `error` |
| `metric_emit_failed` | CloudWatch error | `error` — check `monitoring` VPC endpoint |
| `audit_write_failed` | Audit log write error | `error` |
| `invocation_error` | Unhandled exception in `/invocations` | `session_id`, `error` |

### Audit log group

`/ai-platform/orchestrator/audit-dev` — hash-only `orchestrator_request` and
`orchestrator_response` records. 90-day retention. Join a request + response
pair by `request_id`. Correlate across sub-agent logs by `trace_id`.

### Distributed trace correlation

The same `trace_id` appears in:

- Orchestrator's response body (`trace_id` field).
- Every orchestrator log event (`supervisor_invoke`, `dispatch_succeeded`,
  etc.) via `tracing.log_fields()`.
- The sub-agent's `strands_invoke` log event (propagated through the
  dispatch payload's `trace_context` field).
- Both audit records (`orchestrator_request`, `orchestrator_response`).

---

## Iterative Cycle

```bash
cd terraform/dev/agents/orchestrator

# Rebuild container (if code changed)
cd container && \
  docker build --platform linux/arm64 -t "${ECR_URI}:orchestrator-${GIT_SHA}" . && \
  docker push "${ECR_URI}:orchestrator-${GIT_SHA}" && cd ..

# Update agent_image_uri in terraform.tfvars
terraform plan -out=tfplan
terraform apply tfplan

# Invoke — see Live Invocation
```

AgentCore caches the container image; changing `agent_image_uri` is the
correct way to force a new container. Do not `terraform taint` the runtime
unless you are also willing to wait 2–3 minutes for provisioning.

---

## Known Issues

These were all discovered during Phase O.3 bring-up. Every one is silent and
non-obvious. Full diagnostic detail in `CLAUDE.md` Pitfalls O-5, O-6, O-7.

### Health check timeout on dispatch only — missing `bedrock-agentcore` VPC endpoint

**Symptom:** Refusals and no-dispatch paths succeed in a few seconds.
HR-policy requests time out after ~2 minutes with
`RuntimeClientError: Runtime health check failed or timed out`. Container
logs show `dispatch_agent` starting but never completing.

**Cause:** The nested `bedrock-agentcore:InvokeAgentRuntime` call to the
sub-agent has no route from the private subnet — boto3 resolves a public IP
and hangs.

**Fix:** Add `com.amazonaws.us-east-2.bedrock-agentcore` as an interface VPC
endpoint in the foundation `networking` module. Apply foundation. No
container restart needed — private-DNS routing picks it up.

### Health check timeout on every request — missing `comprehend` VPC endpoint

**Symptom:** Every request times out (including refusals). Latency goes
from ~5s to 120s. No `pii_scan_failed` log event.

**Cause:** `middleware.scan_and_redact` calls Comprehend twice per request.
Each call hangs for the full boto3 socket timeout (~60s) without a VPC
endpoint. Two hangs in series exceed the AgentCore health check budget.

**Fix:** Add `com.amazonaws.us-east-2.comprehend` as an interface VPC
endpoint. Apply foundation.

### `dispatched_agent` is `null` despite successful dispatch

**Symptom:** Logs show `dispatch_succeeded` with the sub-agent's response.
The response returned to the caller has `dispatched_agent: null`.

**Cause:** Strands runs `@tool` functions on a worker thread, so
`threading.local` state written inside the tool is invisible to the caller
thread after `agent(...)` returns.

**Fix:** Use module-level state protected by a lock, with
`begin_turn(session_id)` / `end_turn(session_id)` bracketing every
`agent(...)` call. Inside the tool, prefer `_active_session_id` (the
orchestrator's real session) over the LLM-supplied `session_id` parameter,
which can be fabricated. See `CLAUDE.md` Pitfall O-6 for the full pattern.

### Runtime health check timeout while logs show the agent completing successfully

**Symptom:** Container logs show `supervisor_invoke` completing normally,
but the caller receives `RuntimeClientError: Runtime health check failed
or timed out`.

**Cause:** A synchronous boto3 call is running between `supervisor_invoke`
and `return JSONResponse(...)`, blocking the asyncio event loop long enough
for AgentCore's health check to time out.

**Fix:** Wrap every blocking boto3 call in `asyncio.to_thread(...)` (if the
result is needed before the response) or `BackgroundTasks.add_task(...)`
(if fire-and-forget after the response). Never add a direct sync boto3
call inside an `async def` handler before a `return`. See Pitfall O-5.

### Log group `ResourceAlreadyExistsException` on first apply

AgentCore pre-creates the log group when the runtime is provisioned. Import
it before re-applying:

```bash
RUNTIME_ID=$(terraform output -raw agentcore_endpoint_id)
terraform import \
  'aws_cloudwatch_log_group.orchestrator_runtime[0]' \
  "/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT"
terraform apply
```

### `dispatched_agent: null` on every HR request — registry out of date

**Symptom:** Logs show `dispatch_unknown_domain` with a plausible domain
like `hr.policy`. Metric `RoutingFailureUnknownDomain` increments.

**Cause:** The sub-agent's registry entry is missing `domains` or has
`enabled=false`.

**Fix:** Verify the registry scan (see Prerequisites). Re-apply the
sub-agent layer to re-register. The orchestrator's 60s cache means the
change takes up to 60 seconds to be visible.

### Agent manifest item not removed on destroy

`terraform destroy` does not delete the `orchestrator-dev` item from the
agent registry. Delete manually:

```bash
aws dynamodb delete-item \
  --region us-east-2 \
  --table-name ai-platform-dev-agent-registry \
  --key '{"agent_id": {"S": "orchestrator-dev"}}'
```

### S3 orchestrator session objects persist after destroy

Session history is written to `strands-sessions/orchestrator/` on the
platform-owned prompt vault bucket. These must be purged before destroying
the platform layer. Use the purge script in `terraform/dev/platform/README.md`.

### ECR repository destroy fails — repo not empty

`ai-platform-dev-orchestrator` must be empty before
`terraform destroy` succeeds:

```bash
aws ecr batch-delete-image \
  --region us-east-2 \
  --repository-name ai-platform-dev-orchestrator \
  --image-ids "$(aws ecr list-images \
    --region us-east-2 \
    --repository-name ai-platform-dev-orchestrator \
    --query 'imageIds[*]' --output json)"
```

---

## Teardown

```bash
cd terraform/dev/agents/orchestrator
terraform destroy -auto-approve

# Clean up the registry item
aws dynamodb delete-item \
  --region us-east-2 \
  --table-name ai-platform-dev-agent-registry \
  --key '{"agent_id": {"S": "orchestrator-dev"}}'

# ECR cleanup if needed (see Known Issues)
```

The orchestrator layer must be destroyed before the platform layer. The
platform layer owns the registry table and the prompt vault bucket — once
those are gone the orchestrator manifest provisioner and `S3SessionManager`
will both fail.
