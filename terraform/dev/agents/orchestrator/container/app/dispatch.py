"""dispatch_agent — the orchestrator's only Strands tool.

Calls bedrock-agentcore:InvokeAgentRuntime against the sub-agent's runtime
ARN (looked up from the registry by domain). Enforces single-dispatch
discipline per user turn — a second call in the same turn returns
`single_dispatch_only` without invoking anything.

Trace context is injected into the payload so the sub-agent can correlate
log events with the orchestrator's trace_id (sub-agents must parse
`payload['trace_context']` at /invocations entry).
"""

from __future__ import annotations

import json
import logging
import threading
import time
from typing import Any

import boto3
from botocore.exceptions import ClientError
from strands import tool

from app import config, metrics, registry, tracing

logger = logging.getLogger(__name__)

_agentcore_lock = threading.Lock()
_agentcore_client = None


def _get_agentcore():
    global _agentcore_client
    if _agentcore_client is not None:
        return _agentcore_client
    with _agentcore_lock:
        if _agentcore_client is None:
            _agentcore_client = boto3.client("bedrock-agentcore", region_name=config.AWS_REGION)
    return _agentcore_client


# Per-request state. The LLM cannot pass the orchestrator's real session_id
# through the tool signature (it never sees it), and Strands may run the
# tool on a worker thread, so threading.local can't carry it either.
# AgentCore containers serialize invocations per process, so a module-level
# holder protected by a lock is the simplest correct scope.
_state_lock = threading.Lock()
_active_session_id: str | None = None
_dispatched_count: int = 0
_last_dispatched_agent: str | None = None
_last_dispatched_runtime_arn: str | None = None
_last_dispatched_domain: str | None = None
_routing_only: bool = False


def begin_turn(session_id: str, routing_only: bool = False) -> None:
    """Reset per-turn dispatch state. Call from orchestrator.invoke() before agent().

    When routing_only=True, the dispatch tool records the routing decision
    (agent_id + runtime_arn) but skips the sub-agent invoke. The caller is
    then expected to invoke the sub-agent directly — used for streaming.
    """
    global _active_session_id, _dispatched_count, _last_dispatched_agent
    global _last_dispatched_runtime_arn, _last_dispatched_domain, _routing_only
    with _state_lock:
        _active_session_id = session_id
        _dispatched_count = 0
        _last_dispatched_agent = None
        _last_dispatched_runtime_arn = None
        _last_dispatched_domain = None
        _routing_only = routing_only


def end_turn(session_id: str) -> None:
    global _active_session_id, _routing_only
    with _state_lock:
        if _active_session_id == session_id:
            _active_session_id = None
            _routing_only = False


def last_dispatched_agent(session_id: str) -> str | None:
    with _state_lock:
        return _last_dispatched_agent if _active_session_id == session_id else None


def last_dispatched_runtime_arn(session_id: str) -> str | None:
    with _state_lock:
        return _last_dispatched_runtime_arn if _active_session_id == session_id else None


def last_dispatched_domain(session_id: str) -> str | None:
    with _state_lock:
        return _last_dispatched_domain if _active_session_id == session_id else None


