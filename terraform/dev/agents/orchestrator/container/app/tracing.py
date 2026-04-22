"""Trace context generation + propagation.

OTEL is wired end-to-end in Phase O.3 but the AgentCore runtime boundary
does not propagate OTEL HTTP headers natively. We generate a trace_id per
request at the orchestrator entry point and forward it in the dispatch
payload body. Sub-agents consume `payload['trace_context']` and include
`trace_id` in their log events, giving correlated distributed traces.
"""

from __future__ import annotations

import contextvars
import secrets
from typing import Any

_current: contextvars.ContextVar[dict[str, str] | None] = contextvars.ContextVar(
    "orchestrator_trace_context", default=None
)


def new_trace_context() -> dict[str, str]:
    """Generate a fresh trace context. 16-byte trace_id, 8-byte span_id — OTEL-compatible widths."""
    ctx = {
        "trace_id": secrets.token_hex(16),
        "span_id": secrets.token_hex(8),
    }
    _current.set(ctx)
    return ctx


def current_trace_context() -> dict[str, str]:
    ctx = _current.get()
    if ctx is None:
        return new_trace_context()
    return ctx


def trace_id() -> str:
    return current_trace_context()["trace_id"]


def log_fields() -> dict[str, Any]:
    """Fields to include on every structured log event for correlation."""
    ctx = current_trace_context()
    return {"trace_id": ctx["trace_id"], "span_id": ctx["span_id"]}
