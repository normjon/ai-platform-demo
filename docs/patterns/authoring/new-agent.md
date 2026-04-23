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
- Its own container image (separate ECR repo)
- Its own AgentCore runtime

Do **not** fork an existing layer to add "a slight variant." Either extend
the existing agent via config (system prompt, guardrail, tool list) or
scaffold a fresh layer. Forks drift.

---

## Prerequisites

1. `foundation/` applied in the target environment (VPC, KMS, VPC
   endpoints, ECR state bucket).
2. `platform/` applied and smoke tests pass (`agentcore_endpoint_id`,
   `agent_registry_table`, `opensearch_collection_arn` etc. populated).
3. For agents that use MCP tools: the corresponding `tools/<tool>/` layer
   applied and the gateway target registered.
4. For orchestrator-dispatched sub-agents: at least one sub-agent layer
   must have `enabled = true` in the registry before the orchestrator
   smoke tests will pass.

---

## Layer Scaffold

Minimum file set for a new agent at `terraform/<env>/agents/<name>/`:

```
backend.tf                 # S3 remote state — key: <env>/agents/<name>/terraform.tfstate
main.tf                    # Providers, remote state, ECR, IAM, runtime, log group, manifest
variables.tf               # aws_region, environment, project_name, account_id, agent_image_uri, model_arn, ...
outputs.tf                 # iam_role_arn, ecr_repository_url, agentcore_endpoint_id, agentcore_runtime_arn, app_log_group_name
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
- **Two-step apply**. First apply with `agent_image_uri = ""` to create ECR
  + IAM. Push the container to the new ECR repo. Set `agent_image_uri` to
  the pushed URI and re-apply to land the runtime + registry entry. The
  runtime resource is `count`-gated on `var.agent_image_uri != ""`.
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
| `ECRPullImage` | Always | `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`, `ecr:BatchCheckLayerAvailability` on this agent's ECR repo ARN |
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

Each agent layer teardown is standalone:

```bash
# 1. Purge ECR images (required — repo destruction fails on non-empty repo)
aws ecr list-images --region <region> \
  --repository-name ai-platform-<env>-<name> \
  --query 'imageIds[*]' --output json | \
  aws ecr batch-delete-image --region <region> \
    --repository-name ai-platform-<env>-<name> \
    --image-ids file:///dev/stdin

# 2. Destroy the layer
cd terraform/<env>/agents/<name>
terraform destroy -auto-approve
```

The `when = destroy` provisioner on the manifest resource removes the
registry entry automatically.

Teardown ordering across the tree follows the operations runbook's destroy
sequence: orchestrator → sub-agents → tools → platform → foundation.
See [../../operations.md](../../operations.md#teardown-order).
