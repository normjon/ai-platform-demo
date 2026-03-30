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

## Repository Structure
```
/
├── CLAUDE.md              # Claude Code agent instructions (read first)
├── README.md              # This file
├── docs/                  # Architecture and reference documentation
│   └── Enterprise_AI_Platform_Architecture.md
└── terraform/
    ├── dev/                # Dev environment root — run Terraform from here
    │   ├── backend.tf          # Remote state configuration
    │   ├── main.tf             # Root module — calls all child modules
    │   ├── variables.tf        # Input variables
    │   ├── outputs.tf          # Output values
    │   └── terraform.tfvars.example  # Variable template (copy to terraform.tfvars)
    └── modules/            # Reusable modules — shared across environments
        ├── bedrock/        # Bedrock KB, model access, guardrails
        ├── agentcore/      # AgentCore runtime, memory, gateway
        ├── networking/     # VPC, subnets, security groups, VPC endpoints
        ├── iam/            # IAM roles and policies (IRSA)
        ├── storage/        # S3 buckets, DynamoDB tables
        └── observability/  # CloudWatch log groups and alarms
```

## Prerequisites

Before running any Terraform commands:

1. AWS CLI configured with SSO credentials for the dev account
2. Terraform >= 1.6 installed
   (use `tfenv` — `brew install terraform` provides a deprecated version)
3. S3 bucket and DynamoDB table for remote state created manually:
   - S3 bucket: `ai-platform-terraform-state-dev-<account-id>`
   - DynamoDB table: `ai-platform-terraform-lock-dev`
4. `terraform.tfvars` created from `terraform.tfvars.example`
   and populated with dev account values

## Getting Started
```bash
# 1. Clone the repository
git clone 
cd 

# 2. Configure remote state backend
# Edit terraform/dev/backend.tf — replace <account-id> with your AWS account ID

# 3. Configure variables
cp terraform/dev/terraform.tfvars.example terraform/dev/terraform.tfvars
# Edit terraform.tfvars with your dev environment values
# Never commit terraform.tfvars — it is git-ignored

# 4. Initialise and plan from the dev directory
cd terraform/dev
terraform init

# 5. Always review the plan before applying
terraform plan -out=tfplan

# 6. Apply only after reviewing the plan output
terraform apply tfplan
```

## Key Decisions

All significant architecture and infrastructure decisions are
documented as Architecture Decision Records (ADRs) in the ADR
library. Read the relevant ADR before making changes that affect
the areas below.

| Decision Area | ADR | Rule Summary |
|---------------|-----|--------------|
| AWS credential delivery | ADR-001 | Use IRSA — never instance profiles or env vars |
| Container architecture | ADR-004 | All containers must target arm64/Graviton |
| Terraform state | ADR-017 | One state file per account — never shared |
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