@tool
def dispatch_agent(domain: str, message: str, session_id: str) -> dict:
    """Route a request to the sub-agent that owns the given domain.

    Call exactly once per user turn. A second call in the same turn is
    rejected to enforce single-dispatch discipline at launch (parallel
    fan-out is deferred).

    Args:
        domain: Topic domain from the agent registry (e.g. "hr.policy").
                Must exactly match one of the advertised domains.
        message: The user's message to forward. Pass through verbatim — do
                 not rewrite, summarize, or paraphrase.
        session_id: Orchestrator session ID. The sub-agent session is
                    derived from this automatically.

    Returns:
        On success: {"agent_id": str, "response": str}
        On failure: {"error": str, "domain": str, "detail": str}
    """
    global _dispatched_count, _last_dispatched_agent
    with _state_lock:
        if _dispatched_count >= 1:
            logger.warning(json.dumps({
                "event": "dispatch_rejected",
                "reason": "single_dispatch_only",
                **tracing.log_fields(),
            }))
            return {"error": "single_dispatch_only", "domain": domain, "detail": ""}
        _dispatched_count += 1
        sid = _active_session_id or session_id

    entry = registry.lookup_by_domain(domain)
    if entry is None:
        metrics.emit_routing_counter("RoutingFailureUnknownDomain")
        logger.info(json.dumps({
            "event": "dispatch_unknown_domain",
            "domain": domain,
            **tracing.log_fields(),
        }))
        return {"error": "no_agent_for_domain", "domain": domain, "detail": ""}

    if not entry.get("enabled", False):
        metrics.emit_routing_counter("RoutingFailureAgentDisabled")
        return {
            "error": "agent_disabled",
            "domain": domain,
            "detail": entry.get("agent_id", ""),
        }

    runtime_arn = entry.get("runtime_arn", "")
    agent_id = entry.get("agent_id", "")
    if not runtime_arn:
        logger.error(json.dumps({
            "event": "dispatch_missing_runtime_arn",
            "domain": domain,
            "agent_id": agent_id,
            **tracing.log_fields(),
        }))
        return {"error": "invoke_failed", "domain": domain, "detail": "missing runtime_arn in registry"}

    sub_session = f"{sid}-{agent_id}"
    payload = json.dumps({
        "prompt": message,
        "sessionId": sub_session,
        "trace_context": tracing.current_trace_context(),
    }).encode()

    global _last_dispatched_runtime_arn, _last_dispatched_domain
    with _state_lock:
        _last_dispatched_agent = agent_id
        _last_dispatched_runtime_arn = runtime_arn
        _last_dispatched_domain = domain
        routing_only = _routing_only

    # Routing-only mode: the handler will invoke the sub-agent directly with
    # streaming. Skip the sync invoke here and return a placeholder so the
    # Strands loop can terminate normally. The Strands LLM will typically
    # emit a short wrapper ("Here's what I found...") which is discarded by
    # the streaming handler — the caller sees only the sub-agent stream.
    if routing_only:
        logger.info(json.dumps({
            "event": "dispatch_routing_only",
            "agent_id": agent_id,
            "domain": domain,
            **tracing.log_fields(),
        }))
        return {"agent_id": agent_id, "response": "<streaming>"}

    start_ms = int(time.monotonic() * 1000)
    try:
        resp = _get_agentcore().invoke_agent_runtime(
            agentRuntimeArn=runtime_arn,
            runtimeSessionId=sub_session,
            payload=payload,
        )
    except ClientError as exc:
        latency = int(time.monotonic() * 1000) - start_ms
        metrics.emit_dispatch_metrics(agent_id, latency, success=False, error_class="invoke_failed")
        logger.warning(json.dumps({
            "event": "dispatch_invoke_failed",
            "agent_id": agent_id,
            "error": str(exc),
            **tracing.log_fields(),
        }))
        return {"error": "invoke_failed", "domain": domain, "detail": str(exc)}

    latency = int(time.monotonic() * 1000) - start_ms
    try:
        body = json.loads(resp["response"].read())
    except Exception as exc:
        metrics.emit_dispatch_metrics(agent_id, latency, success=False, error_class="decode_failed")
        return {"error": "invoke_failed", "domain": domain, "detail": f"response decode error: {exc}"}

    sub_response = body.get("response") or body.get("output") or ""
    metrics.emit_dispatch_metrics(agent_id, latency, success=True)
    logger.info(json.dumps({
        "event": "dispatch_succeeded",
        "agent_id": agent_id,
        "domain": domain,
        "latency_ms": latency,
        "response_chars": len(sub_response),
        **tracing.log_fields(),
    }))
    return {"agent_id": agent_id, "response": sub_response}
