"""
LLM-as-Judge quality scorer Lambda handler.

Runs hourly via EventBridge. Discovers unscored Prompt Vault records,
invokes Haiku to score each interaction across five quality dimensions,
writes results to DynamoDB, and emits CloudWatch custom metrics.
"""

import json
import logging
import os
import time
from datetime import datetime, timezone

import boto3

try:
    from aws_xray_sdk.core import patch_all, xray_recorder
    patch_all()
except ImportError:
    # Graceful degradation if sdk is not packaged
    xray_recorder = None

logger = logging.getLogger()
logger.setLevel(logging.INFO)

PROMPT_VAULT_BUCKET = os.environ["PROMPT_VAULT_BUCKET"]
QUALITY_TABLE = os.environ["QUALITY_TABLE"]
SCORER_MODEL_ARN = os.environ["SCORER_MODEL_ARN"]
SCORE_THRESHOLD = float(os.environ.get("SCORE_THRESHOLD", "0.70"))
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
AGENT_REGISTRY_TABLE = os.environ["AGENT_REGISTRY_TABLE"]

DIMENSIONS = ["correctness", "relevance", "groundedness", "completeness", "tone"]

EVALUATION_PROMPT_TEMPLATE = """\
You are a quality evaluator for an enterprise AI agent.
The agent being evaluated is: {agent_id} — {agent_description}
Evaluate the following interaction and score it on five dimensions.

USER INPUT:
{user_input}

AGENT RESPONSE:
{agent_response}

TOOL CALLS MADE:
{tool_calls_summary}

GUARDRAIL RESULT:
{guardrail_result}

Score each dimension from 0.0 to 1.0 where:
1.0 = excellent, 0.8 = good, 0.6 = acceptable,
0.4 = poor, 0.2 = very poor, 0.0 = completely wrong

DIMENSIONS:

correctness (0.0-1.0):
Is the information factually accurate? Does it correctly answer
the question asked? Penalise hallucinated facts, wrong figures,
or content that contradicts retrieved documentation.

relevance (0.0-1.0):
Does the response directly address what the user asked?
Penalise responses that are technically correct but answer
a different question, or that contain large amounts of
irrelevant content.

groundedness (0.0-1.0):
Is the response grounded in retrieved content rather than
the model's parametric knowledge? If tool calls were made,
does the response reflect what those tools returned?
Penalise responses that ignore retrieved documentation or
contradict it.

completeness (0.0-1.0):
Does the response fully address the question or does it
leave important aspects unanswered? Penalise partial answers
that require follow-up for basic information retrieved
documentation would contain.

tone (0.0-1.0):
Is the response professional, clear, and appropriately concise
for an enterprise assistant context? Penalise responses that
are overly long, use excessive jargon, are condescending, or
inappropriately casual.

Respond with ONLY this JSON object and nothing else:
{{
  "correctness": 0.0,
  "relevance": 0.0,
  "groundedness": 0.0,
  "completeness": 0.0,
  "tone": 0.0,
  "reasoning": "One sentence identifying the most significant quality issue, or 'No significant issues identified' if all scores are above 0.8"
}}"""


def _build_tool_calls_summary(tool_calls):
    if not tool_calls:
        return "No tools called — response from model knowledge or KB context only"
    parts = []
    for call in tool_calls:
        tool_name = call.get("tool_name", "unknown")
        inp = call.get("input", "")
        out = str(call.get("output", ""))[:200]
        parts.append(f"Called {tool_name} with query '{inp}' — returned: {out}")
    return "\n".join(parts)


def _load_agent_descriptions(agent_ids, dynamodb):
    """Fetch agent_description for each unique agent_id. Returns dict keyed on agent_id."""
    table = dynamodb.Table(AGENT_REGISTRY_TABLE)
    descriptions = {}
    for agent_id in agent_ids:
        try:
            resp = table.get_item(Key={"agent_id": agent_id})
            item = resp.get("Item", {})
            desc = item.get("agent_description")
            if desc:
                descriptions[agent_id] = desc
            else:
                logger.warning(json.dumps({
                    "event": "agent_description_missing",
                    "agent_id": agent_id,
                    "fallback": "an enterprise AI assistant",
                }))
                descriptions[agent_id] = "an enterprise AI assistant"
        except Exception as exc:
            logger.warning(json.dumps({
                "event": "agent_registry_lookup_failed",
                "agent_id": agent_id,
                "error": str(exc),
                "fallback": "an enterprise AI assistant",
            }))
            descriptions[agent_id] = "an enterprise AI assistant"
    return descriptions


def _get_scored_record_ids(dynamodb, record_ids):
    """Return the set of record_ids that already have a quality record."""
    table = dynamodb.Table(QUALITY_TABLE)
    scored = set()
    for record_id in record_ids:
        resp = table.query(
            KeyConditionExpression="record_id = :rid",
            ExpressionAttributeValues={":rid": record_id},
            Limit=1,
            Select="COUNT",
        )
        if resp.get("Count", 0) > 0:
            scored.add(record_id)
    return scored


