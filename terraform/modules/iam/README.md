# Module: iam

All IAM roles, policies, and the shared KMS key. Every service identity follows
the IRSA pattern (ADR-001) — roles are assumed via service principal with
`aws:SourceAccount` conditions. No instance profiles, no long-lived access keys.

## Resources

| Resource | Purpose |
|---|---|
| `aws_kms_key.storage` | Encryption key for DynamoDB and S3 SSE. Rotation enabled. |
| `aws_iam_role.agentcore` | Execution role for the AgentCore runtime. Assumed by `bedrock.amazonaws.com`. |
| `aws_iam_role_policy.agentcore` | Least-privilege policy: Bedrock model invocation, KB retrieval, DynamoDB session access, CloudWatch log writes. |
| `aws_iam_role.bedrock_kb` | Ingestion role for the Bedrock Knowledge Base. Assumed by `bedrock.amazonaws.com`. |
| `aws_iam_role_policy.bedrock_kb` | S3 read on the document landing bucket, Titan Embeddings invocation, OpenSearch Serverless access. |

## Design decisions

- All trust policies include `aws:SourceAccount` conditions to prevent confused
  deputy attacks.
- KMS key is created here (not in storage/) so that its ARN can be passed to
  both the storage module and future Lambda modules without circular dependencies.
- Role names are deterministic (`name_prefix` + suffix) so they can be referenced
  in SCPs and CloudTrail queries without looking them up.
