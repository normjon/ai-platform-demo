# HR Assistant Agent Layer — `terraform/dev/agents/hr-assistant/`

Agent-specific configuration for the HR Assistant. Currently a placeholder —
no resources are deployed from this layer. The AgentCore runtime that executes
the HR Assistant is managed by the platform layer.

---

## Purpose

This layer is the HR Assistant team's ownership boundary. It will contain
infrastructure and configuration that is specific to this agent and that the
team can manage independently without involving the platform team:

- Agent-specific IAM grants (e.g. scoped access to specific S3 prefixes)
- Prompt template references and Prompt Vault configuration
- Bedrock Knowledge Base configuration (when KB is in scope)
- Agent manifest and runtime configuration overrides
- Agent-level test harness configuration

When the platform team introduces per-agent runtime isolation (separate
AgentCore endpoints per agent), the runtime resource and its IAM role will
move here from the platform layer.

---

## Current State

No Terraform resources are managed by this layer. The layer exists to:

1. Establish the ownership boundary and state file for the HR Assistant team.
2. Provide a `terraform_remote_state` data source for reading platform outputs,
   ready for when agent-specific resources are added.
3. Demonstrate the pattern for onboarding future agents.

---

## Dependencies

Reads from the platform layer via `terraform_remote_state`:

| Platform output | Will be used for |
|---|---|
| `agentcore_endpoint_id` | Targeting the runtime when configuring agent manifests |
| `agentcore_gateway_id` | If the agent registers its own dedicated MCP tools |
| `session_memory_table` | If agent-specific DynamoDB access grants are needed |
| `document_landing_bucket` | If agent-specific S3 prefix grants are needed |

---

## Prerequisites

- Platform layer applied.
- `terraform.tfvars` created (copy from `.example`).

---

## First-Time Setup

```bash
cd terraform/dev/agents/hr-assistant

# One-time per machine
terraform init

# Create tfvars
cp terraform.tfvars.example terraform.tfvars
# Only account_id is required

terraform plan -out=tfplan
# Expect: No changes (no resources defined yet)
terraform apply tfplan
```

---

## Iterative Cycle

```bash
cd terraform/dev/agents/hr-assistant

terraform destroy -auto-approve
# Expect: 0 resources destroyed

terraform plan -out=tfplan
terraform apply tfplan
# Expect: 0 resources added
```

---

## Adding Agent-Specific Resources

When the HR Assistant team needs to add infrastructure to this layer:

1. Define resources in `main.tf`. Use `data.terraform_remote_state.platform`
   for any values from the platform layer (gateway ID, table names, etc.).
2. Create IAM roles inline in `main.tf` — do not add them to foundation or
   platform (Option B IAM ownership).
3. Add outputs to `outputs.tf` for any values that tests or other systems
   need to reference.
4. Update this README to reflect the new resources, tests, and observability.

---

## Tests

No infrastructure tests apply to this layer while it has no resources.

When resources are added, add test commands here following the same pattern
as `terraform/dev/tools/glean/README.md` — verify each resource is READY
and exercised end-to-end.

---

## Observability

No observability resources are deployed from this layer. The AgentCore runtime
logs for the HR Assistant appear in the platform layer's log group:

```
/aws/agentcore/ai-platform-dev
```

When agent-specific resources are added, document their log groups and
relevant query patterns here.

---

## Onboarding a New Agent

To add a new agent, copy this directory structure:

```bash
cp -r terraform/dev/agents/hr-assistant terraform/dev/agents/<new-agent-name>
```

Update:
- `backend.tf` — change the state key to `dev/agents/<new-agent-name>/terraform.tfstate`
- `main.tf` — add agent-specific resources
- `terraform.tfvars.example` — document required variables
- This README — replace all HR Assistant references

Then run `terraform init` and `terraform apply` from the new directory.
