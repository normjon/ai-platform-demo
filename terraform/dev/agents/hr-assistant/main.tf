terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# Platform state — reads AgentCore endpoint and shared platform outputs.
# ---------------------------------------------------------------------------

data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "ai-platform-terraform-state-dev-096305373014"
    key    = "dev/platform/terraform.tfstate"
    region = "us-east-2"
  }
}

# ---------------------------------------------------------------------------
# Component 1 — System Prompt (Bedrock Prompt Management)
# ---------------------------------------------------------------------------

resource "aws_bedrock_prompt" "hr_assistant_system" {
  name        = "hr-assistant-system-prompt-dev"
  description = "System prompt for the HR Assistant agent - dev environment."

  default_variant = "default"

  variant {
    name          = "default"
    template_type = "TEXT"
    template_configuration {
      text {
        text = file("${path.module}/prompts/hr-assistant-system-prompt.txt")
      }
    }
  }

  tags = merge(var.tags, { Component = "system-prompt" })
}

resource "aws_bedrock_prompt_version" "hr_assistant_system" {
  prompt_arn  = aws_bedrock_prompt.hr_assistant_system.arn
  description = "Phase 1 baseline — dev environment."
}

# ---------------------------------------------------------------------------
# Component 2 — Guardrails (Bedrock Guardrails)
# ---------------------------------------------------------------------------

resource "aws_bedrock_guardrail" "hr_assistant" {
  name                      = "hr-assistant-guardrail-dev"
  description               = "Guardrail for the HR Assistant agent - dev environment."
  blocked_input_messaging   = "I'm not able to help with that request. For assistance, please\ncontact the HR team directly at hr@example.com or speak with your\nHR Business Partner."
  blocked_outputs_messaging = "I'm not able to help with that request. For assistance, please\ncontact the HR team directly at hr@example.com or speak with your\nHR Business Partner."

  # Topic policies — deny out-of-scope topics
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

  # Content filters
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

  # PII handling — anonymize rather than block
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
      type   = "DATE_OF_BIRTH"
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
      type   = "BANK_ACCOUNT_NUMBER"
      action = "ANONYMIZE"
    }
  }

  # Contextual grounding — block responses below 0.75 grounding threshold
  contextual_grounding_policy_config {
    filters_config {
      type      = "GROUNDING"
      threshold = 0.75
    }
  }

  tags = merge(var.tags, { Component = "guardrail" })
}
