# Module: iam

All IAM roles, policies, and the shared KMS key for the Enterprise AI Platform.
No other module in this repository may define IAM resources — all IAM belongs here.

## Purpose

This module is the single source of truth for machine identity on the platform.
It creates one dedicated least-privilege IAM role per service, following the
IRSA pattern defined in ADR-001. Each role has a narrowly scoped trust policy
and a policy that grants only the permissions required for that service to
perform its specific function.

The KMS key for encrypting S3 buckets, DynamoDB tables, and CloudWatch log
groups is also created here. Its ARN is exposed as an output so storage/,
observability/, and bedrock/ can consume it without circular dependencies.

This module lives in the **foundation layer** (`terraform/dev/foundation/`).
It is applied once and survives app layer destroy/apply cycles.

## Roles Created

| Role | Name Pattern | Trust Principal | Purpose |
|---|---|---|---|
| AgentCore Runtime | `{project}-agentcore-runtime-{env}` | `bedrock-agentcore.amazonaws.com` | Invokes Bedrock models, writes AgentCore logs, reads/writes session memory |
| Bedrock KB | `{project}-bedrock-kb-{env}` | `bedrock.amazonaws.com` | Reads source documents from S3 for future Knowledge Base ingestion |
| Lambda Execution | `{project}-lambda-{env}` | `lambda.amazonaws.com` | Evaluation and ingestion Lambda functions — scoped to platform resources |

## Input Variables

| Name | Type | Required | Description |
|---|---|---|---|
| `project_name` | `string` | Yes | Project name — used in all resource names |
| `environment` | `string` | Yes | Environment name (dev, staging, production) |
| `aws_region` | `string` | Yes | AWS region — used in model ARNs and log group ARNs within policies |
| `aws_account_id` | `string` | Yes | AWS account ID — used in trust policy conditions and policy resource ARNs |
| `document_bucket_arn` | `string` | Yes | Document landing S3 bucket ARN — granted to the KB role and Lambda role |
| `prompt_vault_bucket_arn` | `string` | Yes | Prompt Vault S3 bucket ARN — granted to the Lambda role |
| `agentcore_log_group_arn` | `string` | Yes | AgentCore CloudWatch log group ARN — granted to the AgentCore runtime role |
| `session_table_arn` | `string` | Yes | DynamoDB session memory table ARN — granted to the Lambda role |
| `registry_table_arn` | `string` | Yes | DynamoDB agent registry table ARN — granted to the Lambda role |
| `tags` | `map(string)` | No | Additional tags merged onto all resources |

## Outputs

| Name | Description |
|---|---|
| `agentcore_runtime_role_arn` | AgentCore runtime role ARN — passed to the agentcore/ module |
| `agentcore_runtime_role_name` | AgentCore runtime role name |
| `bedrock_kb_role_arn` | Bedrock KB ingestion role ARN — passed to the bedrock/ module when re-enabled |
| `bedrock_kb_role_name` | Bedrock KB ingestion role name |
| `lambda_execution_role_arn` | Lambda execution role ARN — passed to any Lambda resource |
| `lambda_execution_role_name` | Lambda execution role name |
| `storage_kms_key_arn` | KMS key ARN — passed to storage/, observability/, and bedrock/ modules |

## Example Usage

```hcl
# In terraform/dev/foundation/main.tf
module "iam" {
  source = "../../modules/iam"

  project_name   = var.project_name
  environment    = var.environment
  aws_region     = var.aws_region
  aws_account_id = var.account_id

  document_bucket_arn     = "arn:aws:s3:::ai-platform-dev-document-landing-096305373014"
  prompt_vault_bucket_arn = "arn:aws:s3:::ai-platform-dev-prompt-vault-096305373014"
  agentcore_log_group_arn = "arn:aws:logs:us-east-2:096305373014:log-group:/aws/agentcore/ai-platform-dev"
  session_table_arn       = "arn:aws:dynamodb:us-east-2:096305373014:table/ai-platform-dev-session-memory"
  registry_table_arn      = "arn:aws:dynamodb:us-east-2:096305373014:table/ai-platform-dev-agent-registry"

  tags = local.common_tags
}

# Consuming role ARNs in the app layer via remote state:
data "terraform_remote_state" "foundation" { ... }

module "agentcore" {
  ...
  agentcore_role_arn = data.terraform_remote_state.foundation.outputs.agentcore_runtime_role_arn
}
```

## Security — Why IRSA

All roles in this module follow the IAM Roles for Service Accounts (IRSA) pattern
mandated by ADR-001. In the context of this platform (AWS managed services rather
than EKS pods), IRSA means:

- **One role per service** — AgentCore, Bedrock KB, and Lambda each have a
  dedicated role. No shared roles, no broad wildcard trust.
- **Service principal trust** — Each role is assumed via `sts:AssumeRole` by the
  specific AWS service principal (`bedrock-agentcore.amazonaws.com`,
  `bedrock.amazonaws.com`, `lambda.amazonaws.com`). No IAM users, no long-lived
  access keys, no instance profiles.
- **`aws:SourceAccount` condition** — Every service principal trust statement
  includes a `StringEquals` condition on `aws:SourceAccount`. This prevents
  confused deputy attacks where another AWS account's service could assume
  this account's roles.
- **Least-privilege policies** — Each role policy grants only the specific
  actions on specific resource ARNs required for that service's function.
  The AgentCore runtime role cannot write to S3. The KB role cannot invoke
  models. The Lambda role is restricted to Haiku — it cannot invoke Sonnet.
- **Ephemeral credentials** — All credentials are short-lived STS tokens
  issued at execution time. No credentials exist at rest in any configuration
  file, environment variable, or secret store.

See ADR-001 and architecture document Section 8.1 for full rationale.

## Known Issues and Build Notes

### AWS Provider Must Be ~> 6.0

The `agentcore/` module uses `aws_bedrockagentcore_agent_runtime`,
`aws_bedrockagentcore_gateway`, and `aws_bedrockagentcore_gateway_target`.
These resource types do not exist in hashicorp/aws `~> 5.x`. If `terraform validate`
reports "The provider hashicorp/aws does not support resource type
aws_bedrockagentcore_agent_runtime", the root cause is a `~> 5.0` constraint.
Fix: update to `~> 6.0` and run `terraform init -upgrade`.

### data.aws_region.current.name Deprecated in v6

In hashicorp/aws v6, `data.aws_region.current.name` is deprecated. Use
`data.aws_region.current.region` instead. The symptom is a deprecation warning
on every VPC endpoint `service_name` in `networking/main.tf`. Fixed in the
current codebase — note this if upgrading from a v5 snapshot.

### dynamodb_table Backend Parameter Deprecated in v6

Every `terraform init` and `terraform apply` prints:

```
Warning: Deprecated Parameter
The parameter "dynamodb_table" is deprecated. Use parameter "use_lockfile" instead.
```

This is a cosmetic warning from the AWS provider v6 S3 backend. State locking
continues to work correctly. To silence it, replace `dynamodb_table = "..."` with
`use_lockfile = true` in both `foundation/backend.tf` and `app/backend.tf`, then
re-run `terraform init`. The DynamoDB lock table still functions with `use_lockfile`
— only the parameter name changed. Safe to ignore until the next provider upgrade.

### glean_mcp_endpoint Must Start With https://

The AWS provider validates that `aws_bedrockagentcore_gateway_target`
`target_configuration.mcp.mcp_server.endpoint` starts with `https://`. If
`terraform plan` fails with "Must start with https://", the placeholder value
in `terraform.tfvars` has not been replaced with the real Glean MCP endpoint.
