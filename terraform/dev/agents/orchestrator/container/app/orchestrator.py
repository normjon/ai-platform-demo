"""Strands supervisor agent — the routing brain.

Builds a Strands Agent per request. BedrockModel is cached at module level;
the Agent and S3SessionManager are lightweight and re-created per request
so the session_id binds correctly. Same pattern as hr-assistant-strands.

The supervisor system prompt embeds the current registry summary — adding
or disabling an agent is reflected on the next orchestrator invocation
after the 60s cache window, with zero orchestrator redeploy.
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any

from strands import Agent
from strands.agent.conversation_manager import SlidingWindowConversationManager
from strands.models.bedrock import BedrockModel
from strands.session import S3SessionManager

from app import config, dispatch, registry, tracing

logger = logging.getLogger(__name__)

_model: BedrockModel | None = None


def init() -> None:
    """Initialize module-level BedrockModel. Called once from main.startup()."""
    global _model
    _model = BedrockModel(
        model_id=config.MODEL_ID,
        region_name=config.AWS_REGION,
        guardrail_id=config.GUARDRAIL_ID,
        guardrail_version=config.GUARDRAIL_VERSION,
        guardrail_trace="enabled",
    )
    logger.info(json.dumps({
        "event": "supervisor_initialized",
        "model_id": config.MODEL_ID,
        "guardrail_id": config.GUARDRAIL_ID,
    }))


def _system_prompt(registry_summary: str, known_domains: list[str]) -> str:
    domain_list = ", ".join(known_domains) if known_domains else "(none currently)"
    return f"""You are the front-door orchestrator for an enterprise AI platform.

Your only job is to route the user's message to exactly one sub-agent based on the
topic domain, then return the sub-agent's response to the user with minimal rewording.
You do not answer from your own knowledge — you dispatch or refuse.

Available sub-agents (source of truth: agent registry):
{registry_summary}

Currently advertised domains: {domain_list}

Rules:
1. Call the `dispatch_agent` tool exactly ONCE per user turn, passing:
   - `domain`: one of the advertised domains above, chosen to match the user's intent
   - `message`: the user's message, passed through verbatim
   - `session_id`: pass the session_id you received for this turn
2. If no advertised domain matches the user's request, respond with a brief polite
   refusal. Do NOT invent a domain. Do NOT call `dispatch_agent` with a made-up value.
3. After receiving the sub-agent's response, return it to the user. You may add a
   very brief contextualizing sentence but do not rewrite, summarize, or re-interpret
   the content.
4. Never call `dispatch_agent` more than once. The second call will be rejected.
"""


def invoke(session_id: str, user_message: str, routing_only: bool = False) -> dict[str, Any]:
    """Run the supervisor loop for a single user turn.

    When routing_only=True, dispatch_agent records the routing decision
    without invoking the sub-agent. The caller is responsible for invoking
    the sub-agent directly — used to power streaming passthrough.

    Returns:
        response:          str   — user-facing text
        dispatched_agent:  str?  — agent_id of the sub-agent the supervisor routed to (if any)
        runtime_arn:       str?  — sub-agent runtime ARN (routing_only mode)
        input_tokens:      int
        output_tokens:     int
        latency_ms:        int
        stop_reason:       str
    """
    if _model is None:
        raise RuntimeError("orchestrator.init() was not called — model is None")

    start_ms = int(time.monotonic() * 1000)

    dispatch.begin_turn(session_id, routing_only=routing_only)

    s3sm = S3SessionManager(
        session_id=session_id,
        bucket=config.PROMPT_VAULT_BUCKET,
        prefix="strands-sessions/orchestrator/",
        region_name=config.AWS_REGION,
    )

    agent = Agent(
        model=_model,
        tools=[dispatch.dispatch_agent],
        system_prompt=_system_prompt(registry.summary(), registry.all_domains()),
        session_manager=s3sm,
        conversation_manager=SlidingWindowConversationManager(window_size=10),
        callback_handler=None,
    )

    try:
        result = agent(user_message)
    finally:
        dispatched = dispatch.last_dispatched_agent(session_id)
        runtime_arn = dispatch.last_dispatched_runtime_arn(session_id)
        dispatch.end_turn(session_id)

    latency_ms = int(time.monotonic() * 1000) - start_ms
    invocations = result.metrics.agent_invocations
    usage = invocations[-1].usage if invocations else {}

    logger.info(json.dumps({
        "event": "supervisor_invoke",
        "session_id": session_id,
        "stop_reason": result.stop_reason,
        "cycle_count": result.metrics.cycle_count,
        "input_tokens": usage.get("inputTokens", 0),
        "output_tokens": usage.get("outputTokens", 0),
        "latency_ms": latency_ms,
        "dispatched_agent": dispatched,
        **tracing.log_fields(),
    }))

    return {
        "response": str(result),
        "dispatched_agent": dispatched,
        "runtime_arn": runtime_arn,
        "input_tokens": usage.get("inputTokens", 0),
        "output_tokens": usage.get("outputTokens", 0),
        "latency_ms": latency_ms,
        "stop_reason": result.stop_reason,
    }
