"""PII middleware — Amazon Comprehend DetectPiiEntities on inbound/outbound."""

from __future__ import annotations

import json
import logging
import threading
from dataclasses import dataclass

import boto3

from app import config

logger = logging.getLogger(__name__)

_comprehend_lock = threading.Lock()
_comprehend_client = None


def _get_comprehend():
    global _comprehend_client
    if _comprehend_client is not None:
        return _comprehend_client
    with _comprehend_lock:
        if _comprehend_client is None:
            _comprehend_client = boto3.client("comprehend", region_name=config.AWS_REGION)
    return _comprehend_client


@dataclass
class PiiResult:
    redacted_text: str
    pii_types: list[str]


def scan_and_redact(text: str, language_code: str = "en") -> PiiResult:
    """Call Comprehend DetectPiiEntities. Redact entities in-place with {TYPE} placeholders.

    Returns the redacted text and the sorted unique list of detected entity
    types. If the call fails, we log and pass the text through unchanged —
    Comprehend is defense-in-depth on top of the guardrail and transient
    failures must not block user-facing flow.
    """
    if not text:
        return PiiResult(redacted_text=text, pii_types=[])

    try:
        resp = _get_comprehend().detect_pii_entities(Text=text, LanguageCode=language_code)
    except Exception as exc:
        logger.warning(json.dumps({"event": "pii_scan_failed", "error": str(exc)}))
        return PiiResult(redacted_text=text, pii_types=[])

    entities = resp.get("Entities", [])
    if not entities:
        return PiiResult(redacted_text=text, pii_types=[])

    # Replace from the end backwards so offsets remain valid.
    chars = list(text)
    for ent in sorted(entities, key=lambda e: e.get("BeginOffset", 0), reverse=True):
        begin = ent.get("BeginOffset")
        end = ent.get("EndOffset")
        if begin is None or end is None:
            continue
        chars[begin:end] = list(f"{{{ent.get('Type', 'PII')}}}")

    pii_types = sorted({ent.get("Type", "PII") for ent in entities})
    return PiiResult(redacted_text="".join(chars), pii_types=pii_types)
