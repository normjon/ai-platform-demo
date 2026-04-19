# HR Assistant Strands Agent Layer — `terraform/dev/agents/hr-assistant-strands/`

Parallel HR Assistant implementation using the AWS Strands Agents SDK.
The boto3 implementation in `terraform/dev/agents/hr-assistant/` remains fully
operational alongside this layer as a regression baseline.

---

## Purpose

This layer provisions a second AgentCore runtime endpoint running a Strands SDK
container. Behaviourally it is a 1:1 replacement for the boto3 agent:

- Same tools: `glean_search` (MCP via Lambda) and `retrieve_hr_documents` (Bedrock KB)
- Same system prompt, guardrail, and Knowledge Base (all read from `hr-assistant` layer outputs)
- Same Prompt Vault write path
- Different internal execution model: Strands loop + `S3SessionManager` instead of
  hand-written boto3 `converse()` loop + DynamoDB session table

Phase 1 scope is the loop replacement and observability wiring only.
Skills-driven architecture and AgentCore Gateway MCP tools are Phase 2.

---

## Resources

| Resource | Name | Purpose |
| --- | --- | --- |
| `aws_bedrockagentcore_agent_runtime` | `ai_platform_dev_hr_assistant_strands` | Dedicated Strands runtime endpoint (separate from boto3 runtime) |
| `aws_cloudwatch_log_group` | `/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT` | Imported from AWS-managed group; 90-day retention, KMS encrypted |
| `terraform_data` (local-exec) | — | Registers `hr-assistant-strands-dev` manifest in DynamoDB agent registry |

### Shared Resources (owned by `hr-assistant` layer, read as variables)

| Resource | Where | Used for |
| --- | --- | --- |
| System prompt ARN | `terraform output system_prompt_arn` | Loaded at container startup from Bedrock Prompt Management |
| Guardrail ID | `terraform output guardrail_id` | Wired into `BedrockModel` at startup |
| Knowledge Base ID | `terraform output knowledge_base_id` | Set as `KNOWLEDGE_BASE_ID` env var inside the container |
| Prompt Vault Lambda ARN | `terraform output prompt_vault_writer_arn` | Registered in agent manifest; read at startup by `vault.init()` |
| Prompt Vault S3 bucket | `terraform output prompt_vault_bucket` | Session history prefix `strands-sessions/hr-assistant/` |

---

## Container

**Location:** `container/`

**Image tag convention:** `strands-<git-sha>` (e.g. `strands-981904d`), per ADR-009.
Differentiates from the boto3 agent's `<git-sha>` tags in the same ECR repository.

**Key dependencies (`requirements.txt`):**

| Package | Version | Note |
| --- | --- | --- |
| `strands-agents[otel]` | `1.35.0` | Pinned exactly — API surface verified against this version |
| `fastapi` | `0.115.6` | |
| `uvicorn[standard]` | `0.32.1` | |
| `boto3` | `1.35.92` | |

**Build and push:**

```bash
cd terraform/dev/agents/hr-assistant-strands/container

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com/ai-platform-dev-hr-assistant"
GIT_SHA=$(git rev-parse --short HEAD)

# Authenticate (public ECR first, then private)
aws ecr-public get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin public.ecr.aws
aws ecr get-login-password --region us-east-2 | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com"

docker build --platform linux/arm64 -t "${ECR_URI}:strands-${GIT_SHA}" .
docker push "${ECR_URI}:strands-${GIT_SHA}"
```

Then set `agent_image_uri = "${ECR_URI}:strands-${GIT_SHA}"` in `terraform.tfvars`
and run `terraform apply`.

---

## Session Management

The Strands agent uses `S3SessionManager` instead of the boto3 agent's DynamoDB table.
Session history is persisted at:

```
s3://ai-platform-dev-prompt-vault-<account>/strands-sessions/hr-assistant/session_<session_id>/session.json
```

A new `S3SessionManager` and `Agent` are created per request. `BedrockModel` and
`@tool` functions are created once at startup. The boto3 session memory DynamoDB table
(`ai-platform-dev-session-memory`) is not used by this agent.

---

## Dependencies

Reads from platform remote state:

| Platform output | Used for |
| --- | --- |
| `agentcore_gateway_id` | Agent manifest registration |
| `agent_registry_table` | DynamoDB target for local-exec manifest registration |
| `prompt_vault_bucket` | `PROMPT_VAULT_BUCKET` env var (required by S3SessionManager) |
| `kms_key_arn` | CloudWatch log group encryption |

