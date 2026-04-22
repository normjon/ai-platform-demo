"""
HR Assistant — Strands SDK agentic loop.

Replaces the hand-written boto3 bedrock-runtime.converse() loop with the
AWS Strands Agents SDK. The external contract (invoke() return dict shape)
is identical to agent.py so main.py's vault.write() call is unchanged.

ADR-001: all AWS access via IRSA — no credentials in code or env vars.
ADR-003: structured JSON logging to stdout.
ADR-004: container targets arm64/Graviton.
"""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Any

import boto3
from strands import Agent, tool
from strands.models.bedrock import BedrockModel
from strands.session import S3SessionManager
from strands.agent.conversation_manager import SlidingWindowConversationManager

logger = logging.getLogger(__name__)

_REGION = os.environ.get("AWS_REGION", "us-east-2")
_lambda_client = boto3.client("lambda", region_name=_REGION)
_bedrock_agent_runtime = boto3.client("bedrock-agent-runtime", region_name=_REGION)

# ---------------------------------------------------------------------------
# Module-level state — set once by init() at container startup.
# BedrockModel and system prompt are created once; only S3SessionManager
# and Agent are created per request (S3SessionManager takes session_id
# at construction time).
# ---------------------------------------------------------------------------

_model: BedrockModel | None = None
_SYSTEM_PROMPT_TEXT: str = ""
_MODEL_ID: str = ""  # exposed for main.py vault.write() call


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

@tool
def glean_search(query: str) -> str:
    """Search the company knowledge base and HR documentation.
    Use this tool before answering any HR policy question.
    Do not answer from memory without searching first.
    """
    mcp_event = {
        "body": json.dumps({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "search",
                "arguments": {"query": query, "maxResults": 5},
            },
        }),
        "requestContext": {"http": {"method": "POST"}},
        "rawPath": "/",
    }

    try:
        resp = _lambda_client.invoke(
            FunctionName="ai-platform-dev-glean-stub",
            Payload=json.dumps(mcp_event).encode(),
        )
        payload = json.loads(resp["Payload"].read())
        body = json.loads(payload.get("body", "{}"))
        content = body.get("result", {}).get("content", [])
        text = content[0].get("text", "") if content else ""
        logger.info(json.dumps({
            "event": "glean_search",
            "query": query,
            "result_chars": len(text),
        }))
        return text
    except Exception as exc:
        logger.warning(json.dumps({
            "event": "glean_search_error",
            "query": query,
            "error": str(exc),
        }))
        return "Search unavailable."


@tool
def retrieve_hr_documents(query: str) -> str:
    """Retrieve relevant HR policy passages from the Knowledge Base.
    Returns formatted passages with source citations, or empty string
    if no relevant results are found.
    """
    kb_id = os.environ.get("KNOWLEDGE_BASE_ID", "")
    if not kb_id:
        return ""

    try:
        resp = _bedrock_agent_runtime.retrieve(
            knowledgeBaseId=kb_id,
            retrievalQuery={"text": query},
            retrievalConfiguration={
                "vectorSearchConfiguration": {"numberOfResults": 5}
            },
        )
        results = resp.get("retrievalResults", [])
        if not results:
            return ""

        passages = []
        for r in results:
            content = r.get("content", {}).get("text", "")
            source = r.get("location", {}).get("s3Location", {}).get("uri", "")
            if content:
                passages.append(f"[Source: {source}]\n{content}")

        context = "\n\n".join(passages)
        logger.info(json.dumps({
            "event": "kb_retrieve",
            "kb_id": kb_id,
            "passages": len(passages),
        }))
        return context

    except Exception as exc:
        logger.warning(json.dumps({
            "event": "kb_retrieve_error",
            "kb_id": kb_id,
            "error": str(exc),
        }))
        return ""


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

def init(config: dict[str, Any], system_prompt: str) -> None:
    """
    Set module-level state. Called once from main.py startup hook.

    Sets KNOWLEDGE_BASE_ID in os.environ so the @tool function can read it —
    the tool decorator runs at module level and has no access to the config dict.
    """
    global _model, _SYSTEM_PROMPT_TEXT, _MODEL_ID

    _MODEL_ID = config.get("model_arn", "us.anthropic.claude-sonnet-4-6")
    _SYSTEM_PROMPT_TEXT = system_prompt

    # Expose KB ID to retrieve_hr_documents tool via environment.
    if config.get("knowledge_base_id"):
        os.environ["KNOWLEDGE_BASE_ID"] = config["knowledge_base_id"]

    _model = BedrockModel(
        model_id=_MODEL_ID,
        region_name=os.environ.get("AWS_REGION", "us-east-2"),
        guardrail_id=config["guardrail_id"],
        guardrail_version=config.get("guardrail_version", "DRAFT"),
        guardrail_trace="enabled",
    )

    logger.info(json.dumps({
        "event": "strands_agent_initialized",
        "model_id": _MODEL_ID,
        "guardrail_id": config["guardrail_id"],
        "system_prompt_chars": len(system_prompt),
    }))


# ---------------------------------------------------------------------------
# Invocation
# ---------------------------------------------------------------------------

