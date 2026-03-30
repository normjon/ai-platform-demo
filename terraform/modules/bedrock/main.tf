# ---------------------------------------------------------------------------
# OpenSearch Serverless collection — vector store for the Knowledge Base.
# ---------------------------------------------------------------------------

resource "aws_opensearchserverless_security_policy" "encryption" {
  name        = "${var.name_prefix}-kb-enc"
  type        = "encryption"
  description = "Encryption policy for the Knowledge Base vector collection — CMK."

  # Uses the project CMK from iam/ — consistent with project-wide KMS posture.
  policy = jsonencode({
    Rules = [{
      Resource     = ["collection/${var.name_prefix}-kb"]
      ResourceType = "collection"
    }]
    KmsARN = var.kms_key_arn
  })
}

resource "aws_opensearchserverless_security_policy" "network" {
  name        = "${var.name_prefix}-kb-net"
  type        = "network"
  description = "Network policy — private VPC access only."

  policy = jsonencode([{
    Rules = [
      { Resource = ["collection/${var.name_prefix}-kb"], ResourceType = "collection" },
      { Resource = ["dashboards/default"],               ResourceType = "dashboard"  }
    ]
    AllowFromPublic = false
  }])
}

resource "aws_opensearchserverless_access_policy" "kb" {
  name        = "${var.name_prefix}-kb-access"
  type        = "data"
  description = "Grants the Knowledge Base ingestion role access to the collection."

  policy = jsonencode([{
    Rules = [{
      Resource     = ["index/${var.name_prefix}-kb/*"]
      Permission   = ["aoss:CreateIndex", "aoss:DeleteIndex", "aoss:UpdateIndex",
                      "aoss:DescribeIndex", "aoss:ReadDocument", "aoss:WriteDocument"]
      ResourceType = "index"
    }]
    Principal = [var.kb_role_arn]
  }])
}

resource "aws_opensearchserverless_collection" "kb" {
  name = "${var.name_prefix}-kb"
  type = "VECTORSEARCH"
  tags = var.tags

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network,
  ]
}

# ---------------------------------------------------------------------------
# Bedrock Knowledge Base — Platform Documentation KB.
# ---------------------------------------------------------------------------

resource "aws_bedrockagent_knowledge_base" "platform_docs" {
  name        = "${var.name_prefix}-platform-docs-kb"
  description = "Platform Documentation Knowledge Base — curated reference content for agents."
  role_arn    = var.kb_role_arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.model_arn_embeddings}"
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.kb.arn
      vector_index_name = "${var.name_prefix}-kb-index"
      field_mapping {
        vector_field   = "embedding"
        text_field     = "text"
        metadata_field = "metadata"
      }
    }
  }

  tags = var.tags
}

resource "aws_bedrockagent_data_source" "document_landing" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.platform_docs.id
  name              = "${var.name_prefix}-document-landing"
  description       = "S3 document landing bucket — source for KB ingestion."

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = "arn:aws:s3:::${var.document_landing_bucket}"
    }
  }
}

# ---------------------------------------------------------------------------
# Bedrock Guardrail — applied to all agent invocations via agentcore module.
# ---------------------------------------------------------------------------

resource "aws_bedrock_guardrail" "default" {
  name                      = "${var.name_prefix}-guardrail"
  description               = "Default guardrail for dev environment agents."
  blocked_input_messaging   = "I cannot process this request."
  blocked_outputs_messaging = "I cannot return this response."

  content_policy_config {
    filters_config {
      type            = "SEXUAL"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "MEDIUM"
      output_strength = "MEDIUM"
    }
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
  }

  tags = var.tags
}
