output "knowledge_base_id" {
  description = "Bedrock Knowledge Base ID."
  value       = aws_bedrockagent_knowledge_base.platform_docs.id
}

output "opensearch_collection_endpoint" {
  description = "OpenSearch Serverless collection endpoint."
  value       = aws_opensearchserverless_collection.kb.collection_endpoint
}

output "guardrail_id" {
  description = "Bedrock Guardrail ID applied to agent invocations."
  value       = aws_bedrock_guardrail.default.guardrail_id
}

output "guardrail_arn" {
  description = "Bedrock Guardrail ARN."
  value       = aws_bedrock_guardrail.default.guardrail_arn
}
