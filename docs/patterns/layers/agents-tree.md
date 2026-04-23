# Pattern — Agents Tree

**Scope:** `terraform/<env>/agents/` and all agent sub-layers.

Meta-guide for the whole tree. Per-agent pattern files (e.g.
[agent-hr-assistant.md](agent-hr-assistant.md),
[agent-orchestrator.md](agent-orchestrator.md), etc.) contain the
Level-3 pattern content for each specific agent.

---

## Read Order Before Editing

1. Project-root `CLAUDE.md` — Terraform structure, ADR pointers,
   approved model ARNs.
2. This file — shared rules that apply to every agent layer (runtime
   invocation contract, direct-write log handler, IAM/scaffolding).
3. [../authoring/new-agent.md](../authoring/new-agent.md) — authoring
   guide. Scaffolding, IAM statements by capability, smoke test
   contract, two-step apply.
4. [platform.md](platform.md) → "Agent Onboarding" — registry manifest
   schema. Single source of truth for field definitions.
5. ADR-022 (agent layer pattern) and ADR-023 (container requirements)
   in `docs/adrs/ai-platform/`.
6. The specific `<agent>.md` pattern file for whichever layer you are
   editing.

---

## Hierarchy Position (ADR-021)

This tree contains **Level-3 pattern content** — one pattern file per
agent type. Each documents the exact scaffolding sequence, quality
gates, and known anti-patterns for that agent.

The agents-tree pattern (this file) is the shared meta-guide. It routes
to canonical sources and sets conventions common to all agents. Not a
substitute for any level in the ADR-021 hierarchy.

---

## README vs CLAUDE.md — The Split Rule

Every agent layer (and every tool layer) ships two per-environment
markdown files. They have distinct readers and distinct purposes.

| File | Reader | Answers |
|---|---|---|
| `README.md` | Operator running the layer | **How do I use this?** Apply, smoke test, teardown, resource inventory, operational runbook. Current state, commands, known issues. |
| `CLAUDE.md` | Engineer (or agent) modifying the layer | **How do I change this without breaking it?** Scope, invariants, editing rules, pitfalls that cause non-obvious failures, ADR pointers. Rationale, not recipes. |

**Concrete implications:**

- Resource tables, apply/destroy commands, smoke-test usage → `README.md`.
- "Don't do X because Y will silently fail" → `CLAUDE.md` / pattern file.
- An editing rule that belongs in both? Write it in the pattern file
  and link from the per-env `README.md` — not duplicated, so fixes
  land in one place.
- If a new contributor can't figure out what to edit after reading the
  pattern file + `CLAUDE.md` stub, the pattern is missing rules. If
  they can't figure out how to apply after reading `README.md`, the
  README is missing steps. Both get updated.
- Pattern files stay short — typically under 150 lines per ADR-021. If
  a pattern takes more than 150 lines to describe, it is probably two
  patterns and should be split or promoted to an ADR.

This split is the reason the documentation scales with new agents:
operators learn by reading READMEs; changes are reviewed by reading
pattern files.

---

## Rules That Apply to Every Agent Layer

1. **Inline IAM** (ADR-017 Option B). Never move roles to a shared
   module. Never reuse another agent's role.

2. **Two-step apply.** Runtime resource is `count`-gated on
   `var.agent_image_uri != ""`. First apply creates ECR + IAM; push
   image; second apply lands the runtime and registry entry.

3. **Direct-write CloudWatch log handler.** Mandatory. See *"Direct-write
   CloudWatch log handler"* below for the full contract.

4. **`when = destroy` on the manifest resource.** Required so teardown
   removes the registry item. Without it, the registry drifts from
   Terraform state.

5. **Registry manifest comes from the platform schema.** Never invent
   new fields here. If a field is genuinely needed, add it to the
   platform pattern → "Agent Onboarding" first — the scorer,
   orchestrator, and dashboards all read the registry.

6. **arm64/Graviton** (ADR-004) and **immutable image tags** (ADR-009).

---

## AgentCore Runtime Invocation Contract

These rules apply to any layer that provisions an AgentCore runtime
or invokes a runtime programmatically.

### Runtime ARN format

```
arn:aws:bedrock-agentcore:<region>:<account>:runtime/<runtime-id>
```

`agent-runtime` in the path returns `ResourceNotFoundException`.
Confirm the canonical ARN:

```bash
aws bedrock-agentcore-control get-agent-runtime \
  --agent-runtime-id "<runtime-id>" \
  --region <region> \
  --query 'agentRuntimeArn' --output text
```

### `sessionId` goes in the payload body

`--runtime-session-id` is a control-plane routing/billing identifier.
It is **not** forwarded to the container as the
`X-Amzn-Bedrock-AgentCore-Session-Id` header. Always include
`sessionId` in the JSON payload:

```bash
PAYLOAD=$(python3 -c "import json,base64; print(base64.b64encode(json.dumps({
    'prompt': 'your question',
    'sessionId': '${SESSION_ID}'
}).encode()).decode())")
```

**Unique `sessionId` per invocation.** Reusing a session that has
corrupt history (incomplete `tool_use`/`tool_result` pairs from a
failed invocation) causes
`Expected toolResult blocks at messages.X.content`. The control-plane
minimum length is **33 characters** — UUID-based IDs satisfy this.

### CloudWatch log group path

AgentCore creates and owns:

```
/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT
```

`/aws/agentcore/<name>` does not exist. For **application logs** use
the direct-write handler below — do not attempt to write app events to
the AgentCore-owned runtime log group.