Reads from `terraform.tfvars` (populated from `hr-assistant` layer outputs):

| Variable | Source command |
| --- | --- |
| `system_prompt_arn` | `cd ../hr-assistant && terraform output -raw system_prompt_arn` |
| `guardrail_id` | `cd ../hr-assistant && terraform output -raw guardrail_id` |
| `guardrail_version` | `cd ../hr-assistant && terraform output -raw guardrail_version` |
| `knowledge_base_id` | `cd ../hr-assistant && terraform output -raw knowledge_base_id` |
| `prompt_vault_lambda_arn` | `cd ../hr-assistant && terraform output -raw prompt_vault_writer_arn` |

---

## Prerequisites

1. Foundation layer applied
2. Platform layer applied, including:
   - `S3StrandsSessionReadWrite` IAM statement on `agentcore_runtime` role (see Known Issues)
   - `cloudwatch_monitoring` VPC endpoint in networking module (see Known Issues)
3. `hr-assistant` layer applied (provides the shared resource ARNs/IDs)
4. Strands container image built and pushed to ECR
5. `terraform.tfvars` created with all variable values

---

## First-Time Setup

```bash
cd terraform/dev/agents/hr-assistant-strands

terraform init

cp terraform.tfvars.example terraform.tfvars
# Populate from hr-assistant outputs and account values

terraform plan -out=tfplan
terraform apply tfplan
# Expect: 3 resources to add
# If ResourceAlreadyExistsException on log group, see Known Issues below
```

---

## Live Invocation

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
RUNTIME_ID=$(terraform output -raw agentcore_endpoint_id)
RUNTIME_ARN="arn:aws:bedrock-agentcore:us-east-2:${ACCOUNT_ID}:runtime/${RUNTIME_ID}"
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

> **`sessionId` must be in the payload body.** `--runtime-session-id` is used by the
> AgentCore control plane for routing but is NOT forwarded to the container. Always
> include `sessionId` in the JSON payload.

---

## Tests

Run after every apply:

```bash
cd terraform/dev/agents/hr-assistant-strands
./smoke-test.sh
```

The script resolves all values from Terraform outputs — no arguments needed. Reads
shared resource IDs from the `../hr-assistant/` layer outputs. Exits 0 if all 6 tests
pass, 1 if any fail.

| Test | What it checks | Pass condition |
| --- | --- | --- |
| 8a | Live AgentCore invocation — annual leave question | Response contains "25" (KB-grounded from annual-leave-policy.md) |
| 8b | Guardrail blocks legal advice input | `action = GUARDRAIL_INTERVENED`; topic `Legal Advice` |
| 8c | Live AgentCore invocation — distress prompt | Response contains `1800-EAP-HELP` |
| 8d | Prompt Vault Lambda write path | Lambda returns S3 key matching `prompt-vault/hr-assistant/YYYY/MM/DD/*.json` |
| 8e | CloudWatch logs confirm `strands_invoke` event | Event found in runtime log group (last 5 min) |
| 8f | CloudWatch logs confirm `kb_retrieve` event with correct KB ID | Event with `kb_id: BWJGUXDACJ` found (last 5 min) |

---

## Observability

### CloudWatch Custom Metrics

After every successful invocation the container emits to namespace `bedrock-agentcore`:

| Metric | Unit | Dimensions |
| --- | --- | --- |
| `InvocationLatency` | Milliseconds | `AgentId=hr-assistant-strands-dev`, `Environment=dev` |
| `InputTokens` | Count | `AgentId=hr-assistant-strands-dev`, `Environment=dev` |
| `OutputTokens` | Count | `AgentId=hr-assistant-strands-dev`, `Environment=dev` |

Verify metrics are arriving:

```bash
aws cloudwatch get-metric-statistics \
  --region us-east-2 \
  --namespace "bedrock-agentcore" \
  --metric-name "InvocationLatency" \
  --dimensions Name=AgentId,Value=hr-assistant-strands-dev Name=Environment,Value=dev \
  --start-time "$(python3 -c "import datetime; print((datetime.datetime.utcnow() - datetime.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 3600 \
  --statistics Average Maximum SampleCount
```

If `Datapoints` is empty after confirmed invocations, check the `monitoring` VPC endpoint
(see Known Issues).

### Container Log Group

```
/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT
```

