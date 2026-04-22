"""Environment-backed configuration for the orchestrator container."""

from __future__ import annotations

import os

AWS_REGION = os.environ.get("AWS_REGION", "us-east-2")
AGENT_ENV = os.environ.get("AGENT_ENV", "dev")
AGENT_ID = "orchestrator-dev"

MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-sonnet-4-6")
GUARDRAIL_ID = os.environ.get("GUARDRAIL_ID", "")
GUARDRAIL_VERSION = os.environ.get("GUARDRAIL_VERSION", "DRAFT")

REGISTRY_TABLE = os.environ.get("AGENT_REGISTRY_TABLE", "")
SESSION_MEMORY_TABLE = os.environ.get("SESSION_MEMORY_TABLE", "")
PROMPT_VAULT_BUCKET = os.environ.get("PROMPT_VAULT_BUCKET", "")
AUDIT_LOG_GROUP = os.environ.get("AUDIT_LOG_GROUP", "/ai-platform/orchestrator/audit-dev")
APP_LOG_GROUP = os.environ.get("APP_LOG_GROUP", "/ai-platform/orchestrator/app-dev")

REGISTRY_CACHE_TTL_SECONDS = int(os.environ.get("REGISTRY_CACHE_TTL_SECONDS", "60"))

METRIC_NAMESPACE = "bedrock-agentcore"
