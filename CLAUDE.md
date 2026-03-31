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
Location: docs/Enterprise_AI_Platform_Architecture.md
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
- ADR-017 (infrastructure/): One state file per deployment layer per
                             account in S3 with DynamoDB locking.
                             Dev environment uses foundation/, platform/,
                             tools/, and agents/ layers with separate
                             state keys. Never share state across
                             accounts or layers.
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

---

## Terraform Authoring Guidelines

Follow these four steps in order when writing Terraform for any
AgentCore or Bedrock resource. Do not skip steps.

### Step 1 — Fetch the AWS Labs baseline
Fetch and read the relevant pattern from the AgentCore samples
repository before writing any resource definitions. Do not rely
on training knowledge for AgentCore resource definitions —
AgentCore reached GA in October 2025 and training knowledge
may be incomplete or outdated.

  Basic runtime (AgentCore endpoint):
  https://github.com/awslabs/amazon-bedrock-agentcore-samples/tree/main/04-infrastructure-as-code/terraform/basic-runtime

  MCP server and Gateway:
  https://github.com/awslabs/amazon-bedrock-agentcore-samples/tree/main/04-infrastructure-as-code/terraform/mcp-server-agentcore-runtime

  Multi-agent workflows:
  https://github.com/awslabs/amazon-bedrock-agentcore-samples/tree/main/04-infrastructure-as-code/terraform/multi-agent-runtime

Use the sample to understand the required resource types, mandatory
arguments, and dependency relationships. Use it as the baseline —
not as a copy-paste source.

### Step 2 — Adapt to platform standards
After reading the sample, apply these constraints before writing
any code:

- ADR-001: Replace any hardcoded credentials, environment variable
  credentials, or instance profiles with IRSA-scoped IAM roles.
  All service identities use IAM roles assumed at execution time.
  Never use long-lived credentials anywhere.

- ADR-004: All container resources must target arm64/Graviton.
  Set platform = "linux/arm64" on all container definitions.
  See the ARM64 / Graviton Requirement section for the exact
  Python dependency packaging command.

- ADR-017: Each deployment layer owns its own IAM resources (Option B).
  Never define IAM roles inside reusable service modules (agentcore/,
  storage/, etc.). IAM roles belong inline in the deployment layer that
  owns the resource they protect (platform/, tools/<name>/, agents/<name>/).
  Every service module receives role ARNs as input variables.

- Architecture document Section 5.2: Use the agent manifest
  schema for all AgentCore agent configuration values.

- Architecture document Section 4.1: Use only the approved
  model ARNs defined in the Approved Bedrock Model ARNs section
  of this file. Never hardcode model identifiers.

### Step 3 — Enforce module boundaries
Never define IAM resources inside bedrock/, agentcore/,
networking/, storage/, or observability/ modules.
IAM roles and policies belong inline in the deployment layer that owns the
resource (platform/, tools/<name>/, agents/<name>/). Service modules receive
role ARNs as input variables — they never create roles themselves.

Never define networking resources inside service modules.
All VPCs, subnets, and security groups belong in networking/.
Service modules receive vpc_id, subnet_ids, and
security_group_ids as input variables.

Never define storage resources inside service modules.
All S3 buckets and DynamoDB tables belong in storage/.
Service modules receive bucket names and table names as
input variables.

### Step 4 — Use consistent variable names
Use these variable names across all modules so root module
wiring in dev/main.tf is predictable and readable:

  vpc_id           — VPC identifier
  subnet_ids       — List of subnet identifiers
  aws_region       — AWS region string
  environment      — Environment name (dev, staging, production)
  project_name     — Project identifier used in resource naming
  tags             — Map of tags applied to all resources
  kms_key_arn      — KMS key ARN for encryption

---

## Dev Environment Scope
This repository currently provisions the DEV environment only.
The dev environment is a single AWS account — not the full
multi-account production topology described in the architecture
document. Build only what is listed here. Do not provision
staging or production resources.

### In scope for dev (Phase 1):
- Single AWS account with Bedrock enabled in us-east-2
- VPC with private subnets and PrivateLink endpoints
  for Bedrock and AgentCore
- IAM roles using IRSA for all service identities
- KMS key for encryption
- One AgentCore endpoint (internal, dev configuration)
- MCP Gateway with stubbed Glean Search Lambda tool
- One test agent (HR Assistant)
- DynamoDB tables for session memory and agent registry
- S3 bucket for Prompt Vault
- CloudWatch log groups and basic alarms

### Deferred to Phase 2 (do not provision now):
- Bedrock Knowledge Base and OpenSearch Serverless collection
- Real Glean MCP endpoint (stub Lambda used in Phase 1)
- Document landing S3 bucket and ingestion pipeline
- Multi-account AWS Organizations structure
- Production or staging AgentCore endpoints
- External production WAF and Cognito user pool
- Fine-tuning pipeline infrastructure
- CodePipeline promotion pipeline

