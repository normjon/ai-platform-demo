"""
Session memory — DynamoDB read/write for HR Assistant conversation history.

Table: SESSION_MEMORY_TABLE env var (ai-platform-dev-session-memory)
Schema: partition key session_id (S), sort key timestamp (S)
        message_history stored as JSON string in attribute messages (S)

ADR-003: structured JSON logging to stdout.
"""

from __future__ import annotations

import json
import logging
import os
import time
from datetime import datetime, timezone
from typing import Any

import boto3

logger = logging.getLogger(__name__)

_dynamodb = boto3.resource("dynamodb", region_name=os.environ.get("AWS_REGION", "us-east-2"))
_TABLE_NAME = os.environ["SESSION_MEMORY_TABLE"]
_table = _dynamodb.Table(_TABLE_NAME)

_MAX_HISTORY_TURNS = 10  # keep last N turns to manage context window


def get_history(session_id: str) -> list[dict[str, Any]]:
    """Return the message history for session_id, or [] if none exists."""
    try:
        resp = _table.get_item(
            Key={"session_id": session_id, "timestamp": "latest"}
        )
        item = resp.get("Item", {})
        raw = item.get("messages", "[]")
        history: list[dict[str, Any]] = json.loads(raw)
        logger.info(json.dumps({
            "event": "session_read",
            "session_id": session_id,
            "turns": len(history),
        }))
        return history[-_MAX_HISTORY_TURNS:]
    except Exception as exc:
        logger.warning(json.dumps({
            "event": "session_read_error",
            "session_id": session_id,
            "error": str(exc),
        }))
        return []


def put_history(session_id: str, messages: list[dict[str, Any]]) -> None:
    """Persist message history for session_id."""
    try:
        trimmed = messages[-_MAX_HISTORY_TURNS:]
        _table.put_item(Item={
            "session_id": session_id,
            "timestamp": "latest",
            "messages": json.dumps(trimmed),
            "updated_at": datetime.now(timezone.utc).isoformat(),
            "ttl": int(time.time()) + 86400,  # 24-hour TTL matches manifest
        })
        logger.info(json.dumps({
            "event": "session_write",
            "session_id": session_id,
            "turns": len(trimmed),
        }))
    except Exception as exc:
        logger.warning(json.dumps({
            "event": "session_write_error",
            "session_id": session_id,
            "error": str(exc),
        }))
