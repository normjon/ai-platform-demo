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

- ADR-017: Reference IAM roles from the iam/ module outputs.
  Never define IAM roles inline inside a resource module.
  Every module receives role ARNs as input variables.

- Architecture document Section 5.2: Use the agent manifest
  schema for all AgentCore agent configuration values.

- Architecture document Section 4.1: Use only the approved
  model ARNs defined in the Approved Bedrock Model ARNs section
  of this file. Never hardcode model identifiers.

### Step 3 — Enforce module boundaries
Never define IAM resources inside bedrock/, agentcore/,
networking/, storage/, or observability/ modules.
All IAM roles, policies, and attachments belong in iam/.
Other modules receive role ARNs as input variables.

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
  dev/
    main.tf                   # Calls child modules, dev-specific config
    backend.tf                # Dev account state — committed with real values
    variables.tf              # Input variables with descriptions
    outputs.tf                # Output values referenced by other modules
    terraform.tfvars          # Dev values — git-ignored, never committed
    terraform.tfvars.example  # Placeholder template — committed
  modules/
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

When staging and production environments are added, they each
get their own folder at the same level as dev/ sharing the same
modules. All environment differences live in the tfvars files
and backend configuration — never in the module code itself.

---

## File Conventions

Committed as real files (not .example):
- terraform/dev/backend.tf        — Real dev values, committed to git.
                                    Does not contain secrets.
- All *.tf module files            — Always committed as real files.
- terraform.tfvars.example         — Committed with placeholder values
                                    as a template for engineers.
- .terraform.lock.hcl              — Committed so all engineers and CI/CD
                                    pipelines use identical provider versions.
                                    Re-run terraform init and commit the
                                    updated lock file when upgrading providers.

Git-ignored, never committed:
- terraform/dev/terraform.tfvars   — Contains environment-specific values.
                                    Copy from terraform.tfvars.example
                                    and populate before running Terraform.
- .terraform/                      — Provider cache, never committed.
- *.tfstate and *.tfstate.backup   — State files, never committed.
- crash.log                        — Terraform crash log, never committed.
- override.tf                      — Local overrides, never committed.

Never create .example versions of .tf files. The only .example
file in this repository is terraform.tfvars.example.

---

## Terraform Working Directory and Commands
Always run Terraform commands from terraform/dev/ — not from
the repository root or any other directory.

```bash
cd terraform/dev

# One-time setup — create backend state resources first (manual)
# Then initialise:
terraform init

# Always review the plan before applying:
terraform plan -out=tfplan

# Apply only after human review and explicit approval:
terraform apply tfplan
```

Never run terraform apply without first running terraform plan
and presenting the plan output for human review. Do not run
terraform apply autonomously. Generate the plan, show it, and
wait for explicit instruction to apply.

---

## Terraform State Configuration
State file lives in S3 with DynamoDB locking per ADR-017.
You must create the S3 bucket and DynamoDB table manually before
running terraform init. Use these exact resource names:

  S3 bucket:       ai-platform-terraform-state-dev-096305373014
  DynamoDB table:  ai-platform-terraform-lock-dev
  State file key:  dev/terraform.tfstate
  Region:          us-east-2

Never use local state. Never share this state file with another
environment.

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
  feat(module-name): description of what was added
  fix(module-name): description of what was corrected
  docs(module-name): documentation update only

Examples:
  feat(iam): add IRSA roles for AgentCore runtime and gateway
  feat(networking): add VPC, subnets, and PrivateLink endpoints
  fix(bedrock): correct Knowledge Base chunking strategy variable

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
