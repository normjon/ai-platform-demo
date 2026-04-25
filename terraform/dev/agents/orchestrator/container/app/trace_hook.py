"""
Strands HookProvider that emits a per-event structured log line for each
agent lifecycle stage. SSE-safe — hooks fire synchronously at well-defined
points and never wrap the async generator.

Spec: ai-observability-platform/specs/trace-ingestion.md §15.

Correlation: callers pass the request's trace_id at construction; every
emitted log line carries it so a single CloudWatch Logs Insights query
(filter by trace_id, sort by @timestamp) reconstructs the agent lifecycle.

Resilience: every callback body is wrapped in try/except so a logging
glitch can never kill an in-flight invocation.
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any

from opentelemetry import trace as otel_trace
from strands.hooks import (
    AfterInvocationEvent,
    AfterToolCallEvent,
    BeforeInvocationEvent,
    BeforeToolCallEvent,
    HookProvider,
    HookRegistry,
)

logger = logging.getLogger(__name__)


def _otel_trace_id() -> str | None:
    """Return the active OTEL trace_id as a 32-char hex string, or None
    if no valid span is in scope. Lets logs pivot to the AgentCore
    native AgentCore.Runtime.Invoke span via Transaction Search."""
    span = otel_trace.get_current_span()
    if span is None:
        return None
    ctx = span.get_span_context()
    if not ctx or not getattr(ctx, "is_valid", False):
        return None
    return f"{ctx.trace_id:032x}"


class TraceHook(HookProvider):
    def __init__(self, agent_id: str, session_id: str, trace_id: str) -> None:
        self._agent_id = agent_id
        self._session_id = session_id
        # Prefer caller-supplied trace_id (orchestrator-dispatched calls
        # carry it in trace_context). Fall back to the active OTEL span
        # context (native AgentCore instrumentation), then to a marker.
        self._trace_id = trace_id or _otel_trace_id() or "-"
        self._invocation_start: float | None = None
        self._tool_starts: dict[str, float] = {}

    def register_hooks(self, registry: HookRegistry, **_: Any) -> None:
        registry.add_callback(BeforeInvocationEvent, self._before_invocation)
        registry.add_callback(AfterInvocationEvent, self._after_invocation)
        registry.add_callback(BeforeToolCallEvent, self._before_tool)
        registry.add_callback(AfterToolCallEvent, self._after_tool)

    def _emit(self, payload: dict[str, Any]) -> None:
        try:
            base = {
                "trace_id": self._trace_id,
                "agent_id": self._agent_id,
                "session_id": self._session_id,
            }
            logger.info(json.dumps({**base, **payload}))
        except Exception as exc:
            try:
                logger.warning(json.dumps({
                    "event": "trace_hook_emit_error",
                    "error": str(exc)[:256],
                }))
            except Exception:
                pass

    def _before_invocation(self, _event: BeforeInvocationEvent) -> None:
        try:
            self._invocation_start = time.monotonic()
            self._emit({"event": "agent_start"})
        except Exception as exc:
            self._emit({"event": "trace_hook_error", "where": "before_invocation",
                        "error": str(exc)[:256]})

    def _after_invocation(self, event: AfterInvocationEvent) -> None:
        try:
            duration_ms = (
                int((time.monotonic() - self._invocation_start) * 1000)
                if self._invocation_start is not None
                else None
            )
            usage: dict[str, Any] = {}
            tool_call_count = 0
            stop_reason = None
            cycle_count = None
            if event.result is not None and getattr(event.result, "metrics", None) is not None:
                metrics = event.result.metrics
                usage = getattr(metrics, "accumulated_usage", {}) or {}
                tool_call_count = sum(
                    getattr(tm, "call_count", 0)
                    for tm in (getattr(metrics, "tool_metrics", {}) or {}).values()
                )
                cycle_count = getattr(metrics, "cycle_count", None)
                stop_reason = getattr(event.result, "stop_reason", None)

            self._emit({
                "event": "agent_end",
                "duration_ms": duration_ms,
                "stop_reason": stop_reason,
                "cycle_count": cycle_count,
                "input_tokens": usage.get("inputTokens"),
                "output_tokens": usage.get("outputTokens"),
                "total_tokens": usage.get("totalTokens"),
                "tool_calls": tool_call_count,
            })
        except Exception as exc:
            self._emit({"event": "trace_hook_error", "where": "after_invocation",
                        "error": str(exc)[:256]})

    def _before_tool(self, event: BeforeToolCallEvent) -> None:
        try:
            tool_use = event.tool_use or {}
            tool_use_id = tool_use.get("toolUseId", "")
            self._tool_starts[tool_use_id] = time.monotonic()
            input_obj = tool_use.get("input", {})
            self._emit({
                "event": "tool_start",
                "tool": tool_use.get("name"),
                "tool_use_id": tool_use_id,
                # Size-only — no raw payload (matches orchestrator audit-log discipline).
                "input_chars": len(json.dumps(input_obj)) if input_obj is not None else 0,
            })
        except Exception as exc:
            self._emit({"event": "trace_hook_error", "where": "before_tool",
                        "error": str(exc)[:256]})

    def _after_tool(self, event: AfterToolCallEvent) -> None:
        try:
            tool_use = event.tool_use or {}
            tool_use_id = tool_use.get("toolUseId", "")
            start = self._tool_starts.pop(tool_use_id, None)
            duration_ms = (
                int((time.monotonic() - start) * 1000)
                if start is not None
                else None
            )
            exc = event.exception
            result_status = None
            if event.result is not None:
                result_status = event.result.get("status")

            self._emit({
                "event": "tool_end",
                "tool": tool_use.get("name"),
                "tool_use_id": tool_use_id,
                "duration_ms": duration_ms,
                "result_status": result_status,
                "error": exc is not None,
                "error_type": type(exc).__name__ if exc is not None else None,
                "error_msg": str(exc)[:256] if exc is not None else None,
            })
        except Exception as inner_exc:
            self._emit({"event": "trace_hook_error", "where": "after_tool",
                        "error": str(inner_exc)[:256]})
