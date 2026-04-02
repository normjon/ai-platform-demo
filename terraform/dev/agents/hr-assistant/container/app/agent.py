"""
HR Assistant agent loop.

Responsibilities:
  1. Bootstrap configuration from the DynamoDB agent registry at startup.
  2. Load the system prompt text from Bedrock Prompt Management.
  3. Retrieve relevant HR policy context from the Knowledge Base.
  4. Call Bedrock converse() with system prompt, KB context, history, and tools.
  5. Handle glean-search tool calls by invoking the Glean stub Lambda.
  6. Return the final text response.

ADR-001: all AWS access via IRSA — no credentials in code or env vars.
ADR-003: structured JSON logging to stdout.
ADR-004: this container runs on arm64/Graviton — no x86 binary assumptions.
"""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Any

import boto3

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# AWS clients
# ---------------------------------------------------------------------------

_REGION = os.environ.get("AWS_REGION", "us-east-2")
_bedrock = boto3.client("bedrock-runtime", region_name=_REGION)
_bedrock_agent = boto3.client("bedrock-agent", region_name=_REGION)
_bedrock_agent_runtime = boto3.client("bedrock-agent-runtime", region_name=_REGION)
_dynamodb = boto3.resource("dynamodb", region_name=_REGION)
_lambda = boto3.client("lambda", region_name=_REGION)

# ---------------------------------------------------------------------------
# Agent configuration — loaded from DynamoDB registry at startup
# ---------------------------------------------------------------------------

_AGENT_ID = "hr-assistant-dev"
_REGISTRY_TABLE = os.environ["AGENT_REGISTRY_TABLE"]
_MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "anthropic.claude-sonnet-4-6")
_GLEAN_FUNCTION = "ai-platform-dev-glean-stub"

# Populated by _load_config() at startup
_CONFIG: dict[str, str] = {}
_SYSTEM_PROMPT_TEXT: str = ""


def _load_config() -> None:
    """
    Read agent manifest from the DynamoDB registry and load the system prompt.
    Called once at container startup. Raises on failure — startup should fail
    rather than serving requests with incomplete configuration.
    """
    global _CONFIG, _SYSTEM_PROMPT_TEXT

    table = _dynamodb.Table(_REGISTRY_TABLE)
    resp = table.get_item(Key={"agent_id": _AGENT_ID})
    item = resp.get("Item", {})
    if not item:
        raise RuntimeError(
            f"Agent manifest not found in registry for agent_id={_AGENT_ID}"
        )

    _CONFIG = {
        "system_prompt_arn": item["system_prompt_arn"]["S"] if isinstance(item.get("system_prompt_arn"), dict) else item.get("system_prompt_arn", ""),
        "guardrail_id": item["guardrail_id"]["S"] if isinstance(item.get("guardrail_id"), dict) else item.get("guardrail_id", ""),
        "guardrail_version": item["guardrail_version"]["S"] if isinstance(item.get("guardrail_version"), dict) else item.get("guardrail_version", "DRAFT"),
        "knowledge_base_id": item["knowledge_base_id"]["S"] if isinstance(item.get("knowledge_base_id"), dict) else item.get("knowledge_base_id", ""),
        "model_arn": _MODEL_ID,
    }

    # Load system prompt text from Bedrock Prompt Management
    prompt_arn = _CONFIG["system_prompt_arn"]
    if prompt_arn:
        prompt_resp = _bedrock_agent.get_prompt(promptIdentifier=prompt_arn)
        variants = prompt_resp.get("variants", [])
        if variants:
            _SYSTEM_PROMPT_TEXT = (
                variants[0]
                .get("templateConfiguration", {})
                .get("text", {})
                .get("text", "")
            )

    logger.info(json.dumps({
        "event": "agent_config_loaded",
        "agent_id": _AGENT_ID,
        "guardrail_id": _CONFIG["guardrail_id"],
        "knowledge_base_id": _CONFIG.get("knowledge_base_id", ""),
        "system_prompt_chars": len(_SYSTEM_PROMPT_TEXT),
    }))


def _retrieve_kb_context(query: str) -> str:
    """
    Retrieve relevant HR policy passages from the Bedrock Knowledge Base.
    Returns a formatted string of retrieved passages, or empty string if
    no KB is configured or retrieval fails.
    """
    kb_id = _CONFIG.get("knowledge_base_id", "")
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


