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
  `local-exec` (see Component 3 note below)
- **Prompt Vault Lambda** — write path for persisting interaction records to S3
- **Golden Dataset** — 15 test cases for evaluating agent behaviour
- **Smoke Test** — 4 integration tests run after every apply

---

## Resources

| Resource | Name | Purpose |
|---|---|---|
| `aws_bedrockagent_prompt` | `hr-assistant-system-prompt-dev` | System prompt stored in Bedrock Prompt Management |
| `aws_bedrock_guardrail` | `hr-assistant-guardrail-dev` | Topic policies, content filters, PII anonymization |
| `terraform_data` (local-exec) | — | Registers agent manifest in DynamoDB agent registry |
| `aws_iam_role` | `hr-assistant-prompt-vault-writer-dev` | Lambda execution role — scoped to hr-assistant S3 prefix |
| `aws_iam_role_policy` | `PromptVaultWriterPolicy` | S3 write, KMS, CloudWatch Logs |
| `aws_cloudwatch_log_group` | `/aws/lambda/hr-assistant-prompt-vault-writer-dev` | 30-day retention, KMS encrypted |
| `aws_lambda_function` | `hr-assistant-prompt-vault-writer-dev` | arm64/Graviton, python3.12 |
| `aws_lambda_permission` | `AllowAgentCoreInvoke` | Allows AgentCore to invoke the Lambda |

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

## Agent Manifest (Component 3)

The agent manifest is registered in the platform DynamoDB agent registry table
(`ai-platform-dev-agent-registry`) via `terraform_data + local-exec`.

**Why local-exec:** As of AWS provider v6 (October 2025 GA), there is no native
Terraform resource for registering a declarative agent manifest against an existing
AgentCore runtime endpoint. The `aws_bedrockagentcore_agent_runtime` resource manages
container-based runtimes and is not applicable here. When a native resource becomes
available (expected: `aws_bedrockagentcore_agent_configuration` or equivalent),
replace the `terraform_data` block in `main.tf`.

**CLI command used:**
```bash
aws dynamodb put-item \
  --region us-east-2 \
  --table-name ai-platform-dev-agent-registry \
  --item '{ "agent_id": {"S": "hr-assistant-dev"}, ... }'
```

To verify the manifest is registered:

```bash
aws dynamodb get-item \
  --region us-east-2 \
  --table-name ai-platform-dev-agent-registry \
  --key '{"agent_id": {"S": "hr-assistant-dev"}}' \
  --output json
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

To invoke the Lambda manually with a test event:

```bash
cat > /tmp/test-event.json << 'EOF'
{
  "sessionId": "manual-test-001",
  "input": "How many days of annual leave?",
  "output": "You are entitled to 25 days per year.",
  "toolCalls": [],
  "guardrailResult": {"action": "NONE", "topicPolicyResult": "", "contentFilterResult": ""},
  "modelArn": "anthropic.claude-sonnet-4-6",
  "inputTokens": 50,
  "outputTokens": 30,
  "latencyMs": 800
}
EOF

aws lambda invoke \
  --region us-east-2 \
  --function-name hr-assistant-prompt-vault-writer-dev \
  --payload file:///tmp/test-event.json \
  --cli-binary-format raw-in-base64-out \
  /tmp/response.json && cat /tmp/response.json
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
| `kms_key_arn` | Lambda IAM KMS permissions, CloudWatch log group encryption |

---

## Prerequisites

- Platform layer applied.
- `terraform.tfvars` created with `account_id` set.

---

## First-Time Setup

```bash
cd terraform/dev/agents/hr-assistant

terraform init
cp terraform.tfvars.example terraform.tfvars
# Set account_id — all other variables have safe defaults

terraform plan -out=tfplan
# Expect: 8 resources to add
terraform apply tfplan
```

---

## Iterative Cycle

```bash
cd terraform/dev/agents/hr-assistant

terraform destroy -auto-approve
# Expect: 8 resources destroyed

terraform plan -out=tfplan
terraform apply tfplan
# Expect: 8 resources added
```

---

## Tests

Run after every apply to confirm all components are operational.

```bash
cd terraform/dev/agents/hr-assistant
./smoke-test.sh
```

**Tests covered:**

| Test | What it checks | Pass condition |
|---|---|---|
| 7a | System prompt deployed and contains in-scope HR guidance | Prompt retrieved from Bedrock; contains `glean-search` and `annual leave` |
| 7b | Guardrail blocks legal advice input | `action = GUARDRAIL_INTERVENED`; topic `Legal Advice` detected |
| 7c | Safety redirect (EAP) configured in system prompt | Prompt text contains `1800-EAP-HELP` |
| 7d | Prompt Vault Lambda writes to S3 | Lambda returns 200 with S3 key matching `prompt-vault/hr-assistant/YYYY/MM/DD/*.json` |

**Phase 1 note:** Tests 7a and 7c validate Bedrock resources directly (system prompt API,
prompt text content). Tests 7b and 7d exercise live AWS APIs (Guardrails, Lambda).
Live end-to-end runtime invocations (7a/7c via AgentCore) are deferred to Phase 2
when the HR Assistant container is built and deployed. See Phase 1 Known Limitations.

---

## Observability

AgentCore runtime logs appear in the platform layer's log group:

```
/aws/agentcore/ai-platform-dev
```

Prompt Vault Lambda logs:

```
/aws/lambda/hr-assistant-prompt-vault-writer-dev
```

Query Lambda logs for recent errors:

```bash
aws logs filter-log-events \
  --log-group-name /aws/lambda/hr-assistant-prompt-vault-writer-dev \
  --region us-east-2 \
  --filter-pattern '{ $.status = "error" }' \
  --start-time $(date -v-1H +%s000) \
  --query 'events[].message' \
  --output text
```

---

## Phase 1 Known Limitations

| Limitation | Notes |
|---|---|
| No Bedrock Knowledge Base | Deferred to Phase 2. Glean stub Lambda returns mock results. |
| Glean stub (not real Glean) | `tools/glean/` deploys a stub Lambda. Replace with real Glean endpoint in Phase 2 — no infra changes required. |
| System prompt uses dev placeholders | `[COMPANY_NAME]`, `hr@example.com`, `1800-EAP-HELP`. Not for production use. |
| Agent manifest uses `local-exec` | No native Terraform resource for AgentCore declarative agent configuration in provider v6. Replace when `aws_bedrockagentcore_agent_configuration` is available. |
| No live runtime invocation in smoke test | AgentCore runtime is container-based. No HR Assistant container deployed in Phase 1. Smoke tests 7a/7c validate Bedrock resources directly instead. |

---

## Adding Agent-Specific Resources

1. Define resources in `main.tf`. Use `data.terraform_remote_state.platform`
   for any values from the platform layer (gateway ID, table names, etc.).
2. Create IAM roles inline in `main.tf` — Option B ownership: do not add them
   to foundation or platform.
3. Add outputs to `outputs.tf` for values that tests or other systems reference.
4. Update this README and run the smoke test after every apply.
