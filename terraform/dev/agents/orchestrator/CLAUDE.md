# CLAUDE.md — Orchestrator Agent Layer

**Scope:** `terraform/dev/agents/orchestrator/` only.
This is level 3 of the three-level CLAUDE.md hierarchy (ADR-021).
Read the project-root CLAUDE.md, `terraform/dev/agents/hr-assistant/CLAUDE.md`, and
`terraform/dev/agents/hr-assistant-strands/CLAUDE.md` before reading this file —
patterns documented there are not repeated here.

Authoritative plan: `specs/orchestrator-plan.md` at the repository root.

**Status (2026-04):** Phases O.1–O.3 complete. The runtime routes employee HR
questions to `hr-assistant-strands-dev` end-to-end with distributed trace
propagation, Comprehend-based PII redaction on both legs, and hash-only audit
records. Phase O.4 (registry validation rule) and multi-sub-agent dispatch are
deferred.

---

## What This Layer Owns

- `aws_ecr_repository.orchestrator` — `ai-platform-dev-orchestrator` image repo
- `aws_iam_role.orchestrator_runtime` + inline policy — distinct from the platform
  `agentcore_runtime` role. Orchestrator has cross-runtime invoke permission and
  no KB/Prompt-Vault/tool-Lambda permissions.
- `aws_bedrock_guardrail.orchestrator` — front-door guardrail with `DRAFT` version
- `aws_cloudwatch_log_group.orchestrator_audit` (`/ai-platform/orchestrator/audit-dev`) —
  audit records (hashes only, 90-day retention)
- `aws_bedrockagentcore_agent_runtime.orchestrator` — count-gated on `agent_image_uri`
- `aws_cloudwatch_log_group.orchestrator_runtime` — count-gated; imported on first apply
- `terraform_data.orchestrator_manifest` — registry entry for `orchestrator-dev`

It does NOT own: VPC, KMS, subnets, security groups, session memory table, agent registry
table, prompt vault bucket, or the sub-agent runtimes. Those live in foundation,
platform, or the individual agent layers.

---

## Two-Step Apply Model

The AgentCore runtime requires a container image URI. On initial scaffold apply
there is no orchestrator image in ECR, so the runtime and registry entry are
**count-gated** on `var.agent_image_uri`. The typical sequence is:

### Apply 1 (Phase O.2) — scaffold without runtime

Leave `agent_image_uri = ""` in `terraform.tfvars`. Apply creates: IAM role +
policy, guardrail, ECR repo, audit log group. It does NOT create the AgentCore
runtime or the registry entry.

```bash
cd terraform/dev/agents/orchestrator
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### Apply 2 (Phase O.3) — push container and enable runtime

Build the orchestrator container (see Container Build below), push to ECR,
update `agent_image_uri` in `terraform.tfvars`, and re-apply. The runtime +
registry entry land on this apply.

```bash
# After container push
# Edit terraform.tfvars:
#   agent_image_uri = "096305373014.dkr.ecr.us-east-2.amazonaws.com/ai-platform-dev-orchestrator:orchestrator-<sha>"

terraform plan -out=tfplan
terraform apply tfplan
```

Phase O.3 is the only path that creates the runtime. Do not set
`agent_image_uri` before the image is in ECR — the runtime resource will
fail to create and Terraform will leave partial state.

---

## Pre-Flight Checklist

### 1. Foundation + Platform + both HR agent layers applied

The orchestrator reads platform outputs (registry table, session memory table,
prompt vault bucket, subnets, security group) and expects the `hr-assistant` and
`hr-assistant-strands` layers to be applied so the registry scan returns at
least one routable sub-agent with `enabled=true`.

### 2. Registry contains sub-agent entries with Phase O.1 schema

Before Apply 2, verify the registry has `enabled=true` entries with
`domains` populated:

```bash
aws dynamodb scan \
  --region us-east-2 \
  --table-name ai-platform-dev-agent-registry \
  --filter-expression "enabled = :t" \
  --expression-attribute-values '{":t":{"BOOL":true}}' \
  --query 'Items[*].{agent_id:agent_id.S,domains:domains.SS}'
