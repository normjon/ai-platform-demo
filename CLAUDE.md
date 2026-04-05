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

### 2 — Layer README files

Every Terraform layer has a README.md. Read the README.md of any
layer you are working in or depending on before making changes.
READMEs document current state, known issues, prerequisites, and
operational nuances that are not derivable from the Terraform code
alone. Failing to read the README before acting has caused wasted
work in this project (e.g. attempting platform operations without
understanding the S3 purge requirement or the container image
prerequisite).

Layer READMEs:
- terraform/dev/foundation/README.md
- terraform/dev/platform/README.md
- terraform/dev/tools/glean/README.md
- terraform/dev/agents/hr-assistant/README.md

### 3 — ADR Library

Repository: https://github.com/normjon/claude-foundation-best-practice
Local path: `docs/adrs/` (git submodule — read from here, do not WebFetch)

The ADR library is mounted as a git submodule at `docs/adrs/`. Always read
from the local path — it is faster, supports grep across all files, and
does not require network access. If the submodule directory is empty, run:

```bash
git submodule update --init --recursive
```

Read `docs/adrs/CLAUDE.md` for domain routing and folder structure before
writing any code.

Read `docs/adrs/CLAUDE.md` for global rules that apply across all projects
(credentials, logging, image tags, branching, documentation, CI/CD applies).

Project-specific ADR constraints for this repository:
- ADR-004 (infrastructure/): All containers must target arm64/Graviton.
                             Build Python dependencies with explicit
                             platform targeting — never build on x86
                             for arm64 runtimes.
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

**IAM** — Option B: inline ownership, never a shared module.
Never put IAM roles or policies inside any reusable module
(agentcore/, storage/, networking/, observability/, or the
deprecated iam/ module). modules/iam/ is deprecated — do not
add resources to it. IAM roles belong inline in the deployment
layer that owns the resource they protect:
  platform/      — agentcore_runtime role
  tools/<name>/  — that tool's Lambda execution role
  agents/<name>/ — that agent's roles (including per-agent KB service roles)
Service modules receive role ARNs as input variables and never
create roles themselves.

**Networking** — centralised in networking/, not in service modules.
Never define VPCs, subnets, or security groups inside agentcore/,
storage/, observability/, or any other service module.
Service modules receive vpc_id, subnet_ids, and
security_group_ids as input variables.

**Storage** — centralised in storage/, not in service modules.
Never define S3 buckets or DynamoDB tables inside agentcore/,
observability/, or any other service module.
Service modules receive bucket names and table names as
input variables.

### Step 4 — Use consistent variable names

Use these variable names across all modules so wiring between
deployment layers and modules is predictable and readable:

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

### In scope for dev (Phase 1 + Phase 2 complete):

- Single AWS account with Bedrock enabled in us-east-2
- VPC with private subnets and PrivateLink endpoints
  for Bedrock and AgentCore
- IAM roles using IRSA for all service identities
- KMS key for encryption
- One AgentCore endpoint (internal, dev configuration)
- MCP Gateway with stubbed Glean Search Lambda tool
- One agent (HR Assistant) — arm64 container, live invocations
- DynamoDB tables for session memory and agent registry
- S3 bucket for Prompt Vault
- CloudWatch log groups and basic alarms
- Shared OpenSearch Serverless collection (`ai-platform-kb-dev`) — owned by platform layer
- HR Policies Knowledge Base (Bedrock KB + per-index AOSS access policy) — owned by hr-assistant layer
- 8 HR policy documents in document landing S3 bucket

### Deferred (do not provision):

- Real Glean MCP endpoint (stub Lambda used in dev)
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
  # IMPORTANT: agents and tools MUST be destroyed before platform.
  # platform/main.tf has data "aws_lambda_function" "prompt_vault_writer" which
  # reads the Prompt Vault Lambda at plan time. If agents layer is not destroyed
  # first (Lambda deleted), platform destroy will fail with ResourceNotFoundException.

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
  Evaluation/scoring:         us.anthropic.claude-haiku-4-5-20251001-v1:0
  Embeddings:                 amazon.titan-embed-text-v2:0

All Bedrock and AgentCore resources must be provisioned in us-east-2.
Never hardcode model ARNs in module code. Reference them through
the variables defined in variables.tf.

**Claude 4.x cross-region inference profile requirement:**
Claude 4.x models (claude-sonnet-4-6, claude-opus-4-6) require the
cross-region inference profile prefix for on-demand throughput. Using
the bare model ID causes:
  `"Invocation of model ID anthropic.claude-sonnet-4-6 with on-demand
   throughput isn't supported"`

