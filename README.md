# Enterprise AI Platform Infrastructure

Infrastructure as Code for the Enterprise AI Platform built on
AWS Bedrock, Amazon Bedrock AgentCore, and Glean.

## What This Repository Provisions

This repository provisions the AWS infrastructure for a governed,
enterprise-grade AI agent platform. The platform enables engineering
teams to build, deploy, and operate AI agents that are secure,
auditable, and compliant with organisational governance requirements.

The current scope of this repository is the **dev environment** —
a single AWS account deployment used for platform validation and
agent development. The full multi-account production topology is
defined in the architecture document at `docs/` and will be
provisioned in subsequent phases.

## Architecture

The platform is built on three technology pillars:

- **AWS Bedrock** — Managed foundation model access, Knowledge Bases,
  Guardrails, and the governance framework for all AI model invocations
- **Amazon Bedrock AgentCore** — Agent runtime, memory management,
  MCP Gateway for tool access, identity controls, and observability
- **Glean** — Enterprise knowledge layer providing permissions-aware
  search across organisational systems, exposed as an MCP tool

Full architecture documentation is at
`docs/Enterprise_AI_Platform_Architecture.md`.

Agent container documentation (arm64 requirement, image push, placeholder
vs real image) is at `docs/agent-container.md`.

## Repository Structure
```
/
├── CLAUDE.md              # Claude Code agent instructions (read first)
├── README.md              # This file
└── docs/
│   ├── Enterprise_AI_Platform_Architecture.md  # Full platform architecture
│   ├── agent-container.md                      # arm64 image build, push, ECR, placeholder
│   └── playbook-basic-test.md                  # Smoke tests and teardown runbook
└── terraform/
    ├── dev/
    │   ├── foundation/         # Layer 1 — long-lived: VPC, KMS, ECR (platform team)
    │   │   ├── backend.tf          # State key: dev/foundation/terraform.tfstate
    │   │   ├── main.tf             # networking + kms modules + ECR repository
    │   │   ├── variables.tf
    │   │   ├── outputs.tf          # Platform API: VPC, subnets, SGs, KMS, ECR
    │   │   └── terraform.tfvars.example
    │   ├── platform/           # Layer 2 — platform services (platform team)
    │   │   ├── backend.tf          # State key: dev/platform/terraform.tfstate
    │   │   ├── main.tf             # AgentCore runtime + gateway + storage + observability
    │   │   │                       # + shared AOSS collection + platform IAM (agentcore_runtime)
    │   │   ├── variables.tf
    │   │   ├── outputs.tf          # Platform API: gateway_id, tables, buckets, vpc re-exports,
    │   │   │                       # opensearch_collection_arn/endpoint/name/id
    │   │   └── terraform.tfvars.example
    │   ├── tools/
    │   │   └── glean/          # Glean MCP tool (Glean/Search team)
    │   │       ├── backend.tf      # State key: dev/tools/glean/terraform.tfstate
    │   │       ├── main.tf         # Lambda stub + gateway target + Glean IAM role
    │   │       ├── variables.tf
    │   │       ├── outputs.tf
    │   │       └── terraform.tfvars.example
    │   └── agents/
    │       └── hr-assistant/   # HR Assistant agent (placeholder)
    │           ├── backend.tf      # State key: dev/agents/hr-assistant/terraform.tfstate
    │           ├── main.tf         # Agent-specific config (placeholder)
    │           ├── variables.tf
    │           ├── outputs.tf
    │           └── terraform.tfvars.example
    └── modules/            # Reusable modules — shared across layers
        ├── kms/            # KMS CMK (used by foundation only)
        ├── bedrock/        # Bedrock KB, model access, guardrails (future)
        ├── agentcore/      # AgentCore runtime and MCP gateway
        ├── glean-stub/     # Lambda MCP stub for dev Glean testing
        ├── networking/     # VPC, subnets, security groups, VPC endpoints
        ├── storage/        # S3 buckets, DynamoDB tables
        └── observability/  # CloudWatch log groups and alarms
```

