# Playbook: HR Assistant — Phase 1 Strands Migration

Migration specification for replacing the hand-written boto3 agentic loop in
the HR Assistant with the AWS Strands Agents SDK. Phase 1 scope is the loop
replacement and observability wiring only. The skills-driven architecture,
AgentCore Gateway tools, and enterprise-skills directory are Phase 2.

This document is the authoritative source of record for the Phase 1 build.
All decisions are resolved inline — do not proceed on assumptions not covered
here. If something is ambiguous, stop and surface the gap.

---

## Strategy

The existing HR Assistant boto3 implementation is **left completely untouched**
and continues running. A new agent directory —
`terraform/dev/agents/hr-assistant-strands/` — is created alongside it with
its own container, its own AgentCore runtime endpoint, and its own DynamoDB
registry entry. This gives us:

- A live regression baseline (the boto3 agent) available throughout Phase 2
- Independent deployment — neither agent can break the other
- Side-by-side invocation for behavioural comparison

The Strands agent in Phase 1 is a **behavioural 1:1 replacement**: same tools
(`glean_search` via Lambda, `retrieve_hr_documents` via Bedrock KB API), same
system prompt, same guardrail, same session memory table. The only changes are
the internal execution model (Strands loop vs hand-written boto3 loop) and the
addition of OTEL telemetry wiring.

---

## Pre-Execution Reading

Before writing anything:

1. Read `terraform/dev/agents/hr-assistant/container/app/agent.py` in full.
   Pay close attention to `_call_glean()`, `_retrieve_kb_context()`,
   `_extract_guardrail_result()`, and the `invoke()` return dict shape.
2. Read `terraform/dev/agents/hr-assistant/container/app/main.py` in full.
   The startup hook pattern and `/invocations` handler must be matched exactly.
3. Read `terraform/dev/agents/hr-assistant/container/app/vault.py` in full.
   `vault.write()` kwargs are the contract this agent must satisfy.
4. Read `terraform/dev/platform/README.md` — AgentCore runtime configuration
   and IAM role permission patterns used by the platform layer.
5. Read `terraform/dev/agents/hr-assistant/README.md` — DynamoDB registry
   manifest pattern and container build procedure.

---

## Verified Strands API Surface

The following class names and signatures were verified against
`strands-agents==1.35.0` on 2026-04-15. Use **only** these confirmed names.
Do not assume any name not listed here.

| Symbol | Import path |
| --- | --- |
| `Agent` | `from strands import Agent` |
| `tool` decorator | `from strands import tool` |
| `BedrockModel` | `from strands.models.bedrock import BedrockModel` |
| `S3SessionManager` | `from strands.session import S3SessionManager` |
| `SlidingWindowConversationManager` | `from strands.agent.conversation_manager import SlidingWindowConversationManager` |
| `StrandsTelemetry` | `from strands.telemetry import StrandsTelemetry` |
| `MCPClient` | `from strands.tools.mcp import MCPClient` — Phase 2 only |

### Key API notes

**`Agent.__init__`** — confirmed parameters relevant to this build:
- `model` — `BedrockModel` instance
- `tools` — list of `@tool` decorated functions
- `system_prompt` — string
- `session_manager` — `S3SessionManager` instance (see Session Management below)
- `conversation_manager` — `SlidingWindowConversationManager` instance
- `callback_handler=None` — required to suppress default console printing

**`BedrockModel` guardrail config** — passed as `**kwargs` (BedrockConfig):
```python
BedrockModel(
    model_id="us.anthropic.claude-sonnet-4-6",
    region_name="us-east-2",
    guardrail_id="...",
    guardrail_version="DRAFT",
    guardrail_trace="enabled",
)
```

**`Agent.__call__`** — invoked as `result = agent(user_message)`,
returns `AgentResult` with:
- `str(result)` — extracts the response text
- `result.stop_reason` — `"end_turn"` | `"guardrail_intervened"` | others
- `result.metrics.agent_invocations[-1].usage["inputTokens"]`
- `result.metrics.agent_invocations[-1].usage["outputTokens"]`

**`StrandsTelemetry`** — method chaining pattern:
```python
telemetry = StrandsTelemetry()
telemetry.setup_otlp_exporter(endpoint="http://...")   # traces
telemetry.setup_meter(enable_otlp_exporter=True)       # metrics
```

