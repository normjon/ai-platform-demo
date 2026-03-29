# CLAUDE.md — Enterprise AI Platform Infrastructure

## Primary Audience
Claude Code agents. Human engineers are the secondary audience.
All instructions are imperative commands. When these instructions
conflict with a simpler or more obvious approach, follow these
instructions — the simpler approach was considered and rejected.

---

## Project Purpose
This repository provisions the infrastructure for the Enterprise AI
Platform built on AWS Bedrock, Amazon Bedrock AgentCore, and Glean.
The platform is governed by two authoritative knowledge sources that
must be read before generating any resource, module, or configuration.

---

## Authoritative Knowledge Sources

### 1 — Architecture Document
Location: docs/Enterprise_AI_Platform_Architecture_v2.docx
Read this before designing any component. It defines the account
structure, OU hierarchy, service catalogue, agent manifest schema,
MCP Gateway topology, memory architecture, security posture, and
the four-phase rollout roadmap. When in doubt about what to build
or how to configure it, the architecture document is the source
of truth.

### 2 — ADR Library
Repository: https://github.com/normjon/claude-foundation-best-practice
Read the relevant domain folder CLAUDE.md before writing any code.
Domain routing:
- Provisioning AWS resources          → security/ then infrastructure/
- Writing application or agent code   → application/ then ai-platform/
- Setting up logging or monitoring    → observability/
- Creating branches or pipeline jobs  → process/
- Building or configuring agents      → ai-platform/

Critical rules from the ADR library (read the full ADR for rationale):
- ADR-001 (security/):       Use IRSA for all AWS credential delivery.
                             Never use node instance profiles or env vars.
- ADR-003 (observability/):  All logs must be structured JSON to stdout.
- ADR-004 (infrastructure/): All containers must target arm64/Graviton.
                             Build Python dependencies with explicit
                             platform targeting — never build on x86
                             for arm64 runtimes.
- ADR-005 (infrastructure/): Use staged Terraform apply for
                             CRD-dependent resources.
- ADR-009 (application/):    Image tags must be git SHA. Never use
                             'latest' in staging or production.
- ADR-013 (process/):        GitFlow branching. Never commit directly
                             to main or develop.
- ADR-015 (process/):        Update README.md and CLAUDE.md in the
                             same PR as any change that affects
                             agent or infrastructure behaviour.
- ADR-017 (infrastructure/): Each AWS account has exactly one
                             Terraform state file in S3 with
                             DynamoDB locking. Never share state
                             across accounts.
- ADR-018 (security/):       Validate all MCP Gateway inputs against
                             declared JSON schema before execution.
- ADR-021 (ai-platform/):    All agent repositories must follow the
                             three-level CLAUDE.md hierarchy.

---

## External Reference Libraries
Read these before generating AgentCore or Bedrock resource definitions:
- AgentCore Terraform samples:
  https://github.com/awslabs/amazon-bedrock-agentcore-samples/tree/main/04-infrastructure-as-code/terraform
- AgentCore Fullstack Template (FAST):
  https://github.com/awslabs/fullstack-solution-template-for-agentcore
- Anthropic Claude patterns:
  https://github.com/anthropics/claude-cookbooks
- Claude on AWS patterns:
  https://github.com/aws-samples/anthropic-on-aws

Start with the basic-runtime Terraform pattern from the AgentCore
samples as the baseline for any AgentCore runtime resource. Adapt
it to follow ADR-001, ADR-004, and ADR-017 before using it.

---

## Dev Environment Scope
This repository currently provisions the DEV environment only.
The dev environment is a single AWS account — not the full
multi-account production topology described in the architecture
document. Build only what is listed here. Do not provision
staging or production resources.

### In scope for dev:
- Single AWS account with Bedrock enabled
- One AgentCore endpoint (internal, dev configuration)
- One Bedrock Knowledge Base (Platform Documentation KB)
- OpenSearch Serverless collection for the Knowledge Base index
- MCP Gateway with Glean Search tool registered
- One test agent (HR Assistant) exercising the end-to-end path
- DynamoDB tables for session memory and agent registry
- CloudWatch log groups and basic alarms
- IAM roles following IRSA pattern for all service identities
- S3 buckets for Terraform state, Prompt Vault, and document landing

