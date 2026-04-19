"""
HR Assistant Strands — FastAPI entry point for the AgentCore container runtime.

Strands-only implementation. No AGENT_IMPL routing — this container always
runs the Strands implementation. The /invocations contract with AgentCore
(POST /invocations, GET /health) is unchanged from the boto3 agent.

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

_REGION = os.environ.get("AWS_REGION", "us-east-2")

# ---------------------------------------------------------------------------
# App initialisation
# ---------------------------------------------------------------------------

app = FastAPI(title="HR Assistant Strands", version="1.0.0")


@app.on_event("startup")
async def startup() -> None:
    """
    Bootstrap agent from DynamoDB registry and configure Strands + OTEL.

    Sequence:
    1. Load registry item for hr-assistant-strands-dev from DynamoDB
    2. Load system prompt text from Bedrock Prompt Management
    3. Configure OTEL (graceful skip if OTEL_EXPORTER_OTLP_ENDPOINT not set)
    4. Call agent_strands.init(config, system_prompt_text)
    5. Call vault.init(lambda_arn)
    6. Log container_ready
    """
    from app import agent_strands, vault

    _AGENT_ID = "hr-assistant-strands-dev"
    _REGISTRY_TABLE = os.environ["AGENT_REGISTRY_TABLE"]

    dynamodb = boto3.resource("dynamodb", region_name=_REGION)
    bedrock_agent = boto3.client("bedrock-agent", region_name=_REGION)

    # Step 1 — Load registry manifest
    table = dynamodb.Table(_REGISTRY_TABLE)
    resp = table.get_item(Key={"agent_id": _AGENT_ID})
    item = resp.get("Item", {})
    if not item:
        raise RuntimeError(
            f"Agent manifest not found in registry for agent_id={_AGENT_ID}"
        )

    # DynamoDB resource returns plain Python types; raw client returns {"S": ...} dicts.
    # Handle both to be safe.
    def _str(val: object, default: str = "") -> str:
        if isinstance(val, dict):
            return val.get("S", default)
        return val if isinstance(val, str) else default

    config = {
        "system_prompt_arn":      _str(item.get("system_prompt_arn")),
        "guardrail_id":           _str(item.get("guardrail_id")),
        "guardrail_version":      _str(item.get("guardrail_version"), "DRAFT"),
        "knowledge_base_id":      _str(item.get("knowledge_base_id")),
        "prompt_vault_lambda_arn":_str(item.get("prompt_vault_lambda_arn")),
        "model_arn":              _str(
            item.get("model_arn"),
            os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-sonnet-4-6"),
        ),
    }

    # Step 2 — Load system prompt text from Bedrock Prompt Management
    system_prompt_text = ""
    prompt_arn = config["system_prompt_arn"]
    if prompt_arn:
        prompt_resp = bedrock_agent.get_prompt(promptIdentifier=prompt_arn)
        variants = prompt_resp.get("variants", [])
        if variants:
            system_prompt_text = (
                variants[0]
                .get("templateConfiguration", {})
                .get("text", {})
                .get("text", "")
            )

    # Step 3 — Configure OTEL (quick path — graceful skip if endpoint not set)
    otlp_endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT")
    if otlp_endpoint:
        try:
            from strands.telemetry import StrandsTelemetry
            StrandsTelemetry().setup_otlp_exporter(endpoint=otlp_endpoint)
            StrandsTelemetry().setup_meter(enable_otlp_exporter=True)
            logger.info(json.dumps({"event": "otel_configured", "endpoint": otlp_endpoint}))
        except Exception as exc:
            logger.warning(json.dumps({"event": "otel_setup_error", "error": str(exc)}))
    else:
        logger.warning(json.dumps({
            "event": "otel_disabled",
            "reason": "OTEL_EXPORTER_OTLP_ENDPOINT not set — traces and metrics not exported",
        }))

    # Step 4 — Fail fast if PROMPT_VAULT_BUCKET is missing (needed by S3SessionManager)
    if not os.environ.get("PROMPT_VAULT_BUCKET"):
        raise RuntimeError("PROMPT_VAULT_BUCKET environment variable is required for S3SessionManager")

    # Step 5 — Initialize Strands agent
    agent_strands.init(config, system_prompt_text)

    # Step 6 — Initialize Prompt Vault
    vault.init(config.get("prompt_vault_lambda_arn", ""))

    logger.info(json.dumps({"event": "container_ready", "agent_id": _AGENT_ID}))


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
    from app import agent_strands, vault

    body: dict = {}
    try:
        body = await request.json()
    except Exception:
        return JSONResponse(status_code=400, content={"error": "Invalid JSON payload"})

    user_message = body.get("prompt") or body.get("inputText") or body.get("input", "")
    if not user_message:
        return JSONResponse(status_code=400, content={"error": "Missing prompt in payload"})

    # Session ID — prefer header, fall back to payload, fall back to default
    session_id = (
        request.headers.get("X-Amzn-Bedrock-AgentCore-Session-Id")
        or request.headers.get("x-amzn-bedrock-agentcore-session-id")
        or body.get("sessionId", "default-session")
    )

    try:
        result = agent_strands.invoke(session_id=session_id, user_message=user_message)
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
        model_arn=agent_strands._MODEL_ID,
        input_tokens=result["input_tokens"],
        output_tokens=result["output_tokens"],
        latency_ms=result["latency_ms"],
    )

    return JSONResponse(content={"response": result["response"]})
