# Playbook: Orchestrator Layer — AWS Supervisor Pattern

Specification for introducing an orchestration layer on top of the existing
AgentCore sub-agent runtimes. The orchestrator is a Strands supervisor agent
that becomes the single front door for all agent invocations, routing each
request to one or more sub-agent runtimes discovered through the existing
DynamoDB agent registry.

This playbook follows the AWS Multi-Agent Orchestration reference pattern
exactly. The skills-driven architecture proposed in
`specs/skills-architecture-plan.md` is **shelved** — each sub-agent team
continues to own its own runtime with system prompt in-container, reviewed
in PRs. Skills may be reintroduced later if and only if a content-authoring
need surfaces that deployment-coupled prompts cannot serve.

Status: Phase O (Orchestration) — design resolved 2026-04-20, implementation
pending. This document is the authoritative source of record for the build.
All decisions are resolved inline; do not proceed on assumptions not covered
here.

---

## Strategy

The existing agents are **left completely untouched** and continue to be
invokable directly via their AgentCore endpoints throughout Phase O. A new
layer — `terraform/dev/agents/orchestrator/` — provisions an additional
AgentCore runtime that fronts them.

- Direct invocation of `hr-assistant-strands-dev` remains operational
  throughout the Phase O build as a regression baseline.
- The orchestrator is purely additive: no existing agent, tool, or platform
  resource is modified beyond the registry schema extension in Phase O.1
  (which is backwards-compatible — new optional fields only).
- A second sub-agent (`stub-agent`) is added in Phase O.4 purely to validate
  that the registry-driven dispatch pattern works across more than one tenant.
  This is the piece that actually earns the orchestrator its keep.
- Cutover happens in docs only: the orchestrator endpoint becomes the
  published front door once the Phase O.5 test matrix is green. Direct
  sub-agent endpoints remain available for operators and regression testing.

---

## Design Decisions — Locked In

| # | Decision | Resolution |
| --- | --- | --- |
| D1 | Session memory for orchestrator | Reuse DynamoDB session memory table (consistent with existing agents). Defer AgentCore Memory until we have a reason to adopt it. |
| D2 | Dispatch shape at launch | Single-agent dispatch only. Parallel fan-out + synthesis deferred to a post-launch increment; it is the same `dispatch_agent` tool called N times. |
| D3 | Second agent content | Pure stub — returns a known-good echo response. Purpose is to validate the registry + dispatch pattern, not to ship a second product. |
| D4 | Middleware scope | PII redaction (Comprehend `DetectPiiEntities`) and audit logging land together in Phase O.3. They share the same seam; splitting doubles test surface. |
| D5 | Guardrail strategy | New orchestrator-specific guardrail. Content surface is different (the supervisor sees every inbound and outbound message across all domains), and guardrails are cheap. |
| D6 | Skills layer | Shelved. Sub-agent system prompts stay in their containers. Revisit only if a non-engineer content-authoring need arises. |
| D7 | Auth | IAM-only in dev. Cognito/JWT deferred, matching the deferral in the shelved skills plan. |
| D8 | ADR authoring | Deferred until the orchestrator is proven working end-to-end. Per `feedback_adr_timing.md`, capture decisions here in the spec during build; draft the ADR once cutover criteria are met. |

---

## Pre-Execution Reading

Before writing any code or Terraform in this layer:

1. `docs/Enterprise_AI_Platform_Architecture.md` — Section 5.2 (agent manifest
   schema) and Section 7 (orchestration topology). The registry extension in
   Phase O.1 must remain consistent with the manifest schema.
2. `terraform/dev/platform/main.tf` — DynamoDB agent registry table
   definition. Confirm current schema before extending.
3. `terraform/dev/agents/hr-assistant-strands/main.tf` and its `CLAUDE.md` —
   the orchestrator is itself a Strands + AgentCore runtime with the same
   build, deploy, and operational shape. Reuse patterns verbatim.
4. `terraform/dev/agents/hr-assistant-strands/container/app/agent_strands.py`
   — Strands `Agent`, `BedrockModel`, `@tool`, and `S3SessionManager` usage.
   The orchestrator uses the same primitives plus a `dispatch_agent` tool.
5. `~/Downloads/multi-agent-orchestration-on-aws.pdf` — AWS reference
   pattern. Every deviation from this pattern must be justified in this
   spec, not in code comments.
6. ADR-004 (arm64), ADR-017 (inline IAM per layer), ADR-021 (three-level
   CLAUDE.md hierarchy).

---

## Target Architecture

