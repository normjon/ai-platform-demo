# Authoring Guide — New Agent Layer

Environment-agnostic guide for adding a new agent to the platform. Read this
before scaffolding a new agent layer in any environment.

The agents tree is not a deployable layer — each sub-directory
(`hr-assistant/`, `hr-assistant-strands/`, `orchestrator/`, `stub-agent/`)
is an independently applied Terraform layer with its own state file and its
own apply boundary.

---

## Authoritative References

Read these first. This guide coordinates them; it does not replace them.

| Source | Use for |
|---|---|
| Project-root `CLAUDE.md` | Terraform structure, ADR pointers, approved model ARNs, AgentCore pitfalls, direct-write log handler, VPC endpoint checklist |
| [../layers/platform.md](../layers/platform.md) | Registry manifest schema, AOSS KB wiring, platform outputs |
| ADR-022 (`docs/adrs/ai-platform/ADR-022-agent-layer-pattern.md`) | Canonical four-component agent layer pattern + inline IAM ownership |
| ADR-023 (`docs/adrs/ai-platform/ADR-023-agentcore-container-requirements.md`) | Six non-obvious AgentCore container runtime rules |
| ADR-017 (`docs/adrs/infrastructure/`) | One-state-per-layer + inline IAM (Option B) |

---

## When to Add a New Agent Layer

Add a new layer when the agent has:

