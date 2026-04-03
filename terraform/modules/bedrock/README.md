# Module: bedrock

Bedrock Knowledge Base (Platform Documentation KB), its OpenSearch Serverless
vector store, and the default Guardrail applied to all agent invocations.

## Resources

| Resource | Purpose |
| --- | --- |
| `aws_opensearchserverless_collection.kb` | Vector search collection backing the Knowledge Base index. |
| `aws_opensearchserverless_security_policy.encryption` | Encryption policy — AWS-owned key for dev. Upgrade to CMK for production. |
| `aws_opensearchserverless_security_policy.network` | Network policy — private access only, no public endpoint. |
| `aws_opensearchserverless_access_policy.kb` | Data access policy granting the KB ingestion role index read/write. |
| `aws_bedrockagent_knowledge_base.platform_docs` | Platform Documentation KB using Titan Embeddings V2 for indexing. |
| `aws_bedrockagent_data_source.document_landing` | S3 data source — syncs documents from the landing bucket. |
| `aws_bedrock_guardrail.default` | Content filters applied to all agent inputs and outputs. |

## Design decisions

- Glean is the default knowledge layer for dynamic organisational content.
  This Knowledge Base is only for curated, governed reference material
  (architecture docs, runbooks, policy). See architecture doc §4.2 for the
  Glean vs Knowledge Base decision framework.
- The OpenSearch Serverless collection uses `depends_on` for the security
  policy resources because the collection creation fails if the encryption
  policy does not exist first (ADR-005 staged apply pattern).
- Guardrail thresholds are set conservatively for dev. Tune before staging.

## Triggering a sync

After uploading documents to the landing bucket, trigger a sync:

```bash
aws bedrock-agent start-ingestion-job \
  --knowledge-base-id <kb-id> \
  --data-source-id <ds-id>
```