```
                        ┌─────────────────────────┐
                        │    User / Client        │
                        │ (IAM-signed HTTPS call) │
                        └───────────┬─────────────┘
                                    │
                                    ▼
  ┌───────────────────────────────────────────────────────────────┐
  │      Orchestrator AgentCore Runtime  (this layer)             │
  │                                                               │
  │   ┌──────────────────────────────────────────────────────┐    │
  │   │  Container middleware (always runs, LLM-independent) │    │
  │   │    1. Inbound PII scan   (Comprehend)                │    │
  │   │    2. Audit log: request                             │    │
  │   │    3. Session load       (DynamoDB)                  │    │
  │   │                ─── Strands supervisor ───            │    │
  │   │    • Reads agent registry (DynamoDB, cached)         │    │
  │   │    • Chooses domain → calls dispatch_agent tool      │    │
  │   │    • dispatch_agent invokes sub-agent AgentCore RT   │    │
  │   │    • Composes final response                         │    │
  │   │                ──────────────────────────            │    │
  │   │    4. Outbound PII scan  (Comprehend, defense-in-    │    │
  │   │                           depth)                     │    │
  │   │    5. Session save       (DynamoDB)                  │    │
  │   │    6. Audit log: response                            │    │
  │   └──────────────────────────────────────────────────────┘    │
  └──────────┬────────────────────────────────┬───────────────────┘
             │ InvokeAgentRuntime             │ InvokeAgentRuntime
             │ (IAM prefix-scoped)            │ (IAM prefix-scoped)
             ▼                                ▼
   ┌──────────────────────┐          ┌──────────────────────┐
   │  hr-assistant-       │          │  stub-agent          │
   │  strands-dev         │          │  (added in O.4)      │
   │  (existing,          │          │  echoes payload      │
   │   unmodified)        │          │                      │
   └──────────────────────┘          └──────────────────────┘
             │
             └── MCP Gateway (existing, unmodified) ──► Glean stub
                                                    ─► HR KB Lambda
```

Key invariants:

- The orchestrator is the only component that reads the agent registry.
  Sub-agents do not know about each other.
- Cross-cutting concerns (PII, audit) live in container middleware — not in
  Strands tools — because they are unconditional. LLM planning has no say in
  whether they run.
- `dispatch_agent` is the **only** Strands tool exposed to the supervisor
  LLM. The LLM's job is routing decisions; everything else is deterministic.

---

## Phase O.1 — Registry Schema Extension

**Scope.** Add discovery-related fields to the `ai-platform-dev-agent-registry`
DynamoDB table and backfill entries for the two existing agents. This is a
data-model change — the table already exists and is owned by the platform
layer. No table-level Terraform change is required because DynamoDB is
schemaless.

**Fields to add to each registry item:**

| Field | Type | Required | Purpose |
| --- | --- | --- | --- |
| `domains` | `SS` (string set) | Yes | Topic domains this agent handles, e.g. `{"hr.policy", "hr.escalation"}`. The orchestrator matches user intent against this set. |
| `tier` | `S` | Yes | `"conversational"` (Strands loop) or `"workflow"` (deterministic pipeline). Orchestrator uses this for dispatch parameter shaping. |
| `enabled` | `BOOL` | Yes | When `false`, orchestrator refuses to dispatch. Allows operator kill-switch without IAM or Terraform changes. |
| `owner_team` | `S` | Yes | Team name for audit log attribution. |

Existing fields (`agent_id`, `runtime_arn`, `model_id`,
`prompt_vault_lambda_arn`, `agent_description`, etc.) are preserved unchanged.
The orchestrator reuses the existing `agent_description` field as the
one-line description injected into the supervisor system prompt — no new
`description` field is added, avoiding duplicate data in the registry.

**Backfill approach.** Each agent layer already writes its registry entry
via a `terraform_data + local-exec` block calling `aws dynamodb put-item`.
Extend that put-item payload in each agent layer to include the new fields:

```hcl
"domains":      { "SS": ["hr.policy", "hr.escalation"] }
"tier":         { "S":  "conversational" }
"enabled":      { "BOOL": true }
"owner_team":   { "S":  "hr-platform" }
"description":  { "S":  "HR policy and escalation assistant (Strands)." }
```

**Re-registration trigger.** The `triggers_replace` clause on the
`terraform_data` manifest resource must include the new fields so a change
to `domains` or `enabled` re-fires the put-item. Existing Strands layer
already uses this pattern — follow it.

**Acceptance criteria.**

- `hr-assistant-dev` and `hr-assistant-strands-dev` items have all four new
  fields set.
- `aws dynamodb get-item` returns the extended schema for both.
- `aws dynamodb scan --filter-expression "enabled = :t" --expression-attribute-values '{":t":{"BOOL":true}}'`
  returns exactly one item (`hr-assistant-strands-dev`). Per Option A, the
  boto3 `hr-assistant-dev` entry has `enabled=false` and is excluded from
  orchestrator routing — it remains in the registry as a regression baseline.
- Neither agent's runtime behaviour is affected (containers don't read the
  new fields).

**Rollback.** Remove the fields from the put-item blocks and re-apply. The
orchestrator does not exist yet, so no consumer depends on them.

---

## Phase O.2 — Terraform Layer Scaffold

**Scope.** Create `terraform/dev/agents/orchestrator/` with all infrastructure
for the orchestrator runtime **except** the container. This lets the IAM
role, guardrail, runtime resource, and registry entry land first, then the
container push triggers the apply that wires the runtime to an image in O.3.

**Directory layout:**