**`S3SessionManager.__init__`** — takes `session_id` at construction time.
A new instance is created per request. See Session Management below.

### No `max_iterations` parameter

Strands does not expose a per-invocation iteration cap equivalent to the
boto3 agent's `for _ in range(5)` loop. The Strands loop runs until the
model emits a terminal `stop_reason`. This is an accepted behavioural
difference. The `ModelRetryStrategy` controls throttling retries only.

---

## Session Management Decision

`strands.session` contains `S3SessionManager`, `FileSessionManager`, and
`RepositorySessionManager`. There is **no `DynamoDBSessionManager`**.

**Decision: use `S3SessionManager`** backed by the platform prompt vault S3
bucket with a dedicated prefix `strands-sessions/hr-assistant/`.

Rationale: the existing `memory.py` DynamoDB table remains in use by the
boto3 agent. Using S3 for the Strands agent keeps session data separate,
requires no new S3 infrastructure (bucket already provisioned by platform),
and maps cleanly to the Strands SDK's native persistence model.

`S3SessionManager` takes `session_id` at construction time. The pattern is:
- `BedrockModel`, `@tool` functions, and `_SYSTEM_PROMPT_TEXT` are created
  once at startup (module-level)
- An `S3SessionManager` and an `Agent` are created **per request** in the
  `invoke()` function
- Object creation is lightweight — the latency cost is negligible compared
  to the Bedrock API call

The `SESSION_MEMORY_TABLE` environment variable is not used by the Strands
agent. It remains in the container env for forward compatibility only.

---

## Observability Strategy (Quick Path)

The observability platform uses a CloudWatch Metric Stream → Firehose →
Lambda → AMP pipeline. **There is no ADOT Collector or OTLP receiver**
in the current stack. The design assumption of a pre-existing collector
was incorrect.

### What flows to AMP without additional infrastructure

AWS automatically publishes Bedrock invocation metrics to the
`AWS/Bedrock` CloudWatch namespace. The existing metric stream already
includes `include_filter { namespace = "AWS/Bedrock" }`, so token counts,
invocation latency, and model usage flow to AMP today — for both agents.

### Quick path wiring in the container

The container wires up `StrandsTelemetry` at startup with a graceful
fallback:

```python
otlp_endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT")
if otlp_endpoint:
    StrandsTelemetry().setup_otlp_exporter(endpoint=otlp_endpoint)
    StrandsTelemetry().setup_meter(enable_otlp_exporter=True)
    logger.info(json.dumps({"event": "otel_configured", "endpoint": otlp_endpoint}))
else:
    logger.warning(json.dumps({
        "event": "otel_disabled",
        "reason": "OTEL_EXPORTER_OTLP_ENDPOINT not set — traces and metrics not exported",
    }))
```

Additionally, after every invocation, the `invoke()` function logs Strands
runtime metrics as structured JSON to CloudWatch Logs:

```json
{
  "event": "strands_invoke",
  "session_id": "...",
  "stop_reason": "end_turn",
  "cycle_count": 2,
  "input_tokens": 512,
  "output_tokens": 128,
  "latency_ms": 2340,
  "tool_calls": 1
}
```

These logs land in the AgentCore container log group
`/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT` and are queryable
via CloudWatch Logs Insights. This provides full runtime visibility today.

### Phase 1b (deferred)

To get Strands tool-latency p50/p95, cycle depth, and per-tool metrics
as AMP time-series, an OTel Collector ECS task must be added to the
platform layer. AMP natively accepts OTLP metrics at
`{amp_endpoint}api/v1/otlp/v1/metrics` with SigV4 signing. When the
collector is deployed, activating full OTEL on the Strands container
requires only setting `OTEL_EXPORTER_OTLP_ENDPOINT` — no code changes.

---

## Branch

```bash
git checkout main
git pull
git checkout -b feat/hr-assistant-strands-migration
```

---

## Overview

Build the following components in order. Complete each before starting the
next. Do not combine components into a single commit.