## Prerequisites

Before running any Terraform commands:

1. AWS CLI configured with SSO credentials for the dev account
   (run `awssandbox` to refresh if credentials have expired)
2. Terraform >= 1.6 installed
   (use `tfenv` — `brew install terraform` provides a deprecated version)
3. S3 bucket and DynamoDB table for remote state created manually:
   - S3 bucket: `ai-platform-terraform-state-dev-<account-id>`
   - DynamoDB table: `ai-platform-terraform-lock-dev`
4. `terraform.tfvars` created in each layer from the `.example` file

## Getting Started

The dev environment uses four independent Terraform state layers.
**Apply in order: foundation → platform → tools → agents.**

```bash
# 1. Clone the repository
git clone
cd

# ---- Foundation layer (VPC, KMS, ECR) ----

# 2. Configure foundation variables
cp terraform/dev/foundation/terraform.tfvars.example terraform/dev/foundation/terraform.tfvars
# Edit with your account values — never commit terraform.tfvars

# 3. Apply foundation
cd terraform/dev/foundation
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# 4. Push an arm64 agent image to ECR (see docs/agent-container.md for full details)
GIT_SHA=$(git rev-parse --short HEAD)
ECR_URL=$(terraform output -raw ecr_repository_url)
IMAGE_URI="${ECR_URL}:${GIT_SHA}"
aws ecr get-login-password --region us-east-2 \
  | docker login --username AWS --password-stdin "${ECR_URL}"
docker pull --platform linux/arm64 python:3.12-slim
docker tag python:3.12-slim "${IMAGE_URI}"
docker push "${IMAGE_URI}"

# ---- Platform layer (AgentCore runtime, gateway, storage, observability) ----

# 5. Configure platform variables
cp terraform/dev/platform/terraform.tfvars.example terraform/dev/platform/terraform.tfvars
# Set agent_image_uri to the ECR URI with the pushed git SHA tag

# 6. Apply platform layer
cd ../platform
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# ---- Tools layer (each tool team runs their own) ----

# 7. Configure and apply the Glean stub tool
cp terraform/dev/tools/glean/terraform.tfvars.example terraform/dev/tools/glean/terraform.tfvars
cd ../tools/glean
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# ---- Agents layer (each agent team runs their own) ----

# 8. Apply the HR Assistant agent layer (provisions Prompt Vault Lambda, KB, guardrail, agent manifest)
cp terraform/dev/agents/hr-assistant/terraform.tfvars.example terraform/dev/agents/hr-assistant/terraform.tfvars
# Edit with your account values (model_arn, knowledge_base_id, etc.)
cd ../agents/hr-assistant
terraform init
terraform plan -out=tfplan
terraform apply tfplan
# After apply: run KB ingestion (see terraform/dev/agents/hr-assistant/README.md)

# ---- Platform re-apply (wires Prompt Vault Lambda into AgentCore runtime) ----

# 9. Re-apply platform layer — the platform reads the Prompt Vault Lambda ARN via
#    data "aws_lambda_function" which requires the agents layer to be applied first.
cd ../../platform
terraform plan -out=tfplan
terraform apply tfplan
```

> **Apply order note:** The agents layer must be applied before the final platform
> apply because `data "aws_lambda_function" "prompt_vault_writer"` in `platform/main.tf`
> reads the Prompt Vault Lambda ARN from AWS at plan time. If the Lambda does not exist,
> the platform plan will fail. This is the one exception to the strict foundation →
> platform → tools → agents ordering.

## Iterative Dev Cycle

The platform, tools, and agents layers are designed to be destroyed and
reapplied freely. Foundation stays up throughout — no need to re-push the
ECR image between cycles.

