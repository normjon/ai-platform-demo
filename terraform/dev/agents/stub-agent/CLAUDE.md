# CLAUDE.md — Stub Agent Layer

**Scope:** `terraform/dev/agents/stub-agent/` only.
Level 3 of the three-level CLAUDE.md hierarchy (ADR-021). Read the project-root
CLAUDE.md and `terraform/dev/agents/orchestrator/CLAUDE.md` first. Patterns
documented there are not repeated here.

Authoritative plan: `specs/orchestrator-plan.md` Phase O.4.

---

## Purpose

A second sub-agent exists solely to prove registry-driven dispatch routes
correctly to more than one tenant. With `hr-assistant-strands-dev` as the only
enabled entry, the orchestrator has one option — "routing" is indistinguishable
from "dispatch to the only agent." This layer is the thing that earns the
orchestrator its keep.

The container is a deterministic echo: given `{"prompt": "Hello"}` it returns
`{"response": "[stub-agent] received: Hello"}`. No LLM, no Bedrock, no guardrail,
no Strands, no session manager — dispatch assertions stay flake-free.

---

## What This Layer Owns

- `aws_ecr_repository.stub` — `ai-platform-dev-stub-agent` image repo (own, not shared)
- `aws_iam_role.stub_runtime` + inline policy — minimal (ECR pull, CloudWatch logs/metrics, KMS decrypt, workload identity, direct-write app log group)
- `aws_bedrockagentcore_agent_runtime.stub` — count-gated on `agent_image_uri`
- `aws_cloudwatch_log_group.stub_app` (`/ai-platform/stub-agent/app-dev`) — destination for the container's direct-write CloudWatch handler (see project-root CLAUDE.md "Application logs via direct-write CloudWatch handler")
- `aws_cloudwatch_log_group.stub_runtime` — count-gated; may need import (Pitfall 5)
- `terraform_data.stub_manifest` — registry entry for `stub-agent-dev` with `domains=["test.echo"]`

It does NOT own: VPC, KMS, guardrail, KB, Bedrock model, session memory table,
agent registry table, prompt vault bucket.

---

## Two-Step Apply Model

### Apply 1 — scaffold ECR + IAM

`agent_image_uri = ""` in `terraform.tfvars`. Creates ECR repo and IAM role; no
runtime, no registry entry.

```bash
cd terraform/dev/agents/stub-agent
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### Apply 2 — push container, enable runtime

See Container Build below. Set `agent_image_uri = "...:stub-<SHA>"` in
`terraform.tfvars` and re-apply.

---

## Container Build

Always build for arm64/Graviton (ADR-004).

```bash
cd terraform/dev/agents/stub-agent/container

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com/ai-platform-dev-stub-agent"
GIT_SHA=$(git rev-parse --short HEAD)

aws ecr-public get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin public.ecr.aws

aws ecr get-login-password --region us-east-2 | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com"

docker build --platform linux/arm64 -t "${ECR_URI}:stub-${GIT_SHA}" .
docker push "${ECR_URI}:stub-${GIT_SHA}"
```

---

## Registry Entry

```json
{
  "agent_id":     {"S":  "stub-agent-dev"},
  "runtime_arn":  {"S":  "arn:aws:bedrock-agentcore:us-east-2:<acct>:runtime/<id>"},
  "domains":      {"SS": ["test.echo"]},
  "tier":         {"S":  "workflow"},
  "enabled":      {"BOOL": true},
  "owner_team":   {"S":  "platform"}
}
```

The orchestrator refreshes its registry cache on a 60s TTL. After applying this
layer, the orchestrator picks up `test.echo` on the next cache miss — no
orchestrator redeploy required. That's the test.

---

## Smoke Tests

`smoke-test.sh` runs two tests against the direct runtime:

- **S1** — invoke with `{"prompt": "Hello from smoke test"}` and assert the
  response contains `[stub-agent] received: Hello from smoke test`.
- **S2** — **application** log group (`/ai-platform/stub-agent/app-dev`)
  contains a `stub_invoke` event. NOT the runtime log group — the AgentCore
  stdout sidecar silently drops events, so the container writes direct via
  `app/log_handler.py`. See project-root CLAUDE.md "Application logs via
  direct-write CloudWatch handler" for the authoritative pattern.

The orchestrator-side dispatch assertion (Phase O.5.b) lives in the orchestrator
layer's `smoke-test.sh`. Keeping the two layers' smoke tests independent avoids
circular dependencies.

---

## Known Pitfalls

All pitfalls from `hr-assistant-strands/CLAUDE.md` apply (arm64 packaging,
log-group pre-creation, runtime name underscore rule). Stub-agent-specific:

### No guardrail is intentional

The orchestrator's front-door guardrail runs before dispatch. Adding a stub
guardrail would duplicate that work and introduce flakiness in the echo
assertion. Sub-agents that do real work (like `hr-assistant-strands-dev`)
still have their own guardrails — the stub is the exception because its
output is trivially safe by construction.

### No Bedrock permissions in the IAM role

The role grants CloudWatch + ECR + KMS + workload-identity only. If the
container ever needs Bedrock, Comprehend, DynamoDB, or S3, add the statement
here — don't reuse the platform `agentcore_runtime` role. Per ADR-017, IAM
belongs inline in the layer that owns the resource.

---

## Teardown

```bash
terraform destroy -auto-approve
```

The `when = destroy` provisioner on `terraform_data.stub_manifest` removes the
registry item. ECR images must be purged manually before the repository can be
destroyed:

```bash
aws ecr batch-delete-image \
  --region us-east-2 \
  --repository-name ai-platform-dev-stub-agent \
  --image-ids imageTag=stub-<SHA>
```

---

## Files in This Layer

```
backend.tf                Remote state backend
main.tf                   ECR + IAM + runtime (count-gated) + log group + manifest
variables.tf              Input variables
outputs.tf                ECR URL, IAM role ARN, runtime endpoint/ARN
terraform.tfvars.example  Template (copy to terraform.tfvars)
smoke-test.sh             Tests S1 (direct echo), S2 (log event)
README.md                 Operator runbook
CLAUDE.md                 This file
container/
  Dockerfile              arm64 FastAPI — no Strands, no Bedrock
  requirements.txt        fastapi + uvicorn + boto3 (boto3 for the direct-write log handler)
  app/
    __init__.py
    main.py               Echo handler + health + stub_invoke log; installs log_handler at startup
    log_handler.py        Direct-write CloudWatch handler — bypasses sidecar (reads APP_LOG_GROUP)
```
