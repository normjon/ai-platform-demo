# Module: storage

S3 buckets and DynamoDB tables for the dev environment. All resources follow
the security baseline from CLAUDE.md:

- S3: public access blocked, versioning enabled, KMS SSE with bucket key.
- DynamoDB: KMS encryption on all tables, PAY_PER_REQUEST billing.

## Resources

| Resource | Purpose |
|---|---|
| `aws_s3_bucket.document_landing` | Source bucket for Bedrock Knowledge Base document ingestion. |
| `aws_s3_bucket.prompt_vault` | Stores versioned prompt templates (Prompt Vault). |
| `aws_dynamodb_table.session_memory` | AgentCore per-session conversation memory. TTL attribute enables automatic expiry. |
| `aws_dynamodb_table.agent_registry` | Registry of deployed agents and their manifest metadata. |

## Inputs

| Name | Description |
|---|---|
| `name_prefix` | Resource name prefix. |
| `account_id` | Appended to S3 bucket names to ensure global uniqueness. |
| `kms_key_arn` | KMS key from the iam module — shared across all storage resources. |

## Outputs

| Name | Description |
|---|---|
| `document_landing_bucket` | Passed to the bedrock module as the KB data source. |
| `prompt_vault_bucket` | Exposed as a root output for operator reference. |
| `session_memory_table` | Passed to the agentcore module. |
| `agent_registry_table` | Passed to the agentcore module. |