---

## Terraform Structure

The dev environment uses a four-layer structure under
terraform/dev/. Each layer has its own isolated Terraform
state, its own backend.tf, and its own apply boundary.
This provides blast radius isolation and enables self-service
ownership — agent teams can apply the agents/ layer
independently without touching platform or foundation.

### Layer order — always apply in this sequence:

  1. foundation/   — VPC, KMS, ECR. Apply once. Rarely changes.
  2. platform/     — AgentCore, MCP Gateway, storage, observability.
                     Depends on foundation remote state outputs.
  3. tools/<name>/ — MCP tool integrations (e.g. tools/glean/).
                     Depends on platform remote state outputs.
                     Independently deployable per tool.
  4. agents/<name>/ — Agent-specific configuration.
                      Depends on platform remote state outputs.
                      Independently deployable per agent team.

### Never apply layers out of order.
### Never collapse layers into a single root module.
### Each layer must have its own backend.tf and state key.

### Directory layout:

  terraform/
    dev/
      foundation/         # VPC, subnets, security groups, KMS,
      │  backend.tf        # ECR. Apply first. All other layers
      │  main.tf           # depend on these outputs.
      │  variables.tf
      │  outputs.tf
      │  terraform.tfvars         # git-ignored
      │  terraform.tfvars.example # committed
      │
      platform/           # AgentCore runtime, MCP Gateway,
      │  backend.tf        # storage, observability. Reads
      │  main.tf           # foundation remote state.
      │  variables.tf
      │  outputs.tf
      │  smoke-test.sh     # Tests 1-5: run after every apply
      │  terraform.tfvars
      │  terraform.tfvars.example
      │
      tools/
      │  glean/           # Glean stub Lambda registered as
      │     backend.tf     # MCP tool. Reads platform remote
      │     main.tf        # state. Swap stub for real Glean
      │     variables.tf   # endpoint in Phase 2 — no infra
      │     outputs.tf     # changes required.
      │     smoke-test.sh  # Tests 2a-2b: run after every apply
      │     terraform.tfvars
      │     terraform.tfvars.example
      │
      agents/
         hr-assistant/    # HR Assistant agent configuration.
            backend.tf    # Reads platform remote state.
            main.tf       # Agent team ownership boundary.
            variables.tf
            outputs.tf
            terraform.tfvars
            terraform.tfvars.example

  modules/                # Reusable modules called by layers above
    kms/                  # KMS CMK — called by foundation
    networking/           # VPC resources — called by foundation
    agentcore/            # AgentCore runtime and MCP gateway — called by platform
    storage/              # S3, DynamoDB — called by platform
    observability/        # CloudWatch — called by platform
    glean-stub/           # Lambda MCP stub — called by tools/glean
    bedrock/              # DEFERRED — Phase 2 only
    iam/                  # DEPRECATED — replaced by inline IAM in each layer

### State key convention (one per layer):

  foundation:          dev/foundation/terraform.tfstate
  platform:            dev/platform/terraform.tfstate
  tools/glean:         dev/tools/glean/terraform.tfstate
  agents/hr-assistant: dev/agents/hr-assistant/terraform.tfstate

### Remote state pattern between layers:

Platform reads foundation outputs:

  data "terraform_remote_state" "foundation" {
    backend = "s3"
    config = {
      bucket = "ai-platform-terraform-state-dev-096305373014"
      key    = "dev/foundation/terraform.tfstate"
      region = "us-east-2"
    }
  }

Tools and agents read platform outputs the same way.
Tools and agents never read foundation state directly —
always go through platform.

### IAM ownership (Option B):

Each layer creates IAM roles inline in its own main.tf.
Platform creates agentcore_runtime and bedrock_kb roles.
Each tool creates its own Lambda execution role.
Each agent creates its own roles.
Never define IAM roles inside reusable modules (agentcore/,
storage/, networking/, observability/).

When staging and production environments are added, they each
get their own folder at the same level as dev/ with the same
four-layer split. All environment differences live in the
tfvars files and backend configuration — never in module code.

---

## File Conventions

Committed as real files (not .example):
- terraform/dev/foundation/backend.tf            — Real dev values, committed to git.
- terraform/dev/platform/backend.tf              — Real dev values, committed to git.
- terraform/dev/tools/glean/backend.tf           — Real dev values, committed to git.
- terraform/dev/agents/hr-assistant/backend.tf   — Real dev values, committed to git.
- All *.tf module files                          — Always committed as real files.
- terraform.tfvars.example                       — Committed with placeholder values
                                                   as a template for engineers.
- .terraform.lock.hcl                            — Committed so all engineers and CI/CD
                                                   pipelines use identical provider versions.
                                                   Re-run terraform init and commit the
                                                   updated lock file when upgrading providers.

