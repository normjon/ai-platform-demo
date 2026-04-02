# HR Assistant Agent Layer — `terraform/dev/agents/hr-assistant/`

Agent-specific configuration for the HR Assistant — the first production-grade
agent on the Enterprise AI Platform dev environment.

---

## Purpose

This layer is the HR Assistant team's ownership boundary. It manages all
infrastructure and configuration specific to this agent, independently of the
platform and foundation layers:

- **System Prompt** — versioned via Bedrock Prompt Management; loaded from
  `prompts/hr-assistant-system-prompt.txt`
- **Guardrails** — Bedrock Guardrails with topic policies, content filters,
  PII anonymization, and contextual grounding
- **Agent Manifest** — registered in the platform DynamoDB agent registry via
  `local-exec` (see Component 3 note below); includes KB ID from Phase 2
- **Prompt Vault Lambda** — write path for persisting interaction records to S3
- **HR Policies Knowledge Base** — Bedrock Knowledge Base backed by the platform-owned
  OpenSearch Serverless collection (`ai-platform-kb-dev`); per-index access policy
  (`hr-policies-kb-access-dev`) scoped to `hr-policies-index`; vector index pre-created
  by `null_resource` at apply; collection ARN/endpoint/name read from platform remote state
- **HR Assistant Container** — arm64/Graviton FastAPI container image pushed to ECR;
  deployed as the AgentCore runtime workload
- **Golden Dataset** — 15 test cases for evaluating agent behaviour
- **Smoke Tests** — 6 integration tests run after every apply (Phase 2: live invocations)

---

## Resources

| Resource | Name | Purpose |
|---|---|---|
| `aws_bedrockagent_prompt` | `hr-assistant-system-prompt-dev` | System prompt stored in Bedrock Prompt Management |
| `aws_bedrock_guardrail` | `hr-assistant-guardrail-dev` | Topic policies, content filters, PII anonymization |
| `terraform_data` (local-exec) | — | Registers agent manifest (with KB ID) in DynamoDB agent registry |
| `aws_iam_role` | `hr-assistant-prompt-vault-writer-dev` | Lambda execution role — scoped to hr-assistant S3 prefix |
| `aws_iam_role_policy` | `PromptVaultWriterPolicy` | S3 write, KMS, CloudWatch Logs |
| `aws_cloudwatch_log_group` | `/aws/lambda/hr-assistant-prompt-vault-writer-dev` | 30-day retention, KMS encrypted |
| `aws_lambda_function` | `hr-assistant-prompt-vault-writer-dev` | arm64/Graviton, python3.12 |
| `aws_lambda_permission` | `AllowAgentCoreInvoke` | Allows AgentCore to invoke the Lambda |
| `aws_opensearchserverless_access_policy` | `hr-policies-kb-access-dev` | Per-index data access for KB service role — scoped to `hr-policies-index` in platform collection only |
| `null_resource` | `create_hr_policies_index` | Pre-creates `hr-policies-index` in the platform collection before KB creation |
| `aws_iam_role` | `hr-policies-kb-role-dev` | Bedrock KB service role (Option B, scoped to this layer) |
| `aws_iam_role_policy` | `HRPoliciesKBPolicy` | S3 read, Bedrock embedding, KMS decrypt — scoped to platform KMS key |
| `aws_bedrockagent_knowledge_base` | `hr-policies-kb-dev` | VECTOR KB backed by OpenSearch Serverless |
| `aws_bedrockagent_data_source` | `hr-policies-s3-source` | S3 data source reading `hr-policies/` prefix |
| 8× `aws_s3_object` | `hr-policies/*.md` | Dev HR policy documents uploaded to document landing bucket |

---

## System Prompt

**Location:** `prompts/hr-assistant-system-prompt.txt`

The prompt is loaded at plan time via `file()` — no variable substitution.
The dev prompt contains literal placeholder strings that must be replaced
before promoting to staging or production:

| Placeholder | Replace with |
|---|---|
| `[COMPANY_NAME]` | The organisation's legal trading name |
| `hr@example.com` | The real HR team contact email address |
| `1800-EAP-HELP` | The real Employee Assistance Programme phone number |

To update the system prompt: edit the file and run `terraform apply`. The
`aws_bedrockagent_prompt` resource will detect the change via `file()` and
update in place.

---

## Guardrail Configuration

**Guardrail ID:** resolved via `terraform output -raw guardrail_id`

| Category | Configuration |
|---|---|
| Topic policies (DENY) | Legal Advice, Medical Advice, Financial Planning Advice, Employee Personal Information |
| Content filters | HATE/INSULTS/SEXUAL/VIOLENCE = HIGH; MISCONDUCT = MEDIUM |
| PII anonymization | NAME, EMAIL, PHONE, ADDRESS, AGE, SSN, CREDIT_DEBIT_CARD_NUMBER, US_BANK_ACCOUNT_NUMBER |
| Contextual grounding | GROUNDING threshold = 0.75 |

To test the guardrail independently of the agent runtime:

```bash
GUARDRAIL_ID=$(terraform output -raw guardrail_id)
GUARDRAIL_VERSION=$(terraform output -raw guardrail_version)

aws bedrock-runtime apply-guardrail \
  --region us-east-2 \
  --guardrail-identifier "${GUARDRAIL_ID}" \
  --guardrail-version "${GUARDRAIL_VERSION}" \
  --source INPUT \
  --content '[{"text":{"text":"Can I sue the company for this?"}}]' \
  --output json
```

Expected: `action = GUARDRAIL_INTERVENED`, topic `Legal Advice` detected and blocked.

---

## HR Policies Knowledge Base

**KB ID:** resolved via `terraform output -raw knowledge_base_id`

**Data source ID:** resolved via `terraform output -raw knowledge_base_data_source_id`

**Documents indexed:** 8 HR policy markdown files from `kb-docs/`:

| File | Content |
|---|---|
| `annual-leave-policy.md` | 25 days entitlement, carry-over, booking rules |
| `sick-leave-policy.md` | SSP, enhanced sick pay tiers by service length |
| `parental-leave-policy.md` | Maternity (52 weeks), paternity (2 weeks), SPL |
| `remote-working-policy.md` | Hybrid model (3 days office), broadband allowance, equipment |
| `expenses-policy.md` | Mileage rates, hotel limits, subsistence allowances |
| `performance-review-process.md` | Annual cycle, 5 rating levels, PIP process |
| `employee-assistance-programme.md` | 1800-EAP-HELP, 24/7, counselling and support |
| `benefits-enrolment-guide.md` | 5% pension match, flexible benefits window |

**Index pre-creation:** Bedrock KB requires the OpenSearch vector index to exist before
KB creation. A `null_resource + local-exec` runs `scripts/create-os-index.py` (via
`uv run --with boto3 --with opensearch-py`) against the platform-owned collection,
with a 60-second sleep for the agent-level AOSS data access policy to propagate.
The platform collection must be ACTIVE before this layer is applied (see Prerequisites).

**Ingestion:** Run after apply (or whenever documents change):

```bash
KB_ID=$(terraform output -raw knowledge_base_id)
DS_ID=$(terraform output -raw knowledge_base_data_source_id)

aws bedrock-agent start-ingestion-job \
  --knowledge-base-id "${KB_ID}" \
  --data-source-id "${DS_ID}" \
  --region us-east-2

# Poll until COMPLETE
aws bedrock-agent get-ingestion-job \
  --knowledge-base-id "${KB_ID}" \
  --data-source-id "${DS_ID}" \
  --ingestion-job-id <JOB_ID> \
  --region us-east-2 \
  --query 'ingestionJob.{status:status,stats:statistics}'
```

---

## HR Assistant Container

**Location:** `container/`

**Image tag convention:** git SHA (`git rev-parse --short HEAD`), per ADR-009.

**Build and push:**

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com/ai-platform-hr-assistant"
GIT_SHA=$(git rev-parse --short HEAD)