```
terraform/dev/agents/orchestrator/
  backend.tf              dev/agents/orchestrator/terraform.tfstate
  main.tf                 IAM role, runtime, guardrail, log group, manifest
  variables.tf
  outputs.tf              agentcore_endpoint_id, runtime_arn, iam_role_arn
  smoke-test.sh           Tests O.5.a – O.5.i
  terraform.tfvars.example
  CLAUDE.md               Level-3 CLAUDE per ADR-021
  container/
    app/
      main.py             FastAPI entry — startup, /invocations, BackgroundTasks
      orchestrator.py     Strands Agent + supervisor system prompt + loop
      dispatch.py         dispatch_agent @tool (emits dispatch metrics)
      registry.py         DynamoDB registry reader with TTL cache
      middleware.py       PII scan + audit log
      metrics.py          Orchestrator + per-sub-agent metric emission
      tracing.py          OTEL trace_id generation + sub-agent propagation
      config.py           Env var loader
      audit.py            Audit record schema + CloudWatch Logs writer
    Dockerfile            arm64, identical structure to hr-assistant-strands
    requirements.txt      strands-agents[otel]==1.35.0, fastapi, uvicorn, boto3
```

**IAM — inline in this layer (ADR-017).** The orchestrator gets its own
execution role; the platform `agentcore_runtime` role is **not** reused.
This keeps orchestrator's very different permission surface cleanly isolated
from sub-agent roles.

Required permissions:

| Action | Resource | Notes |
| --- | --- | --- |
| `bedrock-agentcore:InvokeAgentRuntime` | `arn:aws:bedrock-agentcore:us-east-2:ACCOUNT:runtime/*` | Prefix-based — covers current and future sub-agents without code change. See IAM Scoping Pattern below. |
| `bedrock:InvokeModel` | `inference-profile/us.anthropic.claude-sonnet-4-6`, `foundation-model/*` | Inference profile ARN mandatory for Claude 4.x on-demand. |
| `bedrock:ApplyGuardrail` | Orchestrator guardrail ARN | For the orchestrator's own guardrail (D5). |
| `dynamodb:GetItem`, `Scan`, `Query` | Agent registry table | Read-only; orchestrator never writes to the registry. |
| `dynamodb:GetItem`, `PutItem`, `UpdateItem` | Session memory table | Orchestrator's own conversation state (D1). |
| `comprehend:DetectPiiEntities` | `*` | Comprehend has no resource-level scoping. |
| `logs:CreateLogStream`, `PutLogEvents` | Orchestrator log group + audit log group | Two log groups: runtime logs and audit logs (see below). |
| `cloudwatch:PutMetricData` | `*` with `cloudwatch:namespace = "bedrock-agentcore"` | Same condition as sub-agents. |
| `kms:Decrypt`, `GenerateDataKey` | Platform KMS key | For registry and session table reads. |
| `s3:GetObject`, `PutObject`, `DeleteObject`, `ListBucket` | `strands-sessions/orchestrator/*` on prompt vault bucket | For `S3SessionManager` (same pattern as hr-assistant-strands). |

**Guardrail.** A dedicated `orchestrator-guardrail-dev` resource with
default Anthropic-managed filters plus project-specific denied topic
policies (legal advice, medical advice, financial advice). Version pinned
to `DRAFT` in dev; version-pinned for staging/prod later.

**Log groups.** Two separate CloudWatch log groups:

- `/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT` — auto-created by
  AgentCore; import on first apply (Pitfall 5 from the Strands layer).
- `/ai-platform/orchestrator/audit-dev` — created by this layer, 90-day
  retention, KMS-encrypted. Audit middleware writes structured JSON here.

**Registry entry for the orchestrator itself.** The orchestrator is listed
in the agent registry as a self-referencing entry with `domains = ["_orchestrator"]`
and `enabled = true`. This gives operators one-table visibility of all
agents including the front door.

**Acceptance criteria.**

- `terraform plan` in this layer is clean against foundation + platform +
  hr-assistant + hr-assistant-strands state.
- `terraform apply` creates: IAM role, guardrail, AgentCore runtime (with a
  placeholder image that will be replaced in O.3), log groups, registry
  entry for `orchestrator-dev`.
- Direct `InvokeAgentRuntime` against the orchestrator endpoint fails with
  a container error (expected — no real container yet) but the IAM path
  resolves.
- Existing agents continue to work end-to-end via direct invocation.

---

## Phase O.3 — Orchestrator Container

**Scope.** Build and push the orchestrator container image, then re-apply
the Terraform layer to point the runtime at the real image URI. Implements
the Strands supervisor, `dispatch_agent` tool, PII + audit middleware, and
registry-aware routing.

**Container build.** Identical pattern to `hr-assistant-strands` — arm64,
public-ECR-first auth, `orchestrator-<sha>` tag prefix on a new ECR
repository `ai-platform-dev-orchestrator` (foundation layer adds this
repository in an atomic update, or this layer owns it — owner TBD in the
first apply; default: this layer owns it for isolation).

**`orchestrator.py` — supervisor shape.**