def invoke(
    session_id: str,
    user_message: str,
    trace_context: dict[str, str] | None = None,
) -> dict[str, Any]:
    """
    Run the Strands agent loop for a single user turn.

    Returns a dict with the same shape as agent.py's invoke() so main.py's
    vault.write() call works identically for both implementations:
      response      — the agent's text response
      tool_calls    — always [] in Phase 1 (Strands SDK limitation)
      guardrail_result — action derived from stop_reason
      input_tokens  — from last AgentInvocation usage
      output_tokens — from last AgentInvocation usage
      latency_ms    — total wall-clock latency
    """
    start_ms = int(time.monotonic() * 1000)

    s3sm = S3SessionManager(
        session_id=session_id,
        bucket=os.environ["PROMPT_VAULT_BUCKET"],
        prefix="strands-sessions/hr-assistant/",
        region_name=os.environ.get("AWS_REGION", "us-east-2"),
    )

    agent = Agent(
        model=_model,
        tools=[glean_search, retrieve_hr_documents],
        system_prompt=_SYSTEM_PROMPT_TEXT,
        session_manager=s3sm,
        conversation_manager=SlidingWindowConversationManager(window_size=10),
        callback_handler=None,
    )

    result = agent(user_message)

    latency_ms = int(time.monotonic() * 1000) - start_ms
    invocations = result.metrics.agent_invocations
    usage = invocations[-1].usage if invocations else {}

    log_event = {
        "event": "strands_invoke",
        "session_id": session_id,
        "stop_reason": result.stop_reason,
        "cycle_count": result.metrics.cycle_count,
        "input_tokens": usage.get("inputTokens", 0),
        "output_tokens": usage.get("outputTokens", 0),
        "latency_ms": latency_ms,
        "tool_calls": len(result.metrics.tool_metrics),
    }
    if trace_context:
        log_event["trace_id"] = trace_context.get("trace_id", "")
        log_event["parent_span_id"] = trace_context.get("span_id", "")
    logger.info(json.dumps(log_event))

    return {
        "response": str(result),
        "tool_calls": [],  # Strands tool_metrics does not expose per-call
                           # input/output text — known limitation, Phase 2.
        "guardrail_result": {
            "action": "GUARDRAIL_INTERVENED"
                      if result.stop_reason == "guardrail_intervened"
                      else "NONE",
            "topic_policy_result": "",   # not exposed by Strands SDK
            "content_filter_result": "", # not exposed by Strands SDK
        },
        "input_tokens": usage.get("inputTokens", 0),
        "output_tokens": usage.get("outputTokens", 0),
        "latency_ms": latency_ms,
    }


async def invoke_stream(
    session_id: str,
    user_message: str,
    trace_context: dict[str, str] | None = None,
):
    """Streaming counterpart to invoke().

    Yields NDJSON-ready dicts as they are produced by the agent:
      {"type": "text", "data": "..."}       — text chunk
      {"type": "tool_use", "name": "..."}   — tool invocation started
      {"type": "done", "metadata": {...}}   — terminal event with usage + latency

    A final metadata dict is yielded so the caller can emit metrics and write
    the vault record once the stream closes. The caller is responsible for
    turning dicts into NDJSON bytes.
    """
    start_ms = int(time.monotonic() * 1000)

    s3sm = S3SessionManager(
        session_id=session_id,
        bucket=os.environ["PROMPT_VAULT_BUCKET"],
        prefix="strands-sessions/hr-assistant/",
        region_name=os.environ.get("AWS_REGION", "us-east-2"),
    )

    agent = Agent(
        model=_model,
        tools=[glean_search, retrieve_hr_documents],
        system_prompt=_SYSTEM_PROMPT_TEXT,
        session_manager=s3sm,
        conversation_manager=SlidingWindowConversationManager(window_size=10),
        callback_handler=None,
    )

    response_chars = 0
    input_tokens = 0
    output_tokens = 0
    stop_reason = "unknown"
    tool_calls = 0

    first_event_logged = False
    first_text_logged = False
    async for event in agent.stream_async(user_message):
        if not first_event_logged:
            logger.info(json.dumps({
                "event": "strands_stream_first_event",
                "session_id": session_id,
                "dt_ms": int(time.monotonic() * 1000) - start_ms,
            }))
            first_event_logged = True
        if isinstance(event, dict) and "data" in event:
            chunk = event["data"]
            if chunk:
                response_chars += len(chunk)
                if not first_text_logged:
                    logger.info(json.dumps({
                        "event": "strands_stream_first_text",
                        "session_id": session_id,
                        "dt_ms": int(time.monotonic() * 1000) - start_ms,
                    }))
                    first_text_logged = True
                yield {"type": "text", "data": chunk}
        elif isinstance(event, dict) and event.get("current_tool_use"):
            tool_calls += 1
            tool_name = event["current_tool_use"].get("name", "")
            yield {"type": "tool_use", "name": tool_name}
        elif isinstance(event, dict) and event.get("result") is not None:
            result = event["result"]
            stop_reason = getattr(result, "stop_reason", "unknown")
            invocations = result.metrics.agent_invocations if hasattr(result, "metrics") else []
            usage = invocations[-1].usage if invocations else {}
            input_tokens = usage.get("inputTokens", 0)
            output_tokens = usage.get("outputTokens", 0)

    latency_ms = int(time.monotonic() * 1000) - start_ms

    log_event = {
        "event": "strands_stream_invoke",
        "session_id": session_id,
        "stop_reason": stop_reason,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "latency_ms": latency_ms,
        "response_chars": response_chars,
        "tool_calls": tool_calls,
    }
    if trace_context:
        log_event["trace_id"] = trace_context.get("trace_id", "")
        log_event["parent_span_id"] = trace_context.get("span_id", "")
    logger.info(json.dumps(log_event))

    yield {
        "type": "done",
        "metadata": {
            "stop_reason": stop_reason,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "latency_ms": latency_ms,
            "response_chars": response_chars,
            "tool_calls": tool_calls,
        },
    }
