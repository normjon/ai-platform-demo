# CLAUDE.md — HR Assistant Agent Layer

**Scope:** `terraform/dev/agents/hr-assistant/` only.
This is level 3 of the three-level CLAUDE.md hierarchy (ADR-021).
Read the project-root CLAUDE.md and the architecture document before reading this file.

---

## What This Layer Owns

The HR Assistant agent layer is the ownership boundary for the HR Assistant team.
It provisions everything specific to this agent and nothing else:

- Bedrock Prompt (system prompt)
- Bedrock Guardrail (topic policies, content filters, PII)
- HR Policies Knowledge Base (OpenSearch Serverless + Bedrock KB + 8 HR policy docs)
- Agent manifest (DynamoDB registry entry via local-exec)
- Prompt Vault Lambda (write path to S3)
- Agent container build and push instructions (container is deployed via platform layer)

It does NOT own: VPC, KMS, ECR, AgentCore runtime, MCP Gateway, S3 buckets, DynamoDB tables
for session memory or agent registry. Those are platform layer resources consumed via
`terraform_remote_state`.

---

## Pre-Flight Checklist

Do not run `terraform apply` in this layer until all of the following are true.
Each prerequisite has caused apply failures when skipped.

### 1. Foundation layer applied
VPC, subnets, KMS key, and ECR repository must exist.

### 2. Platform layer applied with correct VPC endpoints
The platform layer must be applied with all required VPC endpoints
before this layer will function correctly. Refer to the platform layer
README at terraform/dev/platform/README.md for the authoritative list
of required endpoints and the security group prefix list requirements.

The symptom of a missing endpoint or incorrect security group rule is
`dial tcp 3.x.x.x:443: i/o timeout` in the AgentCore runtime
CloudWatch log group. See the Troubleshooting Guide below for diagnosis.

### 3. Platform IAM role has complete permissions
The `agentcore_runtime` IAM role must have the complete permission set
defined in the platform layer. Refer to terraform/dev/platform/README.md
for the authoritative permission list. If the agent returns 502 errors
with AccessDeniedException in CloudWatch logs, the fix is in the
platform layer — not this layer.

### 4. Container image pushed to ECR
The platform layer's `agent_image_uri` in `terraform.tfvars` must point to a pushed image.
See "Container Build" below.

---

## Container Build

**Always build for arm64/Graviton (ADR-004). The AgentCore runtime is Graviton-based.**

```bash
cd terraform/dev/agents/hr-assistant/container

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com/ai-platform-hr-assistant"
GIT_SHA=$(git rev-parse --short HEAD)

# Step 1: authenticate to public ECR first (base image source)
aws ecr-public get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin public.ecr.aws

# Step 2: authenticate to private ECR (push destination)
aws ecr get-login-password --region us-east-2 | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com"

# Step 3: build for arm64 explicitly
docker build --platform linux/arm64 \
  -t "${ECR_URI}:${GIT_SHA}" \
  .

# Step 4: push
docker push "${ECR_URI}:${GIT_SHA}"
```

After pushing, update `agent_image_uri` in `terraform/dev/platform/terraform.tfvars`
and re-apply the platform layer.

### Known container build pitfalls

**DO NOT use `--log-config /dev/null` in uvicorn CMD.**
uvicorn 0.32.1 calls `logging.config.fileConfig()` on the path — if the file is empty
(which `/dev/null` is) it raises `RuntimeError: /dev/null is an empty file`. The container
crashes at startup with no useful log message. Use `--no-access-log --log-level warning`.

**DO NOT omit `--only-binary=:all:` when installing Python deps.**
The Dockerfile uses `uv pip install --python-platform aarch64-manylinux2014` to cross-compile
deps for arm64. Without `--only-binary=:all:`, packages with C extensions build for the host
arch (x86) and silently crash at runtime on Graviton. This failure is invisible until the
agent is invoked — it does not surface during docker build.

**Authenticate to public.ecr.aws BEFORE private ECR.**
Docker credential helpers can override each other. Public ECR auth (`--region us-east-1`)
must be done first so private ECR auth (`--region us-east-2`) is the final state.

---

## Bedrock Model ID

Claude 4.x models require the **cross-region inference profile prefix** for on-demand
throughput. The bare model ID fails with:
`"Invocation of model ID anthropic.claude-sonnet-4-6 with on-demand throughput isn't supported"`

Correct value for all variables, DynamoDB manifest items, and application code:

```
us.anthropic.claude-sonnet-4-6
```

The IAM `bedrock:InvokeModel` resource list must include BOTH:
```
arn:aws:bedrock:REGION:ACCOUNT:inference-profile/*
arn:aws:bedrock:*::foundation-model/*
```