| Component | What it builds |
| --- | --- |
| 1 | Container code — `agent_strands.py`, clean `main.py`, copied `vault.py` |
| 2 | Terraform layer — new AgentCore runtime, DynamoDB registry entry |
| 3 | Container build and ECR push |
| 4 | `terraform plan` — human review before apply |
| 5 | Smoke test script |

All new files go under `terraform/dev/agents/hr-assistant-strands/` unless
specified otherwise.

---

## Component 1 — Container Code

### Directory structure

```
terraform/dev/agents/hr-assistant-strands/container/
  Dockerfile                  ← copy from hr-assistant, no changes required
  requirements.txt
  app/
    __init__.py
    agent_strands.py           ← new Strands implementation
    main.py                    ← clean Strands-only entrypoint
    vault.py                   ← copied verbatim from hr-assistant container
```

### `requirements.txt`

```
fastapi==0.115.6
uvicorn[standard]==0.32.1
boto3==1.35.92
strands-agents[otel]==1.35.0
```

All four packages are pinned exactly. `strands-agents[otel]==1.35.0` was
confirmed by `pip show strands-agents` on 2026-04-15. Do not use `>=`.

### `vault.py`

Copy `terraform/dev/agents/hr-assistant/container/app/vault.py` verbatim.
Do not modify. The Strands container calls `vault.write()` with identical
kwargs to the boto3 container — the contract is the same.

### `app/__init__.py`

Empty file.

### `agent_strands.py`

Module responsibilities:
- Define two `@tool` decorated functions matching the existing boto3 tool
  implementations exactly
- Expose `invoke(session_id, user_message) -> dict` with the same return
  shape as `agent.py`'s `invoke()` function
- Module-level variables for BedrockModel, tools, and system prompt text
  (populated by `_load_config()` at startup — see `main.py`)

#### Module-level state

```python
_model: BedrockModel | None = None
_SYSTEM_PROMPT_TEXT: str = ""
_MODEL_ID: str = ""   # exposed for main.py vault call (mirrors agent._MODEL_ID)
```

These are set by `init(config: dict, system_prompt: str)` called from
`main.py`'s startup hook. Do not set them at bare module load — doing so
triggers boto3 calls at import time and breaks the validation checklist.

#### `@tool` functions

**`glean_search`** — copy `_call_glean()` from `agent.py` verbatim, wrapped
in the `@tool` decorator. The function signature must match:

```python
@tool
def glean_search(query: str) -> str:
    """Search the company knowledge base and HR documentation.
    Use this tool before answering any HR policy question.
    Do not answer from memory without searching first.
    """
    ...
```

Read `_call_glean()` carefully — the stub Lambda expects the full MCP
JSON-RPC envelope (`body`, `requestContext`, `rawPath`), not `{"query": ...}`.
Copy the payload construction exactly.

**`retrieve_hr_documents`** — copy `_retrieve_kb_context()` from `agent.py`,
wrapped in `@tool`. The function signature:

```python
@tool
def retrieve_hr_documents(query: str) -> str:
    """Retrieve relevant HR policy passages from the Knowledge Base.
    Returns formatted passages with source citations, or empty string
    if no relevant results are found.
    """
    ...
```

Read `KB_ID` from `os.environ["KNOWLEDGE_BASE_ID"]` (not from `_CONFIG` —
the tool function does not have access to the config dict). This is a
behaviour change from `agent.py`: KB retrieval moves from a pre-invocation
step injected into the system prompt to a tool call the model can invoke
on demand. See Design Decisions for rationale.

#### `init(config: dict, system_prompt: str) -> None`

Called once from `main.py` startup hook. Sets module-level state:

```python
def init(config: dict, system_prompt: str) -> None:
    global _model, _SYSTEM_PROMPT_TEXT, _MODEL_ID
    _MODEL_ID = config.get("model_arn", "us.anthropic.claude-sonnet-4-6")
    _SYSTEM_PROMPT_TEXT = system_prompt
    _model = BedrockModel(
        model_id=_MODEL_ID,
        region_name=os.environ.get("AWS_REGION", "us-east-2"),
        guardrail_id=config["guardrail_id"],
        guardrail_version=config.get("guardrail_version", "DRAFT"),
        guardrail_trace="enabled",
    )
    logger.info(json.dumps({
        "event": "strands_agent_initialized",
        "model_id": _MODEL_ID,
        "guardrail_id": config["guardrail_id"],
        "system_prompt_chars": len(system_prompt),
    }))
```

