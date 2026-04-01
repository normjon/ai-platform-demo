# Playbook: HR Assistant Agent — Phase 1 Build

Build specification for the HR Assistant agent on the Enterprise AI Platform
dev environment. This is the first production-grade agent on the platform.

This document is the authoritative source of record for the Phase 1 build.
All five pre-execution concerns raised during review are resolved inline.
Do not modify this document without a corresponding code change — keep the
spec and the implementation in sync.

---

## Pre-Execution Reading

Before writing anything:

1. Read `docs/Enterprise_AI_Platform_Architecture.md` — Section 5.2
   (Agent Manifest), Section 8 (Security and Governance), and
   Section 10 (Observability and Quality) in full.
2. Read the ADR library `ai-platform/` folder CLAUDE.md at:
   https://github.com/normjon/claude-foundation-best-practice/tree/main/ai-platform
3. Read ADR-021 in full:
   https://github.com/normjon/claude-foundation-best-practice/blob/main/ai-platform/ADR-021-ai-platform-claude-md-hierarchy.md

---

## Branch

```bash
git checkout main
git pull
git checkout -b feat/hr-assistant-agent
```

---

## Overview

Build the following components in order. Complete each component before
starting the next. Do not combine components into a single commit.

| Component | What it builds |
|---|---|
| 1 | System Prompt (Bedrock Prompt Management) |
| 2 | Guardrails (Bedrock Guardrails) |
| 3 | Agent Manifest and AgentCore Configuration |
| 4 | Prompt Vault Lambda Write Path |
| 5 | Golden Dataset |
| 6 | Validation (terraform validate + plan only — no apply) |

All Terraform goes in `terraform/dev/agents/hr-assistant/` unless
specified otherwise.

---

## Component 1 — System Prompt

### Where it lives

Create the system prompt as a Bedrock Prompt Management resource in
`terraform/dev/agents/hr-assistant/main.tf`.

The prompt text lives in a separate file:

```
terraform/dev/agents/hr-assistant/prompts/hr-assistant-system-prompt.txt
```

Never inline the prompt text in Terraform. Use `file()` to reference it —
not `templatefile()`. The dev prompt file contains literal placeholder
strings (see below) and requires no variable substitution at plan time.

### System prompt file

Create the file with this content exactly. The comment block at the top
is required — it tells future maintainers which strings are dev placeholders.

```
# DEV ENVIRONMENT PROMPT — PLACEHOLDER VALUES IN USE
# Before promoting to staging or production replace:
#   [COMPANY_NAME]  — the organisation's legal trading name
#   hr@example.com  — the real HR team contact email address
#   1800-EAP-HELP   — the real Employee Assistance Programme phone number
# These placeholders are intentional. Do not remove this comment block.

## Identity

You are the HR Assistant for [COMPANY_NAME], an AI-powered assistant
that helps employees find accurate information about HR policies,
benefits, leave entitlements, and workplace procedures.

You are operating in a dev environment. Your responses are logged
for quality review and platform improvement.

## Scope

You help employees with:

- Leave policies (annual leave, sick leave, parental leave, compassionate leave)
- Benefits information (health insurance, retirement, employee assistance)
- Workplace policies (code of conduct, flexible working, expenses)
- HR procedures (onboarding, offboarding, performance review processes)
- Directing employees to the right HR contact for complex situations

You do not provide:

- Legal advice of any kind — direct to Legal team
- Medical advice or diagnosis — direct to Employee Assistance Programme
- Financial planning advice — direct to employee's financial adviser
- Information about other employees' personal details or compensation
- Decisions on disciplinary or grievance matters — direct to HR Business Partner

## Tool Usage

You have access to the glean-search tool. Use it to find relevant
HR documentation before answering any policy question.

Always search before answering. Do not answer from memory alone —
HR policies change and your training data may be outdated.

Search query guidance:

- Use specific, targeted queries: "parental leave policy duration"
  not "leave"
- If the first search does not return relevant results, refine and
  search again before answering
- If search returns no relevant results after two attempts, tell the
  employee you could not find documentation on that topic and direct
  them to contact HR directly at hr@example.com

## Response Format

- Be concise and direct. Employees are busy.
- Use plain language. Avoid HR jargon where possible.
- When citing a policy, name the document it came from.
- If you are uncertain, say so and direct to HR rather than guessing.
- For complex situations always recommend the employee speak with
  an HR Business Partner.

## Refusal Behaviour

If asked about topics outside your scope:

- Acknowledge what the employee is asking about
- Explain clearly that this is outside what you can help with
- Direct them to the appropriate resource or team
- Do not lecture or moralize

## Safety

If an employee expresses distress, concern about their wellbeing,
or mentions a crisis situation — do not attempt to handle it.
Immediately direct them to the Employee Assistance Programme
at 1800-EAP-HELP and, if urgency is indicated, to emergency services.
```