```python
from strands import Agent
from strands.models import BedrockModel
from strands.session import S3SessionManager
from strands.agent.conversation_manager import SlidingWindowConversationManager

_model = BedrockModel(model_id=config.MODEL_ID, region=config.AWS_REGION)

def build_agent(session_id: str, registry_summary: str) -> Agent:
    system_prompt = render_system_prompt(registry_summary)
    session_manager = S3SessionManager(
        session_id=f"orchestrator/session_{session_id}",
        bucket=config.PROMPT_VAULT_BUCKET,
        prefix="strands-sessions",
    )
    return Agent(
        model=_model,
        tools=[dispatch_agent],
        system_prompt=system_prompt,
        session_manager=session_manager,
        conversation_manager=SlidingWindowConversationManager(window_size=10),
        guardrail_id=config.GUARDRAIL_ID,
        guardrail_version=config.GUARDRAIL_VERSION,
    )
```

The supervisor system prompt is built at invocation time with the current
registry summary embedded — so adding a new agent to the registry is
reflected on the very next orchestrator invocation, with no redeploy.

**`dispatch.py` — the only Strands tool.**

```python
@tool
def dispatch_agent(domain: str, message: str, session_id: str) -> dict:
    """Route a request to the sub-agent that owns the given domain.

    Args:
        domain: Topic domain from the agent registry (e.g. "hr.policy").
        message: The user's message to forward. Pass through verbatim.
        session_id: Orchestrator session ID; sub-agents derive their own.

    Returns:
        {"agent_id": str, "response": str} on success.
        {"error": "no_agent_for_domain" | "agent_disabled" | "invoke_failed",
         "domain": str, "detail": str} on failure.
    """
    entry = registry.lookup_by_domain(domain)
    if entry is None:
        return {"error": "no_agent_for_domain", "domain": domain, "detail": ""}
    if not entry["enabled"]:
        return {"error": "agent_disabled", "domain": domain,
                "detail": entry["agent_id"]}

    sub_session = f"{session_id}:{entry['agent_id']}"
    payload = json.dumps({"prompt": message, "sessionId": sub_session}).encode()

    try:
        resp = _agentcore.invoke_agent_runtime(
            agentRuntimeArn=entry["runtime_arn"],
            runtimeSessionId=sub_session,
            payload=payload,
        )
    except ClientError as e:
        return {"error": "invoke_failed", "domain": domain, "detail": str(e)}

    body = json.loads(resp["response"].read())
    return {"agent_id": entry["agent_id"], "response": body["response"]}
```

**Single-dispatch discipline (D2).** The supervisor system prompt
instructs the LLM to call `dispatch_agent` exactly once per user turn. If
the LLM calls it more than once, the second call returns
`{"error": "single_dispatch_only"}`. Parallel fan-out is deferred to a
post-launch increment and will lift this restriction.

**`middleware.py` — unconditional wrappers.**

```python
async def run_with_middleware(prompt: str, session_id: str,
                              user_role: str) -> dict:
    request_id = uuid4().hex

    inbound = pii.scan_and_redact(prompt)
    audit.record_request(request_id, session_id, user_role,
                         inbound.redacted_prompt, inbound.pii_types)

    result = orchestrator.build_agent(session_id,
                                       registry.summary()).invoke(
        inbound.redacted_prompt
    )

    outbound = pii.scan_and_redact(result["response"])
    audit.record_response(request_id, session_id,
                          outbound.redacted_text, outbound.pii_types,
                          result.get("dispatched_agent"))

    return {"response": outbound.redacted_text, "request_id": request_id}
```

Middleware is **synchronous Python** called from an `async def` handler —
but all its calls (Comprehend, DynamoDB, CloudWatch Logs) are offloaded to
`BackgroundTasks` or `asyncio.to_thread` to avoid the event-loop blocking
pitfall documented in the Strands layer. Specifically: audit log writes
(inbound **and** outbound) go through `BackgroundTasks` — they are
non-critical-path.

**`registry.py` — cache shape.**

- 60-second in-memory TTL cache on a full table scan.
- `lookup_by_domain(domain: str)` walks the cached entries.
- `summary()` returns a short text block listing `agent_id`, `domains`,
  `description` for each enabled agent — injected into the supervisor
  system prompt.
- Cache miss triggers a scan; errors fall back to the last-known-good
  cached entries with an `event: registry_stale` log line.

**Audit record schema.** JSON written to
`/ai-platform/orchestrator/audit-dev`, one line per request + one per
response:

```json
{
  "event": "orchestrator_request" | "orchestrator_response",
  "request_id": "hex32",
  "session_id": "user-session-id",
  "user_role": "employee" | "manager" | "admin",
  "timestamp": "2026-04-20T12:00:00Z",
  "prompt_hash": "sha256...",                 // request only
  "pii_types_inbound": ["EMAIL", "SSN"],      // request only
  "dispatched_agent": "hr-assistant-strands-dev", // response only
  "response_hash": "sha256...",               // response only
  "pii_types_outbound": [],                   // response only
  "duration_ms": 1248                         // response only
}
```

Prompts and responses are **hashed, not stored**, in the audit log — the
Prompt Vault remains the authoritative record of content. Audit logs are
for "who called what when," not retrieval.