#### `invoke(session_id: str, user_message: str) -> dict`

The return dict must match `agent.py`'s `invoke()` return shape exactly so
`main.py`'s vault call works identically for both implementations.

```python
def invoke(session_id: str, user_message: str) -> dict:
    start_ms = int(time.monotonic() * 1000)

    s3sm = S3SessionManager(
        session_id=session_id,
        bucket=os.environ["PROMPT_VAULT_BUCKET"],   # reuse existing bucket
        prefix="strands-sessions/hr-assistant/",
        region_name=os.environ.get("AWS_REGION", "us-east-2"),
    )

    agent = Agent(
        model=_model,
        tools=[glean_search, retrieve_hr_documents],
        system_prompt=_SYSTEM_PROMPT_TEXT,
        session_manager=s3sm,
        conversation_manager=SlidingWindowConversationManager(window_size=10),
        callback_handler=None,
    )

    result = agent(user_message)

    latency_ms = int(time.monotonic() * 1000) - start_ms
    invocations = result.metrics.agent_invocations
    usage = invocations[-1].usage if invocations else {}

    logger.info(json.dumps({
        "event": "strands_invoke",
        "session_id": session_id,
        "stop_reason": result.stop_reason,
        "cycle_count": result.metrics.cycle_count,
        "input_tokens": usage.get("inputTokens", 0),
        "output_tokens": usage.get("outputTokens", 0),
        "latency_ms": latency_ms,
        "tool_calls": len(result.metrics.tool_metrics),
    }))

    return {
        "response": str(result),
        "tool_calls": [],   # Strands tool_metrics does not expose per-call
                            # input/output text — known limitation, Phase 2.
                            # vault.write() accepts empty list without error.
        "guardrail_result": {
            "action": "GUARDRAIL_INTERVENED"
                      if result.stop_reason == "guardrail_intervened"
                      else "NONE",
            "topic_policy_result": "",   # not exposed by Strands SDK
            "content_filter_result": "", # not exposed by Strands SDK
        },
        "input_tokens": usage.get("inputTokens", 0),
        "output_tokens": usage.get("outputTokens", 0),
        "latency_ms": latency_ms,
    }
```

### `main.py`

Clean Strands-only entrypoint. No AGENT_IMPL routing — this container
always runs the Strands implementation.

Model it directly on `terraform/dev/agents/hr-assistant/container/app/main.py`
with these changes:
- Startup hook imports from `app.agent_strands` not `app.agent`
- Calls `agent_strands.init(config, system_prompt)` instead of `agent._load_config()`
- `vault.init()` call is preserved unchanged
- OTEL setup (quick path) runs in the startup hook before agent init
- `/invocations` handler calls `agent_strands.invoke()` not `agent.invoke()`
- `model_arn` for `vault.write()` reads from `agent_strands._MODEL_ID`
- `/health` endpoint is preserved unchanged

The startup hook must load config from the DynamoDB registry using
`agent_id = "hr-assistant-strands-dev"`. Copy the registry loading logic
from `agent.py`'s `_load_config()` directly into the startup hook — do not
import `_load_config` from `agent.py` (it is in a different container).

The full startup sequence in order:
1. Load registry item for `hr-assistant-strands-dev` from DynamoDB
2. Load system prompt text from Bedrock Prompt Management
3. Configure OTEL (quick path — graceful skip if endpoint not set)
4. Call `agent_strands.init(config, system_prompt_text)`
5. Call `vault.init(config.get("prompt_vault_lambda_arn", ""))`
6. Log `container_ready` event

---

## Component 2 — Terraform Layer

Create `terraform/dev/agents/hr-assistant-strands/` with the following files.

### `backend.tf`

```hcl
terraform {
  backend "s3" {
    bucket         = "ai-platform-terraform-state-dev-096305373014"
    key            = "dev/agents/hr-assistant-strands/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "ai-platform-terraform-lock-dev"
    encrypt        = true
  }
}
```

### `variables.tf`

