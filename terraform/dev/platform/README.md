# Platform Layer — `terraform/dev/platform/`

Core platform services. Freely destroyable and reapplyable. Foundation must
be applied first. Tools and agents depend on this layer.

---

## Purpose

Platform provisions the runtime and shared services that all agents and tools
run on top of:

- **AgentCore runtime** — the managed agent execution environment. Runs the
  HR Assistant container in VPC-private mode on arm64/Graviton.
- **MCP Gateway** — brokers tool calls from the AgentCore runtime to registered
  MCP tool endpoints. Authorises callers via AWS IAM.
- **Storage** — DynamoDB tables for session memory and agent registry; S3
  buckets for document landing and the Prompt Vault.
- **Observability** — CloudWatch log groups and metric alarms for the AgentCore
  runtime and Bedrock Knowledge Base.
- **Platform IAM** — the AgentCore runtime role and Bedrock KB role. Each is
  scoped to this layer's resources. Tool and agent roles are owned by their
  respective layers.

---

## Resources

| Resource | What it creates |
|---|---|
| `aws_iam_role.agentcore_runtime` | Runtime role assumed by `bedrock-agentcore.amazonaws.com` |
| `aws_iam_role.bedrock_kb` | KB ingestion role assumed by `bedrock.amazonaws.com` |
| `module.storage` | 2 S3 buckets + 2 DynamoDB tables (KMS encrypted) |
| `module.observability` | 2 CloudWatch log groups + 2 metric alarms |
| `module.agentcore` | AgentCore runtime endpoint + MCP Gateway |

### Storage Resources

| Resource | Name | Purpose |
|---|---|---|
| S3 | `ai-platform-dev-document-landing-<account>` | Source documents for Knowledge Base ingestion |
| S3 | `ai-platform-dev-prompt-vault-<account>` | Prompt templates — versioned, KMS encrypted |
| DynamoDB | `ai-platform-dev-session-memory` | AgentCore session state (partition: `session_id`, sort: `timestamp`) |
| DynamoDB | `ai-platform-dev-agent-registry` | Agent manifest registry |

### Observability Resources

| Resource | Name | Purpose |
|---|---|---|
| CloudWatch Log Group | `/aws/agentcore/ai-platform-dev` | AgentCore runtime structured JSON logs |
| CloudWatch Log Group | `/aws/bedrock/knowledge-base/ai-platform-dev` | Bedrock KB ingestion logs |
| CloudWatch Alarm | `ai-platform-dev-agentcore-errors` | Fires on AgentCore error count > 0 |
| CloudWatch Alarm | `ai-platform-dev-agentcore-p99-latency` | Fires on p99 invocation latency threshold |

---

## Dependencies

Reads the following outputs from foundation via `terraform_remote_state`:

| Foundation output | Used for |
|---|---|
| `vpc_id` | Re-exported in platform outputs |
| `subnet_ids` | AgentCore runtime VPC placement |
| `agentcore_sg_id` | AgentCore runtime security group |
| `storage_kms_key_arn` | Encrypts S3, DynamoDB, CloudWatch log groups |
| `ecr_repository_url` | AgentCore runtime container image source |

---

## Platform API (Outputs)

These outputs are the interface contract consumed by tools and agents via
`terraform_remote_state`. Do not remove or rename outputs without updating
all downstream layers.

| Output | Description |
|---|---|
| `agentcore_endpoint_id` | AgentCore runtime endpoint ID |
| `agentcore_gateway_id` | MCP Gateway ID — tools register targets against this |
| `vpc_id` | Re-exported from foundation |
| `subnet_ids` | Re-exported from foundation |
| `agentcore_sg_id` | Re-exported from foundation |
| `kms_key_arn` | Re-exported from foundation |
| `document_landing_bucket` | S3 bucket name |
| `prompt_vault_bucket` | S3 bucket name |
| `session_memory_table` | DynamoDB table name |
| `agent_registry_table` | DynamoDB table name |
| `log_group_agentcore` | CloudWatch log group name |

---

## Prerequisites

- Foundation layer applied. Run `terraform output` in `terraform/dev/foundation/`
  to confirm outputs are available.
- Agent container image pushed to ECR. See `docs/agent-container.md`.
- `terraform.tfvars` created with `agent_image_uri` set to the ECR URI of the
  pushed arm64 image.

---

## First-Time Setup

```bash
cd terraform/dev/platform

# One-time per machine
terraform init

# Create tfvars
cp terraform.tfvars.example terraform.tfvars
# Set agent_image_uri to the ECR URI from foundation output:
#   terraform -chdir=../foundation output -raw ecr_repository_url

terraform plan -out=tfplan
# Review — expect ~15 resources to add
terraform apply tfplan
```