**Acceptance criteria.**

- `docker build --platform linux/arm64` succeeds.
- `docker push` to `ai-platform-dev-orchestrator:orchestrator-<sha>` succeeds.
- `terraform apply` with the real image URI results in a healthy runtime.
- `smoke-test.sh` test O.5.a (happy path HR question) returns an HR policy
  answer end-to-end through the orchestrator.
- Orchestrator-level metrics (`OrchestratorInvocationLatency`, etc.) and
  per-sub-agent dispatch metrics (`DispatchLatency`, `DispatchSuccess`,
  `DispatchFailure` with `DispatchedAgent` dimension) appear in the
  `bedrock-agentcore` CloudWatch namespace after invocations.
- OTEL `trace_id` is generated at request entry and propagated in the
  `dispatch_agent` payload under the key `trace_context`. Sub-agent logs
  for a given invocation share the same `trace_id`.
- `specs/observability-metric-catalogue.md` is extended with the
  orchestrator metric section (see Observability Design below).
- `specs/dashboards/` gains an orchestrator panel file (see Observability
  Design below).

---

## Phase O.4 — Stub Agent for Dispatch Validation

**Scope.** Onboard a second sub-agent — `stub-agent` — that exists purely
to prove the registry + dispatch pattern scales to more than one tenant.
Zero orchestrator code changes are required; onboarding is entirely a
registry put and a new Terraform layer.

**Directory layout:**

```
terraform/dev/agents/stub-agent/
  backend.tf              dev/agents/stub-agent/terraform.tfstate
  main.tf                 IAM role, AgentCore runtime, log group, manifest
  variables.tf
  outputs.tf
  terraform.tfvars.example
  smoke-test.sh           Tests O.5.j (direct), O.5.b (via orchestrator)
  CLAUDE.md
  container/
    app/
      main.py             FastAPI, echoes prompt with a fixed prefix
    Dockerfile            arm64, minimal
    requirements.txt      fastapi + uvicorn only — no Strands, no Bedrock
```

**Behaviour.** Given prompt `"Hello world"`, returns
`{"response": "[stub-agent] received: Hello world"}`. No LLM, no tools, no
guardrail — just a deterministic echo. This makes the dispatch test
fully assertable without LLM flakiness.

**Registry entry:**

```json
{
  "agent_id":     {"S":  "stub-agent-dev"},
  "runtime_arn":  {"S":  "arn:aws:bedrock-agentcore:..."},
  "domains":      {"SS": ["test.echo"]},
  "tier":         {"S":  "workflow"},
  "enabled":      {"BOOL": true},
  "owner_team":   {"S":  "platform"},
  "description":  {"S":  "Deterministic echo agent for dispatch validation."}
}
```

**Acceptance criteria.**

- Direct invocation of the stub runtime returns the expected echo.
- Orchestrator invocation with prompt containing `"echo test"` routes to
  `stub-agent-dev` and returns the echo through the orchestrator response.
- No change to `orchestrator/app/` was required to onboard this agent —
  this is the test that earns the orchestrator its keep.

---

## Phase O.5 — Integration Tests and Cutover

**`smoke-test.sh` in `terraform/dev/agents/orchestrator/` runs the full
matrix.** Each test is scripted and idempotent; they run after every
orchestrator apply.

| ID | Test | Pass criteria |
| --- | --- | --- |
| O.5.a | HR policy question via orchestrator | Response contains a policy-derived answer; audit log shows dispatch to `hr-assistant-strands-dev`. |
| O.5.b | Echo test via orchestrator | Response contains `[stub-agent] received:`; audit log shows dispatch to `stub-agent-dev`. |
| O.5.c | Unknown-domain refusal | Prompt for a domain not in registry → orchestrator returns a refusal, does not fabricate an agent, does not call `dispatch_agent` with invented ARN. |
| O.5.d | Inbound PII redaction | Prompt contains SSN → Comprehend detects; redacted form is what reaches the supervisor LLM (verified via audit log `pii_types_inbound`). |
| O.5.e | Outbound PII redaction | Sub-agent response contrived to contain an email address → outbound middleware redacts before response reaches client. |
| O.5.f | Audit log completeness | Every invocation produces both a `orchestrator_request` and `orchestrator_response` record with all schema fields populated. |
| O.5.g | Disabled-agent refusal | Flip `enabled=false` on `stub-agent-dev` in registry; orchestrator invocation for `test.echo` returns `no_agent_for_domain` / disabled refusal. Flip back and verify dispatch resumes within cache TTL + 5s. |
| O.5.h | Session coherence across domains | Ask HR question, then follow up asking for echo. Second request reaches `stub-agent-dev` with context from the orchestrator's session (not the HR sub-session). |
| O.5.i | IAM prefix boundary | Attempt to invoke a non-AgentCore runtime ARN via a crafted `dispatch_agent` call → AccessDenied. (Validates the prefix scope, not just the policy text.) |
| O.5.j | Direct stub invocation | `stub-agent-dev` reachable directly without orchestrator, returning echo. |
| O.5.k | Single-dispatch discipline | If supervisor attempts two `dispatch_agent` calls in one turn, second returns `single_dispatch_only` error; orchestrator returns first result. |
| O.5.l | Metric dimensions correctness | After a successful orchestrator invocation, `aws cloudwatch list-metrics --namespace bedrock-agentcore` returns `DispatchLatency` with a `DispatchedAgent` dimension matching the registry `agent_id`, plus orchestrator-level metrics with `AgentId=orchestrator-dev`. |
| O.5.m | OTEL trace propagation | The same `trace_id` appears in both orchestrator and sub-agent CloudWatch log events for a single invocation — confirms distributed trace continuity across the AgentCore runtime boundary. |