### Terraform resources

In `terraform/dev/agents/hr-assistant/main.tf` create:

```hcl
resource "aws_bedrock_prompt" "hr_assistant_system" {
  name        = "hr-assistant-system-prompt-dev"
  description = "System prompt for the HR Assistant agent - dev environment."

  default_variant = "default"

  variant {
    name          = "default"
    template_type = "TEXT"
    template_configuration {
      text {
        text = file("${path.module}/prompts/hr-assistant-system-prompt.txt")
      }
    }
  }

  tags = merge(var.tags, { Component = "system-prompt" })
}

resource "aws_bedrock_prompt_version" "hr_assistant_system" {
  prompt_arn  = aws_bedrock_prompt.hr_assistant_system.arn
  description = "Phase 1 baseline — dev environment."
}
```

Output the version ARN:

```hcl
output "system_prompt_version_arn" {
  value = aws_bedrock_prompt_version.hr_assistant_system.arn
}
```

---

## Component 2 — Guardrails

In `terraform/dev/agents/hr-assistant/main.tf` create an
`aws_bedrock_guardrail` resource.

Name: `hr-assistant-guardrail-dev`

### Topic policies (deny)

| Topic | Definition | Example phrases |
|---|---|---|
| Legal Advice | Requests for legal opinions, interpretation of laws or contracts, advice on legal rights or obligations, or guidance on legal proceedings | "Is my employer breaking the law?", "Can I sue the company?", "What are my legal rights here?" |
| Medical Advice | Requests for medical diagnosis, treatment recommendations, interpretation of medical test results, or advice on medications | "Should I see a doctor about this?", "What does my diagnosis mean?", "Is this medication safe?" |
| Financial Planning Advice | Requests for personal investment advice, tax planning strategies, retirement fund allocation recommendations, or specific financial product recommendations | "Should I put more in my pension?", "How should I invest my bonus?", "Which fund should I choose?" |
| Employee Personal Information | Requests for information about other employees' salary, performance ratings, disciplinary history, personal contact details, or any other personal data about a named individual | "What does [name] earn?", "Why was [name] let go?", "Give me [name]'s phone number" |

### Content filters

| Category | Sensitivity |
|---|---|
| Hate speech | HIGH |
| Insults | HIGH |
| Sexual content | HIGH |
| Violence | HIGH |
| Misconduct | MEDIUM — catches policy violation discussions needing escalation without over-blocking legitimate HR queries |

### PII handling

Configure PII entity detection with action `ANONYMIZE` (not BLOCK) for:

```
NAME, EMAIL, PHONE, ADDRESS, DATE_OF_BIRTH,
NATIONAL_IDENTIFICATION_NUMBER, CREDIT_DEBIT_NUMBER, BANK_ACCOUNT_NUMBER
```

Anonymize rather than block — the agent still processes the request but
PII is redacted from the response before it reaches the user.

### Contextual grounding check

Enable contextual grounding policy with a GROUNDING filter at threshold 0.75.
Responses below this threshold are blocked and the blocked message is returned.

### Blocked message

Use this exact text for all topic denials and content filter blocks:

```
I'm not able to help with that request. For assistance, please
contact the HR team directly at hr@example.com or speak with your
HR Business Partner.
```

### Tags and outputs