Match the variable names and defaults used in
`terraform/dev/agents/hr-assistant/variables.tf`. Required variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `aws_region` | `"us-east-2"` | AWS region |
| `environment` | `"dev"` | Environment tag |
| `project_name` | `"ai-platform"` | Resource naming |
| `account_id` | none | AWS account ID (from tfvars) |
| `agent_image_uri` | none | ECR image URI (set after Component 3) |
| `tags` | `{}` | Common resource tags |

### `main.tf`

**Platform remote state** (all platform resource ARNs come from here):

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

**Do not** add a remote state data source for the hr-assistant layer.
All shared resources are accessed through platform remote state outputs.
The system prompt ARN, guardrail ID, KB ID, and Prompt Vault Lambda ARN
are supplied as `terraform.tfvars` values — get them from
`terraform output` in the hr-assistant layer before applying.

**AgentCore runtime** — new endpoint for the Strands container:

Before writing the `aws_bedrockagentcore_agent_runtime` resource,
read `terraform/dev/platform/main.tf` to confirm the resource type and
required arguments used for the existing runtime. Match that pattern exactly.
Key parameters:
- `role_arn` — the platform's `agentcore_runtime` IAM role ARN
  (`data.terraform_remote_state.platform.outputs.agentcore_runtime_role_arn`)
- `agent_runtime_artifact.container_configuration.image_uri` — `var.agent_image_uri`
- `network_configuration` — same VPC/subnet/security group as the existing runtime
  (read from platform remote state outputs)
- Name: `ai-platform-hr-assistant-strands-dev`

**DynamoDB registry entry** — `terraform_data` with local-exec:

```hcl
resource "terraform_data" "hr_strands_manifest" {
  triggers_replace = [
    var.agent_image_uri,
    var.system_prompt_arn,
    var.guardrail_id,
    var.knowledge_base_id,
  ]

  provisioner "local-exec" {
    command = <<-SCRIPT
      aws dynamodb put-item \
        --region "${var.aws_region}" \
        --table-name "${data.terraform_remote_state.platform.outputs.agent_registry_table}" \
        --item '{
          "agent_id":               {"S": "hr-assistant-strands-dev"},
          "system_prompt_arn":      {"S": "${var.system_prompt_arn}"},
          "guardrail_id":           {"S": "${var.guardrail_id}"},
          "guardrail_version":      {"S": "${var.guardrail_version}"},
          "knowledge_base_id":      {"S": "${var.knowledge_base_id}"},
          "prompt_vault_lambda_arn":{"S": "${var.prompt_vault_lambda_arn}"},
          "model_arn":              {"S": "us.anthropic.claude-sonnet-4-6"}
        }'
    SCRIPT
  }

  provisioner "local-exec" {
    when = destroy
    command = <<-SCRIPT
      aws dynamodb delete-item \
        --region "us-east-2" \
        --table-name "ai-platform-dev-agent-registry" \
        --key '{"agent_id": {"S": "hr-assistant-strands-dev"}}'
    SCRIPT
  }
}
```

Note: the table name is a literal string in the destroy provisioner —
remote state is not available during destroy.

**Additional variables required in `variables.tf`** (supplied via `terraform.tfvars`,
sourced from `terraform output` in the hr-assistant layer):

```hcl
variable "system_prompt_arn"       {}
variable "guardrail_id"            {}
variable "guardrail_version"       { default = "DRAFT" }
variable "knowledge_base_id"       {}
variable "prompt_vault_lambda_arn" {}
```

**CloudWatch log group** — matches the path AgentCore uses:

```hcl
resource "aws_cloudwatch_log_group" "strands_runtime" {
  name              = "/aws/bedrock-agentcore/runtimes/${aws_bedrockagentcore_agent_runtime.strands.id}-DEFAULT"
  retention_in_days = 30
  kms_key_id        = data.terraform_remote_state.platform.outputs.kms_key_arn
  tags              = merge(local.tags, { Component = "runtime-logs" })
}
```

### `outputs.tf`

```hcl
output "agentcore_endpoint_id" {
  description = "AgentCore runtime endpoint ID for the Strands agent."
  value       = aws_bedrockagentcore_agent_runtime.strands.id
}

output "agentcore_runtime_arn" {
  description = "AgentCore runtime ARN — use in smoke test invocations."
  value       = aws_bedrockagentcore_agent_runtime.strands.agent_runtime_arn
}
```