The `inference-profile/*` is required for the `us.*` prefix model IDs. Without it,
the runtime receives `AccessDeniedException` even though the InvokeModel action is allowed.

---

## HR Policies Knowledge Base

### Apply sequence

The KB depends on four resources that must exist in order:

```
AOSS security policies → AOSS access policy → AOSS collection (9 min)
  → null_resource (create vector index, 60s sleep + opensearch-py call)
    → aws_bedrockagent_knowledge_base
      → aws_bedrockagent_data_source
```

The `null_resource` is not optional. **Bedrock KB does not auto-create the OpenSearch
vector index.** If the index does not exist before `aws_bedrockagent_knowledge_base`
is applied, Bedrock returns:
`ValidationException: no such index [hr-policies-index]`

### AOSS data access policy principal

Use `data.aws_iam_session_context.current.issuer_arn` — NOT `data.aws_caller_identity.current.arn`.

The difference matters for SSO users:
- `aws_caller_identity.arn` returns the STS session ARN: `arn:aws:sts::ACCOUNT:assumed-role/ROLE/SESSION`
  This changes every time the SSO token refreshes. The AOSS policy match fails after refresh.
- `aws_iam_session_context.issuer_arn` returns the stable IAM role ARN:
  `arn:aws:iam::ACCOUNT:role/aws-reserved/sso.amazonaws.com/REGION/ROLE`
  This is stable across refreshes.

If the null_resource script gets HTTP 403 from OpenSearch Serverless, the data access
policy principal is the first thing to check.

### AOSS propagation delay

AOSS data access policy changes take up to 60 seconds to propagate. The null_resource
local-exec includes `sleep 60` before the index creation script. Do not remove this sleep.
Running the script immediately after `aws_opensearchserverless_access_policy` apply
results in 403 Forbidden even when the policy is correct.

### KB IAM role: KMS Decrypt is mandatory

The document landing S3 bucket is KMS-encrypted with the platform KMS key. The KB
service role (`hr-policies-kb-role-dev`) must have `kms:Decrypt` and `kms:GenerateDataKey`
for the platform KMS key ARN, or ingestion fails with:
`User: .../hr-policies-kb-role-dev/DocumentLoaderTask-... is not authorized to perform: kms:Decrypt`
All 8 documents will fail. The ingestion job will report COMPLETE with numberOfDocumentsFailed=8.

### Trigger ingestion after every apply

Terraform does not trigger KB ingestion automatically. Run after each apply:

```bash
KB_ID=$(terraform output -raw knowledge_base_id)
DS_ID=$(terraform output -raw knowledge_base_data_source_id)

JOB_ID=$(aws bedrock-agent start-ingestion-job \
  --knowledge-base-id "${KB_ID}" \
  --data-source-id "${DS_ID}" \
  --region us-east-2 \
  --query 'ingestionJob.ingestionJobId' --output text)

# Poll until COMPLETE (usually < 30 seconds for 8 small documents)
aws bedrock-agent get-ingestion-job \
  --knowledge-base-id "${KB_ID}" \
  --data-source-id "${DS_ID}" \
  --ingestion-job-id "${JOB_ID}" \
  --region us-east-2 \
  --query 'ingestionJob.{status:status,stats:statistics}'
```

If `numberOfDocumentsFailed > 0`, check `failureReasons` in the response — it will contain
the exact AWS error message (e.g., KMS AccessDenied, S3 NoSuchKey).

---

## AgentCore Runtime: Invocation

### Correct runtime ARN format

```
arn:aws:bedrock-agentcore:REGION:ACCOUNT:runtime/<runtime-id>
```

NOT `agent-runtime` — that path returns ResourceNotFoundException.
The runtime-id comes from `terraform output -raw agentcore_endpoint_id` in the platform layer.

Confirm the correct ARN at any time:
```bash
aws bedrock-agentcore-control get-agent-runtime \
  --agent-runtime-id "$(cd ../../platform && terraform output -raw agentcore_endpoint_id)" \
  --region us-east-2 \
  --query 'agentRuntimeArn' --output text
```

### Session ID in payload — not in CLI flag

`--runtime-session-id` is used by the AgentCore control plane for routing and billing
tracking. It is NOT forwarded to the container as the `X-Amzn-Bedrock-AgentCore-Session-Id`
header. If you rely on `--runtime-session-id` for session isolation, the container will
fall back to its default session ID and contaminate session memory across invocations.

Always include `sessionId` in the JSON payload body:

