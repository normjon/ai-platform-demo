"""CloudWatch metric emission for the orchestrator.

Two views:
- Orchestrator-level: dimension AgentId=orchestrator-dev, Environment=<env>.
- Per-sub-agent dispatch: dimension AgentId=orchestrator-dev, DispatchedAgent=<id>, Environment=<env>.

All metrics emit to the `bedrock-agentcore` namespace. The runtime role's
`cloudwatch:PutMetricData` IAM statement has a namespace condition — any
other namespace is denied.

Never call these functions inline inside an `async def` handler. They are
synchronous boto3 calls; invoke via FastAPI `BackgroundTasks` or
`asyncio.to_thread` so the event loop is not blocked (see the strands
layer CLAUDE.md Pitfall 2).
"""

from __future__ import annotations

import json
import logging
import threading
from typing import Iterable

import boto3

from app import config

logger = logging.getLogger(__name__)

_cloudwatch_lock = threading.Lock()
_cloudwatch_client = None


def _get_cloudwatch():
    global _cloudwatch_client
    if _cloudwatch_client is not None:
        return _cloudwatch_client
    with _cloudwatch_lock:
        if _cloudwatch_client is None:
            _cloudwatch_client = boto3.client("cloudwatch", region_name=config.AWS_REGION)
    return _cloudwatch_client


def _base_dimensions() -> list[dict[str, str]]:
    return [
        {"Name": "AgentId", "Value": config.AGENT_ID},
        {"Name": "Environment", "Value": config.AGENT_ENV},
    ]


def _emit(metric_data: Iterable[dict]) -> None:
    try:
        _get_cloudwatch().put_metric_data(
            Namespace=config.METRIC_NAMESPACE,
            MetricData=list(metric_data),
        )
    except Exception as exc:
        logger.warning(json.dumps({"event": "metric_emit_failed", "error": str(exc)}))


def emit_orchestrator_metrics(
    latency_ms: int,
    input_tokens: int,
    output_tokens: int,
    pii_inbound: int,
    pii_outbound: int,
) -> None:
    dims = _base_dimensions()
    _emit([
        {"MetricName": "OrchestratorInvocationLatency", "Dimensions": dims,
         "Value": latency_ms, "Unit": "Milliseconds"},
        {"MetricName": "OrchestratorInputTokens", "Dimensions": dims,
         "Value": input_tokens, "Unit": "Count"},
        {"MetricName": "OrchestratorOutputTokens", "Dimensions": dims,
         "Value": output_tokens, "Unit": "Count"},
        {"MetricName": "PiiDetectedInbound", "Dimensions": dims,
         "Value": pii_inbound, "Unit": "Count"},
        {"MetricName": "PiiDetectedOutbound", "Dimensions": dims,
         "Value": pii_outbound, "Unit": "Count"},
    ])


def emit_dispatch_metrics(
    dispatched_agent: str,
    latency_ms: int,
    success: bool,
    error_class: str | None = None,
) -> None:
    dims = _base_dimensions() + [{"Name": "DispatchedAgent", "Value": dispatched_agent}]
    data = [
        {"MetricName": "DispatchLatency", "Dimensions": dims,
         "Value": latency_ms, "Unit": "Milliseconds"},
        {"MetricName": "DispatchCount", "Dimensions": dims,
         "Value": 1, "Unit": "Count"},
        {"MetricName": "DispatchSuccess" if success else "DispatchFailure",
         "Dimensions": dims, "Value": 1, "Unit": "Count"},
    ]
    if not success and error_class:
        data.append({
            "MetricName": "DispatchFailure",
            "Dimensions": dims + [{"Name": "ErrorClass", "Value": error_class}],
            "Value": 1,
            "Unit": "Count",
        })
    _emit(data)


def emit_routing_counter(metric_name: str) -> None:
    """Counter metrics for orchestrator-level routing outcomes."""
    _emit([{
        "MetricName": metric_name,
        "Dimensions": _base_dimensions(),
        "Value": 1,
        "Unit": "Count",
    }])