def _score_record(record, agent_description, bedrock):
    """Invoke Haiku to score one interaction record. Returns parsed scores dict or None."""
    tool_calls_summary = _build_tool_calls_summary(record.get("tool_calls", []))
    prompt = EVALUATION_PROMPT_TEMPLATE.format(
        agent_id=record["agent_id"],
        agent_description=agent_description,
        user_input=record["user_input"],
        agent_response=record["agent_response"],
        tool_calls_summary=tool_calls_summary,
        guardrail_result=json.dumps(record.get("guardrail_result", {})),
    )

    t0 = time.monotonic()
    response = bedrock.converse(
        modelId=SCORER_MODEL_ARN,
        messages=[{"role": "user", "content": [{"text": prompt}]}],
        inferenceConfig={"maxTokens": 500, "temperature": 0.0},
    )
    latency_ms = int((time.monotonic() - t0) * 1000)

    raw_text = response["output"]["message"]["content"][0]["text"]
    try:
        parsed = json.loads(raw_text)
    except json.JSONDecodeError:
        logger.warning(json.dumps({
            "event": "score_parse_failed",
            "record_id": record["record_id"],
            "raw_response": raw_text[:500],
        }))
        return None, latency_ms

    scores = {}
    for dim in DIMENSIONS:
        val = parsed.get(dim)
        if val is None:
            logger.warning(json.dumps({
                "event": "score_dimension_missing",
                "record_id": record["record_id"],
                "dimension": dim,
            }))
            return None, latency_ms
        fval = float(val)
        if fval < 0.0 or fval > 1.0:
            logger.warning(json.dumps({
                "event": "score_out_of_range",
                "record_id": record["record_id"],
                "dimension": dim,
                "value": fval,
            }))
            return None, latency_ms
        scores[dim] = fval

    scores["overall"] = sum(scores[d] for d in DIMENSIONS) / len(DIMENSIONS)
    scores["reasoning"] = parsed.get("reasoning", "")
    scores["latency_ms"] = latency_ms
    return scores, latency_ms


def _write_quality_record(record, scores, prompt_vault_key, dynamodb):
    """Write the quality record item to DynamoDB."""
    table = dynamodb.Table(QUALITY_TABLE)
    scored_at = datetime.now(timezone.utc).isoformat()
    ttl = int(time.time()) + (90 * 24 * 60 * 60)
    below_threshold = scores["overall"] < SCORE_THRESHOLD

    item = {
        "record_id": record["record_id"],
        "scored_at": scored_at,
        "agent_id": record["agent_id"],
        "session_id": record.get("session_id", ""),
        "environment": record.get("environment", ENVIRONMENT),
        "score_correctness": str(scores["correctness"]),
        "score_relevance": str(scores["relevance"]),
        "score_groundedness": str(scores["groundedness"]),
        "score_completeness": str(scores["completeness"]),
        "score_tone": str(scores["tone"]),
        "score_overall": str(scores["overall"]),
        "below_threshold": below_threshold,
        "below_threshold_str": "true" if below_threshold else "false",
        "guardrail_fired": False,
        "guardrail_skipped": False,
        "scorer_model": SCORER_MODEL_ARN,
        "evaluation_latency_ms": scores["latency_ms"],
        "prompt_vault_key": prompt_vault_key,
        "reasoning": scores["reasoning"],
        "ttl": ttl,
    }
    table.put_item(Item=item)
    return scored_at, below_threshold


def _write_guardrail_skipped_record(record, prompt_vault_key, dynamodb):
    """Write a quality record for a guardrail-blocked interaction (no scoring)."""
    table = dynamodb.Table(QUALITY_TABLE)
    scored_at = datetime.now(timezone.utc).isoformat()
    ttl = int(time.time()) + (90 * 24 * 60 * 60)

    item = {
        "record_id": record["record_id"],
        "scored_at": scored_at,
        "agent_id": record["agent_id"],
        "session_id": record.get("session_id", ""),
        "environment": record.get("environment", ENVIRONMENT),
        "below_threshold": False,
        "below_threshold_str": "false",
        "guardrail_fired": True,
        "guardrail_skipped": True,
        "scorer_model": SCORER_MODEL_ARN,
        "prompt_vault_key": prompt_vault_key,
        "reasoning": "Record skipped — guardrail intervention",
        "ttl": ttl,
    }
    table.put_item(Item=item)


def _emit_metrics(metric_data, cloudwatch):
    """Flush metric_data in batches of 20 (CloudWatch PutMetricData limit)."""
    for i in range(0, len(metric_data), 20):
        cloudwatch.put_metric_data(
            Namespace="AIPlatform/Quality",
            MetricData=metric_data[i:i + 20],
        )