```

Expected (per Option A in `specs/orchestrator-plan.md`): exactly one entry
(`hr-assistant-strands-dev`). The boto3 `hr-assistant-dev` entry has
`enabled=false` and is excluded from routing.

### 3. Orchestrator container image pushed to ECR (Apply 2 only)

See Container Build below. Skip for Apply 1.

---

## IAM Design Notes

The orchestrator has its own execution role — it does **not** reuse the platform
`agentcore_runtime` role. Rationale:

- **Cross-runtime invoke.** `bedrock-agentcore:InvokeAgentRuntime` is orchestrator-only.
  Granting it to the shared role would allow any sub-agent to invoke any other.
- **No KB / tool Lambda access.** Orchestrator never retrieves from Bedrock KB and
  never calls tool Lambdas directly — dispatching is its only outbound path.
- **Different session footprint.** Orchestrator uses `strands-sessions/orchestrator/*`
  on the prompt vault bucket; sub-agents use `strands-sessions/hr-assistant/*`.
  Separate roles enforce that separation at the IAM boundary.

`bedrock-agentcore:InvokeAgentRuntime` is scoped by **prefix** to
`runtime/*` in this account and region. This was an intentional design decision
(plan decision D7) — it covers current and future sub-agents with no policy edit
per agent. The registry `enabled=true` filter is the actual routing gate.

---

## Guardrail

The orchestrator has its own guardrail (`ai-platform-dev-orchestrator-guardrail`)
separate from sub-agents. It applies at the front door **before** dispatch, so a
denied topic never reaches a sub-agent. Sub-agents retain their own guardrails
as defense in depth.

Version pinned to `DRAFT` in dev. For staging/prod the orchestrator should pin to
a numbered version — changing guardrail policy without bumping the version is a
policy drift vector.

---

## Container Build (Phase O.3)

**Always build for arm64/Graviton (ADR-004).**

```bash
cd terraform/dev/agents/orchestrator/container

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com/ai-platform-dev-orchestrator"
GIT_SHA=$(git rev-parse --short HEAD)

# Step 1: authenticate to public ECR first (base image source)
aws ecr-public get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin public.ecr.aws

# Step 2: authenticate to private ECR (push destination)
aws ecr get-login-password --region us-east-2 | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com"

# Step 3: build for arm64 with orchestrator- prefix
docker build --platform linux/arm64 \
  -t "${ECR_URI}:orchestrator-${GIT_SHA}" \
  .

# Step 4: push
docker push "${ECR_URI}:orchestrator-${GIT_SHA}"
```

After pushing, set `agent_image_uri` in `terraform.tfvars` to
`${ECR_URI}:orchestrator-${GIT_SHA}` and run `terraform apply`.

---

## Implementation Overview

The container is FastAPI on uvicorn, arm64, with a single Strands agent loop
whose only tool is `dispatch_agent`. The LLM never answers from its own
knowledge — it picks a domain from the registry-derived vocabulary and calls
the tool, or politely refuses. The sub-agent's response is returned with at
most a one-sentence contextualizing wrapper.

### Request lifecycle (`container/app/main.py`)

The `/invocations` handler is `async def`. All blocking boto3 work — the two
Comprehend scans, the Strands agent call, audit writes, and metric emission —
runs off the event loop via `asyncio.to_thread` or FastAPI `BackgroundTasks`.
This is not cosmetic: a synchronous boto3 call inside the handler blocks the
asyncio loop long enough for AgentCore's health check to time out with
`RuntimeClientError: Runtime health check failed or timed out`. See Pitfall O-5.

Per request:

1. `tracing.new_trace_context()` — fresh `trace_id` / `span_id` per turn
2. `middleware.scan_and_redact(user_message)` (off-loop) — inbound PII
3. `audit.record_request(...)` (background) — hash-only audit trail
4. `orchestrator.invoke(session_id, redacted)` (off-loop) — Strands loop
5. `middleware.scan_and_redact(result.response)` (off-loop) — outbound PII
6. `audit.record_response(...)` + `metrics.emit_orchestrator_metrics(...)`
   (background) — fire-and-forget after the response is sent
7. Return `{response, dispatched_agent, request_id, trace_id}`

### Registry-driven routing (`container/app/registry.py`)

`registry.summary()` and `registry.all_domains()` are evaluated **on every
invocation** and injected into the Strands system prompt. The LLM sees the
up-to-date sub-agent list (minus the orchestrator's own entry) with their
domains and descriptions. Registry scans are cached in-process for
`REGISTRY_CACHE_TTL_SECONDS` (60s); adding, removing, or disabling an agent
takes effect on the next orchestrator invocation after the cache expires
with zero redeploy.

The scan filter is `enabled = true AND agent_id != orchestrator-dev`. The
self-exclusion keeps the router from recommending itself.

### Dispatch discipline (`container/app/dispatch.py`)

Single-dispatch-per-turn is enforced in the tool itself. The first call
increments a module-level counter; any subsequent call in the same turn
returns `{"error": "single_dispatch_only", ...}` without invoking anything.
Parallel fan-out is deferred.

`dispatch_agent` builds the sub-agent session as `f"{orchestrator_session}-{agent_id}"`
so each sub-agent keeps a stable session history keyed to the orchestrator's
session. The orchestrator's real `session_id` comes from module-level state
populated by `begin_turn(session_id)` — NOT from the tool's `session_id`
parameter, which the LLM can fabricate. See Pitfall O-6.

Trace context (`tracing.current_trace_context()`) is injected into the
payload body as `trace_context`. `hr-assistant-strands`' `/invocations`
handler reads `payload['trace_context']` and includes `trace_id` +
`parent_span_id` in its `strands_invoke` log event, giving correlated logs
across runtime hops without OTEL HTTP-header propagation.

### PII redaction (`container/app/middleware.py`)

Amazon Comprehend `DetectPiiEntities` on both legs. Detected entities are
replaced in-place with `{TYPE}` placeholders (e.g. `{EMAIL}`, `{DATE_TIME}`).
Failures log `pii_scan_failed` and pass the text through unchanged —
Comprehend is defense in depth on top of the guardrail, not the primary
control. Both Comprehend calls require the `comprehend` VPC endpoint (see
Pitfall O-7).

### Audit trail (`container/app/audit.py`)

Hashes only. Prompts and responses are SHA-256'd before being written to
`/ai-platform/orchestrator/audit-dev` (90-day retention). The Prompt Vault
remains the authoritative content store for the sub-agent side; the audit
log answers "who called what when," not "what did they say." Each record
includes `request_id`, `session_id`, `trace_id`, `user_role`, PII-type
lists, dispatched agent, and duration.

### Model and guardrail

`BedrockModel` is created once at startup with `guardrail_trace="enabled"`.
A new `Agent` and `S3SessionManager` are created per request — the Agent
is lightweight, and per-request instantiation lets `session_id` bind
correctly without thread-local trickery.

Container source files:

```
container/app/
  main.py          FastAPI entry — handler orchestration + off-loop dispatch
  orchestrator.py  Strands Agent + BedrockModel + supervisor system prompt
  dispatch.py      dispatch_agent @tool — single-dispatch enforcement + cross-runtime invoke
  registry.py      DynamoDB scan + TTL cache + LLM-facing summary
  middleware.py    Comprehend DetectPiiEntities + placeholder redaction
  metrics.py       CloudWatch PutMetricData — orchestrator + per-dispatch dimensions
  tracing.py       Per-request trace_id/span_id generation + propagation
  audit.py         Hash-only audit log writer (CloudWatch Logs)
  config.py        Environment-variable contract
```

---

## Session Management — S3SessionManager

The orchestrator uses `strands.session.S3SessionManager` with prefix
`strands-sessions/orchestrator/` on the prompt vault bucket. DynamoDB session
memory is also in scope (plan D1) — the registry scan cache and request
correlation records live there. The two are **not duplicates**: S3 stores
conversational history for LLM context, DynamoDB stores request metadata for
orchestrator-internal bookkeeping.

---

## Known Pitfalls — Orchestrator-Specific

Pitfalls 1–6 from `hr-assistant-strands/CLAUDE.md` all apply — S3 PutObject
from the platform role, BackgroundTasks for blocking boto3 calls, CloudWatch
`monitoring` VPC endpoint, `agent_runtime_name` underscore rule, log group
pre-creation, guardrail PII anonymization. Read that file first.

Orchestrator-specific additions:

### Pitfall O-1 — `_orchestrator` domain must never be claimed by a sub-agent

The orchestrator's registry entry uses `domains = ["_orchestrator"]` as a
self-marker. If a sub-agent (current or future) adds `_orchestrator` to its
`domains` set, `dispatch_agent` will attempt to route to itself → infinite loop.

**How to enforce:** a registry validation rule (plan Phase O.4) asserts that no
two `enabled` entries overlap on any domain. That rule must also reject any
sub-agent entry that includes `_orchestrator`.

### Pitfall O-2 — Runtime ARN format in registry

The registry stores `runtime_arn` (full ARN) for cross-runtime invoke, not
`endpoint_id`. Use the `runtime_arn` field in `dispatch.py`. Use `endpoint_id`
only for human-readable logging.

The correct ARN format is:

```
arn:aws:bedrock-agentcore:REGION:ACCOUNT:runtime/<runtime-id>
```

NOT `agent-runtime` — that path returns `ResourceNotFoundException`.

### Pitfall O-3 — Registry cache staleness masks enable flips

The orchestrator's 60-second in-memory registry cache means flipping a
sub-agent's `enabled` flag in DynamoDB takes up to 60 seconds to be respected.
For operator actions that must take effect immediately (e.g. disabling a
misbehaving agent), also deny the runtime at IAM by removing the runtime ARN
from the assume-role trust or tagging it — then the orchestrator's next call
fails closed.

### Pitfall O-4 — Orchestrator endpoint is still private

The orchestrator runs on the same VPC private subnets as the sub-agents. It
has no public endpoint in dev. Invocations are via `bedrock-agentcore
invoke-agent-runtime` against the returned runtime ARN — same pattern as
`hr-assistant-strands`. Plan session IDs and payload base64 identically.

### Pitfall O-5 — Every blocking boto3 call must leave the event loop

**Symptom:** The handler's non-trivial boto3 calls (Comprehend,
`bedrock-agentcore:InvokeAgentRuntime`, `cloudwatch:PutMetricData`,
`logs:PutLogEvents`) are all synchronous. Calling any of them directly
inside the `async def /invocations` handler blocks the asyncio loop for
hundreds of milliseconds to several seconds. AgentCore's periodic health
check (retries × 2 ≈ 2 minutes) times out and the client receives
`RuntimeClientError: Runtime health check failed or timed out` even though
the agent is responding correctly in logs.

**The symptom is especially confusing because the handler eventually
completes successfully** — the response never reaches the caller because the
health check killed the session first. Adding a single `logger.info(...)`
immediately before `return JSONResponse(...)` is the fastest way to prove
the blocking call is the culprit: if `strands_invoke` appears but the
pre-return log line does not, a sync call between them is eating the loop.

**Fix — two patterns, choose by whether the result is on the critical path:**

- Needed before the response → `asyncio.to_thread(fn, ...)`
  (Comprehend scans, the Strands agent call itself, anything whose result
  is part of the returned body)

- Fire-and-forget after the response → FastAPI `BackgroundTasks`
  (audit record writes, `cloudwatch:PutMetricData`, any cleanup)

Never add a sync boto3 call before the return statement without wrapping it
in one of these. The `vault.py` pattern of `InvocationType="Event"` only
works for Lambda — for CloudWatch there is no async mode, so
`BackgroundTasks` is the only option.

### Pitfall O-6 — Strands tool state must NOT use `threading.local`

**Symptom:** `dispatched_agent` in the response body is `null` despite
successful dispatch. Logs show `dispatch_succeeded` on the worker side,
but `last_dispatched_agent` always returns `None` back in the handler.

**Root cause:** Strands' `Agent.__call__` may run tool functions on a
worker thread from an internal thread pool. Anything stashed in
`threading.local` inside the tool is invisible to the caller thread after
`agent(...)` returns. Additionally, the LLM never sees the orchestrator's
real `session_id` — it only sees whatever arrives in its context, so
relying on the tool's `session_id` parameter to identify the active session
is unsafe (the LLM can and will fabricate values).

**Fix — module-level state protected by a lock:**

```python
_state_lock = threading.Lock()
_active_session_id: str | None = None
_dispatched_count: int = 0
_last_dispatched_agent: str | None = None

def begin_turn(session_id: str) -> None:
    with _state_lock:
        _active_session_id = session_id
        _dispatched_count = 0
        _last_dispatched_agent = None

def last_dispatched_agent(session_id: str) -> str | None:
    with _state_lock:
        return _last_dispatched_agent if _active_session_id == session_id else None
```

Inside the tool, use `sid = _active_session_id or session_id` — prefer the
orchestrator's real session ID over the LLM-supplied parameter. AgentCore
serializes invocations per container process, so module-level state is the
correct scope; the lock protects against Strands' internal parallelism.
`begin_turn` / `end_turn` bracket every `agent(...)` call in a try/finally.

### Pitfall O-7 — Every AWS endpoint the container touches needs a VPC interface endpoint

**Symptom A:** Short-path invocations (refusals, no dispatch) succeed, but
any request that hits an HR-policy domain times out with
`RuntimeClientError: Runtime health check failed or timed out`. Container
logs show `dispatch_agent` starting but never completing.

**Root cause A:** The orchestrator's nested
`bedrock-agentcore:InvokeAgentRuntime` call against the sub-agent resolves
`bedrock-agentcore.us-east-2.amazonaws.com` to a public IP with no route
from the private subnet. The connection hangs until AgentCore's health
check timeout fires. Short-path invocations work because they never reach
the nested invoke.

**Fix A:** Add the `bedrock-agentcore` interface VPC endpoint in the
foundation networking module. Once active, boto3 private-DNS routing
transparently handles the nested call.

**Symptom B:** After fixing A, latency regresses from ~5s to 120s and
health checks time out again — this time on **every** request, including
refusals.

**Root cause B:** `middleware.scan_and_redact` calls Comprehend
`DetectPiiEntities` twice per request (inbound + outbound). Each call
hangs for the full boto3 socket timeout (~60s) without a VPC endpoint,
silently — no exception, no log. Two hangs in series exceed the AgentCore
health check budget on every request.

**Fix B:** Add the `comprehend` interface VPC endpoint in the foundation
networking module.

**Generalisable rule:** Before deploying a new agent container, list every
AWS service it calls and verify each has either an interface endpoint or
(for S3 / DynamoDB) a gateway endpoint + prefix-list egress rule. The
project-root CLAUDE.md "VPC endpoints and security group egress" table is
the checklist — keep it updated whenever new AWS calls are added.

---

## Terraform State

State key: `dev/agents/orchestrator/terraform.tfstate`

This layer reads foundation + platform state (never writes to either):

```hcl
data "terraform_remote_state" "foundation" { ... }  # KMS key ARN
data "terraform_remote_state" "platform"   { ... }  # subnets, SG, tables, bucket
```

**Log group import (Apply 2 only):** After the first successful runtime create,
AgentCore may pre-create the CloudWatch log group. If the runtime log group
create fails with `ResourceAlreadyExistsException`, import and re-apply:

```bash
RUNTIME_ID=$(terraform output -raw agentcore_endpoint_id)
terraform import \
  'aws_cloudwatch_log_group.orchestrator_runtime[0]' \
  "/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT"
terraform plan -out=tfplan   # expect 0 add, 1 change
terraform apply tfplan
```

---

## Teardown Notes

```bash
terraform destroy -auto-approve
```

The `terraform_data + local-exec` destroy provisioner removes the
`orchestrator-dev` registry item. If destroy is interrupted mid-apply, clean up
manually:

```bash
aws dynamodb delete-item \
  --region us-east-2 \
  --table-name ai-platform-dev-agent-registry \
  --key '{"agent_id": {"S": "orchestrator-dev"}}'
```

**S3 orchestrator session objects** — `strands-sessions/orchestrator/*` on the
prompt vault bucket. Must be purged before destroying the platform layer.

**ECR images** — `ai-platform-dev-orchestrator` repo. Must be empty before
repository destroy succeeds.

---

## Files in This Layer

```
backend.tf                Remote state backend (S3 + DynamoDB lock)
main.tf                   IAM role + policy, guardrail, ECR, audit log group,
                          runtime (count-gated), runtime log group, manifest
variables.tf              Input variables (agent_image_uri optional, default "")
outputs.tf                IAM role ARN, guardrail, ECR URL, audit log group,
                          runtime endpoint/ARN (null until Apply 2)
terraform.tfvars.example  Copy to terraform.tfvars and fill in before applying
README.md                 Operator-facing runbook (apply / invoke / debug)
CLAUDE.md                 This file — agent-facing implementation notes
container/
  Dockerfile              arm64 FastAPI image — reuses the hr-assistant-strands base
  requirements.txt        strands-agents[otel] + fastapi + uvicorn + boto3
  app/                    see Implementation Overview above for per-file responsibilities
```