**Cutover criteria.** All tests O.5.a – O.5.m pass, plus:

- Direct invocation of `hr-assistant-strands-dev` still works (regression baseline).
- Direct invocation of `hr-assistant-dev` (boto3) still works.
- `docs/Enterprise_AI_Platform_Architecture.md` updated to reference the
  orchestrator endpoint as the published entry point. Direct sub-agent
  endpoints documented as operator/regression-only.
- Runbook added: "Onboarding a new agent" — Terraform layer + registry put.
  No orchestrator changes required (validated by Phase O.4).
- ADR drafted (not opened as PR yet per D8) capturing the orchestrator
  architecture. Review with engineer, then open PR on the ADR repo.

---

## Observability Design

Routing every request through a single front door is a significant
observability multiplier. The orchestrator sees things sub-agents cannot
see about themselves (routing distribution, cross-domain patterns,
end-to-end latency including dispatch overhead), while sub-agents retain
their own self-reported metrics for isolation-level diagnostics.

Three complementary views are produced:

| View | Emitted by | `AgentId` dimension | Answers |
| --- | --- | --- | --- |
| Orchestrator whole | Orchestrator container | `orchestrator-dev` | "How's the front door performing?" |
| Orchestrator by sub-agent | Orchestrator container | `orchestrator-dev` + `DispatchedAgent` | "From the user's perspective, which sub-agent is slow or failing?" |
| Sub-agent self | Sub-agent container (existing) | `<sub-agent-id>` | "How's the sub-agent performing in isolation?" |

The delta between the second and third views is network + dispatch
overhead — itself a useful signal to track over time.

### Metric Catalogue Extension

All metrics emit to the existing `bedrock-agentcore` namespace to stay
consistent with the catalogue's IAM condition. Phase O.3 extends
`specs/observability-metric-catalogue.md` with a new "Orchestrator"
section covering:

**Orchestrator-level (dimension: `AgentId=orchestrator-dev`, `Environment=dev`)**

| Metric | Unit | Purpose |
| --- | --- | --- |
| `OrchestratorInvocationLatency` | Milliseconds | End-to-end wall-clock latency: inbound middleware + supervisor loop + dispatch + outbound middleware. |
| `OrchestratorInputTokens` | Count | Supervisor LLM input tokens for the routing decision. |
| `OrchestratorOutputTokens` | Count | Supervisor LLM output tokens for response synthesis. |
| `PiiDetectedInbound` | Count | Number of PII entities detected in user prompts. Emit `0` on clean requests so absence is distinguishable from instrumentation failure. |
| `PiiDetectedOutbound` | Count | Number of PII entities detected in sub-agent responses before client delivery. |
| `RoutingFailureUnknownDomain` | Count | Requests where the supervisor requested a domain not in the registry. |
| `RoutingFailureAgentDisabled` | Count | Requests routed to an agent currently flagged `enabled = false`. |
| `RegistryCacheMiss` | Count | Number of cache misses triggering a DynamoDB scan. |
| `RegistryCacheStale` | Count | Number of requests served from last-known-good cache after a refresh failure. |

**Per-sub-agent dispatch view (dimensions: `AgentId=orchestrator-dev`, `DispatchedAgent=<sub_agent_id>`, `Environment=dev`)**

| Metric | Unit | Purpose |
| --- | --- | --- |
| `DispatchLatency` | Milliseconds | Wall-clock time of the `InvokeAgentRuntime` call to the sub-agent (excludes supervisor overhead). |
| `DispatchSuccess` | Count | Emit `1` per successful dispatch. Use `sum_over_time` in PromQL for totals. |
| `DispatchFailure` | Count | Emit `1` per failed dispatch; attach an `ErrorClass` dimension (`invoke_failed`, `agent_disabled`, `no_agent_for_domain`, `single_dispatch_only`, `timeout`). |
| `DispatchCount` | Count | Emit `1` per dispatch regardless of outcome. Enables dispatch-share panels (% of traffic per sub-agent). |

Dimension discipline: always include `Environment` so the same query
patterns work when staging/prod land. Never emit a metric without at
least `AgentId` and `Environment`.

### Dashboard Panels

Phase O.3 adds `specs/dashboards/orchestrator.json` (CloudWatch dashboard
JSON or AMG equivalent) with six panels:

1. **Front-door traffic** — `OrchestratorInvocationLatency` p50/p95/p99
   plus request rate over time.
