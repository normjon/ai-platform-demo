"""
Prompt Vault Lambda — HR Assistant write path.

Receives an AgentCore post-invocation event and writes a structured
interaction record to S3 at:
  prompt-vault/hr-assistant/YYYY/MM/DD/<record_id>.json

Target: arm64/Graviton, python3.12 (ADR-004)
Logging: structured JSON to stdout (ADR-003)
"""

from __future__ import annotations

import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

# ---------------------------------------------------------------------------
# Structured JSON logging (ADR-003)
# ---------------------------------------------------------------------------

logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger(__name__)


def _log(event_name: str, **kwargs) -> None:
    """Emit a structured JSON log entry to stdout."""
    record = {"event": event_name, **kwargs}
    print(json.dumps(record), flush=True)


# ---------------------------------------------------------------------------
# S3 client
# ---------------------------------------------------------------------------

S3_CLIENT = boto3.client("s3")
PROMPT_VAULT_BUCKET = os.environ["PROMPT_VAULT_BUCKET"]
AGENT_ID = os.environ.get("AGENT_ID", "hr-assistant-dev")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")


# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------


def handler(event: dict, context: object) -> dict:
    """
    Lambda entry point.

    Expected event shape (AgentCore post-invocation):
    {
      "sessionId":      str,
      "input":          str,
      "output":         str,
      "toolCalls":      [{"toolName": str, "input": str, "output": str}],
      "guardrailResult": {"action": str, "topicPolicyResult": str, "contentFilterResult": str},
      "modelArn":       str,
      "inputTokens":    int,
      "outputTokens":   int,
      "latencyMs":      int
    }
    """
    start_time = time.monotonic()

    session_id = event.get("sessionId", "unknown")
    record_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)

    # Build the Prompt Vault record.
    tool_calls_raw = event.get("toolCalls", [])
    tool_calls = [
        {
            "tool_name": tc.get("toolName", ""),
            "input": tc.get("input", ""),
            "output": tc.get("output", ""),
        }
        for tc in (tool_calls_raw if isinstance(tool_calls_raw, list) else [])
    ]

    guardrail_raw = event.get("guardrailResult", {})
    guardrail_result = {
        "action": guardrail_raw.get("action", ""),
        "topic_policy_result": guardrail_raw.get("topicPolicyResult", ""),
        "content_filter_result": guardrail_raw.get("contentFilterResult", ""),
    }

    vault_record = {
        "record_id": record_id,
        "timestamp": now.isoformat(),
        "agent_id": AGENT_ID,
        "session_id": session_id,
        "user_input": event.get("input", ""),
        "agent_response": event.get("output", ""),
        "tool_calls": tool_calls,
        "guardrail_result": guardrail_result,
        "model_arn": event.get("modelArn", ""),
        "input_tokens": int(event.get("inputTokens", 0)),
        "output_tokens": int(event.get("outputTokens", 0)),
        "latency_ms": int(event.get("latencyMs", 0)),
        "data_classification": "INTERNAL",
        "environment": ENVIRONMENT,
    }

    # S3 key: prompt-vault/hr-assistant/YYYY/MM/DD/<record_id>.json
    s3_key = (
        f"prompt-vault/hr-assistant/"
        f"{now.year:04d}/{now.month:02d}/{now.day:02d}/"
        f"{record_id}.json"
    )

    try:
        S3_CLIENT.put_object(
            Bucket=PROMPT_VAULT_BUCKET,
            Key=s3_key,
            Body=json.dumps(vault_record, ensure_ascii=False),
            ContentType="application/json",
        )
    except ClientError as exc:
        _log(
            "prompt_vault_write",
            record_id=record_id,
            session_id=session_id,
            status="error",
            error=str(exc),
            latency_ms=int((time.monotonic() - start_time) * 1000),
        )
        raise

    write_latency_ms = int((time.monotonic() - start_time) * 1000)

    # Structured log — ADR-003 compliant.
    _log(
        "prompt_vault_write",
        record_id=record_id,
        session_id=session_id,
        status="success",
        latency_ms=write_latency_ms,
        s3_key=s3_key,
    )

    return {
        "statusCode": 200,
        "recordId": record_id,
        "s3Key": s3_key,
    }