```bash
RUNTIME_ID=$(terraform output -raw agentcore_endpoint_id)
LOG_GROUP="/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT"

# Recent invocations
aws logs filter-log-events \
  --region us-east-2 \
  --log-group-name "${LOG_GROUP}" \
  --start-time $(python3 -c "import time; print(int((time.time()-600)*1000))") \
  --filter-pattern '"strands_invoke"' \
  --query 'events[*].message' --output text | tr '\t' '\n'

# Errors only
aws logs filter-log-events \
  --region us-east-2 \
  --log-group-name "${LOG_GROUP}" \
  --start-time $(python3 -c "import time; print(int((time.time()-600)*1000))") \
  --filter-pattern '"invocation_error"' \
  --query 'events[*].message' --output text | tr '\t' '\n'
```

---

## Iterative Cycle

```bash
cd terraform/dev/agents/hr-assistant-strands

# Rebuild container (if code changed)
cd container && docker build --platform linux/arm64 -t "${ECR_URI}:strands-${GIT_SHA}" . && \
  docker push "${ECR_URI}:strands-${GIT_SHA}" && cd ..
# Update agent_image_uri in terraform.tfvars

terraform destroy -auto-approve
terraform plan -out=tfplan
terraform apply tfplan
# If log group import needed, see Known Issues

./smoke-test.sh
```

---

## Known Issues

### Log group `ResourceAlreadyExistsException` on first apply

AgentCore creates the CloudWatch log group when the runtime is provisioned. If
Terraform then tries to create the same group, apply fails. Import the group first:

```bash
RUNTIME_ID=$(terraform output -raw agentcore_endpoint_id)
terraform import \
  aws_cloudwatch_log_group.strands_runtime \
  "/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT"
terraform apply  # re-plan not needed; apply will reconcile
```

### S3 `AccessDenied` on `strands-sessions/*` — platform IAM gap

If every invocation fails with `invocation_error: AccessDenied when calling the PutObject
operation`, the `S3StrandsSessionReadWrite` IAM statement is missing from the platform
`agentcore_runtime` role. This is a **platform layer** fix:

```hcl
# In terraform/dev/platform/main.tf, aws_iam_role_policy.agentcore_runtime:
{
  Sid    = "S3StrandsSessionReadWrite"
  Effect = "Allow"
  Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
  Resource = [
    "arn:aws:s3:::${local.prompt_vault_bucket_name}",
    "arn:aws:s3:::${local.prompt_vault_bucket_name}/strands-sessions/*",
  ]
}
```

Apply the platform layer, then retry the invocation.

### CloudWatch metrics not appearing — `monitoring` VPC endpoint missing

If CloudWatch `list-metrics` shows 0 results for namespace `bedrock-agentcore` despite
successful invocations, the `monitoring` interface VPC endpoint is missing from the
foundation layer. Without it, `put_metric_data` calls hang silently in the private subnet
and no error is logged.

Fix in the **networking module** (`terraform/modules/networking/main.tf`):

```hcl
resource "aws_vpc_endpoint" "cloudwatch_monitoring" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.monitoring"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.agentcore.id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.name_prefix}-monitoring-endpoint" })
}
```

Apply the foundation layer. No container restart needed — the endpoint routes existing
DNS resolution transparently once active.

### `stop_reason: guardrail_intervened` on normal queries

Annual-leave and other in-scope queries may log `stop_reason: guardrail_intervened`
while still returning the correct answer. This occurs when the guardrail applies PII
anonymization to the system prompt template (placeholder text like `{ADDRESS}` triggers
the ADDRESS PII type). The response still flows through — this is not a block. Only treat
it as a problem if `topicPolicyResult` in the vault record is non-empty.

### Agent manifest item not removed on destroy

`terraform destroy` does not delete the `hr-assistant-strands-dev` item from the agent
registry table. Delete manually after destroy:

```bash
aws dynamodb delete-item \
  --region us-east-2 \
  --table-name ai-platform-dev-agent-registry \
  --key '{"agent_id": {"S": "hr-assistant-strands-dev"}}'
```

### S3 session and prompt vault objects persist after destroy

Session history (`strands-sessions/hr-assistant/`) and Prompt Vault records
(`prompt-vault/hr-assistant/`) are written to the platform-owned bucket.
These must be purged before destroying the platform layer. See the purge script in
`terraform/dev/platform/README.md` (Destroy section).

---

## Teardown

```bash
cd terraform/dev/agents/hr-assistant-strands
terraform destroy -auto-approve

# Clean up registry item
aws dynamodb delete-item \
  --region us-east-2 \
  --table-name ai-platform-dev-agent-registry \
  --key '{"agent_id": {"S": "hr-assistant-strands-dev"}}'
```