2. **Dispatch distribution** — stacked area of `DispatchCount` by
   `DispatchedAgent`. Shows routing share per sub-agent.
3. **Per-sub-agent latency** — `DispatchLatency` p95 per
   `DispatchedAgent`, overlay of each sub-agent's self-reported
   `InvocationLatency` for comparison. Gap between the two is
   network/dispatch overhead.
4. **Dispatch errors** — `DispatchFailure` stacked by `ErrorClass`.
5. **PII prevalence** — `PiiDetectedInbound` vs `PiiDetectedOutbound`
   rates. Outbound non-zero is a stronger signal — sub-agent emitted PII.
6. **Supervisor token cost** — `OrchestratorInputTokens` +
   `OrchestratorOutputTokens` per request, averaged. Flags whether the
   supervisor is burning too many tokens on routing vs dispatch value.

Dashboard queries follow the `_sum / _count` gauge pattern documented
in the metric catalogue — do not use `rate()` or `increase()`.

### Distributed Tracing via OTEL

Phase O.3 wires OTEL trace propagation across the orchestrator →
sub-agent boundary. The Strands SDK already includes `[otel]` extras;
the missing piece is explicit propagation through the `InvokeAgentRuntime`
payload (AgentCore does not propagate OTEL headers natively across
runtimes).

**Propagation shape.** `dispatch_agent` injects trace context into the
payload body — AgentCore forwards the body verbatim to the sub-agent:

```python
payload = json.dumps({
    "prompt": message,
    "sessionId": sub_session,
    "trace_context": {
        "trace_id": current_trace_id(),
        "span_id":  current_span_id(),
    },
}).encode()
```

**Sub-agent handling.** Each sub-agent's `main.py` startup hook is
extended once to read `trace_context` from the payload and set it as the
parent span for the invocation. This is a small, bounded change to each
sub-agent container. It is the **only** orchestrator-related change
required in sub-agents for Phase O — do not conflate it with any other
scope.

**Logging correlation.** Every structured log event in the orchestrator
and every sub-agent now includes a `trace_id` field. `aws logs
filter-log-events` across both log groups on `trace_id=<id>` produces the
full request journey in chronological order.

**Deferred to a later increment:** shipping traces to an OTEL collector /
X-Ray / Tempo. Phase O uses `trace_id` in logs only — enough for
correlation, without the collector infrastructure lift.

### Acceptance (adds to Phase O.3)

