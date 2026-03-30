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

## Roles Created

| Role | Name Pattern | Trust Principal | Purpose |
|---|---|---|---|
| AgentCore Runtime | `{project}-agentcore-runtime-{env}` | `bedrock-agentcore.amazonaws.com` | Invokes Bedrock models, retrieves from Knowledge Base, writes AgentCore logs |
| Bedrock KB | `{project}-bedrock-kb-{env}` | `bedrock.amazonaws.com` | Reads source documents from S3, writes vectors to OpenSearch Serverless |
| Lambda Execution | `{project}-lambda-{env}` | `lambda.amazonaws.com` | Evaluation and ingestion Lambda functions — Haiku only, scoped to platform resources |
| OpenSearch Access | `{project}-opensearch-{env}` | `bedrock.amazonaws.com`, `bedrock-agentcore.amazonaws.com` | Direct vector index read/write beyond KB ingestion role scope |

## Input Variables

| Name | Type | Required | Description |
|---|---|---|---|
| `project_name` | `string` | Yes | Project name — used in all resource names |
| `environment` | `string` | Yes | Environment name (dev, staging, production) |
| `aws_region` | `string` | Yes | AWS region — used in model ARNs and log group ARNs within policies |
| `aws_account_id` | `string` | Yes | AWS account ID — used in trust policy conditions and policy resource ARNs |
| `kb_arn` | `string` | Yes | Bedrock Knowledge Base ARN — granted to the AgentCore runtime role |
| `document_bucket_arn` | `string` | Yes | Document landing S3 bucket ARN — granted to the KB role and Lambda role |
| `prompt_vault_bucket_arn` | `string` | Yes | Prompt Vault S3 bucket ARN — granted to the Lambda role |
| `opensearch_collection_arn` | `string` | Yes | OpenSearch Serverless collection ARN — granted to the KB role and OpenSearch access role |
| `agentcore_log_group_arn` | `string` | Yes | AgentCore CloudWatch log group ARN — granted to the AgentCore runtime role |
| `session_table_arn` | `string` | Yes | DynamoDB session memory table ARN — granted to the Lambda role |
| `registry_table_arn` | `string` | Yes | DynamoDB agent registry table ARN — granted to the Lambda role |
| `tags` | `map(string)` | No | Additional tags merged onto all resources |

## Outputs

| Name | Description |
|---|---|
| `agentcore_runtime_role_arn` | AgentCore runtime role ARN — passed to the agentcore/ module |
| `agentcore_runtime_role_name` | AgentCore runtime role name |
| `bedrock_kb_role_arn` | Bedrock KB ingestion role ARN — passed to the bedrock/ module |
| `bedrock_kb_role_name` | Bedrock KB ingestion role name |
| `lambda_execution_role_arn` | Lambda execution role ARN — passed to any Lambda resource |
| `lambda_execution_role_name` | Lambda execution role name |
| `opensearch_access_role_arn` | OpenSearch direct-access role ARN |
| `opensearch_access_role_name` | OpenSearch direct-access role name |
| `storage_kms_key_arn` | KMS key ARN — passed to storage/, observability/, and bedrock/ modules |

## Example Usage

```hcl
# In terraform/dev/main.tf
module "iam" {
  source = "../modules/iam"

  project_name   = var.project_name
  environment    = var.environment
  aws_region     = var.aws_region
  aws_account_id = var.account_id

  kb_arn                    = "arn:aws:bedrock:us-east-2:096305373014:knowledge-base/<id>"
  document_bucket_arn       = "arn:aws:s3:::ai-platform-dev-document-landing-096305373014"
  prompt_vault_bucket_arn   = "arn:aws:s3:::ai-platform-dev-prompt-vault-096305373014"
  opensearch_collection_arn = "arn:aws:aoss:us-east-2:096305373014:collection/<id>"
  agentcore_log_group_arn   = "arn:aws:logs:us-east-2:096305373014:log-group:/aws/agentcore/ai-platform-dev"
  session_table_arn         = "arn:aws:dynamodb:us-east-2:096305373014:table/ai-platform-dev-session-memory"
  registry_table_arn        = "arn:aws:dynamodb:us-east-2:096305373014:table/ai-platform-dev-agent-registry"

  tags = local.common_tags
}

# Consuming role ARNs in other modules:
module "agentcore" {
  ...
  agentcore_role_arn = module.iam.agentcore_runtime_role_arn
}

module "bedrock" {
  ...
  kb_role_arn = module.iam.bedrock_kb_role_arn
  kms_key_arn = module.iam.storage_kms_key_arn
}
```

## Security — Why IRSA

All roles in this module follow the IAM Roles for Service Accounts (IRSA) pattern
mandated by ADR-001. In the context of this platform (AWS managed services rather
than EKS pods), IRSA means:

- **One role per service** — AgentCore, Bedrock KB, Lambda, and OpenSearch each
  have a dedicated role. No shared roles, no broad wildcard trust.
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