def _call_glean(query: str) -> str:
    """
    Invoke the Glean stub Lambda (MCP JSON-RPC tools/call).
    Returns the text content of the search results.
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
        resp = _lambda.invoke(
            FunctionName=_GLEAN_FUNCTION,
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


def _extract_guardrail_result(resp: dict) -> dict:
    """
    Extract guardrail assessment from a Bedrock converse() response.

    Returns the structured result expected by the Prompt Vault record.
    When no guardrail fired, returns action=NONE with empty topic/filter fields.
    When a guardrail fired, extracts the first blocked topic and content filter
    from the trace assessments (both input and output assessments are checked).
    """
    if resp.get("stopReason", "") != "guardrail_intervened":
        return {"action": "NONE", "topic_policy_result": "", "content_filter_result": ""}

    guardrail_trace = resp.get("trace", {}).get("guardrail", {})

    topic_name = ""
    content_filter_name = ""

    # inputAssessment is a dict keyed by guardrail ID; outputAssessments is a list.
    raw_assessments: list[dict] = []
    input_assessment = guardrail_trace.get("inputAssessment", {})
    if isinstance(input_assessment, dict):
        raw_assessments.extend(input_assessment.values())
    output_assessments = guardrail_trace.get("outputAssessments", [])
    if isinstance(output_assessments, list):
        raw_assessments.extend(output_assessments)

    for assessment in raw_assessments:
        if not topic_name:
            for topic in assessment.get("topicPolicy", {}).get("topics", []):
                if topic.get("action") == "BLOCKED":
                    topic_name = topic.get("name", "")
                    break
        if not content_filter_name:
            for f in assessment.get("contentPolicy", {}).get("filters", []):
                if f.get("action") == "BLOCKED":
                    content_filter_name = f.get("type", "")
                    break
        if topic_name and content_filter_name:
            break

    return {
        "action": "GUARDRAIL_INTERVENED",
        "topic_policy_result": topic_name,
        "content_filter_result": content_filter_name,
    }


_GLEAN_TOOL_SPEC = {
    "toolSpec": {
        "name": "glean_search",
        "description": (
            "Search the company knowledge base and HR documentation. "
            "Use this tool before answering any HR policy question. "
            "Do not answer from memory without searching first."
        ),
        "inputSchema": {
            "json": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Search query — be specific (e.g. 'annual leave entitlement days').",
                    }
                },
                "required": ["query"],
            }
        },
    }
}


def invoke(session_id: str, user_message: str) -> dict[str, Any]:
    """
    Run the agent loop for a single user turn.

    Returns a dict with:
      response      — the agent's text response
      tool_calls    — list of tool calls made during this turn
      input_tokens  — total input tokens consumed
      output_tokens — total output tokens consumed
      latency_ms    — total wall-clock latency in milliseconds
    """
    from app import memory  # local import to avoid circular

    start_ms = int(time.monotonic() * 1000)

    # Retrieve KB context before calling the model
    kb_context = _retrieve_kb_context(user_message)

    # Build system prompt — inject KB context when available
    system_text = _SYSTEM_PROMPT_TEXT
    if kb_context:
        system_text = (
            f"{_SYSTEM_PROMPT_TEXT}\n\n"
            "## Relevant HR Policy Passages (retrieved from Knowledge Base)\n\n"
            f"{kb_context}\n\n"
            "Use the above passages to ground your response. "
            "Cite the source document when referencing policy details."
        )

    # Load session history and append the new user message
    history = memory.get_history(session_id)
    history.append({"role": "user", "content": [{"text": user_message}]})

    tool_calls_made: list[dict[str, Any]] = []
    total_input_tokens = 0
    total_output_tokens = 0
    final_response = ""
    guardrail_result: dict[str, str] = {"action": "NONE", "topic_policy_result": "", "content_filter_result": ""}

    # Agentic loop — runs until the model stops requesting tools
    messages = list(history)
    for _ in range(5):  # max 5 tool rounds
        resp = _bedrock.converse(
            modelId=_MODEL_ID,
            system=[{"text": system_text}],
            messages=messages,
            toolConfig={"tools": [_GLEAN_TOOL_SPEC]},
            guardrailConfig={
                "guardrailIdentifier": _CONFIG["guardrail_id"],
                "guardrailVersion": _CONFIG["guardrail_version"],
                "trace": "enabled",
            },
        )

        usage = resp.get("usage", {})
        total_input_tokens += usage.get("inputTokens", 0)
        total_output_tokens += usage.get("outputTokens", 0)

        stop_reason = resp.get("stopReason", "")
        output_message = resp["output"]["message"]
        messages.append(output_message)

        # Capture guardrail assessment on every round — overwrites only if
        # a guardrail fires (action=NONE is the no-op default).
        guardrail_result = _extract_guardrail_result(resp)

        if stop_reason == "tool_use":
            tool_results = []
            for block in output_message.get("content", []):
                if block.get("type") != "tool_use" and "toolUse" not in block:
                    continue
                tool_block = block.get("toolUse", block)
                tool_name = tool_block.get("name", "")
                tool_input = tool_block.get("input", {})
                tool_use_id = tool_block.get("toolUseId", "")

                result_text = ""
                if tool_name == "glean_search":
                    result_text = _call_glean(tool_input.get("query", ""))
                else:
                    result_text = f"Unknown tool: {tool_name}"

                tool_calls_made.append({
                    "toolName": tool_name,
                    "input": json.dumps(tool_input),
                    "output": result_text,
                })
                tool_results.append({
                    "toolResult": {
                        "toolUseId": tool_use_id,
                        "content": [{"text": result_text}],
                    }
                })

            messages.append({"role": "user", "content": tool_results})

        else:
            # Extract final text response
            for block in output_message.get("content", []):
                if "text" in block:
                    final_response = block["text"]
                    break
            break

    # Persist updated session history (up to last user+assistant turn)
    memory.put_history(session_id, messages)

    latency_ms = int(time.monotonic() * 1000) - start_ms

    logger.info(json.dumps({
        "event": "agent_invoke",
        "session_id": session_id,
        "tool_calls": len(tool_calls_made),
        "guardrail_action": guardrail_result["action"],
        "input_tokens": total_input_tokens,
        "output_tokens": total_output_tokens,
        "latency_ms": latency_ms,
    }))

    return {
        "response": final_response,
        "tool_calls": tool_calls_made,
        "guardrail_result": guardrail_result,
        "input_tokens": total_input_tokens,
        "output_tokens": total_output_tokens,
        "latency_ms": latency_ms,
    }