```bash
# Tool-only cycle (only the Glean tool, platform stays up)
# Run from terraform/dev/tools/glean/
terraform destroy -auto-approve
terraform plan -out=tfplan
terraform apply tfplan

# Full platform cycle (destroys and recreates platform + all tools/agents)
# Purge S3 versions first — see docs/playbook-basic-test.md S3 Known Issue
cd terraform/dev/tools/glean && terraform destroy -auto-approve
cd terraform/dev/agents/hr-assistant && terraform destroy -auto-approve
cd terraform/dev/platform && terraform destroy -auto-approve
terraform plan -out=tfplan && terraform apply tfplan
cd terraform/dev/tools/glean && terraform plan -out=tfplan && terraform apply tfplan

# Note: terraform init is required once per layer per machine before first use.
# If .terraform/ does not exist in a layer directory, run terraform init first.

# Run smoke tests after any apply
# See docs/playbook-basic-test.md
```

## Teardown

Destroy in reverse dependency order. Never destroy foundation while platform is up.

```bash
# Destroy tools and agents first (order within this group doesn't matter)
cd terraform/dev/tools/glean && terraform destroy -auto-approve
cd terraform/dev/agents/hr-assistant && terraform destroy -auto-approve

# Purge versioned S3 buckets before destroying platform
# See docs/playbook-basic-test.md — S3 versioned buckets not empty

# Then platform
cd terraform/dev/platform && terraform destroy -auto-approve

# Then foundation (only when decommissioning the environment entirely)
cd terraform/dev/foundation && terraform destroy -auto-approve
```

See `docs/playbook-basic-test.md` for known teardown issues (VPC endpoint ENIs,
AgentCore VPC ENIs, S3 versioned bucket cleanup).

## Known Issues

**`dynamodb_table` backend deprecation warning**

Every `terraform init` and `terraform apply` will print:

```
Warning: Deprecated Parameter
The parameter "dynamodb_table" is deprecated. Use parameter "use_lockfile" instead.
```

This is a cosmetic warning from the AWS provider v6 S3 backend. State locking
continues to work correctly with `dynamodb_table`. To silence the warning,
replace `dynamodb_table` with `use_lockfile = true` in both `backend.tf` files
and re-run `terraform init`. The DynamoDB lock table itself is still used when
`use_lockfile = true` — the parameter name changed, not the mechanism.

This is safe to ignore until the next planned provider upgrade.

## Key Decisions

All significant architecture and infrastructure decisions are
documented as Architecture Decision Records (ADRs) in the ADR
library. Read the relevant ADR before making changes that affect
the areas below.

| Decision Area | ADR | Rule Summary |
|---------------|-----|--------------|
| AWS credential delivery | ADR-001 | Use IRSA — never instance profiles or env vars |
| Container architecture | ADR-004 | All containers must target arm64/Graviton |
| Terraform state | ADR-017 | One state file per layer per account — foundation, platform, tools/*, agents/* are separate |
| MCP Gateway input validation | ADR-018 | Validate all inputs against schema before execution |
| Agent CLAUDE.md structure | ADR-021 | Three-level hierarchy for all agent repositories |

ADR Library: https://github.com/normjon/claude-foundation-best-practice

## Definition of Done — Dev Environment

The dev environment is operational when:
- `terraform apply` completes with zero errors
- The HR Assistant test agent can be invoked end-to-end
- The agent retrieves a document from the Knowledge Base
  and returns a grounded response
- The Glean Search MCP tool returns results for a test query
- CloudWatch logs show structured JSON for all agent invocations
- All IAM roles use IRSA with no instance profiles or env var
  credentials in the deployed infrastructure

## Contributing

Follow the GitFlow branching strategy per ADR-013. All PRs must
target `develop`. Never commit directly to `main` or `develop`.

Update this README and CLAUDE.md in the same PR as any change that
affects infrastructure behaviour or agent configuration, per ADR-015.

For infrastructure changes, attach the `terraform plan` output to
your PR before requesting review, per ADR-017.

## Security

- Never commit `terraform.tfvars` — it is git-ignored
- Never store AWS credentials in code, environment variables,
  or variable files
- All secrets are managed through AWS Secrets Manager accessed
  via IRSA-scoped roles
- Report security concerns to the platform team before opening
  a public issue