---

## Iterative Cycle

Platform can be destroyed and reapplied freely. Foundation stays up.

```bash
cd terraform/dev/platform

# Destroy (purge S3 first — see Known Issues)
terraform destroy -auto-approve

# Reapply
terraform plan -out=tfplan
terraform apply tfplan
```

After reapply, redeploy any tools that registered gateway targets, as the
gateway ID changes on each apply.

---

## Destroy

Purge S3 versions before destroying — Terraform cannot delete non-empty
versioned buckets.

```bash
for BUCKET in \
  ai-platform-dev-document-landing-096305373014 \
  ai-platform-dev-prompt-vault-096305373014; do

  VERSIONS=$(aws s3api list-object-versions --bucket "$BUCKET" --region us-east-2 \
    --query 'Versions[].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null)
  if [ "$VERSIONS" != "null" ] && [ "$VERSIONS" != "[]" ] && [ -n "$VERSIONS" ]; then
    DELETE_JSON=$(echo "$VERSIONS" | python3 -c \
      "import sys,json; v=json.load(sys.stdin); print(json.dumps({'Objects':v,'Quiet':True}))")
    aws s3api delete-objects --bucket "$BUCKET" --region us-east-2 --delete "$DELETE_JSON"
  fi

  MARKERS=$(aws s3api list-object-versions --bucket "$BUCKET" --region us-east-2 \
    --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null)
  if [ "$MARKERS" != "null" ] && [ "$MARKERS" != "[]" ] && [ -n "$MARKERS" ]; then
    DELETE_JSON=$(echo "$MARKERS" | python3 -c \
      "import sys,json; v=json.load(sys.stdin); print(json.dumps({'Objects':v,'Quiet':True}))")
    aws s3api delete-objects --bucket "$BUCKET" --region us-east-2 --delete "$DELETE_JSON"
  fi

done

cd terraform/dev/platform
terraform destroy -auto-approve
```

---

## Tests

Run after every apply to confirm the platform is operational.

```bash
cd terraform/dev/platform
./smoke-test.sh
```

The script reads all values from `terraform output` — no arguments needed. It exits 0
if all five tests pass and 1 if any fail, making it suitable for CI/CD pipelines.

**Tests covered:**

| Test | What it checks | Pass condition |
|---|---|---|
| 1 | AgentCore runtime status | `READY` |
| 2 | MCP Gateway status, auth, protocol | `READY` + `AWS_IAM` + `MCP` |
| 3 | Bedrock model invocation | Response contains `PASS` |
| 4 | DynamoDB session memory write/read/delete | Read returns written value |
| 5 | S3 document bucket KMS encryption | `ServerSideEncryption = aws:kms` |

---

## Observability

### CloudWatch Log Groups

| Log group | Content |
|---|---|
| `/aws/agentcore/ai-platform-dev` | Structured JSON from the AgentCore runtime. All agent invocations, tool calls, and errors appear here. |
| `/aws/bedrock/knowledge-base/ai-platform-dev` | Bedrock KB ingestion job results. |

Query the AgentCore log group for recent errors:

```bash
aws logs filter-log-events \
  --log-group-name /aws/agentcore/ai-platform-dev \
  --region us-east-2 \
  --filter-pattern '{ $.level = "ERROR" }' \
  --start-time $(date -v-1H +%s000) \
  --query 'events[].message' \
  --output text
```

### CloudWatch Alarms

| Alarm | Condition | Action |
|---|---|---|
| `ai-platform-dev-agentcore-errors` | Error count > 0 | Investigate `/aws/agentcore/ai-platform-dev` |
| `ai-platform-dev-agentcore-p99-latency` | p99 latency above threshold | Check runtime configuration and model |

Check alarm states:

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix ai-platform-dev \
  --region us-east-2 \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue}' \
  --output table
```

---

## Known Issues

**AgentCore VPC-mode ENIs block subnet deletion on destroy**

After destroying the AgentCore runtime, AWS releases `agentic_ai` ENIs
asynchronously. If platform destroy completes but foundation destroy
subsequently fails on subnet deletion with `DependencyViolation`, wait
15-30 minutes and re-run `terraform destroy -auto-approve` in foundation/.

**Gateway ID changes on every apply**

The MCP Gateway ID is regenerated each time the platform layer is destroyed
and reapplied. Any tools that registered gateway targets must be redeployed
after a platform cycle to register against the new gateway ID.
