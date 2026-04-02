"""
Prompt Vault write path — invokes the Prompt Vault Lambda after each interaction.

The Lambda writes structured interaction records to S3 at:
  prompt-vault/hr-assistant/YYYY/MM/DD/<record_id>.json

ADR-003: structured JSON logging to stdout.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any

import boto3

logger = logging.getLogger(__name__)

_lambda = boto3.client("lambda", region_name=os.environ.get("AWS_REGION", "us-east-2"))
_VAULT_LAMBDA = os.environ.get("PROMPT_VAULT_LAMBDA", "")


def write(
    *,
    session_id: str,
    user_input: str,
    agent_output: str,
    tool_calls: list[dict[str, Any]],
    guardrail_result: dict[str, Any],
    model_arn: str,
    input_tokens: int,
    output_tokens: int,
    latency_ms: int,
) -> None:
    """
    Invoke the Prompt Vault Lambda asynchronously (Event invocation type).
    Failure is logged but does not raise — Prompt Vault writes are non-critical.
    """
    if not _VAULT_LAMBDA:
        logger.warning(json.dumps({
            "event": "vault_skip",
            "reason": "PROMPT_VAULT_LAMBDA not set",
            "session_id": session_id,
        }))
        return

    payload = {
        "sessionId": session_id,
        "input": user_input,
        "output": agent_output,
        "toolCalls": tool_calls,
        # Lambda handler.py reads camelCase keys — convert from the snake_case
        # dict returned by agent._extract_guardrail_result().
        "guardrailResult": {
            "action": guardrail_result.get("action", "NONE"),
            "topicPolicyResult": guardrail_result.get("topic_policy_result", ""),
            "contentFilterResult": guardrail_result.get("content_filter_result", ""),
        },
        "modelArn": model_arn,
        "inputTokens": input_tokens,
        "outputTokens": output_tokens,
        "latencyMs": latency_ms,
    }

    try:
        _lambda.invoke(
            FunctionName=_VAULT_LAMBDA,
            InvocationType="Event",  # async — do not block the response path
            Payload=json.dumps(payload).encode(),
        )
        logger.info(json.dumps({
            "event": "vault_write_dispatched",
            "session_id": session_id,
        }))
    except Exception as exc:
        logger.warning(json.dumps({
            "event": "vault_write_error",
            "session_id": session_id,
            "error": str(exc),
        }))
