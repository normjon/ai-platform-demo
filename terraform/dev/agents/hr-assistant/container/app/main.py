"""
HR Assistant — FastAPI entry point for the AgentCore container runtime.

AgentCore sends POST /invocations with the payload from invoke-agent-runtime.
The session ID is passed in the X-Amzn-Bedrock-AgentCore-Session-Id header
or within the request payload as sessionId.

ADR-003: structured JSON logging to stdout.
ADR-004: container targets arm64/Graviton.
"""

from __future__ import annotations

import json
import logging
import os

import boto3
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse

# ---------------------------------------------------------------------------
# Logging setup — structured JSON to stdout (ADR-003)
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=getattr(logging, os.environ.get("LOG_LEVEL", "INFO")),
    format="%(message)s",
)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# App initialisation
# ---------------------------------------------------------------------------

app = FastAPI(title="HR Assistant", version="2.0.0")


@app.on_event("startup")
async def startup() -> None:
    """Load agent configuration from DynamoDB registry at container start."""
    from app import agent, vault
    agent._load_config()
    vault.init(agent._CONFIG.get("prompt_vault_lambda_arn", ""))
    logger.info(json.dumps({"event": "container_ready", "agent_id": "hr-assistant-dev"}))


# ---------------------------------------------------------------------------
# Health check — AgentCore polls this to confirm the container is alive
# ---------------------------------------------------------------------------

@app.get("/health")
async def health() -> dict:
    return {"status": "healthy"}


# ---------------------------------------------------------------------------
# Invocation endpoint — AgentCore routes agent invocations here
# ---------------------------------------------------------------------------

@app.post("/invocations")
async def invocations(request: Request) -> Response:
    """
    Receive an invocation from the AgentCore runtime.

    Expected payload: {"prompt": "<user message>"}
    Optional header:  X-Amzn-Bedrock-AgentCore-Session-Id: <session_id>

    Returns: {"response": "<agent response>"}
    """
    from app import agent, vault

    body: dict = {}
    try:
        body = await request.json()
    except Exception:
        return JSONResponse(status_code=400, content={"error": "Invalid JSON payload"})

    user_message = body.get("prompt") or body.get("inputText") or body.get("input", "")
    if not user_message:
        return JSONResponse(status_code=400, content={"error": "Missing prompt in payload"})

    # Session ID — prefer header, fall back to payload, fall back to generated
    session_id = (
        request.headers.get("X-Amzn-Bedrock-AgentCore-Session-Id")
        or request.headers.get("x-amzn-bedrock-agentcore-session-id")
        or body.get("sessionId", "default-session")
    )

    try:
        result = agent.invoke(session_id=session_id, user_message=user_message)
    except Exception as exc:
        logger.error(json.dumps({
            "event": "invocation_error",
            "session_id": session_id,
            "error": str(exc),
        }))
        return JSONResponse(
            status_code=500,
            content={"error": "Internal agent error", "detail": str(exc)},
        )

    # Fire-and-forget Prompt Vault write
    vault.write(
        session_id=session_id,
        user_input=user_message,
        agent_output=result["response"],
        tool_calls=result["tool_calls"],
        guardrail_result=result["guardrail_result"],
        model_arn=agent._MODEL_ID,
        input_tokens=result["input_tokens"],
        output_tokens=result["output_tokens"],
        latency_ms=result["latency_ms"],
    )

    return JSONResponse(content={"response": result["response"]})
