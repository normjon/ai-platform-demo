"""DynamoDB agent registry reader with in-memory TTL cache.

The registry is the source of truth for which sub-agents exist and which
domains they serve. The orchestrator scans it once per cache interval
(default 60s). `lookup_by_domain()` returns exactly one enabled entry or
None. `summary()` returns a LLM-friendly text block injected into the
supervisor system prompt.

All mutation happens out-of-band (Terraform put-item from each agent
layer). The orchestrator never writes to the registry.
"""

from __future__ import annotations

import json
import logging
import threading
import time
from typing import Any

import boto3
from boto3.dynamodb.conditions import Attr

from app import config

logger = logging.getLogger(__name__)

_dynamodb_lock = threading.Lock()
_dynamodb_resource = None


def _get_dynamodb():
    global _dynamodb_resource
    if _dynamodb_resource is not None:
        return _dynamodb_resource
    with _dynamodb_lock:
        if _dynamodb_resource is None:
            _dynamodb_resource = boto3.resource("dynamodb", region_name=config.AWS_REGION)
    return _dynamodb_resource


_lock = threading.Lock()
_cached_entries: list[dict[str, Any]] = []
_cached_at: float = 0.0


def _load() -> list[dict[str, Any]]:
    """Scan the registry for enabled entries. Excludes the orchestrator self-entry."""
    if not config.REGISTRY_TABLE:
        raise RuntimeError("AGENT_REGISTRY_TABLE not set")

    table = _get_dynamodb().Table(config.REGISTRY_TABLE)
    items: list[dict[str, Any]] = []
    scan_kwargs = {
        "FilterExpression": Attr("enabled").eq(True) & Attr("agent_id").ne(config.AGENT_ID),
    }
    while True:
        resp = table.scan(**scan_kwargs)
        items.extend(resp.get("Items", []))
        if "LastEvaluatedKey" not in resp:
            break
        scan_kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]

    return items


def _cache_is_fresh() -> bool:
    return _cached_entries and (time.monotonic() - _cached_at) < config.REGISTRY_CACHE_TTL_SECONDS


def entries(force_refresh: bool = False) -> list[dict[str, Any]]:
    """Return cached enabled registry entries; refreshes on expiry."""
    from app import metrics

    global _cached_entries, _cached_at

    with _lock:
        if not force_refresh and _cache_is_fresh():
            return list(_cached_entries)

        try:
            fresh = _load()
            _cached_entries = fresh
            _cached_at = time.monotonic()
            metrics.emit_routing_counter("RegistryCacheMiss")
            return list(_cached_entries)
        except Exception as exc:
            logger.warning(json.dumps({
                "event": "registry_stale",
                "error": str(exc),
                "cached_count": len(_cached_entries),
            }))
            metrics.emit_routing_counter("RegistryCacheStale")
            return list(_cached_entries)


def lookup_by_domain(domain: str) -> dict[str, Any] | None:
    """Return the first enabled entry advertising this domain, or None.

    Phase O.1 decision: a single enabled agent owns each domain. If two
    entries overlap, the registry-validation rule (Phase O.4) rejects the
    registration. Lookup returns the first match from the cache.
    """
    for entry in entries():
        domains = entry.get("domains") or set()
        if domain in domains:
            return entry
    return None


def summary() -> str:
    """LLM-facing text block listing enabled sub-agents and the domains they serve."""
    lines: list[str] = []
    for entry in entries():
        agent_id = entry.get("agent_id", "")
        description = entry.get("agent_description", "")
        domains = sorted(entry.get("domains") or [])
        lines.append(f"- agent_id={agent_id}; domains={','.join(domains)}; description={description}")

    if not lines:
        return "(no sub-agents currently enabled)"
    return "\n".join(lines)


def all_domains() -> list[str]:
    """Flat list of domains advertised by enabled sub-agents."""
    domains: set[str] = set()
    for entry in entries():
        domains.update(entry.get("domains") or set())
    return sorted(domains)