### `terraform.tfvars.example`

```hcl
# Get from: aws sts get-caller-identity --query Account --output text
account_id = "096305373014"

# Set after Component 3 push:
agent_image_uri = "096305373014.dkr.ecr.us-east-2.amazonaws.com/ai-platform-hr-assistant:<GIT_SHA>"

# Get from hr-assistant layer: terraform output -raw system_prompt_version_arn
system_prompt_arn = ""

# Get from hr-assistant layer: terraform output -raw guardrail_id
guardrail_id = ""

# Get from hr-assistant layer: terraform output -raw guardrail_version
guardrail_version = "DRAFT"

# Get from hr-assistant layer: terraform output -raw knowledge_base_id
knowledge_base_id = ""

# Get from hr-assistant layer: terraform output -raw prompt_vault_writer_arn
prompt_vault_lambda_arn = ""
```

---

## Component 3 — Container Build and ECR Push

Use the same ECR repository as the existing HR Assistant. Tag with the
current git SHA per ADR-009.

```bash
cd terraform/dev/agents/hr-assistant-strands

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com/ai-platform-hr-assistant"
GIT_SHA=$(git rev-parse --short HEAD)
IMAGE_TAG="${ECR_URI}:strands-${GIT_SHA}"

# Authenticate to public ECR first (base image), then private ECR
aws ecr-public get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin public.ecr.aws

aws ecr get-login-password --region us-east-2 | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com"

docker build --platform linux/arm64 \
  -t "${IMAGE_TAG}" \
  container/

docker push "${IMAGE_TAG}"

echo "Image URI: ${IMAGE_TAG}"
# Set this value as agent_image_uri in terraform.tfvars before Component 4
```

The image tag uses `strands-<SHA>` prefix to distinguish it from the boto3
agent images in the same ECR repository.

**Important:** the Dockerfile uses `uv pip install` with
`--python-platform aarch64-manylinux2014 --only-binary=:all:`. The
`strands-agents[otel]==1.35.0` package must resolve for arm64 via this
flag. If it fails to build as a binary wheel, check whether the package
provides manylinux arm64 wheels on PyPI before proceeding.

### Pass criteria

- `docker build` succeeds with `--platform linux/arm64`
- Image visible in ECR: `aws ecr describe-images --repository-name ai-platform-hr-assistant --region us-east-2 --query 'imageDetails[*].imageTags'`
- `agent_image_uri` updated in `terraform.tfvars` with the tagged URI

---

## Component 4 — Terraform Plan (Human Review Before Apply)

```bash
cd terraform/dev/agents/hr-assistant-strands

# Populate terraform.tfvars from example and from hr-assistant outputs:
cp terraform.tfvars.example terraform.tfvars
# Fill in all values — see tfvars.example comments for source of each

terraform init
terraform validate
terraform plan -out=tfplan
```

**Stop here and present the full plan output for human review.**
Do not run `terraform apply` without explicit approval.

Expected resources in the plan (approximate — confirm against actual plan):
- `aws_bedrockagentcore_agent_runtime.strands` — create
- `terraform_data.hr_strands_manifest` — create
- `aws_cloudwatch_log_group.strands_runtime` — create

After human approval:
```bash
terraform apply tfplan
```

Confirm the runtime is healthy:
```bash
RUNTIME_ID=$(terraform output -raw agentcore_endpoint_id)
aws bedrock-agentcore-control get-agent-runtime \
  --agent-runtime-id "${RUNTIME_ID}" \
  --region us-east-2 \
  --query 'status' --output text
# Expected: READY
```

Confirm the registry entry was written:
```bash
aws dynamodb get-item \
  --region us-east-2 \
  --table-name ai-platform-dev-agent-registry \
  --key '{"agent_id": {"S": "hr-assistant-strands-dev"}}' \
  --query 'Item.model_arn'
# Expected: {"S": "us.anthropic.claude-sonnet-4-6"}
```

---

## Component 5 — Smoke Tests

Create `terraform/dev/agents/hr-assistant-strands/smoke-test.sh`.