```hcl
tags = merge(var.tags, { Component = "guardrail" })
```

Outputs:

```hcl
output "guardrail_id" {
  value = aws_bedrock_guardrail.hr_assistant.guardrail_id
}

output "guardrail_version" {
  value = aws_bedrock_guardrail.hr_assistant.version
}
```

---

## Component 3 — Agent Manifest and AgentCore Configuration

### Terraform resource type — confirm before writing

Before writing any code for this component:

1. Fetch and read the AWS Labs basic-runtime Terraform sample at the URL
   in `CLAUDE.md` (Terraform Authoring Guidelines, Step 1).
2. Check the hashicorp/aws provider documentation for all current
   `aws_bedrockagentcore_*` resource types.

**If a native Terraform resource exists** for registering a named agent
with a system prompt, guardrail, and tool policy — use it.

**If no native Terraform resource exists**, use a `terraform_data` resource
with a `provisioner "local-exec"` block that calls the AgentCore API via
the AWS CLI or SDK to register the agent configuration. Document this
approach clearly in the README with a note that it should be replaced with
a native Terraform resource when the provider adds support. Do not invent
a resource type that does not exist — this will cause plan failures that
are difficult to diagnose.

### Agent configuration values

| Field | Value |
|---|---|
| Agent ID | `hr-assistant-dev` |
| Display name | `HR Assistant (Dev)` |
| Model ARN | `anthropic.claude-sonnet-4-6` |
| System prompt | ARN from Component 1 output (`system_prompt_version_arn`) |
| Guardrail ID | ID from Component 2 output (`guardrail_id`) |
| Guardrail version | Version from Component 2 output (`guardrail_version`) |
| Allowed tools | `[glean-search]` |
| Denied tools | `[all write tools]` |
| Session TTL | 24 hours |
| Long-term memory | Disabled (Phase 2) |
| Data classification ceiling | INTERNAL |
| Grounding score minimum | 0.75 |
| Response latency P95 | 5000ms (dev tolerance) |
| Monthly cost limit | USD 50 |
| Cost alert threshold | 80% |

### Layer ownership

The agent manifest lives in `agents/hr-assistant/`, not `platform/`.
The platform layer cannot own these resources because the manifest
references Component 1 and Component 2 outputs which belong to this layer.

Read platform remote state for the runtime endpoint and gateway ID:

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

Reference `data.terraform_remote_state.platform.outputs.agentcore_endpoint_id`
and `data.terraform_remote_state.platform.outputs.agentcore_gateway_id`.
Do not hardcode these values.

---

## Component 4 — Prompt Vault Lambda Write Path

Every interaction the HR Assistant has must be written to the Prompt Vault
before it is considered complete. Without this write path, interaction data
is lost permanently and quality scoring is impossible.

### Lambda handler

Create `terraform/dev/agents/hr-assistant/prompt-vault/handler.py`.

The handler must:

- Receive an AgentCore post-invocation event containing: session ID, input,
  output, tool calls made, guardrail result, token counts, and latency
- Construct a structured Prompt Vault record as JSON:

```json
{
  "record_id":          "<UUID generated at write time>",
  "timestamp":          "<ISO 8601 UTC>",
  "agent_id":           "hr-assistant-dev",
  "session_id":         "<from event>",
  "user_input":         "<from event>",
  "agent_response":     "<from event>",
  "tool_calls":         [{"tool_name": "...", "input": "...", "output": "..."}],
  "guardrail_result":   {"action": "...", "topic_policy_result": "...", "content_filter_result": "..."},
  "model_arn":          "<from event>",
  "input_tokens":       0,
  "output_tokens":      0,
  "latency_ms":         0,
  "data_classification": "INTERNAL",
  "environment":        "dev"
}
```

- Write the record to S3 at this key pattern:
  `prompt-vault/hr-assistant/YYYY/MM/DD/<record_id>.json`
- Log the write operation as structured JSON to stdout (ADR-003):

```json
{"event": "prompt_vault_write", "record_id": "...", "session_id": "...", "status": "success", "latency_ms": 0}
```

- Target arm64/Graviton (ADR-004). Runtime: python3.12.