# Authenticate to public ECR (for base image) and private ECR
aws ecr-public get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin public.ecr.aws

aws ecr get-login-password --region us-east-2 | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com"

docker build --platform linux/arm64 \
  -t "${ECR_URI}:${GIT_SHA}" \
  container/

docker push "${ECR_URI}:${GIT_SHA}"
```

**Update the platform layer:** After pushing, update `agent_image_uri` in
`terraform/dev/platform/terraform.tfvars` and run `terraform apply` in the platform layer.

---

## Agent Manifest (Component 3)

The agent manifest is registered in the platform DynamoDB agent registry table
(`ai-platform-dev-agent-registry`) via `terraform_data + local-exec`.

**Why local-exec:** As of AWS provider v6 (October 2025 GA), there is no native
Terraform resource for registering a declarative agent manifest against an existing
AgentCore runtime endpoint. When a native resource becomes available (expected:
`aws_bedrockagentcore_agent_configuration` or equivalent), replace the `terraform_data`
block in `main.tf`.

**Manifest fields registered (Phase 2):** `agent_id`, `display_name`, `model_arn`,
`system_prompt_arn`, `guardrail_id`, `guardrail_version`, `endpoint_id`, `gateway_id`,
`knowledge_base_id`, `allowed_tools`, `data_classification_ceiling`, `session_ttl_hours`,
`grounding_score_min`, `response_latency_p95_ms`, `monthly_usd_limit`,
`alert_threshold_pct`, `environment`, `registered_at`.

To verify the manifest is registered:

```bash
aws dynamodb get-item \
  --region us-east-2 \
  --table-name ai-platform-dev-agent-registry \
  --key '{"agent_id": {"S": "hr-assistant-dev"}}' \
  --output json
```

---

## Live Agent Invocation

The HR Assistant is invoked via the AgentCore data plane. Use a unique
`sessionId` in the payload for each conversation — it is not forwarded
from `--runtime-session-id` to the container.

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

---

## Prompt Vault Write Path

The Prompt Vault Lambda receives AgentCore post-invocation events and writes
structured JSON interaction records to S3.

**Lambda:** `hr-assistant-prompt-vault-writer-dev` (arm64, python3.12, 30s timeout)

**S3 key pattern:** `prompt-vault/hr-assistant/YYYY/MM/DD/<uuid>.json`

**Bucket:** `ai-platform-dev-prompt-vault-096305373014` (re-exported from platform)

To query records for a given date:

```bash
aws s3 ls s3://ai-platform-dev-prompt-vault-096305373014/prompt-vault/hr-assistant/$(date +%Y/%m/%d)/ \
  --region us-east-2
```

---

## Golden Dataset

**Location:** `test/golden-dataset.json`

15 test cases covering:

| Category | Count |
|---|---|
| In-scope (annual leave, sick leave, parental leave, remote working, expenses, performance review, EAP, benefits) | 8 |
| Out-of-scope (legal advice, employee personal information, medical advice, financial planning) | 4 |
| Edge cases (ambiguous conflict query, PII in input, employee distress) | 3 |

Each case includes: `id`, `category`, `input`, `expected_behaviour`, `tool_expected`,
`guardrail_expected`, `pass_criteria`.

---

## Dependencies

Reads the following outputs from the platform layer via `terraform_remote_state`:

| Platform output | Used for |
|---|---|
| `agentcore_endpoint_id` | Agent manifest registration, re-exported for smoke test |
| `agentcore_gateway_id` | Agent manifest registration |
| `agent_registry_table` | DynamoDB agent registry target for local-exec |
| `prompt_vault_bucket` | Lambda environment variable, IAM S3 resource ARN |
| `kms_key_arn` | Lambda IAM KMS permissions, CloudWatch log group encryption, KB KMS decrypt |
| `opensearch_collection_arn` | `aws_bedrockagent_knowledge_base` storage config `collection_arn` |
| `opensearch_collection_endpoint` | `null_resource` index creation script argument; re-exported as layer output |
| `opensearch_collection_name` | AOSS access policy resource string (`index/<name>/hr-policies-index`) |
| `opensearch_collection_id` | Pre-flight check — confirm collection is ACTIVE before applying this layer |

---

## Prerequisites

- Foundation and Platform layers applied.
- `terraform.tfvars` created with `account_id` set.
- HR Assistant container image built and pushed to ECR (image tag in platform `terraform.tfvars`).
- Python 3 and `uv` installed locally (required for `null_resource` index creation script).
- Platform OpenSearch Serverless collection is ACTIVE (creation takes ~9 min on first apply):

```bash
aws opensearchserverless get-collection \
  --id $(terraform -chdir=../../platform output -raw opensearch_collection_id) \
  --region us-east-2 \
  --query 'collectionDetails.status'
