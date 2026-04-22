"""Audit log writer.

Writes structured JSON records to the orchestrator audit CloudWatch Log
Group. Prompts and responses are hashed, never stored — the Prompt Vault
remains the authoritative record of content. Audit logs answer
"who called what when," not "what did they say."
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import logging
import threading

import boto3

from app import config

logger = logging.getLogger(__name__)

_logs_lock = threading.Lock()
_logs_client = None

_log_stream_lock = threading.Lock()
_log_stream_name: str | None = None


def _get_logs():
    global _logs_client
    if _logs_client is not None:
        return _logs_client
    with _logs_lock:
        if _logs_client is None:
            _logs_client = boto3.client("logs", region_name=config.AWS_REGION)
    return _logs_client


def _sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _ensure_stream() -> str:
    global _log_stream_name
    logs = _get_logs()
    with _log_stream_lock:
        if _log_stream_name is not None:
            return _log_stream_name
        stream = f"orchestrator-{dt.datetime.utcnow().strftime('%Y-%m-%d')}-{config.AGENT_ENV}"
        try:
            logs.create_log_stream(
                logGroupName=config.AUDIT_LOG_GROUP,
                logStreamName=stream,
            )
        except logs.exceptions.ResourceAlreadyExistsException:
            pass
        _log_stream_name = stream
        return stream


def _put(record: dict) -> None:
    try:
        stream = _ensure_stream()
        _get_logs().put_log_events(
            logGroupName=config.AUDIT_LOG_GROUP,
            logStreamName=stream,
            logEvents=[{
                "timestamp": int(dt.datetime.utcnow().timestamp() * 1000),
                "message": json.dumps(record),
            }],
        )
    except Exception as exc:
        logger.warning(json.dumps({"event": "audit_write_failed", "error": str(exc)}))


def record_request(
    request_id: str,
    session_id: str,
    user_role: str,
    trace_id: str,
    prompt: str,
    pii_types_inbound: list[str],
) -> None:
    _put({
        "event": "orchestrator_request",
        "request_id": request_id,
        "session_id": session_id,
        "user_role": user_role,
        "trace_id": trace_id,
        "timestamp": dt.datetime.utcnow().isoformat() + "Z",
        "prompt_hash": _sha256(prompt),
        "pii_types_inbound": pii_types_inbound,
    })


def record_response(
    request_id: str,
    session_id: str,
    trace_id: str,
    response: str,
    pii_types_outbound: list[str],
    dispatched_agent: str | None,
    duration_ms: int,
) -> None:
    _put({
        "event": "orchestrator_response",
        "request_id": request_id,
        "session_id": session_id,
        "trace_id": trace_id,
        "timestamp": dt.datetime.utcnow().isoformat() + "Z",
        "response_hash": _sha256(response),
        "pii_types_outbound": pii_types_outbound,
        "dispatched_agent": dispatched_agent,
        "duration_ms": duration_ms,
    })