### IAM role — inline in agents/hr-assistant (Option B)

Create the Lambda execution role inline in `main.tf`. Do not reference
a `lambda_execution_role_arn` output from platform remote state — that
output does not exist and platform does not own Lambda IAM roles for
agent layers.

The inline role policy must include exactly these permissions:

```hcl
# S3 write to Prompt Vault — scoped to hr-assistant prefix only
statement {
  sid    = "PromptVaultWrite"
  effect = "Allow"
  actions = ["s3:PutObject"]
  resources = [
    "${data.terraform_remote_state.platform.outputs.prompt_vault_bucket_arn}/prompt-vault/hr-assistant/*"
  ]
}

# KMS — required to write to the KMS-encrypted Prompt Vault bucket
# Without these actions the Lambda receives AccessDenied at runtime,
# not at plan time. The failure is silent until first invocation.
statement {
  sid    = "PromptVaultKMS"
  effect = "Allow"
  actions = ["kms:GenerateDataKey", "kms:Decrypt"]
  resources = [data.terraform_remote_state.platform.outputs.kms_key_arn]
}

# CloudWatch Logs — scoped to this Lambda's log group only
statement {
  sid    = "CloudWatchLogs"
  effect = "Allow"
  actions = [
    "logs:CreateLogGroup",
    "logs:CreateLogStream",
    "logs:PutLogEvents"
  ]
  resources = [
    "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/lambda/hr-assistant-prompt-vault-writer-dev:*"
  ]
}
```

### Terraform resources

In `terraform/dev/agents/hr-assistant/main.tf` create:

- `aws_iam_role.prompt_vault_writer` — inline execution role with the
  policy above
- `aws_lambda_function` for the Prompt Vault writer:
  - Runtime: python3.12, architecture: arm64
  - Timeout: 30 seconds
  - Environment variables:
    - `PROMPT_VAULT_BUCKET`: from `data.terraform_remote_state.platform.outputs.prompt_vault_bucket`
    - `AGENT_ID`: `"hr-assistant-dev"`
    - `ENVIRONMENT`: `"dev"`
- `aws_lambda_permission` to allow AgentCore to invoke it
- `aws_cloudwatch_log_group` for the Lambda with 30-day retention

Output:

```hcl
output "prompt_vault_writer_arn" {
  value = aws_lambda_function.prompt_vault_writer.arn
}
```

---

## Component 5 — Golden Dataset

Create `terraform/dev/agents/hr-assistant/test/golden-dataset.json`.

Write 15 test cases covering these categories:

**In-scope queries (8 cases) — agent should answer:**
1. Annual leave entitlement query
2. Sick leave policy query
3. Parental leave duration query
4. Remote working policy query
5. Expense claim procedure query
6. Performance review process query
7. Employee assistance programme query
8. Benefits enrolment deadline query

**Out-of-scope queries (4 cases) — agent should decline:**
9. Request for legal advice (decline and redirect to Legal)
10. Request about another employee's salary (decline — Employee Personal Information guardrail)
11. Medical advice request (decline and redirect to EAP)
12. Financial investment advice (decline and redirect to financial adviser)

**Edge cases (3 cases):**
13. Ambiguous query that could be in or out of scope
14. Query containing PII in the input (name or email address)
15. Employee expressing distress (redirect to EAP immediately — no policy answer)

Each test case must have:

```json
{
  "id": 1,
  "category": "in-scope",
  "input": "<the user message>",
  "expected_behaviour": "<description of what a correct response does — behaviour, not exact wording>",
  "tool_expected": true,
  "guardrail_expected": null,
  "pass_criteria": "<the conditions that make this a passing response>"
}
```

Format: a JSON array of 15 objects.

---

## Component 6 — Validation

Run from `terraform/dev/agents/hr-assistant/`:

```bash
# Confirm terraform.tfvars exists — it should be present from earlier setup.
# If it does not exist, copy from example and populate environment-specific values only.
# Confirm the file is git-ignored before proceeding. Do not commit it.
ls terraform.tfvars || (cp terraform.tfvars.example terraform.tfvars && echo "Created from example — populate before planning")

terraform init
terraform validate
terraform plan -out=tfplan
```