- Its own identity (distinct `agent_id`, registry entry)
- Its own IAM role (Option B inline — never reuse another agent's role)
- Its own container image (separate ECR repo in the `ecr/` layer — see
  [../layers/ecr.md](../layers/ecr.md))
- Its own AgentCore runtime

Do **not** fork an existing layer to add "a slight variant." Either extend
the existing agent via config (system prompt, guardrail, tool list) or
scaffold a fresh layer. Forks drift.

---

## Prerequisites

1. `foundation/` applied in the target environment (VPC, KMS, VPC
   endpoints).
2. `ecr/` updated with a new `aws_ecr_repository.<agent>` resource (+
   lifecycle policy + `<agent>_repository_url`/`<agent>_repository_arn`
   outputs) and applied. See [../layers/ecr.md](../layers/ecr.md).
   Agent layers do **not** create their own ECR repositories.
3. `platform/` applied and smoke tests pass (`agentcore_endpoint_id`,
   `agent_registry_table`, `opensearch_collection_arn` etc. populated).
4. For agents that use MCP tools: the corresponding `tools/<tool>/` layer
   applied and the gateway target registered.
5. For orchestrator-dispatched sub-agents: at least one sub-agent layer
   must have `enabled = true` in the registry before the orchestrator
   smoke tests will pass.

---

## Layer Scaffold

Minimum file set for a new agent at `terraform/<env>/agents/<name>/`:

```
backend.tf                 # S3 remote state — key: <env>/agents/<name>/terraform.tfstate
main.tf                    # Providers, remote state (foundation + platform + ecr), IAM, runtime, log group, manifest
variables.tf               # aws_region, environment, project_name, account_id, agent_image_uri, model_arn, ...
outputs.tf                 # iam_role_arn, agentcore_endpoint_id, agentcore_runtime_arn, app_log_group_name
terraform.tfvars.example   # Committed template with placeholders
terraform.tfvars           # Real values, GIT-IGNORED
smoke-test.sh              # Runs against terraform outputs — no args
README.md                  # Environment-specific stub (concrete values; deltas from the pattern)
CLAUDE.md                  # Environment-specific stub (deltas only; points at pattern file)
container/
  Dockerfile               # arm64 base (ADR-004)
  requirements.txt         # Include boto3 if using the direct-write log handler
  app/
    __init__.py
    main.py                # FastAPI + startup hook that installs log_handler
    log_handler.py         # Copy verbatim from hr-assistant-strands/container/app/
```

Reference implementations live under `terraform/dev/agents/`. Start by
copying the nearest match:

| Start from | When you're building |
|---|---|
| `stub-agent/` | A dispatch target that needs no LLM, KB, or guardrail (echo/integration testing) |
| `hr-assistant-strands/` | A Strands-SDK conversational agent that reuses another layer's KB/guardrail/prompt |
| `hr-assistant/` | A self-contained conversational agent that owns its KB, guardrail, system prompt, and Prompt Vault Lambda (ADR-022 "four components inline") |
| `orchestrator/` | A dispatcher that routes to sub-agents via `InvokeAgentRuntime` |

---

## Core Conventions

These apply to every agent layer without exception. Each has a failure mode
documented in the project-root `CLAUDE.md` — don't rediscover them.

- **arm64/Graviton** (ADR-004). Build with
  `--python-platform aarch64-manylinux2014 --only-binary=:all:`.
- **Immutable image tags** (ADR-009). Tag with
  `<agent>-$(git rev-parse --short HEAD)`; ECR repo uses
  `image_tag_mutability = "IMMUTABLE"`.
- **Direct-write CloudWatch log handler** (required). Copy
  `log_handler.py` from `hr-assistant-strands/container/app/`. Install at
  startup. Provision `/ai-platform/<agent>/app-<env>` log group, grant
  `logs:CreateLogStream` + `logs:PutLogEvents` on it, and pass
  `APP_LOG_GROUP` via `environment_variables`. Do **not** rely on the
  AgentCore stdout sidecar for application logs — it silently drops events
  on some runtimes.
- **Inline IAM** (ADR-017 Option B). The runtime IAM role is created in
  this layer's `main.tf`. Never reuse another agent's role. Never move
  roles to `modules/iam/`.
- **Two-step apply**. First apply with `agent_image_uri = ""` to create
  IAM and the app log group. Push the container to the agent's repo in
  the `ecr/` layer. Set `agent_image_uri` to the pushed URI and re-apply
  to land the runtime + registry entry. The runtime resource is
  `count`-gated on `var.agent_image_uri != ""`.
  Step 2 **will fail** the first time on
  `ResourceAlreadyExistsException` for the runtime log group — AgentCore
  pre-creates it. Import the group and re-apply; see
  [agents-tree.md → Runtime log group collision on first apply](../layers/agents-tree.md#runtime-log-group-collision-on-first-apply-import-required).
- **`sessionId` in payload body**. The control-plane
  `--runtime-session-id` is not forwarded to the container. Include
  `sessionId` in the JSON payload body for every invocation.
- **Underscore runtime names**. `agent_runtime_name` rejects hyphens — use
  `replace("${name_prefix}-<agent>", "-", "_")`.

---

## Required IAM Statements

Start from this set. Drop the statements that don't apply to your agent's
capabilities:

| Sid | Required when | Notes |
|---|---|---|
| `ECRTokenAccess` | Always | `ecr:GetAuthorizationToken` on `*` |
| `ECRPullImage` | Always | `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`, `ecr:BatchCheckLayerAvailability` on this agent's ECR repo ARN (read from `data.terraform_remote_state.ecr.outputs.<agent>_repository_arn`) |
| `CloudWatchLogsWrite` | Always | Runtime log group auto-writes — scope to `arn:aws:logs:<region>:<account>:log-group:/aws/bedrock-agentcore/runtimes/*` |
| `AppLogGroupDirectWrite` | Always | `logs:CreateLogStream` + `logs:PutLogEvents` on `${aws_cloudwatch_log_group.<agent>_app.arn}:*` |
| `CloudWatchMetrics` | Always | `cloudwatch:PutMetricData` with `cloudwatch:namespace = bedrock-agentcore` condition |
| `WorkloadIdentityTokens` | Always | `bedrock-agentcore:GetWorkloadAccessToken*` on the default workload identity directory |
| `KMSDecrypt` | Always | `kms:Decrypt`, `kms:GenerateDataKey` on `foundation.storage_kms_key_arn` |
| `BedrockInvokeModel` | Agent calls Bedrock | Include both `inference-profile/*` and `foundation-model/*` ARNs (see root CLAUDE.md) |
| `BedrockKBRetrieve` | Agent has a KB | `bedrock:Retrieve` on the KB ARN |
| `DynamoDBSessionMemory` | Agent uses session memory | Scoped to `agent_registry_table` + `session_memory_table` from platform outputs |
| `LambdaInvokePromptVault` | Agent emits interaction records | `lambda:InvokeFunction` on the agent's Prompt Vault writer |
| `InvokeSubAgent` | Orchestrator-style dispatcher | `bedrock-agentcore:InvokeAgentRuntime` on sub-agent runtime ARNs |
| `S3StrandsSessionReadWrite` | Strands S3 session manager | `s3:PutObject/GetObject/DeleteObject/ListBucket` on prompt-vault bucket with `strands-sessions/*` prefix (the platform role already has this — per-agent roles need it only if they bypass the platform runtime role) |

---

## Registry Manifest

The registry schema is defined in the **platform pattern file →
[Agent Onboarding](../layers/platform.md#agent-onboarding)**. Don't
duplicate it here.

Two things specific to authoring:

1. Use a `terraform_data` resource with `triggers_replace` covering every
   field that changes meaning if the agent is rebuilt (image URI, runtime
   ARN, allowed tools, domains, tier). The `local-exec` block `put-item`s
   the manifest.
2. Add a second `local-exec` with `when = destroy` that `delete-item`s the
   manifest. Required so teardown leaves no registry drift.

---

## Container Build

```bash
cd terraform/<env>/agents/<name>/container

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.<region>.amazonaws.com/ai-platform-<env>-<name>"
GIT_SHA=$(git rev-parse --short HEAD)

# Public ECR first, private ECR second — credential helpers can override each other
aws ecr-public get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin public.ecr.aws

aws ecr get-login-password --region <region> | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.<region>.amazonaws.com"

docker build --platform linux/arm64 -t "${ECR_URI}:<prefix>-${GIT_SHA}" .
docker push "${ECR_URI}:<prefix>-${GIT_SHA}"
```

Use a short prefix per agent (`stub-`, `strands-`, `orchestrator-`) so tags
are readable in ECR listings.

---

## Strands Hooks — Lifecycle Tracing (Strands agents only)

Applies to any agent whose container uses the Strands SDK (`from strands
import Agent`). Skip this section for non-Strands containers (the
stub-agent, for example).

Reference implementation:
`terraform/dev/agents/hr-assistant-strands/container/app/trace_hook.py`.
Spec: `ai-observability-platform/specs/trace-ingestion.md` §15.

### Why hooks, not OTEL auto-instrumentation

Strands' streaming path (`Agent.stream_async`) is **broken by any
framework-level OTEL auto-wrap layer**. Confirmed broken in SDK 1.35.0:

- `StrandsTelemetry().setup_otlp_exporter()` / `setup_meter()`
- `aws-opentelemetry-distro` + the `opentelemetry-instrument` CMD wrapper

Symptom: SSE invocations hang mid-stream; AgentCore reports "Runtime
health check failed or timed out" even though `/ping` returns 200.

The supported path is Strands' own typed hook system, which fires
synchronous callbacks at lifecycle points without touching the async
generator.

**Do NOT in any Strands container:**
- Add `aws-opentelemetry-distro` to `requirements.txt`.
- Wrap the CMD with `opentelemetry-instrument`.
- Call `StrandsTelemetry().setup_otlp_exporter` or `setup_meter`.

### What to wire in

1. Drop `trace_hook.py` next to `agent_strands.py` (copy from
   `hr-assistant-strands/container/app/`). It defines a `TraceHook`
   class implementing `HookProvider` with callbacks for
   `BeforeInvocationEvent`, `AfterInvocationEvent`,
   `BeforeToolCallEvent`, `AfterToolCallEvent`. Each callback is wrapped
   in try/except → emits `trace_hook_error` and swallows; no callback
   can kill an in-flight invocation.

2. In the Strands agent module, import and pass an instance per
   request:

   ```python
   from app.trace_hook import TraceHook

   _AGENT_ID = "<agent>-<env>"

   trace_id = (trace_context or {}).get("trace_id", "")  # populated
                                                         # only on
                                                         # orchestrator
                                                         # dispatch
   agent = Agent(
       model=_model,
       tools=[...],
       session_manager=s3sm,
       conversation_manager=SlidingWindowConversationManager(window_size=10),
       callback_handler=None,
       hooks=[TraceHook(_AGENT_ID, session_id, trace_id)],
   )
   ```

   Construct a fresh `TraceHook` per invocation — the hook holds the
   per-request `_invocation_start` / `_tool_starts` state.

### Output

Every callback emits a structured JSON line to the agent's app log
group with the base fields `{trace_id, agent_id, session_id}` plus
event-specific data:

| Event | Extra fields |
|---|---|
| `agent_start` | (none) |
| `tool_start` | `tool`, `tool_use_id`, `input_chars` |
| `tool_end` | `tool`, `tool_use_id`, `duration_ms`, `result_status`, `error`, `error_type`, `error_msg` |
| `agent_end` | `duration_ms`, `stop_reason`, `cycle_count`, `input_tokens`, `output_tokens`, `total_tokens`, `tool_calls` |

### Querying a single invocation

CloudWatch Logs Insights against `/ai-platform/<agent>/app-<env>`:

```
fields @timestamp, event, tool, duration_ms, input_tokens, output_tokens
| filter session_id = '<session-id>'
| filter event in ['agent_start','tool_start','tool_end','agent_end']
| sort @timestamp asc
```

`session_id` is the durable correlation ID today. The JSON `trace_id`
field is populated only when the orchestrator dispatches with a
`trace_context` body — direct invocations get `"-"`. A future change
will read `trace.get_current_span().get_span_context().trace_id` so
the JSON `trace_id` matches the OTEL trace_id from AgentCore's native
instrumentation; until then, filter on `session_id`.

### Verification

After deploying a Strands agent with hooks wired, an invocation that
calls one tool produces four hook events (`agent_start`, `tool_start`,
`tool_end`, `agent_end`); two tools produces six. `trace_hook_error`
events should be absent — their presence indicates the callback
captured an exception that needs investigation.

---

## Smoke Test Contract

Every layer ships `smoke-test.sh` that:

1. Exits 1 if required terraform outputs are missing (`agentcore_endpoint_id`).
2. Invokes the runtime directly via `aws bedrock-agentcore invoke-agent-runtime`
   with a fresh `sessionId` per invocation.
3. Asserts a known-good response pattern.
4. Queries the **application** log group (`APP_LOG_GROUP` output) — not the
   runtime log group — for the agent's expected structured event.
5. Prints `PASS`/`FAIL` per test and exits 0/1.

Smoke tests must be idempotent and safe to re-run. They must not depend on
another layer's smoke tests — orchestrator-side dispatch assertions live in
`orchestrator/smoke-test.sh`, not in the sub-agent's.

---

## Backend State Key

```hcl
terraform {
  backend "s3" {
    bucket         = "ai-platform-terraform-state-<env>-<account_id>"
    key            = "<env>/agents/<name>/terraform.tfstate"
    region         = "<region>"
    dynamodb_table = "ai-platform-terraform-lock-<env>"
    encrypt        = true
  }
}
```

---

## CLAUDE.md Files for Each Agent

Per ADR-021, each agent layer gets a Level-3 pattern CLAUDE.md. In this
repository the pattern content lives in `docs/patterns/layers/agent-<name>.md`;
the per-environment `terraform/<env>/agents/<name>/CLAUDE.md` is a thin stub
that points to the pattern and records only environment-specific deltas.

Keep each pattern file under 150 lines per ADR-021. If a pattern takes more
than 150 lines to describe, it is probably two patterns and should be split
or promoted to an ADR.

---

## Skills (Deferred)

Skills are not yet implemented. Read [../layers/skills.md](../layers/skills.md)
and `specs/skills-architecture-plan.md` before any skill-related work. Do not
scaffold skill files inline into an agent layer as a workaround.

---

## Reference Implementations

| Layer | What it demonstrates |
|---|---|
| `stub-agent/` | Minimal dispatch target — no LLM, no KB, no guardrail |
| `hr-assistant/` | ADR-022 full four-component pattern — own KB, guardrail, system prompt, Prompt Vault |
| `hr-assistant-strands/` | Strands SDK variant that reuses another layer's KB/guardrail/prompt |
| `orchestrator/` | Registry-driven dispatcher with audit log group |

---

## Teardown

Each agent layer teardown is standalone and preserves the ECR repo and
its images:

```bash
cd terraform/<env>/agents/<name>
terraform destroy -auto-approve
```

The `when = destroy` provisioner on the manifest resource removes the
registry entry automatically. The ECR repo and its images are owned by
the `ecr/` layer and survive this destroy — the next apply picks up
the existing images without rebuild.

Teardown ordering across the tree follows the operations runbook's destroy
sequence: orchestrator → sub-agents → tools → platform → foundation.
The `ecr/` layer is destroyed only when decommissioning the environment
entirely (after foundation, per the runbook).
See [../../operations.md](../../operations.md#teardown-order).