Use the `us.*` prefixed inference profile everywhere — variables.tf
defaults, DynamoDB manifest items, and application code:

  Correct:   us.anthropic.claude-sonnet-4-6
  Incorrect: anthropic.claude-sonnet-4-6

The IAM `bedrock:InvokeModel` resource list must include BOTH:
  arn:aws:bedrock:REGION:ACCOUNT:inference-profile/*
  arn:aws:bedrock:*::foundation-model/*

The `inference-profile/*` ARN is required for `us.*` prefix model IDs.
Without it, the runtime receives `AccessDeniedException` even when
`InvokeModel` is otherwise allowed.

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

**uvicorn log-config pitfall:**
Do NOT pass `--log-config /dev/null` to uvicorn in the container CMD.
uvicorn 0.32.1 calls `logging.config.fileConfig()` on the provided path.
`/dev/null` is an empty file; `fileConfig()` raises:
  `RuntimeError: /dev/null is an empty file`
The container crashes at startup with no useful log output.
Use `--no-access-log --log-level warning` instead.

**ECR authentication order:**
When building images that pull from public.ecr.aws and push to a private
ECR registry, authenticate to public ECR first (`--region us-east-1`),
then authenticate to private ECR (`--region us-east-2`). Docker credential
helpers can override each other — the private ECR auth must be the final
state so the push succeeds.

---

## AgentCore Runtime Operational Requirements

These rules apply to every agent layer that provisions an AgentCore runtime
or invokes a container via AgentCore. They were learned during Phase 2
debugging — skipping any of them causes non-obvious failures.

### VPC endpoints and security group egress

The following interface VPC endpoints must exist for AgentCore containers
to start and operate. Missing any one causes `i/o timeout` at startup
or at first tool invocation — not a startup error:

| Endpoint | Reason |
| --- | --- |
| `ecr.api` | Container image manifest pull |
| `ecr.dkr` | Container image layer download |
| `bedrock-agent` | KB retrieval API |
| `bedrock-agent-runtime` | KB retrieve operation at runtime |
| `lambda` | Agent invokes tool Lambdas |
| `s3` (gateway type) | S3 layer downloads during image pull |
| `dynamodb` (gateway type) | Session memory and agent registry |

**Critical:** Security groups evaluate BEFORE gateway endpoint routing.
Egress rules that cover only the VPC CIDR (e.g. `10.0.0.0/16`) silently
block traffic to S3 and DynamoDB even when gateway endpoints exist.
The AgentCore security group MUST use AWS-managed **prefix lists** for
S3 and DynamoDB egress — not CIDR blocks.

Also required: a self-referencing HTTPS ingress rule so the container
can reach interface endpoint ENIs that share the same security group.

Container image pull failures (`dial tcp 3.x.x.x:443: i/o timeout`) are
the symptom of missing prefix-list egress rules.

### AgentCore runtime ARN format

```
arn:aws:bedrock-agentcore:REGION:ACCOUNT:runtime/<runtime-id>
```

NOT `agent-runtime` — that path returns `ResourceNotFoundException`.
Confirm the correct ARN:

```bash
aws bedrock-agentcore-control get-agent-runtime \
  --agent-runtime-id "<runtime-id>" \
  --region us-east-2 \
  --query 'agentRuntimeArn' --output text
```

### sessionId must be in the payload body

`--runtime-session-id` is used by the AgentCore control plane for routing
and billing tracking. It is NOT forwarded to the container as the
`X-Amzn-Bedrock-AgentCore-Session-Id` header.

Always include `sessionId` in the JSON payload body:

```bash
PAYLOAD=$(python3 -c "import json,base64; print(base64.b64encode(json.dumps({
    'prompt': 'your question',
    'sessionId': '${SESSION_ID}'
}).encode()).decode())")
```

Using unique `sessionId` values per invocation is mandatory for session
isolation. Reusing a session ID that has corrupt history (incomplete
`tool_use`/`tool_result` pairs from a failed invocation) causes:
  `Expected toolResult blocks at messages.X.content`

### CloudWatch log group path

```
/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT
```

NOT `/aws/agentcore/<name>` — that path does not exist. When debugging
502 errors or unexpected container behaviour, check this log group first.

### OpenSearch Serverless (AOSS) for Knowledge Bases

**Ownership split:** The platform layer owns the shared AOSS collection
(`ai-platform-kb-dev`), its encryption and network security policies, and
the platform-level data access policy for the Terraform caller. Each agent
layer owns only a per-index data access policy scoped to its own index,
the `null_resource` that pre-creates the index, and the Bedrock KB and
data source resources. Agents read `opensearch_collection_arn`,
`opensearch_collection_endpoint`, and `opensearch_collection_name` from
`data.terraform_remote_state.platform.outputs`.

When provisioning a Bedrock Knowledge Base backed by AOSS:

1. **Vector index must pre-exist.** Bedrock KB does not auto-create the
   OpenSearch vector index. Full apply order across both layers:
   ```
   Platform layer:
     AOSS security policies → AOSS platform data access policy
       → AOSS collection (9 min) → platform outputs available

   Agent layer (reads collection outputs from platform remote state):
     agent data access policy (per-index only)
       → null_resource (60s sleep + create-os-index.py)
         → aws_bedrockagent_knowledge_base
           → aws_bedrockagent_data_source
   ```

2. **AOSS data access policy propagation takes ~60 seconds.** Running
   the index creation script immediately after the policy is applied
   results in `403 Forbidden` even when the policy is correct. Include
   `sleep 60` before the script in local-exec.

3. **Use the stable IAM role ARN, not the STS session ARN.**
   Use `data.aws_iam_session_context.current.issuer_arn` for AOSS data
   access policy principals — NOT `data.aws_caller_identity.current.arn`.
   The SSO session ARN changes every time the token refreshes, causing
   the data access policy match to fail after refresh.

4. **KB IAM role requires KMS Decrypt.**
   If the document landing S3 bucket is KMS-encrypted, the KB service
   role must have `kms:Decrypt` and `kms:GenerateDataKey` for the KMS
   key. Without it, ingestion reports COMPLETE with all documents failed:
   `User: .../kb-role/DocumentLoaderTask-... is not authorized: kms:Decrypt`

5. **Use opensearch-py with AWSV4SignerAuth for AOSS API calls.**
   Raw botocore SigV4 signing against AOSS is fragile. Use:
   ```python
   from opensearchpy import AWSV4SignerAuth, OpenSearch, RequestsHttpConnection
   auth = AWSV4SignerAuth(boto3.Session().get_credentials(), region, "aoss")
   ```

6. **Run local-exec Python scripts via `uv run --with <pkg>` pattern.**
   This avoids system Python pollution without requiring a virtualenv:
   ```
   uv run --with boto3 --with opensearch-py python3 scripts/create-os-index.py
   ```

### Prompt Vault Lambda wiring

The Prompt Vault Lambda ARN is stored in the agent registry table under
`prompt_vault_lambda_arn`. The container reads it at startup via
`agent._load_config()` and passes it to `vault.init()` in `main.startup()`.
If absent, vault writes are silently skipped (`vault_skip` log event) —
the agent continues to function normally.

**The platform layer has no knowledge of any agent's Prompt Vault Lambda.**
Each agent owns its Prompt Vault writer Lambda and registers the ARN in its
own registry manifest. Adding a new agent requires zero platform changes.

The platform IAM policy grants `lambda:InvokeFunction` using a naming
convention wildcard (`*-prompt-vault-writer-*`) so it covers all current
and future agents without requiring a platform code change per agent.

Each agent layer registers its Lambda ARN in the `put-item` manifest block:

```json
"prompt_vault_lambda_arn": {"S": "${aws_lambda_function.prompt_vault_writer.arn}"}
```

This also appears in `triggers_replace` on the `terraform_data` manifest
resource so re-registration fires automatically when the Lambda ARN changes.

**There is no prerequisite ordering between the platform layer and agents layer.**
The platform layer applies cleanly with no knowledge of any agent Lambda.
The agents layer applies after platform and writes the ARN into the registry.
The container reads the ARN at startup — a container restart picks up any
registry change (config changes are infrequent and go through Terraform).

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

### ADR library updates

When a gap or correction belongs in the ADR library (`docs/adrs/`),
draft the change and present it to the engineer for review before
submitting. Do not open a PR to the ADR library autonomously.

ADRs are architectural decisions — they warrant deliberation, not
in-session patches. The workflow is:

1. Identify the gap and the affected ADR or domain folder.
2. Draft the addition or correction in the conversation.
3. Get explicit engineer approval on the content.
4. Create a branch in `docs/adrs/`, apply the change, and open a PR
   to `normjon/claude-foundation-best-practice` for review.

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