All variables with safe defaults (`aws_region`, `environment`, `project_name`, `tags`)
must have sensible defaults defined in `variables.tf` so that `terraform.tfvars`
only needs to supply genuinely environment-specific values (e.g. `account_id`).

Show the full `terraform validate` output and `terraform plan` summary.

If validate or plan fails: stop, report the full error. Do not attempt to fix
errors without reporting them first. Do not run `terraform apply`.

---

## README Update

Update `terraform/dev/agents/hr-assistant/README.md` to document:

- All six components built in this session
- The system prompt location (`prompts/hr-assistant-system-prompt.txt`) and
  how to update it (edit the file and create a new `aws_bedrock_prompt_version`)
- The dev placeholder strings and what to replace them with before production
- The guardrail configuration — topic policies, content filter sensitivities,
  PII anonymization, grounding threshold — and how to adjust each
- The Prompt Vault write path: Lambda name, S3 key pattern
  (`prompt-vault/hr-assistant/YYYY/MM/DD/<record_id>.json`), and how to query records
- The golden dataset location and how to add test cases
- The agent manifest configuration: model ARN, tool policy, session TTL
- How to invoke the agent for manual testing once deployed
- Known limitations in Phase 1:
  - No Bedrock Knowledge Base (Phase 2)
  - Glean stub Lambda returns mock results, not real Glean search
  - System prompt contains dev placeholders — not for production use
  - If Component 3 used `local-exec` instead of a native Terraform resource,
    document that explicitly and link to the provider issue or feature request

---

## Commit Strategy

One commit per component — do not combine:

```
feat(agents/hr-assistant): add system prompt in Bedrock Prompt Management
feat(agents/hr-assistant): add guardrails with topic policies and PII handling
feat(agents/hr-assistant): wire agent manifest with system prompt and guardrail
feat(agents/hr-assistant): add Prompt Vault Lambda write path
feat(agents/hr-assistant): add golden dataset with 15 test cases
docs(agents/hr-assistant): update README with all Phase 1 components
```

Do not commit `terraform.tfvars` or `tfplan` files.

---

## Completion Report

When all components are complete provide:

- **Component 1:** Prompt version ARN
- **Component 2:** Guardrail ID and version
- **Component 3:** Confirmation that agent manifest is wired to platform
  remote state with no hardcoded ARNs. If `local-exec` was used, state that
  explicitly and describe the CLI command used.
- **Component 4:** Lambda ARN and S3 key pattern confirmed
- **Component 5:** Count of test cases by category (in-scope / out-of-scope / edge)
- **Component 6:** Full `terraform validate` output and plan resource count
- All six commit hashes

---

## Design Decisions Record

| Decision | Rationale |
|---|---|
| `file()` not `templatefile()` for system prompt | Dev prompt uses literal placeholder strings — no variable substitution needed at plan time. Simpler and avoids a variable requirement. |
| IAM role inline in agents/hr-assistant | Option B ownership: each layer creates its own IAM inline. Platform does not export lambda_execution_role_arn — that output does not exist and would be architecturally incorrect. |
| KMS permissions required in Lambda role | Prompt Vault bucket is KMS-encrypted. Without kms:GenerateDataKey and kms:Decrypt the Lambda silently fails at first invocation, not at plan time. |
| Agent manifest in agents/hr-assistant, not platform | Manifest references Component 1 and 2 outputs which are owned by this layer. Platform cannot depend on agent layer outputs. |
| terraform_data + local-exec fallback for agent manifest | AgentCore Terraform provider coverage is still maturing. If no native resource exists, local-exec is the correct pragmatic approach with a clear upgrade path documented. |
| PII anonymize not block | Employees legitimately include their own details in HR queries. Blocking would harm usability. Anonymizing preserves the interaction while protecting PII in responses. |
| Grounding threshold 0.75 | Matches the platform-level quality SLA minimum. Responses below this are more likely to be hallucinated. Dev tolerance allows iteration. |
