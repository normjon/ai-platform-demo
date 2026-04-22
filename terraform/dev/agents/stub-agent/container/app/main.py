"""Stub-agent — deterministic echo endpoint for orchestrator dispatch validation.

Contract mirrors the other agent runtimes (POST /invocations, GET /health) so
the orchestrator's dispatch path is exercised without any LLM, tool, or KB
variability. Given {"prompt": "Hello"}, returns
{"response": "[stub-agent] received: Hello"}.

No Strands, no Bedrock, no guardrail, no session manager. This is Phase O.4 of
specs/orchestrator-plan.md: the piece that proves registry-driven routing works
across more than one sub-agent tenant.
"""

from __future__ import annotations

import json
import logging
import os

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

logging.basicConfig(
    level=getattr(logging, os.environ.get("LOG_LEVEL", "INFO")),
    format="%(message)s",
)
logger = logging.getLogger(__name__)

_AGENT_ID = "stub-agent-dev"
_PREFIX = "[stub-agent] received:"

app = FastAPI(title="Stub Agent", version="1.0.0")


@app.get("/health")
async def health() -> dict:
    return {"status": "healthy"}


@app.post("/invocations")
async def invocations(request: Request):
    try:
        body = await request.json()
    except Exception:
        return JSONResponse(status_code=400, content={"error": "Invalid JSON payload"})

    prompt = body.get("prompt") or body.get("inputText") or body.get("input", "")
    session_id = (
        request.headers.get("X-Amzn-Bedrock-AgentCore-Session-Id")
        or request.headers.get("x-amzn-bedrock-agentcore-session-id")
        or body.get("sessionId", "default-session")
    )
    trace_context = body.get("trace_context") if isinstance(body.get("trace_context"), dict) else {}

    log_event = {
        "event": "stub_invoke",
        "agent_id": _AGENT_ID,
        "session_id": session_id,
        "prompt_chars": len(prompt),
    }
    if trace_context:
        log_event["trace_id"] = trace_context.get("trace_id", "")
        log_event["parent_span_id"] = trace_context.get("span_id", "")
    logger.info(json.dumps(log_event))

    return JSONResponse(content={"response": f"{_PREFIX} {prompt}"})