### Out of scope for dev (do not provision):
- Multi-account AWS Organizations structure
- Production or staging AgentCore endpoints
- External production WAF and Cognito user pool
- Fine-tuning pipeline infrastructure
- Full MCP tool catalogue beyond Glean Search
- CodePipeline promotion pipeline (manual deployment in dev)

---

## Terraform Structure
All Terraform lives under terraform/ at the repository root.
Use this module structure exactly:
```
terraform/
  backend.tf          # Remote state config — S3 + DynamoDB
  main.tf             # Root module — calls child modules
  variables.tf        # Input variables with descriptions
  outputs.tf          # Output values referenced by other modules
  terraform.tfvars    # Dev environment variable values (git-ignored)
  terraform.tfvars.example  # Template with placeholder values (committed)
  /modules/
    bedrock/          # Bedrock KB, model access, guardrails
    agentcore/        # AgentCore runtime, memory, gateway
    networking/       # VPC, subnets, security groups, PrivateLink
    iam/              # All IAM roles and policies (IRSA pattern)
    storage/          # S3 buckets, DynamoDB tables
    observability/    # CloudWatch log groups, alarms, dashboards
```

Each module must have its own README.md describing its purpose,
inputs, outputs, and any non-obvious implementation decisions.
Update the module README.md in the same PR as any module change.

---

## Terraform State Configuration
State file lives in S3 with DynamoDB locking per ADR-017.
You must create the S3 bucket and DynamoDB table manually before
running terraform init. Use these exact resource names:

  S3 bucket:       ai-platform-terraform-state-dev-<account-id>
  DynamoDB table:  ai-platform-terraform-lock-dev
  State file key:  dev/terraform.tfstate

Never use local state. Never share this state file with another
environment. Configure backend.tf from backend.tf.example before
running terraform init.

---

## Approved Bedrock Model ARNs
Only these model ARNs may be used in any Terraform resource,
agent manifest, or application code in this repository:

  Primary reasoning (dev):  anthropic.claude-sonnet-4-6
  Evaluation/scoring:       anthropic.claude-haiku-4-5-20251001
  Embeddings:               amazon.titan-embed-text-v2:0

Never hardcode model ARNs in module code. Reference them through
the variables defined in variables.tf.

---

## ARM64 / Graviton Requirement
All container images and Lambda functions must target arm64.
AgentCore runtimes run on Graviton. Building Python dependencies
on x86 causes silent import errors at runtime.

When packaging Python dependencies for Lambda or AgentCore:
  uv pip install \
    --python-platform aarch64-manylinux2014 \
    --python-version "3.12" \
    --target="$BUILD_DIR" \
    --only-binary=:all:

Never omit --only-binary=:all: — it is required for cross-platform
compatibility.

---

## Security Requirements
- All S3 buckets must have public access blocked and versioning enabled
- All DynamoDB tables must use KMS encryption
- All Lambda functions must use IRSA-scoped execution roles
- All AgentCore endpoints must be private — no public internet exposure
  in the dev environment
- No long-lived AWS credentials anywhere in the codebase, environment
  variables, or Terraform variable files
- terraform.tfvars is git-ignored — never commit it

---

## Documentation Gap Resolution
If at any point you cannot find complete, unambiguous guidance in
this CLAUDE.md, the architecture document, or the ADR library:

1. Do not make assumptions. Stop and surface the gap explicitly.
2. Resolve the gap with the engineer using their direct knowledge.
3. Generate a documentation update — either a CLAUDE.md addition,
   a new ADR in the ADR library, or a docs/ update as appropriate.
4. Apply the update before proceeding. Do not carry undocumented
   decisions forward in the session without recording them.

---

## Definition of Done — Dev Environment
The dev environment is considered operational when:
- terraform apply completes with zero errors
- The HR Assistant test agent can be invoked end-to-end through
  the AgentCore endpoint
- The agent retrieves a document from the Platform Documentation
  Knowledge Base and returns a grounded response
- The Glean Search MCP tool is registered in the Gateway and
  returns results for a test query
- CloudWatch logs show structured JSON for all agent invocations
- All IAM roles use IRSA — no instance profiles or env var credentials
  exist in the deployed infrastructure