```bash
RUNTIME_ARN="arn:aws:bedrock-agentcore:us-east-2:ACCOUNT:runtime/RUNTIME_ID"
SESSION_ID="my-session-$(uuidgen | tr '[:upper:]' '[:lower:]')"

PAYLOAD=$(python3 -c "
import json, base64
print(base64.b64encode(json.dumps({
    'prompt': 'How many days of annual leave am I entitled to?',
    'sessionId': '${SESSION_ID}'
}).encode()).decode())
")

aws bedrock-agentcore invoke-agent-runtime \
  --region us-east-2 \
  --agent-runtime-arn "${RUNTIME_ARN}" \
  --runtime-session-id "${SESSION_ID}" \
  --payload "${PAYLOAD}" \
  /tmp/response.json

python3 -c "import json; print(json.load(open('/tmp/response.json'))['response'])"
```

`--runtime-session-id` must be >= 33 characters. UUID-based IDs satisfy this.
The payload must be base64-encoded.

### CloudWatch log group path

```
/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT
```

NOT `/aws/agentcore/<name>` — that path does not exist. If you see no logs after
a 502 error, check the log group name first.

```bash
RUNTIME_ID=$(cd ../../platform && terraform output -raw agentcore_endpoint_id)
LOG_GROUP="/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT"

aws logs filter-log-events \
  --log-group-name "${LOG_GROUP}" \
  --region us-east-2 \
  --start-time $(python3 -c "import time; print(int((time.time()-600)*1000))") \
  --query 'events[*].message' --output text | tr '\t' '\n'
```

> **Note:** Symptoms involving VPC endpoints, security groups, IAM
> permissions on the AgentCore runtime role, or ECR image pull failures
> require fixes in the platform or foundation layers — not this layer.
> Refer to terraform/dev/platform/README.md for those fixes.

### Container 502 diagnostic checklist

When `invoke-agent-runtime` returns 502 or `RuntimeClientError`:

1. **Check CloudWatch logs first** (correct log group above). The container logs the
   startup sequence including `agent_config_loaded`. If no logs appear, the container
   failed to start — likely missing VPC endpoints or SG rules (see pre-flight checklist).

2. **`dial tcp X.X.X.X:443: i/o timeout` in logs** → missing VPC endpoint.
   IP starting with `3.x.x.x` = S3 or ECR. Add the missing endpoint.
   IP starting with internal RFC-1918 range = SG is blocking interface endpoint ENI traffic.

3. **`AccessDenied` or `UnauthorizedAccess` in logs** → IAM. Compare the failing action
   against the pre-flight checklist above.

4. **`RuntimeError: /dev/null is an empty file`** → uvicorn was started with
   `--log-config /dev/null`. Rebuild container with `--no-access-log --log-level warning`.

5. **`ValidationException: model ID with on-demand throughput isn't supported`** →
   model ID is bare (`anthropic.claude-sonnet-4-6`) instead of inference profile
   (`us.anthropic.claude-sonnet-4-6`). Update variables.tf and DynamoDB manifest item.

6. **`Expected toolResult blocks at messages.X.content`** → session history is corrupt.
   A previous invocation ended mid-tool-call (e.g., a 500 error after a `tool_use` response
   was stored in DynamoDB but before the `tool_result` was stored). Use a new session ID.

---

## Terraform State

State key: `dev/agents/hr-assistant/terraform.tfstate`

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

---

## Teardown Notes

```bash
terraform destroy -auto-approve
```

After destroy, the following require manual cleanup:

**DynamoDB agent registry item** — the `terraform_data + local-exec` provisioner
has no `when = destroy` handler. The `hr-assistant-dev` item persists:
```bash
aws dynamodb delete-item \
  --region us-east-2 \
  --table-name ai-platform-dev-agent-registry \
  --key '{"agent_id": {"S": "hr-assistant-dev"}}'
```

**S3 prompt vault objects** — written by smoke tests and live invocations.
Must be purged before destroying the platform layer. See platform README.

**OpenSearch Serverless collection** — takes ~5 minutes to delete. The destroy
will hang during this period; this is normal.

---

## Files in This Layer

```
container/          FastAPI arm64 agent — see container/Dockerfile for build rules
kb-docs/            8 HR policy markdown files uploaded to S3 for KB ingestion
prompts/            System prompt text loaded via file() at plan time
prompt-vault/       Lambda handler for writing interaction records to S3
scripts/            create-os-index.py — pre-creates OpenSearch vector index
test/               Golden dataset (15 test cases)
smoke-test.sh       6 integration tests — run after every apply
main.tf             All resources for this layer
variables.tf        Input variables (model_arn default = us.anthropic.claude-sonnet-4-6)
outputs.tf          knowledge_base_id, knowledge_base_data_source_id, etc.
```
