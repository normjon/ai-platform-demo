# Orchestrator Status Events — Design Spec (Draft)

**Status:** Phase 1 approved; Phase 2 deferred to a fast-follow PR.
**Author:** Claude Code
**Date:** 2026-04-23
**Related code:** `terraform/dev/agents/orchestrator/container/app/main.py` (`_sse_passthrough`)
**Related pattern:** `docs/patterns/layers/agent-hr-assistant-strands.md` → *"Streaming — SSE + AgentCore Data-Plane Aggregation"*

---

## Problem

A dispatched orchestrator call takes 30–40s end-to-end. The caller sees
a blank screen until the sub-agent begins emitting text. The one
bright spot today — the `routing` event — fires ~2–4s in but is the
only signal before the long silence between routing and first chunk.
We want ChatGPT-style progress affordances ("Finding the right agent…",
"Retrieving policy context…", "Composing response…") to keep users
engaged during the wait.

Token-by-token streaming is not on the table — AgentCore's data-plane
proxy aggregates SSE frames into 2–3 chunks regardless of container
flushing (see the referenced pattern). Status events sit in the first
chunk and land well before sub-agent content, which is exactly the
window we want to fill.

---

## Goals

1. The caller receives a sequence of discrete, typed events describing
   what the platform is doing between request-received and response-complete.
2. Event emission points tie to real code paths — no UX theater.
3. Backward compatible: existing `"stream": false` callers see no change;
   existing `"stream": true` callers continue to receive `routing`, `text`,
   `done`, `error` frames without breaking.
4. Phased rollout: orchestrator-only first, sub-agent-cooperation later.

## Non-goals

- Token-by-token streaming (AgentCore runtime is the wrong transport).
- Client-side rendering decisions (out of scope; clients decide UX).
- Cancellation / interrupt mid-stream.
- Changes to AgentCore data-plane aggregation (AWS-managed).

---

## Current state

`main.py:_sse_passthrough` already:

- Runs the Strands supervisor in `routing_only=True` mode to pick an agent.
- Emits `{"type": "routing", "agent_id", "request_id", "trace_id"}` before
  sub-agent invocation.
- Invokes the sub-agent with `"stream": true` and forwards each SSE frame
  **verbatim** — sub-agent events (`text`, `done`) pass through unchanged.
- Accumulates text for audit/metrics, emits `{"type": "done"}` terminal frame.

Error path emits `{"type": "error", "detail": "..."}`.

---

## Event vocabulary

Proposed schema — every event is a JSON object with a required `type` and
a required `schema_version` (`"1"` on launch). Unknown types **must** be
ignored by clients.

| `type` | Emitted by | Purpose | Required fields |
|---|---|---|---|
| `received` | Orchestrator | Request accepted, processing started | `request_id`, `trace_id` |
| `validating` | Orchestrator | PII scan / input validation in flight | — |
| `routing` | Orchestrator | Routing decision made | `agent_id`, `agent_name`, `domain` |
| `dispatching` | Orchestrator | Sub-agent invocation started | `agent_id`, `agent_name` |
| `stage` | Sub-agent (Phase 2) | Named pipeline stage inside the sub-agent | `stage` (e.g. `"retrieving"`, `"composing"`), `message` |
| `text` | Sub-agent | Partial response content | `data` |
| `done` | Sub-agent / Orchestrator | Terminal success frame | `metadata` |
| `error` | Orchestrator / Sub-agent | Terminal failure frame | `detail` |

**Field conventions:**
- `agent_name` is a human-friendly label for clients to render without
  re-mapping `agent_id`. Source: title-cased `agent_id` with hyphens
  replaced by spaces (e.g. `hr-assistant-strands` → `"Hr Assistant
  Strands"`). Registry-hosted friendly name deferred — revisit if an
  agent_id doesn't title-case well.
- `message` on `stage` events is a one-line human sentence (e.g. `"Retrieving
  policy context…"`) authored by the sub-agent that owns the pipeline.
- Clients render whichever events they understand; unknown types are
  dropped silently.

**Field scope in Phase 1:**
- `schema_version: "1"` is added to every **orchestrator-emitted**
  frame: `received`, `validating`, `routing`, `dispatching`, and the
  orchestrator's terminal `done`/`error`.
- Pass-through sub-agent frames (`text`, `tool_use`, any sub-agent
  `done`/`error` forwarded verbatim) stay unchanged. The orchestrator
  does not rewrite them.
- `text`, `done`, `error` field shapes are otherwise unchanged — the
  only additions are on `routing` (`agent_name`) and `dispatching`
  (new event). Clients that ignore unknown fields see no breakage.

---

## Phase 1 — Orchestrator-only (scope: this spec)

Adds four new events to `_sse_passthrough`, all emitted by the orchestrator.
No sub-agent changes.

Emission sequence for a normal dispatch:

```
received        → immediately on entering _sse_passthrough
validating      → before PII scan runs (always emitted)
routing         → after supervisor routing_only=True completes (existing)
dispatching     → immediately before invoke_agent_runtime call
(text frames)   → forwarded from sub-agent (existing)
done            → terminal (existing)
```

`received` and `routing` already bracket the orchestrator's own work
window; `validating` and `dispatching` slot into the gaps the user
actually sees today.

**Implementation — file-level changes:**

1. `main.py:_sse_passthrough` — insert three new `yield _sse(...)` calls:
   - `received` — first line of the function, before any work.
   - `validating` — immediately before the PII scan (always, no threshold).
   - `dispatching` — after `orchestrator.invoke` returns, before `_invoke_sub()`.
2. `main.py:invocations` — move the PII scan inside `_sse_passthrough` for
   the streaming path (so the `validating` event can fire before it runs).
   Non-streaming path unchanged.
3. Add `schema_version: "1"` to every outbound frame.
4. `agent_name` on `routing` / `dispatching` events derives from
   `agent_id` via title-case + hyphen-to-space (no registry change).

---

## Phase 2 — Sub-agent cooperation (deferred; notes only)

To surface `"Retrieving policy context…"` / `"Composing response…"` the
**sub-agent** has to emit `stage` events from inside its own pipeline.
For `hr-assistant-strands` that means:

- A small helper that yields `stage` events before each major block
  (KB retrieve, Strands Agent loop, guardrail evaluation).
- Existing SSE framing in the strands container already supports this —
  just new event types.

**Not in scope for the first PR.** Recommend landing Phase 1, measuring
perceived-latency improvement, then deciding whether Phase 2 is worth
the cross-layer coordination.

---

## Backward compatibility

- `"stream": false` or absent → single JSON response (unchanged).
- `"stream": true`, client ignores unknown `type` values → sees existing
  `routing`, `text`, `done`, `error` events exactly as today, plus new
  types it can choose to render or drop.
- No breaking change to `text`/`done`/`routing` field shapes.

---

## Observability

New timing-log events, mirroring the `strands_stream_*` pattern from the
hr-assistant-strands layer. All go to `APP_LOG_GROUP`:

- `orchestrator_stream_received` — T0, with `request_id`, `trace_id`
- `orchestrator_stream_validating` — after PII scan
- `orchestrator_stream_routing_decided` — with `agent_id`, `latency_ms_to_decision`
- `orchestrator_stream_dispatching` — immediately before `invoke_agent_runtime`
- `orchestrator_stream_first_subagent_frame` — when the first sub-agent
  SSE frame is parsed (critical for TTFB diagnosis)
- `orchestrator_stream_done` — at terminal emission, with end-to-end
  `latency_ms`

These let anyone triaging TTFB localize delay to orchestrator vs.
sub-agent vs. AgentCore proxy in one log query, per the
already-established convention.

---

## Testing

`terraform/dev/agents/orchestrator/smoke-test.sh` additions:

1. **Event sequence assertion** — stream a test invocation, assert the
   first parsed event is `received`, a `routing` event arrives before any
   `text`, and the final event is `done`.
2. **Schema version assertion** — every parsed frame has `schema_version: "1"`.
3. **Backward-compat assertion** — a call with `"stream": false` returns
   a single JSON blob (unchanged).
4. **Unknown-type tolerance** — simulate a future event type; confirm the
   smoke test's event parser drops it without error.

Log-based assertions (via `APP_LOG_GROUP`):
- `orchestrator_stream_first_subagent_frame.timestamp - orchestrator_stream_received.timestamp < 10000ms`
  (sanity bound; adjust to observed baseline).

---

## Risks

1. **Data-plane aggregation clumps events.** The 2–3 chunk reality means
   clients may see `received` + `validating` + `routing` + `dispatching`
   arrive as one batch, followed by a second batch containing `text`
   frames. Still an improvement over 30s blank, but worth testing on a
   real client before declaring victory.
2. **Phase 1 alone labels only the first 2–4s.** The 25–35s "long wait"
   stays silent until Phase 2 lands. Phase 2 must follow as a fast
   follow-up to avoid leaving the UX half-finished.

---

## Effort estimate

**Phase 1 (this spec):**

| Task | Estimate |
|---|---|
| `_sse_passthrough` emission points + `schema_version` | 0.5 day |
| Smoke test updates (event sequence, schema, backward-compat) | 0.5 day |
| Timing-log events + doc updates to the orchestrator pattern file | 0.25 day |
| **Total** | **~1.25 engineer-days** |

**Phase 2 (fast follow-up — sub-agent `stage` events in hr-assistant-strands):** +1.5–2 days.

---

## Approved decisions (2026-04-23)

- Event vocabulary as listed (no changes from draft).
- Ship Phase 1 alone; Phase 2 follows as a fast follow-up.
- `friendly_name` registry field deferred; use title-cased `agent_id` fallback.
- `validating` always emitted (no latency threshold).