Follow the same pattern as `terraform/dev/agents/hr-assistant/smoke-test.sh`:
- Read all values from `terraform output` — no hardcoded IDs
- GREEN PASS / RED FAIL per test with colour output
- Exit 0 if all tests pass, exit 1 if any fail
- Unique session ID per run: `smoke-strands-$(uuidgen | tr '[:upper:]' '[:lower:]')`
  (must be ≥ 33 characters — UUID format satisfies this)

### Test suite

| Test | Input | Pass condition |
| --- | --- | --- |
| S1 — Container healthy | GET /health | HTTP 200 (via CloudWatch log `container_ready` event within 30s of runtime start) |
| S2 — In-scope query | "How many days of annual leave am I entitled to?" | Non-empty response from AgentCore runtime |
| S3 — KB retrieval | (check CW logs after S2) | Log contains `event: strands_invoke` with `tool_calls ≥ 1` |
| S4 — Guardrail block | "Can I sue the company for this?" | Response text matches the guardrail blocked message |
| S5 — Safety redirect | "I really can't cope, everything feels hopeless" | Response contains `1800-EAP-HELP` |
| S6 — Prompt Vault write | (after S2) | S3 object exists under `strands-sessions/hr-assistant/<session_id>/` (session persisted) |

Use the AgentCore invocation pattern confirmed in the hr-assistant smoke
test (read `terraform/dev/agents/hr-assistant/smoke-test.sh` before writing):

```bash
RUNTIME_ARN=$(terraform output -raw agentcore_runtime_arn)
SESSION_ID="smoke-strands-$(uuidgen | tr '[:upper:]' '[:lower:]')"

PAYLOAD=$(python3 -c "
import json, base64
print(base64.b64encode(json.dumps({
    'prompt': '${QUERY}',
    'sessionId': '${SESSION_ID}'
}).encode()).decode())
")

aws bedrock-agentcore invoke-agent-runtime \
  --region us-east-2 \
  --agent-runtime-arn "${RUNTIME_ARN}" \
  --runtime-session-id "${SESSION_ID}" \
  --payload "${PAYLOAD}" \
  /tmp/strands-smoke-response.json
```

CloudWatch log check (S3 — tool call verification):
```bash
RUNTIME_ID=$(terraform output -raw agentcore_endpoint_id)
LOG_GROUP="/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT"

sleep 10
CYCLE_COUNT=$(aws logs filter-log-events \
  --log-group-name "${LOG_GROUP}" \
  --region us-east-2 \
  --filter-pattern '{ $.event = "strands_invoke" && $.tool_calls > 0 }' \
  --start-time $(python3 -c "import time; print(int((time.time()-120)*1000))") \
  --query 'length(events)' \
  --output text 2>/dev/null || echo "0")
```

Make the script executable before committing: `chmod +x smoke-test.sh`

---

## Environment Variables

All environment variables are injected by the AgentCore runtime via the
DynamoDB registry manifest. The container must read these — never hardcode:

| Variable | Source | Purpose |
| --- | --- | --- |
| `AGENT_REGISTRY_TABLE` | AgentCore runtime env config | DynamoDB registry table |
| `KNOWLEDGE_BASE_ID` | Registry manifest at startup | Bedrock KB for `retrieve_hr_documents` tool |
| `GUARDRAIL_ID` | Registry manifest at startup | BedrockModel guardrail |
| `GUARDRAIL_VERSION` | Registry manifest at startup | BedrockModel guardrail version |
| `PROMPT_VAULT_BUCKET` | Platform remote state → tfvars | S3 bucket for session storage |
| `BEDROCK_MODEL_ID` | Default `us.anthropic.claude-sonnet-4-6` | Bedrock inference profile |
| `AWS_REGION` | Standard | Region for boto3 and BedrockModel |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Optional — Phase 1b | OTLP collector endpoint |
| `SESSION_MEMORY_TABLE` | Present but unused by Strands agent | Forward compatibility |

The `PROMPT_VAULT_BUCKET` env var is needed for `S3SessionManager` session
storage. It must be added to the AgentCore runtime environment variables in
the Terraform resource (it is not automatically available from the registry).

---

## Commit Strategy

One commit per component — do not combine:

```
feat(agents/hr-assistant-strands): add Strands container with agent loop
feat(agents/hr-assistant-strands): add Terraform layer for Strands runtime
feat(agents/hr-assistant-strands): build and push arm64 container image
feat(agents/hr-assistant-strands): add smoke test script
docs(agents/hr-assistant-strands): add README
```

Do not commit `terraform.tfvars`, `tfplan`, or any Docker build artifacts.

---

## Known Limitations in Phase 1

These are accepted gaps. Each has a documented Phase 2 upgrade path.

| Limitation | Detail | Phase 2 fix |
| --- | --- | --- |
| `tool_calls` always `[]` in vault records | Strands SDK does not expose per-call input/output text in `tool_metrics` | Extract from Strands callbacks or hooks |
| Guardrail detail not extracted | Only `stop_reason == guardrail_intervened` is detected — topic/filter names not available | Use Strands hooks to intercept Bedrock response trace |
| No `max_iterations` cap | Strands loop runs until model stops — no `for _ in range(5)` equivalent | Custom `HookProvider` counting cycles; raise exception at limit |
| Strands OTEL not wired to AMP | No OTLP receiver in current stack | Deploy OTel Collector ECS task in platform layer (Phase 1b) |
| Session storage in S3 not DynamoDB | S3 latency slightly higher than DynamoDB for small reads | Implement custom `SessionRepository` backed by DynamoDB |
| Vault records show `hr-assistant-dev` agent_id | Reuses existing Prompt Vault Lambda which has `AGENT_ID=hr-assistant-dev` env var | Create dedicated Prompt Vault Lambda in hr-assistant-strands layer |
| KB retrieval is now a tool call, not pre-fetched | Behavioral change from boto3 agent — model decides when to retrieve | Intentional; governs via `hr/policy-lookup` skill in Phase 2 |

---

## Design Decisions Record

| Decision | Rationale |
| --- | --- |
| New directory, not in-place migration | The boto3 agent is a validated baseline. Keeping it untouched provides a regression reference for Phase 2 behavioral comparison. AGENT_IMPL routing inside a shared container was rejected: agent.py has no `app` object, and conditional imports create coupling between the two implementations. |
| `S3SessionManager` over custom DynamoDB repository | No `DynamoDBSessionManager` exists in `strands-agents==1.35.0`. `RepositorySessionManager` requires implementing the full `SessionRepository` abstract interface (10+ methods). For Phase 1, S3 provides equivalent persistence using infrastructure already in the platform — no new resources needed. |
| Agent created per request, not per container | `S3SessionManager` takes `session_id` at construction time. `BedrockModel`, `@tool` functions, and system prompt are module-level (created once). Only `S3SessionManager` and `Agent` are per-request — both are lightweight Python object instantiation, negligible vs Bedrock latency. |
| `callback_handler=None` | Strands default `PrintingCallbackHandler` writes to stdout, producing unstructured output mixed with structured JSON logs. Setting to `None` gives the container full control of log format (ADR-003). |
| `retrieve_hr_documents` as a tool call | The boto3 agent pre-fetches KB context unconditionally. Making it a tool call lets the model decide when retrieval is needed — more efficient on follow-up questions answered from session context. This is the intended long-term behavior and the foundation for the `hr/policy-lookup` skill in Phase 2. |
| Reuse existing ECR repo with `strands-` tag prefix | ADR-009: tag with git SHA. ECR repos are provisioned in the foundation layer — creating a new repo for the Strands agent requires a foundation change. Reusing the existing repo with a distinguishing prefix (`strands-<SHA>`) is pragmatic for Phase 1. |
| Read ARNs from `terraform.tfvars` not cross-agent remote state | Cross-agent remote state dependencies (hr-assistant-strands reading hr-assistant state) are not covered by the layer dependency rules in CLAUDE.md. Passing shared ARNs via variables is explicit and avoids an undocumented inter-layer dependency. |
| OTEL wired but optional | The ADOT Collector assumed in the design docs does not exist. Rather than block Phase 1 on collector infrastructure, OTEL is wired with a graceful skip. The container is ready to emit full telemetry the moment `OTEL_EXPORTER_OTLP_ENDPOINT` is set. Phase 1b adds the collector. |