### Runtime log group collision on first apply (import required)

**Symptom.** Step 2 of the two-step apply (the one that creates the
runtime) fails with:

```
Error: creating CloudWatch Logs Log Group
(/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT):
ResourceAlreadyExistsException: The specified log group already exists
```

**Cause.** AgentCore auto-creates the `-DEFAULT` log group the moment
the runtime resource is created. The `aws_cloudwatch_log_group` that
sets retention + KMS on that group races the control plane and loses
every time. This affects **every** agent layer that manages the
runtime log group in Terraform — observed on all three of
`hr-assistant-strands`, `orchestrator`, `stub-agent` in this repo.

**Workaround.** Import the log group, then re-apply. The command
shape differs depending on whether the log-group resource is
`count`-gated:

```bash
# Bare resource (hr-assistant-strands)
terraform import aws_cloudwatch_log_group.<name> \
  "/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT"

# count-gated resource (orchestrator, stub-agent — gated on agent_image_uri)
terraform import 'aws_cloudwatch_log_group.<name>[0]' \
  "/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT"

terraform apply -auto-approve   # re-apply to reconcile retention + KMS
```

One-time cost per agent layer — Terraform owns the group from the
second apply onward. Teardown is unaffected: `terraform destroy`
removes the imported group cleanly.

**Why not remove it from Terraform?** The managed resource sets
retention and the foundation KMS key on the log group. Letting
AgentCore keep it unmanaged means unbounded retention and AWS-owned
encryption — neither is acceptable in this repo.

---

## Direct-Write CloudWatch Log Handler

The AgentCore stdout/stderr capture sidecar silently drops log events
on some runtimes — containers `logger.info(...)`, uvicorn flushes, and
the runtime log group receives zero app events. No error, no warning,
no `[runtime-logs]` stream. Stdout is not a safe diagnostic surface.

**Every agent container must install the direct-write handler.** It
calls `logs:PutLogEvents` from the Python process against a dedicated
application log group, bypassing the sidecar.

Reference implementation:
`terraform/dev/agents/hr-assistant-strands/container/app/log_handler.py`
(env-var version — not the config-module variant).

### Container install

```python
import logging
logging.basicConfig(level=logging.INFO, format="%(message)s")

from app import log_handler
log_handler.install()   # reads APP_LOG_GROUP and AWS_REGION from env
```

When `APP_LOG_GROUP` is unset, `install()` is a no-op so local images
without a log group still run. Any deployed runtime **must** set
`APP_LOG_GROUP`, or diagnostics are invisible.

### Required Terraform wiring

1. **Dedicated application log group.** Separate from the
   AgentCore-managed runtime log group. Naming convention
   `/ai-platform/<agent>/app-<environment>`.

   ```hcl
   resource "aws_cloudwatch_log_group" "<agent>_app" {
     name              = "/ai-platform/<agent>/app-${var.environment}"
     retention_in_days = 30
     kms_key_id        = data.terraform_remote_state.foundation.outputs.storage_kms_key_arn
   }
   ```

2. **IAM grant scoped to the app log group, not the runtime path.**

   ```hcl
   {
     Sid      = "AppLogGroupDirectWrite"
     Effect   = "Allow"
     Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
     Resource = ["${aws_cloudwatch_log_group.<agent>_app.arn}:*"]
   }
   ```

3. **Environment variable on the runtime.**

   ```hcl
   environment_variables = {
     APP_LOG_GROUP = aws_cloudwatch_log_group.<agent>_app.name
   }
   ```

4. **`boto3` in container `requirements.txt`.** The handler calls
   `boto3.client("logs")` directly; it is not transitively provided by
   `fastapi` or `uvicorn`.

### Smoke-test implication

Tests that assert on specific app events (e.g. `stub_invoke`,
`strands_invoke`) must query `APP_LOG_GROUP`. Querying the
AgentCore-managed runtime log group flakes on sidecar-drop and returns
false negatives.

---

## Which Reference Implementation to Start From

| Need | Start from |
|---|---|
| Echo / dispatch target with no LLM | `stub-agent/` — see [agent-stub-agent.md](agent-stub-agent.md) |
| Full self-contained conversational agent (own KB, guardrail, prompt, vault) | `hr-assistant/` — see [agent-hr-assistant.md](agent-hr-assistant.md) |
| Strands SDK variant that reuses another layer's KB/guardrail | `hr-assistant-strands/` — see [agent-hr-assistant-strands.md](agent-hr-assistant-strands.md) |
| Registry-driven dispatcher | `orchestrator/` — see [agent-orchestrator.md](agent-orchestrator.md) |

Copy, rename, re-key backend, re-scope IAM. Do not fork an existing
agent layer to add "a minor tweak" — either extend it via config or
scaffold a new layer.

---

## Skills

Not implemented. Spec at `specs/skills-architecture-plan.md`. Pattern
at [skills.md](skills.md). Do not scaffold skill files inline into an
agent layer until an ADR defines:

- Filesystem layout
- Invocation model (MCP coupling vs. Claude-native skills)
- Versioning and discovery
- Registry representation

Raise the gap if a task requires skills before that ADR exists.

---

## ADR Pointers

| ADR | When it matters |
|---|---|
| ADR-017 | Any IAM change in an agent layer |
| ADR-021 | Before writing or editing any pattern file in this tree |
| ADR-022 | Any new agent layer — the "four components inline" pattern |
| ADR-023 | Any container change — the six container-runtime rules |