```

Expected: `"ACTIVE"`. Do not apply this layer until the collection is ACTIVE.

---

## First-Time Setup

```bash
cd terraform/dev/agents/hr-assistant

terraform init
cp terraform.tfvars.example terraform.tfvars
# Set account_id — all other variables have safe defaults

terraform plan -out=tfplan
terraform apply tfplan
# Expect: ~20 resources to add
# null_resource waits 60s for AOSS policy propagation then creates vector index

# Trigger KB ingestion after apply
KB_ID=$(terraform output -raw knowledge_base_id)
DS_ID=$(terraform output -raw knowledge_base_data_source_id)
aws bedrock-agent start-ingestion-job \
  --knowledge-base-id "${KB_ID}" \
  --data-source-id "${DS_ID}" \
  --region us-east-2
```

---

## Iterative Cycle

```bash
cd terraform/dev/agents/hr-assistant

terraform destroy -auto-approve
terraform plan -out=tfplan
terraform apply tfplan
# Re-trigger ingestion after re-apply
```

---

## Tests

Run after every apply to confirm all components are operational.

```bash
cd terraform/dev/agents/hr-assistant
./smoke-test.sh
```

**Tests covered (Phase 2):**

| Test | What it checks | Pass condition |
|---|---|---|
| 7a | Live AgentCore invocation — annual leave question | Response contains "25" (KB-grounded from annual-leave-policy.md) |
| 7b | Guardrail blocks legal advice input | `action = GUARDRAIL_INTERVENED`; topic `Legal Advice` detected |
| 7c | Live AgentCore invocation — distress prompt | Response contains `1800-EAP-HELP` (EAP safety redirect) |
| 7d | Prompt Vault Lambda writes to S3 | Lambda returns S3 key matching `prompt-vault/hr-assistant/YYYY/MM/DD/*.json` |
| 7e | CloudWatch logs confirm KB retrieval | `kb_retrieve` event with correct KB ID in last 5 min of runtime log group |
| 7f | Glean stub Lambda MCP tools/call | Glean Lambda returns search results for MCP `tools/call` request |

---

## Observability

AgentCore runtime logs (structured JSON, ADR-003):

```
/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT
```

Resolve the log group name:

```bash
RUNTIME_ID=$(terraform output -raw agentcore_endpoint_id)
echo "/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT"
```

Query for recent agent invocations:

```bash
RUNTIME_ID=$(terraform output -raw agentcore_endpoint_id)
aws logs filter-log-events \
  --log-group-name "/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT" \
  --region us-east-2 \
  --filter-pattern '"agent_invoke"' \
  --start-time $(python3 -c "import time; print(int((time.time()-3600)*1000))") \
  --query 'events[*].message' \
  --output text
```

Prompt Vault Lambda logs:

```
/aws/lambda/hr-assistant-prompt-vault-writer-dev
```

---

## Known Issues

**Agent registry item not removed on destroy**

`terraform destroy` in this layer does not delete the `hr-assistant-dev` item from the
`ai-platform-dev-agent-registry` DynamoDB table. The `terraform_data + local-exec` block
has no `when = destroy` provisioner. The item persists in the table after destroy.

This does not block re-standup — `terraform apply` overwrites the item via `put-item`
(idempotent). To remove the item manually after destroy:

```bash
aws dynamodb delete-item \
  --region us-east-2 \
  --table-name ai-platform-dev-agent-registry \
  --key '{"agent_id": {"S": "hr-assistant-dev"}}'
```

**Prompt Vault S3 objects not removed on destroy**

Smoke test runs and any live invocations write objects to the Prompt Vault bucket
(`ai-platform-dev-prompt-vault-096305373014`) under `prompt-vault/hr-assistant/`.
This bucket is owned by the platform layer and not managed by this layer's destroy.

If the platform layer is subsequently destroyed, the S3 bucket versioning will
prevent `terraform destroy` from completing. Purge the objects first — see
the purge script in `terraform/dev/platform/README.md` (Destroy section).

**`--runtime-session-id` not forwarded to container**

The `--runtime-session-id` CLI flag is used by the AgentCore control plane for
routing/tracking but is NOT forwarded to the container as the
`X-Amzn-Bedrock-AgentCore-Session-Id` header. Always include `sessionId` in the
payload JSON to control session isolation.

---

## Troubleshooting Guide

Each entry maps a symptom to the root cause and fix. These were all encountered
during Phase 2 build — the agent CLAUDE.md has the full diagnostic context.

---

### Container 502 / `RuntimeClientError` on invocation

**Check CloudWatch first** — log group: `/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT`

| Symptom in logs | Root cause | Fix |
|---|---|---|
| No logs at all after invocation | Container failed to start — missing VPC endpoint or SG rule | Add missing endpoint; fix SG (see below) |
| `dial tcp 3.x.x.x:443: i/o timeout` | Missing VPC endpoint or SG blocking traffic to S3/ECR | Add prefix-list egress rules to AgentCore SG (not VPC CIDR) |
| `AccessDeniedException` | IAM role missing permission | Compare failing action against platform pre-flight checklist |
| `RuntimeError: /dev/null is an empty file` | uvicorn `--log-config /dev/null` in container CMD | Rebuild container using `--no-access-log --log-level warning` |
| `Invocation of model ID ... with on-demand throughput isn't supported` | Bare model ID (`anthropic.claude-sonnet-4-6`) | Change to `us.anthropic.claude-sonnet-4-6` everywhere + rebuild |
| `Expected toolResult blocks at messages.X.content` | Corrupt session history in DynamoDB | Use a fresh session ID — do not reuse the failing session |
| 502 with no CloudWatch logs AND container starts | `BedrockAgentCoreFullAccess` managed policy missing from runtime IAM role | Add `BedrockAgentCoreFullAccess` to agentcore_runtime role in platform layer |

---

### SG silently blocking S3 / DynamoDB traffic

Security groups evaluate BEFORE gateway endpoint routing. An egress rule
covering only the VPC CIDR (`10.0.0.0/16`) will silently block S3 and
DynamoDB traffic even when gateway endpoints are attached. The container
will time out on ECR image layer downloads or DynamoDB session reads.

**Symptom:** `dial tcp 3.x.x.x:443: i/o timeout` in container logs.

**Fix:** AgentCore security group egress rules must use AWS-managed
prefix lists (`pl-xxxxxxxxx`) for S3 and DynamoDB — not CIDR blocks.
Get the prefix list IDs:

```bash
aws ec2 describe-managed-prefix-lists \
  --region us-east-2 \
  --query "PrefixLists[?contains(PrefixListName,'s3') || contains(PrefixListName,'dynamodb')].[PrefixListName,PrefixListId]" \
  --output text
```

---

### AOSS index creation returns `403 Forbidden`

Two independent causes — check both:

**Cause 1 — STS session ARN in data access policy principal:**
If the AOSS data access policy was created with `data.aws_caller_identity.current.arn`,
that ARN contains the STS session ID (`assumed-role/ROLE/SESSION`). This changes every
time the SSO token refreshes. After a refresh, the policy match fails.

Fix: Re-apply after changing the principal to `data.aws_iam_session_context.current.issuer_arn`,
which returns the stable IAM role ARN.

**Cause 2 — Policy not yet propagated:**
AOSS data access policy changes take ~60 seconds to propagate. Running the index
creation script immediately after `terraform apply` will hit 403 even if the
policy is correct. The `null_resource` local-exec includes `sleep 60` — do not
remove it.

---

### KB ingestion `COMPLETE` but `numberOfDocumentsFailed=8`

**Cause:** The document landing S3 bucket is KMS-encrypted with the platform KMS key.
The KB service role (`hr-policies-kb-role-dev`) was missing `kms:Decrypt` and
`kms:GenerateDataKey`.

**Error in ingestion job:** `User: .../hr-policies-kb-role-dev/DocumentLoaderTask-... is not authorized to perform: kms:Decrypt`

**Fix:** The KB IAM role policy must include a KMS statement for the platform KMS key.
After adding the permission and re-applying, re-run ingestion:

```bash
KB_ID=$(terraform output -raw knowledge_base_id)
DS_ID=$(terraform output -raw knowledge_base_data_source_id)
JOB_ID=$(aws bedrock-agent start-ingestion-job \
  --knowledge-base-id "${KB_ID}" --data-source-id "${DS_ID}" \
  --region us-east-2 --query 'ingestionJob.ingestionJobId' --output text)
# Check results:
aws bedrock-agent get-ingestion-job \
  --knowledge-base-id "${KB_ID}" --data-source-id "${DS_ID}" \
  --ingestion-job-id "${JOB_ID}" --region us-east-2 \
  --query 'ingestionJob.{status:status,stats:statistics,failures:failureReasons}'
```

---

### `ResourceNotFoundException: No endpoint or agent found`

**Cause:** Wrong runtime ARN format — `agent-runtime` in the path instead of `runtime`.

```
Wrong:   arn:aws:bedrock-agentcore:REGION:ACCOUNT:agent-runtime/<id>
Correct: arn:aws:bedrock-agentcore:REGION:ACCOUNT:runtime/<id>
```

Confirm correct ARN:

```bash
aws bedrock-agentcore-control get-agent-runtime \
  --agent-runtime-id "$(terraform -chdir=../../platform output -raw agentcore_endpoint_id)" \
  --region us-east-2 --query 'agentRuntimeArn' --output text
```

---

### `Parameter validation failed: Invalid length for parameter runtimeSessionId`

**Cause:** `--runtime-session-id` requires minimum 33 characters. Short strings like
`test-session` fail validation.

**Fix:** Use UUID-based session IDs:

```bash
SESSION_ID="smoke-$(uuidgen | tr '[:upper:]' '[:lower:]')"
# Result: "smoke-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" = 42 chars
```

---

### Agent responds to all sessions with same context (session isolation broken)

**Cause:** `--runtime-session-id` is not forwarded to the container. The container
falls back to its default session ID and contaminated session history bleeds across
invocations.

**Fix:** Always include `sessionId` in the JSON payload body, not just in
`--runtime-session-id`.

---

### Smoke test 7f failing (`Glean stub returned EMPTY`)

**Cause:** The agent did not call the Glean tool — the KB context was sufficient to
answer the question and the model chose not to invoke the MCP tool. This is correct
agent behaviour, not a bug. Test 7f was redesigned to call the Glean Lambda directly
(bypassing the agent) to validate the MCP tool independently.

If the direct Lambda call also fails, check:
1. Lambda function exists: `aws lambda get-function --function-name ai-platform-dev-glean-stub --region us-east-2`
2. Payload format is correct MCP JSON-RPC `tools/call` with `{"body": "...", "requestContext": {...}, "rawPath": "/"}`

---

## Adding Agent-Specific Resources

1. Define resources in `main.tf`. Use `data.terraform_remote_state.platform`
   for any values from the platform layer (gateway ID, table names, etc.).
2. Create IAM roles inline in `main.tf` — Option B ownership: do not add them
   to foundation or platform.
3. Add outputs to `outputs.tf` for values that tests or other systems reference.
4. Update this README and run the smoke test after every apply (ADR-015).