def lambda_handler(event, context):
    batch_start = time.monotonic()

    s3 = boto3.client("s3")
    dynamodb = boto3.resource("dynamodb")
    bedrock = boto3.client("bedrock-runtime", region_name=os.environ.get("AWS_REGION", "us-east-2"))
    cloudwatch = boto3.client("cloudwatch")

    # Step 1 — Discover all Prompt Vault objects
    paginator = s3.get_paginator("list_objects_v2")
    all_keys = []
    for page in paginator.paginate(Bucket=PROMPT_VAULT_BUCKET, Prefix="prompt-vault/"):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key.endswith(".json"):
                all_keys.append(key)

    records_found = len(all_keys)

    # Derive record_ids and check which are already scored
    key_to_record_id = {k: k.split("/")[-1].replace(".json", "") for k in all_keys}
    all_record_ids = list(key_to_record_id.values())
    already_scored = _get_scored_record_ids(dynamodb, all_record_ids)

    unscored_keys = [k for k in all_keys if key_to_record_id[k] not in already_scored]
    records_skipped_already_scored = records_found - len(unscored_keys)

    # Step 1b — Load agent descriptions for unique agent_ids in unscored batch
    # Read and parse records first to collect agent_ids, then bulk-load descriptions
    unscored_records = []
    records_failed = 0
    for key in unscored_keys:
        try:
            obj = s3.get_object(Bucket=PROMPT_VAULT_BUCKET, Key=key)
            record = json.loads(obj["Body"].read())
        except Exception as exc:
            logger.warning(json.dumps({
                "event": "record_read_failed",
                "key": key,
                "error": str(exc),
            }))
            records_failed += 1
            continue

        required = ["record_id", "agent_id", "session_id", "user_input",
                    "agent_response", "guardrail_result", "environment"]
        missing = [f for f in required if f not in record]
        if missing:
            logger.warning(json.dumps({
                "event": "record_validation_failed",
                "key": key,
                "missing_fields": missing,
            }))
            records_failed += 1
            continue

        unscored_records.append((key, record))

    unique_agent_ids = {rec["agent_id"] for _, rec in unscored_records}
    agent_descriptions = _load_agent_descriptions(unique_agent_ids, dynamodb)

    # Process each unscored record
    records_scored = 0
    records_skipped_guardrail = 0
    below_threshold_count = 0
    metric_data = []

    for key, record in unscored_records:
        agent_id = record["agent_id"]
        guardrail = record.get("guardrail_result", {})
        guardrail_action = guardrail.get("action", "")

        # Step 3 — Handle guardrail-blocked records
        if guardrail_action == "GUARDRAIL_INTERVENED" and not record.get("agent_response", "").strip():
            _write_guardrail_skipped_record(record, key, dynamodb)
            records_skipped_guardrail += 1
            metric_data.append({
                "MetricName": "GuardrailFired",
                "Dimensions": [{"Name": "AgentId", "Value": agent_id}],
                "Value": 1,
                "Unit": "Count",
            })
            continue

        # Steps 4-6 — Build prompt, invoke Haiku, parse and validate scores
        agent_description = agent_descriptions.get(agent_id, "an enterprise AI assistant")
        scores, latency_ms = _score_record(record, agent_description, bedrock)
        if scores is None:
            records_failed += 1
            continue

        # Step 7 — Write quality record
        scored_at, below_threshold = _write_quality_record(record, scores, key, dynamodb)

        if below_threshold:
            below_threshold_count += 1
        records_scored += 1

        # Step 9 — Per-record log
        logger.info(json.dumps({
            "event": "record_scored",
            "record_id": record["record_id"],
            "agent_id": agent_id,
            "score_overall": round(scores["overall"], 4),
            "below_threshold": below_threshold,
            "guardrail_fired": False,
            "evaluation_latency_ms": latency_ms,
            "scorer_model": SCORER_MODEL_ARN,
        }))

        # Step 8 — Collect CloudWatch metrics
        for dim in DIMENSIONS:
            metric_data.append({
                "MetricName": "QualityScore",
                "Dimensions": [
                    {"Name": "AgentId", "Value": agent_id},
                    {"Name": "Dimension", "Value": dim},
                ],
                "Value": scores[dim],
                "Unit": "None",
            })
        metric_data.append({
            "MetricName": "QualityScore",
            "Dimensions": [
                {"Name": "AgentId", "Value": agent_id},
                {"Name": "Dimension", "Value": "overall"},
            ],
            "Value": scores["overall"],
            "Unit": "None",
        })
        metric_data.append({
            "MetricName": "BelowThreshold",
            "Dimensions": [{"Name": "AgentId", "Value": agent_id}],
            "Value": 1 if below_threshold else 0,
            "Unit": "Count",
        })
        metric_data.append({
            "MetricName": "ScorerLatency",
            "Dimensions": [{"Name": "AgentId", "Value": agent_id}],
            "Value": latency_ms,
            "Unit": "Milliseconds",
        })

    # Flush metrics
    if metric_data:
        _emit_metrics(metric_data, cloudwatch)

    batch_duration_ms = int((time.monotonic() - batch_start) * 1000)

    # Batch summary log
    logger.info(json.dumps({
        "event": "scoring_batch_complete",
        "records_found": records_found,
        "records_scored": records_scored,
        "records_skipped_already_scored": records_skipped_already_scored,
        "records_skipped_guardrail": records_skipped_guardrail,
        "records_failed": records_failed,
        "below_threshold_count": below_threshold_count,
        "batch_duration_ms": batch_duration_ms,
    }))