- Metric catalogue PR ready to open (same repo — it's a docs file).
- `specs/dashboards/orchestrator.json` committed with all six panels.
- `trace_id` visible in both orchestrator and sub-agent logs for every
  invocation — this is tested by O.5.m.

---

## IAM Scoping Pattern — Prefix-Based Cross-Runtime Invoke

The orchestrator's `bedrock-agentcore:InvokeAgentRuntime` permission is
scoped to **all AgentCore runtimes in this account + region** via the
wildcard resource:

```json
{
  "Effect": "Allow",
  "Action": "bedrock-agentcore:InvokeAgentRuntime",
  "Resource": "arn:aws:bedrock-agentcore:us-east-2:096305373014:runtime/*"
}
```

**Rationale.** Per-agent enumeration in the orchestrator's IAM policy
would force a Terraform change on every new agent — defeating the
registry-driven onboarding story. Prefix scope restricts blast radius
to AgentCore (not Lambda, not Bedrock, not anything outside the service)
while preserving zero-change onboarding.

**Defence in depth.** IAM permits invocation of any runtime in the
account. The **registry** is what the orchestrator actually dispatches
to. An agent not in the registry with `enabled = true` is unreachable
via the orchestrator regardless of IAM. IAM draws the outer wall;
registry draws the inner wall.

**Disallowed pattern.** Do not add per-agent-ARN `Allow` statements to
the orchestrator role. Do not add `Deny` statements either — use the
registry `enabled` flag for per-agent disable.

---

## Middleware vs Strands Tools — The Boundary

| Concern | Goes in | Why |
| --- | --- | --- |
| PII redaction (inbound + outbound) | Container middleware | Must run every request; LLM must never have the option to skip. |
| Audit logging (request + response) | Container middleware + `BackgroundTasks` | Unconditional; non-critical-path. |
| Session load/save | Container middleware (via `S3SessionManager`) | LLM doesn't choose whether state persists. |
| Agent dispatch | Strands tool (`dispatch_agent`) | This **is** the routing decision — the LLM's actual job. |
| Synthesis of sub-agent response | Natural Strands loop behaviour | The LLM receives the tool result and composes the user-facing answer. |
| Refusing unknown domains | Supervisor system prompt + `dispatch_agent` error return | LLM-visible; refusal text is part of the conversational UX. |

**Rule.** If skipping the step would compromise safety or compliance,
it is middleware. If the LLM's judgment is the point, it is a tool.

---

## Known Pitfalls — Carry Forward

Every pitfall documented in
`terraform/dev/agents/hr-assistant-strands/CLAUDE.md` applies to this
layer verbatim because the runtime, networking, and container pattern
are identical. Specifically:

1. **S3 PutObject must be permitted** for `strands-sessions/orchestrator/*`
   on the prompt vault bucket. Add this to the orchestrator role inline —
   do not reuse the platform `agentcore_runtime` role.
2. **Synchronous boto3 calls in `async def` handlers** will time out
   AgentCore health checks. Every `comprehend.detect_pii_entities`,
   `cloudwatch.put_metric_data`, and `logs.put_log_events` call goes
   through `BackgroundTasks` or `asyncio.to_thread`. No exceptions.
3. **CloudWatch `monitoring` VPC endpoint is required** — already present
   in foundation as of commit `69e059b`. Verify before orchestrator apply.
4. **`agent_runtime_name` rejects hyphens** — use
   `replace("-", "_")` on the name string.
5. **AgentCore pre-creates the runtime log group** — import on first apply.
6. **`guardrail_intervened` is not a block** — it only indicates content
   modification unless `topicPolicyResult` is non-empty.

New pitfalls specific to the orchestrator:

7. **`dispatch_agent` must pass a distinct `sessionId` to sub-agents.**
   Do not forward the orchestrator's `session_id` verbatim — derive
   `f"{orchestrator_session}:{sub_agent_id}"` so each sub-agent has an
   isolated history. Reusing the orchestrator's session ID inside a
   sub-agent produces the `Expected toolResult blocks at messages.X.content`
   error documented for Strands.
8. **Comprehend has no VPC endpoint in us-east-2 at time of writing.**
   Orchestrator egress to `comprehend.us-east-2.amazonaws.com` must route
   through the NAT gateway or an explicitly added interface endpoint.
   Verify routing before Phase O.3 container build, or PII calls will hang.
9. **Registry cache staleness.** A `disabled = false → true` flip
   takes up to the cache TTL (60s) to propagate. This is acceptable for
   normal operation but must be documented in the operator runbook.

---

## Teardown

Destroy order (reverse of apply):

```bash
cd terraform/dev/agents/orchestrator     && terraform destroy -auto-approve
cd terraform/dev/agents/stub-agent       && terraform destroy -auto-approve
# hr-assistant-strands, hr-assistant, tools/glean, platform, foundation unchanged
```

Manual cleanup after orchestrator destroy:

- `orchestrator-dev` and `stub-agent-dev` items in agent registry (same
  pattern as existing agents — `terraform_data` provisioners do not have
  `when = destroy` handlers).
- S3 objects under `strands-sessions/orchestrator/` and the orchestrator
  prompt vault prefix.
- CloudWatch log groups (both runtime and audit) are retained by default.
  Force-delete if purging the environment.

---

## Environment Variables — Orchestrator Container

| Variable | Source | Notes |
| --- | --- | --- |
| `AGENT_ENV` | tfvars | `dev` in this environment. |
| `AWS_REGION` | tfvars | `us-east-2`. |
| `BEDROCK_MODEL_ID` | tfvars | `us.anthropic.claude-sonnet-4-6`. Mandatory `us.*` prefix. |
| `GUARDRAIL_ID` | Orchestrator guardrail resource | Own guardrail, not HR's. |
| `GUARDRAIL_VERSION` | tfvars | `DRAFT` in dev. |
| `AGENT_REGISTRY_TABLE` | platform remote state | Scan source. |
| `SESSION_MEMORY_TABLE` | platform remote state | Orchestrator's own conversation state. |
| `PROMPT_VAULT_BUCKET` | platform remote state | For `S3SessionManager`. |
| `AUDIT_LOG_GROUP` | This layer | `/ai-platform/orchestrator/audit-dev`. |
| `REGISTRY_CACHE_TTL_SECONDS` | tfvars | Default `60`. |
| `LOG_LEVEL` | tfvars | `INFO`. |
| `LOG_FORMAT` | tfvars | `json`. |

---

## Open Questions — Defer Until Implementation Surfaces Them

These are deliberately unresolved in this spec. They become answerable
once a working orchestrator exists:

- **Response streaming.** The AWS pattern supports streaming responses
  from supervisor → client. Single-dispatch (D2) returns after one
  sub-agent call — is the extra complexity of streaming worth it in dev?
  Revisit in the parallel-fan-out increment.
- **Supervisor model choice.** Phase O.3 uses Sonnet 4.6 (same as
  sub-agents). Haiku 4.5 might be adequate for the routing decision and
  save cost. Evaluate after initial traffic data is available.
- **Cognito / JWT auth layer.** Deferred per D7. The AWS reference
  architecture puts Cognito in front of the supervisor. Add when the
  first non-operator consumer is identified.
- **Error-path UX for sub-agent failures.** Current design: supervisor
  composes a generic failure message. Operators may want a richer surface
  (retry button, "try X instead" suggestions) — TBD once failure modes
  are observable in real traffic.
- **OTEL collector adoption.** Phase O ships `trace_id` in logs only. A
  future increment adds an OTEL collector (or X-Ray / Tempo) for
  first-class distributed tracing UX. Revisit once log-based correlation
  proves insufficient.
