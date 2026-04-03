# ---------------------------------------------------------------------------
# Component 2 — Guardrails (Bedrock Guardrails)
#
# Separated from main.tf so guardrail policy changes — topic definitions,
# content filter thresholds, PII entity list — can be reviewed and applied
# independently of infrastructure wiring changes.
#
# Change workflow:
#   1. Edit topic_policy_config, content_policy_config, or
#      sensitive_information_policy_config below.
#   2. Run: terraform plan -out=tfplan   (review the diff)
#   3. Run: terraform apply tfplan
#
# Terraform updates the guardrail in place (DRAFT version). The manifest
# terraform_data block in main.tf watches guardrail_id and version — it
# re-registers the agent manifest automatically if the version changes.
#
# To verify a change, use the Guardrail Configuration section in
# terraform/dev/agents/hr-assistant/README.md.
# ---------------------------------------------------------------------------

resource "aws_bedrock_guardrail" "hr_assistant" {
  name                      = "hr-assistant-guardrail-dev"
  description               = "Guardrail for the HR Assistant agent - dev environment."
  blocked_input_messaging   = "I'm not able to help with that request. For assistance, please\ncontact the HR team directly at hr@example.com or speak with your\nHR Business Partner."
  blocked_outputs_messaging = "I'm not able to help with that request. For assistance, please\ncontact the HR team directly at hr@example.com or speak with your\nHR Business Partner."

  # ---------------------------------------------------------------------------
  # Topic policies — deny out-of-scope topics
  # To add a topic: add a topics_config block with name, definition, examples,
  # and type = "DENY". Keep definitions precise — vague definitions cause
  # false positives on legitimate HR queries.
  # ---------------------------------------------------------------------------

  topic_policy_config {
    topics_config {
      name       = "Legal Advice"
      definition = "Requests for legal opinions, interpretation of laws or contracts, advice on legal rights or obligations, or guidance on legal proceedings."
      examples   = ["Is my employer breaking the law?", "Can I sue the company?", "What are my legal rights here?"]
      type       = "DENY"
    }

    topics_config {
      name       = "Medical Advice"
      definition = "Requests for medical diagnosis, treatment recommendations, interpretation of medical test results, or advice on medications."
      examples   = ["Should I see a doctor about this?", "What does my diagnosis mean?", "Is this medication safe?"]
      type       = "DENY"
    }

    topics_config {
      name       = "Financial Planning Advice"
      definition = "Requests for personal investment advice, tax planning strategies, retirement fund allocation recommendations, or specific financial product recommendations."
      examples   = ["Should I put more in my pension?", "How should I invest my bonus?", "Which fund should I choose?"]
      type       = "DENY"
    }

    topics_config {
      name       = "Employee Personal Information"
      definition = "Requests for information about other employees' salary, performance ratings, disciplinary history, personal contact details, or any other personal data about a named individual."
      examples   = ["What does Sarah earn?", "Why was John let go?", "Give me Jane's phone number"]
      type       = "DENY"
    }
  }

  # ---------------------------------------------------------------------------
  # Content filters
  # Strengths: LOW | MEDIUM | HIGH
  # Raise threshold to increase sensitivity (more blocks).
  # Lower threshold to reduce false positives.
  # ---------------------------------------------------------------------------

  content_policy_config {
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }

    filters_config {
      type            = "INSULTS"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }

    filters_config {
      type            = "SEXUAL"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }

    filters_config {
      type            = "VIOLENCE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }

    filters_config {
      type            = "MISCONDUCT"
      input_strength  = "MEDIUM"
      output_strength = "MEDIUM"
    }
  }

  # ---------------------------------------------------------------------------
  # PII handling — anonymize rather than block
  # ANONYMIZE replaces the PII value in the response with a placeholder.
  # Change action to "BLOCK" to reject the request entirely instead.
  # ---------------------------------------------------------------------------

  sensitive_information_policy_config {
    pii_entities_config {
      type   = "NAME"
      action = "ANONYMIZE"
    }

    pii_entities_config {
      type   = "EMAIL"
      action = "ANONYMIZE"
    }

    pii_entities_config {
      type   = "PHONE"
      action = "ANONYMIZE"
    }

    pii_entities_config {
      type   = "ADDRESS"
      action = "ANONYMIZE"
    }

    pii_entities_config {
      type   = "AGE"
      action = "ANONYMIZE"
    }

    pii_entities_config {
      type   = "US_SOCIAL_SECURITY_NUMBER"
      action = "ANONYMIZE"
    }

    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_NUMBER"
      action = "ANONYMIZE"
    }

    pii_entities_config {
      type   = "US_BANK_ACCOUNT_NUMBER"
      action = "ANONYMIZE"
    }
  }

  # ---------------------------------------------------------------------------
  # Contextual grounding — block responses below grounding threshold
  # Threshold range: 0.0–1.0. Higher = stricter grounding requirement.
  # Current: 0.75 — responses must be 75% grounded in retrieved KB context.
  # ---------------------------------------------------------------------------

  contextual_grounding_policy_config {
    filters_config {
      type      = "GROUNDING"
      threshold = 0.75
    }
  }

  tags = merge(var.tags, { Component = "guardrail" })
}
