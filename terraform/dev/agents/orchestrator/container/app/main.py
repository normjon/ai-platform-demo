"""Orchestrator FastAPI entry point for the AgentCore container runtime.

Contract:
- POST /invocations  body: {"prompt": str, "sessionId": str?, "user_role": str?}
- GET  /health       returns {"status": "healthy"}

Session ID is preferred from the X-Amzn-Bedrock-AgentCore-Session-Id header,
falling back to the `sessionId` body field. A fresh trace_context is generated
per request and forwarded to sub-agents via the dispatch payload.

All synchronous I/O (Strands agent loop, PII scan, audit writes, metric emit)
runs in a worker thread via asyncio.to_thread or FastAPI BackgroundTasks so
the asyncio event loop stays free to serve AgentCore's /health polling.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid

from fastapi import BackgroundTasks, FastAPI, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse

from app import log_handler

logging.basicConfig(level=logging.INFO, format="%(message)s")
log_handler.install()
logger = logging.getLogger(__name__)

app = FastAPI(title="Orchestrator", version="1.0.0")


@app.on_event("startup")
async def startup() -> None:
    from app import config, orchestrator
    orchestrator.init()
    logger.info(json.dumps({"event": "container_ready", "agent_id": config.AGENT_ID}))


@app.get("/health")
async def health() -> dict:
    return {"status": "healthy"}


@app.post("/invocations")
async def invocations(request: Request, background_tasks: BackgroundTasks) -> Response:
    from app import audit, middleware, metrics, orchestrator, tracing

    body: dict = {}
    try:
        body = await request.json()
    except Exception:
        return JSONResponse(status_code=400, content={"error": "Invalid JSON payload"})

    user_message = body.get("prompt") or body.get("inputText") or body.get("input", "")
    if not user_message:
        return JSONResponse(status_code=400, content={"error": "Missing prompt in payload"})

    session_id = (
        request.headers.get("X-Amzn-Bedrock-AgentCore-Session-Id")
        or request.headers.get("x-amzn-bedrock-agentcore-session-id")
        or body.get("sessionId", "default-session")
    )
    user_role = body.get("user_role", "employee")
    request_id = uuid.uuid4().hex

    trace_ctx = tracing.new_trace_context()
    start_ms = int(time.monotonic() * 1000)

    # Streaming path: PII scan + audit happen inside _sse_passthrough so the
    # `validating` status event can fire before the scan runs. See
    # specs/orchestrator-status-events-plan.md (Phase 1).
    if bool(body.get("stream", False)):
        return StreamingResponse(
            _sse_passthrough(
                request_id=request_id,
                session_id=session_id,
                user_message=user_message,
                user_role=user_role,
                trace_ctx=trace_ctx,
                start_ms=start_ms,
                background_tasks=background_tasks,
            ),
            media_type="text/event-stream",
            background=background_tasks,
        )

    pii_in = await asyncio.to_thread(middleware.scan_and_redact, user_message)
    audit.record_request(
        request_id=request_id,
        session_id=session_id,
        user_role=user_role,
        trace_id=trace_ctx["trace_id"],
        prompt=user_message,
        pii_types_inbound=pii_in.pii_types,
    )

    try:
        result = await asyncio.to_thread(
            orchestrator.invoke,
            session_id=session_id,
            user_message=pii_in.redacted_text,
        )
    except Exception as exc:
        logger.error(json.dumps({
            "event": "invocation_error",
            "request_id": request_id,
            "session_id": session_id,
            "error": str(exc),
            **tracing.log_fields(),
        }))
        return JSONResponse(
            status_code=500,
            content={"error": "Internal orchestrator error", "request_id": request_id},
        )

    duration_ms = int(time.monotonic() * 1000) - start_ms

    background_tasks.add_task(
        audit.record_response,
        request_id=request_id,
        session_id=session_id,
        trace_id=trace_ctx["trace_id"],
        response=result["response"],
        pii_types_outbound=[],
        dispatched_agent=result["dispatched_agent"],
        duration_ms=duration_ms,
    )
    background_tasks.add_task(
        metrics.emit_orchestrator_metrics,
        latency_ms=result["latency_ms"],
        input_tokens=result["input_tokens"],
        output_tokens=result["output_tokens"],
        pii_inbound=len(pii_in.pii_types),
        pii_outbound=0,
    )

    return JSONResponse(content={
        "response": result["response"],
        "dispatched_agent": result["dispatched_agent"],
        "request_id": request_id,
        "trace_id": trace_ctx["trace_id"],
    })


# ---------------------------------------------------------------------------
# Streaming passthrough (Server-Sent Events)
#
# Runs the supervisor in routing-only mode to decide the target sub-agent,
# then directly invokes the sub-agent's /invocations with stream=true and
# forwards each SSE event to the caller. A header event (routing decision)
# is emitted first so clients can render a dispatch banner before tokens
# arrive. The terminal "done" event from the sub-agent is passed through,
# then audit + metrics are emitted from the accumulated text.
#
# Protocol note: AgentCore's data plane only streams progressively when the
# container returns Content-Type: text/event-stream. We emit outbound frames
# as `data: <json>\n\n` and parse the sub-agent's identical SSE frames on
# the way back through — each inbound frame is re-emitted verbatim so clients
# see exactly one event per `data:` line.
# ---------------------------------------------------------------------------

def _agent_name_from_id(agent_id: str | None) -> str:
    """Title-cased, hyphen-to-space rendering of an agent_id for UI display.

    Registry-hosted friendly name deferred; see
    specs/orchestrator-status-events-plan.md (Field conventions).
    """
    if not agent_id:
        return ""
    return agent_id.replace("-", " ").title()


async def _sse_passthrough(
    request_id: str,
    session_id: str,
    user_message: str,
    user_role: str,
    trace_ctx: dict,
    start_ms: int,
    background_tasks: BackgroundTasks,
):
    import boto3
    from app import audit, config, middleware, metrics, orchestrator, tracing

    def _sse(event: dict) -> bytes:
        # schema_version is stamped on every orchestrator-emitted frame.
        # Pass-through sub-agent frames are forwarded verbatim elsewhere.
        event = {"schema_version": "1", **event}
        return f"data: {json.dumps(event)}\n\n".encode()

    # T0 — request accepted. Clients can immediately render "Processing…".
    logger.info(json.dumps({
        "event": "orchestrator_stream_received",
        "request_id": request_id,
        "session_id": session_id,
        "trace_id": trace_ctx["trace_id"],
        **tracing.log_fields(),
    }))
    yield _sse({
        "type": "received",
        "request_id": request_id,
        "trace_id": trace_ctx["trace_id"],
    })

    # Validating: always emitted (no threshold). PII scan + audit.record_request
    # run inside the streaming path so this event can fire before the scan.
    yield _sse({"type": "validating"})
    pii_in = await asyncio.to_thread(middleware.scan_and_redact, user_message)
    audit.record_request(
        request_id=request_id,
        session_id=session_id,
        user_role=user_role,
        trace_id=trace_ctx["trace_id"],
        prompt=user_message,
        pii_types_inbound=pii_in.pii_types,
    )
    logger.info(json.dumps({
        "event": "orchestrator_stream_validating",
        "request_id": request_id,
        "pii_inbound": len(pii_in.pii_types),
        **tracing.log_fields(),
    }))

    routing_start_ms = int(time.monotonic() * 1000)
    try:
        result = await asyncio.to_thread(
            orchestrator.invoke,
            session_id=session_id,
            user_message=pii_in.redacted_text,
            routing_only=True,
        )
    except Exception as exc:
        logger.error(json.dumps({
            "event": "invocation_error",
            "request_id": request_id,
            "session_id": session_id,
            "error": str(exc),
            **tracing.log_fields(),
        }))
        yield _sse({"type": "error", "detail": "routing_failed"})
        return

    dispatched_agent = result.get("dispatched_agent")
    runtime_arn = result.get("runtime_arn")
    domain = result.get("domain")
    latency_ms_to_decision = int(time.monotonic() * 1000) - routing_start_ms

    logger.info(json.dumps({
        "event": "orchestrator_stream_routing_decided",
        "request_id": request_id,
        "agent_id": dispatched_agent,
        "domain": domain,
        "latency_ms_to_decision": latency_ms_to_decision,
        **tracing.log_fields(),
    }))
    yield _sse({
        "type": "routing",
        "agent_id": dispatched_agent,
        "agent_name": _agent_name_from_id(dispatched_agent),
        "domain": domain,
        "request_id": request_id,
        "trace_id": trace_ctx["trace_id"],
    })

    if not dispatched_agent or not runtime_arn:
        yield _sse({
            "type": "done",
            "metadata": {"reason": "no_dispatch", "response": result.get("response", "")},
        })

        duration_ms = int(time.monotonic() * 1000) - start_ms
        background_tasks.add_task(
            audit.record_response,
            request_id=request_id,
            session_id=session_id,
            trace_id=trace_ctx["trace_id"],
            response=result.get("response", ""),
            pii_types_outbound=[],
            dispatched_agent=None,
            duration_ms=duration_ms,
        )
        background_tasks.add_task(
            metrics.emit_orchestrator_metrics,
            latency_ms=result["latency_ms"],
            input_tokens=result["input_tokens"],
            output_tokens=result["output_tokens"],
            pii_inbound=len(pii_in.pii_types),
            pii_outbound=0,
        )
        logger.info(json.dumps({
            "event": "orchestrator_stream_done",
            "request_id": request_id,
            "reason": "no_dispatch",
            "latency_ms": duration_ms,
            **tracing.log_fields(),
        }))
        return

    sub_session = f"{session_id}-{dispatched_agent}"
    sub_payload = json.dumps({
        "prompt": pii_in.redacted_text,
        "sessionId": sub_session,
        "stream": True,
        "trace_context": tracing.current_trace_context(),
    }).encode()

    client = boto3.client("bedrock-agentcore", region_name=config.AWS_REGION)

    def _invoke_sub():
        return client.invoke_agent_runtime(
            agentRuntimeArn=runtime_arn,
            runtimeSessionId=sub_session,
            payload=sub_payload,
        )

    yield _sse({
        "type": "dispatching",
        "agent_id": dispatched_agent,
        "agent_name": _agent_name_from_id(dispatched_agent),
    })
    logger.info(json.dumps({
        "event": "orchestrator_stream_dispatching",
        "request_id": request_id,
        "agent_id": dispatched_agent,
        **tracing.log_fields(),
    }))

    try:
        sub_resp = await asyncio.to_thread(_invoke_sub)
    except Exception as exc:
        logger.warning(json.dumps({
            "event": "dispatch_stream_invoke_failed",
            "agent_id": dispatched_agent,
            "error": str(exc),
            **tracing.log_fields(),
        }))
        yield _sse({"type": "error", "detail": "dispatch_failed"})
        return

    accumulated = []
    sub_metadata: dict = {}
    body_stream = sub_resp["response"]
    first_frame_logged = False

    def _read_chunk():
        return body_stream.read(4096)

    # SSE frames end with a blank line (`\n\n`). Split on that boundary, strip
    # the `data: ` prefix, parse the JSON payload, and forward the frame
    # verbatim so the caller sees the identical event shape.
    buffer = b""
    while True:
        chunk = await asyncio.to_thread(_read_chunk)
        if not chunk:
            break
        buffer += chunk
        while b"\n\n" in buffer:
            frame, buffer = buffer.split(b"\n\n", 1)
            payload = b""
            for line in frame.split(b"\n"):
                if line.startswith(b"data:"):
                    payload += line[5:].lstrip()
            if not payload:
                continue
            try:
                event = json.loads(payload)
            except Exception:
                continue
            if not first_frame_logged:
                logger.info(json.dumps({
                    "event": "orchestrator_stream_first_subagent_frame",
                    "request_id": request_id,
                    "agent_id": dispatched_agent,
                    "latency_ms_since_received": int(time.monotonic() * 1000) - start_ms,
                    **tracing.log_fields(),
                }))
                first_frame_logged = True
            if event.get("type") == "text":
                accumulated.append(event.get("data", ""))
            elif event.get("type") == "done":
                sub_metadata = event.get("metadata", {})
            yield frame + b"\n\n"

    if buffer.strip():
        payload = b""
        for line in buffer.split(b"\n"):
            if line.startswith(b"data:"):
                payload += line[5:].lstrip()
        if payload:
            try:
                event = json.loads(payload)
                if event.get("type") == "text":
                    accumulated.append(event.get("data", ""))
                elif event.get("type") == "done":
                    sub_metadata = event.get("metadata", {})
                yield buffer + b"\n\n"
            except Exception:
                pass

    full_response = "".join(accumulated)
    duration_ms = int(time.monotonic() * 1000) - start_ms

    background_tasks.add_task(
        audit.record_response,
        request_id=request_id,
        session_id=session_id,
        trace_id=trace_ctx["trace_id"],
        response=full_response,
        pii_types_outbound=[],
        dispatched_agent=dispatched_agent,
        duration_ms=duration_ms,
    )
    background_tasks.add_task(
        metrics.emit_orchestrator_metrics,
        latency_ms=sub_metadata.get("latency_ms", 0),
        input_tokens=sub_metadata.get("input_tokens", 0),
        output_tokens=sub_metadata.get("output_tokens", 0),
        pii_inbound=len(pii_in.pii_types),
        pii_outbound=0,
    )
    logger.info(json.dumps({
        "event": "orchestrator_stream_done",
        "request_id": request_id,
        "agent_id": dispatched_agent,
        "latency_ms": duration_ms,
        **tracing.log_fields(),
    }))