Git-ignored, never committed:
- terraform/dev/foundation/terraform.tfvars         — Environment-specific values.
- terraform/dev/platform/terraform.tfvars           — Environment-specific values.
- terraform/dev/tools/glean/terraform.tfvars        — Environment-specific values.
- terraform/dev/agents/hr-assistant/terraform.tfvars — Environment-specific values.
- .terraform/                          — Provider cache, never committed.
- *.tfstate and *.tfstate.backup       — State files, never committed.
- crash.log                            — Terraform crash log, never committed.
- override.tf                          — Local overrides, never committed.

Never create .example versions of .tf files. The only .example
files in this repository are terraform.tfvars.example in each layer.

---

## Terraform Working Directory and Commands

Each layer has its own working directory. Always cd into
the layer directory before running any Terraform command.

  # Apply in this order — never skip or reverse:

  cd terraform/dev/foundation
  terraform init && terraform plan -out=tfplan
  # Wait for human review and approval before applying
  terraform apply tfplan

  cd terraform/dev/platform
  terraform init && terraform plan -out=tfplan
  terraform apply tfplan

  cd terraform/dev/tools/glean
  terraform init && terraform plan -out=tfplan
  terraform apply tfplan

  cd terraform/dev/agents/hr-assistant
  terraform init && terraform plan -out=tfplan
  terraform apply tfplan

  # Teardown in reverse order:

  cd terraform/dev/agents/hr-assistant && terraform destroy -auto-approve
  cd terraform/dev/tools/glean && terraform destroy -auto-approve
  cd terraform/dev/platform && terraform destroy -auto-approve
  cd terraform/dev/foundation && terraform destroy -auto-approve

Never run terraform apply without first running terraform plan
and presenting the output for human review. Do not run
terraform apply autonomously.

---

## Terraform State Configuration
Each deployment layer has its own state file in S3 with DynamoDB locking.
ADR-017 rule applied as: one state file per deployment layer per account.
You must create the S3 bucket and DynamoDB table manually before
running terraform init. Use these exact resource names:

  S3 bucket:       ai-platform-terraform-state-dev-096305373014
  DynamoDB table:  ai-platform-terraform-lock-dev
  Region:          us-east-2

  Foundation state key:          dev/foundation/terraform.tfstate
  Platform state key:            dev/platform/terraform.tfstate
  Glean tool state key:          dev/tools/glean/terraform.tfstate
  HR Assistant agent state key:  dev/agents/hr-assistant/terraform.tfstate

Never use local state. Never share state files across environments
or across layers within the same environment.

---

## Approved Bedrock Model ARNs
Only these model ARNs may be used in any Terraform resource,
agent manifest, or application code in this repository:

  Region (all environments):  us-east-2
  Primary reasoning (dev):    anthropic.claude-sonnet-4-6
  Evaluation/scoring:         anthropic.claude-haiku-4-5-20251001
  Embeddings:                 amazon.titan-embed-text-v2:0

All Bedrock and AgentCore resources must be provisioned in us-east-2.
Never hardcode model ARNs in module code. Reference them through
the variables defined in variables.tf.

---

## ARM64 / Graviton Requirement
All container images and Lambda functions must target arm64.
AgentCore runtimes run on Graviton. Building Python dependencies
on x86 causes silent import errors at runtime — not build errors.
This failure mode is silent and will only surface when the agent
is invoked, not during terraform apply.

When packaging Python dependencies for Lambda or AgentCore:

```bash
uv pip install \
  --python-platform aarch64-manylinux2014 \
  --python-version "3.12" \
  --target="$BUILD_DIR" \
  --only-binary=:all:
```

Never omit --only-binary=:all: — it is required for cross-platform
binary compatibility. Never build dependencies on an x86 machine
without this flag and expect them to run on Graviton.

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
- All secrets are managed through AWS Secrets Manager accessed
  via IRSA-scoped roles — never passed as Terraform variables

---

## Commit Granularity
Commit infrastructure changes at module granularity — one commit
per module when building the initial scaffold, one commit per
logical change when modifying existing modules.

Do not commit all modules in a single commit. Individual module
commits make the git history useful for understanding what was
built and when, and make rollback straightforward if a specific
module has a problem.

Commit message format:
  feat(layer-or-module): description of what was added
  fix(layer-or-module): description of what was corrected
  docs(layer-or-module): documentation update only

Examples:
  feat(foundation): add VPC, subnets, and PrivateLink endpoints
  feat(foundation): add IRSA roles for AgentCore and Lambda
  feat(platform): add AgentCore runtime and MCP Gateway
  feat(platform): add DynamoDB session memory and Prompt Vault
  feat(tools/glean): add Glean stub Lambda MCP tool registration
  feat(agents/hr-assistant): add HR Assistant agent configuration
  fix(platform): correct AgentCore runtime arm64 configuration
  docs(foundation): update README with VPC CIDR documentation

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
