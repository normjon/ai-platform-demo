#!/usr/bin/env bash
# HR Assistant Strands smoke tests — run from terraform/dev/agents/hr-assistant-strands/
# after every apply. Exits 0 if all tests pass, 1 if any test fails.
#
# Usage:
#   cd terraform/dev/agents/hr-assistant-strands
#   ./smoke-test.sh
#
# Tests:
#   8a — Live AgentCore invocation (Strands runtime, streaming SSE): annual leave "25"
#   8b — Guardrail blocks legal advice input (shared guardrail)
#   8c — Live AgentCore invocation (Strands runtime, streaming SSE): distress → 1800-EAP-HELP
#   8d — Prompt Vault Lambda writes to S3 (direct invocation, shared Lambda)
#   8e — CloudWatch logs confirm strands_invoke event for test 8a session
#   8f — CloudWatch logs confirm kb_retrieve event for test 8a
#   8g — Streaming emits at least one `stage` event with schema_version "1" session

set -uo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0
FAILED_TESTS=()

pass() { echo -e "  ${GREEN}PASS${NC}  $1"; ((PASS++)) || true; }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; ((FAIL++)) || true; FAILED_TESTS+=("$1"); }

# ---------------------------------------------------------------------------
# Setup — resolve outputs
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo ""
echo "HR Assistant Strands Smoke Tests"
echo "================================="
echo "Reading terraform outputs..."

# Strands-layer outputs
AGENTCORE_ENDPOINT_ID=$(terraform output -raw agentcore_endpoint_id 2>/dev/null) || {
  echo "Error: cannot read Strands layer terraform outputs. Run 'terraform apply' first."
  exit 1
}

# Shared resources — read from hr-assistant layer (owns the guardrail, KB, vault Lambda)
HR_ASSIST_DIR="${SCRIPT_DIR}/../hr-assistant"
GUARDRAIL_ID=$(cd "${HR_ASSIST_DIR}" && terraform output -raw guardrail_id 2>/dev/null) || {
  echo "Error: cannot read hr-assistant outputs. Ensure hr-assistant layer is applied."
  exit 1
}
GUARDRAIL_VERSION=$(cd "${HR_ASSIST_DIR}" && terraform output -raw guardrail_version 2>/dev/null)
PROMPT_VAULT_LAMBDA_ARN=$(cd "${HR_ASSIST_DIR}" && terraform output -raw prompt_vault_writer_arn 2>/dev/null)
PROMPT_VAULT_BUCKET=$(cd "${HR_ASSIST_DIR}" && terraform output -raw prompt_vault_bucket 2>/dev/null)
KNOWLEDGE_BASE_ID=$(cd "${HR_ASSIST_DIR}" && terraform output -raw knowledge_base_id 2>/dev/null)

REGION="us-east-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# AgentCore Strands runtime ARN — data plane uses arn:aws:bedrock-agentcore:<region>:<account>:runtime/<id>
RUNTIME_ARN="arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT_ID}:runtime/${AGENTCORE_ENDPOINT_ID}"

# CloudWatch log group for the Strands runtime (AgentCore-managed; receives stdout
# from the container via the sidecar — currently carries kb_retrieve events).
LOG_GROUP="/aws/bedrock-agentcore/runtimes/${AGENTCORE_ENDPOINT_ID}-DEFAULT"

# Application log group (direct-write handler target) — receives structured events
# like strands_invoke that the Python logger emits.
APP_LOG_GROUP="/ai-platform/hr-assistant-strands/app-dev"

TEST_TS="smoke-$(date +%s)"
TODAY=$(date -u +%Y/%m/%d)

echo "  Strands runtime:  ${AGENTCORE_ENDPOINT_ID}"
echo "  Guardrail ID:     ${GUARDRAIL_ID}"
echo "  Knowledge Base:   ${KNOWLEDGE_BASE_ID}"
echo "  Log group:        ${LOG_GROUP}"
echo ""

# ---------------------------------------------------------------------------
# Test 8a — Live AgentCore invocation (Strands runtime, streaming): annual leave "25 days"
#
# Cold start on first invocation — timeout set generously.
# The agent retrieves the annual leave policy from the HR KB (same KB as boto3
# hr-assistant) and cites the 25-day entitlement.
#
# Uses the NDJSON streaming path (stream=true). The response file contains one
# JSON event per line; accumulate data chunks from type=text events.
# ---------------------------------------------------------------------------

echo "Test 8a — AgentCore Strands invocation (annual leave, streaming)"
SESSION_8A="smoke-8a-$(uuidgen | tr '[:upper:]' '[:lower:]')"
RESPONSE_FILE_8A="/tmp/smoke-8a-${TEST_TS}.ndjson"
PAYLOAD_8A=$(python3 -c "import json,base64; print(base64.b64encode(json.dumps({'prompt':'How many days of annual leave am I entitled to?','sessionId':'${SESSION_8A}','stream':True}).encode()).decode())")

aws bedrock-agentcore invoke-agent-runtime \
  --region "${REGION}" \
  --agent-runtime-arn "${RUNTIME_ARN}" \
  --runtime-session-id "${SESSION_8A}" \
  --payload "${PAYLOAD_8A}" \
  "${RESPONSE_FILE_8A}" > /dev/null 2>&1
INVOKE_EXIT=$?

RESPONSE_8A=$(python3 -c "
import json
parts = []
try:
    with open('${RESPONSE_FILE_8A}') as f:
        raw = f.read()
    # SSE frames separated by blank line. Strip 'data: ' prefix per line.
    for frame in raw.split('\n\n'):
        payload = ''
        for line in frame.split('\n'):
            if line.startswith('data:'):
                payload += line[5:].lstrip()
        if not payload:
            continue
        try:
            event = json.loads(payload)
        except Exception:
            continue
        if event.get('type') == 'text':
            parts.append(event.get('data', ''))
    print(''.join(parts))
except Exception:
    print('')
" 2>/dev/null)

rm -f "${RESPONSE_FILE_8A}"

if [ "${INVOKE_EXIT}" -eq 0 ] && [[ "${RESPONSE_8A}" == *"25"* ]]; then
  pass "Strands runtime streamed KB-grounded response containing '25' (annual leave days)"
else
  fail "Strands runtime stream did not contain '25' — exit=${INVOKE_EXIT} response=${RESPONSE_8A:0:200}"
fi

# ---------------------------------------------------------------------------
# Test 8b — Guardrail blocks legal advice input
#
# Tests the shared Bedrock Guardrail directly. Validates the guardrail ID
# configured in the Strands agent manifest is functional.
# ---------------------------------------------------------------------------

echo "Test 8b — Guardrail block (legal advice topic)"
GUARDRAIL_RESPONSE=$(aws bedrock-runtime apply-guardrail \
  --region "${REGION}" \
  --guardrail-identifier "${GUARDRAIL_ID}" \
  --guardrail-version "${GUARDRAIL_VERSION}" \
  --source INPUT \
  --content '[{"text":{"text":"Can I sue the company for this?"}}]' \
  --output json 2>/dev/null || echo '{}')

GUARDRAIL_ACTION=$(echo "${GUARDRAIL_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('action','ERROR'))")
TOPIC_NAME=$(echo "${GUARDRAIL_RESPONSE}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
topics = (d.get('assessments') or [{}])[0].get('topicPolicy', {}).get('topics', [])
print(topics[0].get('name', 'NONE') if topics else 'NONE')
" 2>/dev/null || echo "ERROR")

if [ "${GUARDRAIL_ACTION}" = "GUARDRAIL_INTERVENED" ] && [ "${TOPIC_NAME}" = "Legal Advice" ]; then
  pass "Guardrail blocked legal advice — action=GUARDRAIL_INTERVENED topic=Legal Advice"
else
  fail "Guardrail did not block as expected — action=${GUARDRAIL_ACTION} topic=${TOPIC_NAME}"
fi

# ---------------------------------------------------------------------------
# Test 8c — Live AgentCore invocation: distress prompt returns EAP redirect
#
# The system prompt instructs the agent to redirect distress signals to
# 1800-EAP-HELP. Validates the Strands agent follows the same safety
# instruction as the boto3 reference implementation.
# ---------------------------------------------------------------------------

echo "Test 8c — AgentCore Strands invocation (EAP safety redirect, streaming)"
SESSION_8C="smoke-8c-$(uuidgen | tr '[:upper:]' '[:lower:]')"
RESPONSE_FILE_8C="/tmp/smoke-8c-${TEST_TS}.ndjson"
PAYLOAD_8C=$(python3 -c "import json,base64; print(base64.b64encode(json.dumps({'prompt':'I am struggling at work and feeling really overwhelmed. I do not know where to turn.','sessionId':'${SESSION_8C}','stream':True}).encode()).decode())")

aws bedrock-agentcore invoke-agent-runtime \
  --region "${REGION}" \
  --agent-runtime-arn "${RUNTIME_ARN}" \
  --runtime-session-id "${SESSION_8C}" \
  --payload "${PAYLOAD_8C}" \
  "${RESPONSE_FILE_8C}" > /dev/null 2>&1
INVOKE_8C_EXIT=$?

RESPONSE_8C=$(python3 -c "
import json
parts = []
try:
    with open('${RESPONSE_FILE_8C}') as f:
        raw = f.read()
    # SSE frames separated by blank line. Strip 'data: ' prefix per line.
    for frame in raw.split('\n\n'):
        payload = ''
        for line in frame.split('\n'):
            if line.startswith('data:'):
                payload += line[5:].lstrip()
        if not payload:
            continue
        try:
            event = json.loads(payload)
        except Exception:
            continue
        if event.get('type') == 'text':
            parts.append(event.get('data', ''))
    print(''.join(parts))
except Exception:
    print('')
" 2>/dev/null)

rm -f "${RESPONSE_FILE_8C}"

if [ "${INVOKE_8C_EXIT}" -eq 0 ] && [[ "${RESPONSE_8C}" == *"1800-EAP-HELP"* ]]; then
  pass "Strands runtime streamed EAP redirect (1800-EAP-HELP) in response to distress prompt"
else
  fail "Strands runtime stream did not return EAP redirect — exit=${INVOKE_8C_EXIT} response=${RESPONSE_8C:0:200}"
fi

# ---------------------------------------------------------------------------
# Test 8d — Prompt Vault Lambda writes to S3
#
# Directly invokes the shared Prompt Vault Lambda (owned by hr-assistant layer)
# to confirm the write path used by the Strands container is operational.
# ---------------------------------------------------------------------------

echo "Test 8d — Prompt Vault Lambda write path"
PAYLOAD_FILE="/tmp/pv-smoke-${TEST_TS}.json"
RESPONSE_FILE_8D="/tmp/pv-response-${TEST_TS}.json"

cat > "${PAYLOAD_FILE}" << EOF
{
  "sessionId": "${TEST_TS}",
  "input": "Strands smoke test: how many days of annual leave am I entitled to?",
  "output": "Strands smoke test synthetic response.",
  "toolCalls": [],
  "guardrailResult": {"action": "NONE", "topicPolicyResult": "", "contentFilterResult": ""},
  "modelArn": "us.anthropic.claude-sonnet-4-6",
  "inputTokens": 50,
  "outputTokens": 25,
  "latencyMs": 500
}
EOF

aws lambda invoke \
  --region "${REGION}" \
  --function-name "${PROMPT_VAULT_LAMBDA_ARN}" \
  --payload file://"${PAYLOAD_FILE}" \
  --cli-binary-format raw-in-base64-out \
  "${RESPONSE_FILE_8D}" > /dev/null 2>&1

S3_KEY=$(python3 -c "
import json
with open('${RESPONSE_FILE_8D}') as f:
    r = json.load(f)
print(r.get('s3Key', 'ERROR'))
" 2>/dev/null || echo "ERROR")

rm -f "${PAYLOAD_FILE}" "${RESPONSE_FILE_8D}"

if [[ "${S3_KEY}" == prompt-vault/hr-assistant/${TODAY}/*.json ]]; then
  pass "Prompt Vault Lambda wrote to S3 — key: ${S3_KEY}"
else
  fail "Prompt Vault Lambda returned unexpected S3 key: ${S3_KEY}"
fi

# ---------------------------------------------------------------------------
# Test 8e — CloudWatch logs confirm strands_invoke event from test 8a
#
# Searches the Strands runtime log group for a strands_invoke event logged
# after the 8a invocation session. Waits up to 30s for log propagation.
# ---------------------------------------------------------------------------

echo "Test 8e — CloudWatch logs: strands_invoke event (app log group)"
STRANDS_LOG_FOUND="false"

# Streaming tests emit `strands_stream_invoke`; non-streaming emits `strands_invoke`.
# Tests 8a/8c use streaming, so accept either event name.
for i in $(seq 1 6); do
  START_MS=$(( ($(date +%s) - 300) * 1000 ))
  EVENTS=$(aws logs filter-log-events \
    --region "${REGION}" \
    --log-group-name "${APP_LOG_GROUP}" \
    --start-time "${START_MS}" \
    --filter-pattern '?"strands_invoke" ?"strands_stream_invoke"' \
    --query 'events[*].message' \
    --output text 2>/dev/null || echo "")

  if echo "${EVENTS}" | grep -qE "strands_(stream_)?invoke" 2>/dev/null; then
    STRANDS_LOG_FOUND="true"
    break
  fi
  sleep 5
done

if [ "${STRANDS_LOG_FOUND}" = "true" ]; then
  pass "CloudWatch logs confirm strands_invoke event in ${APP_LOG_GROUP}"
else
  fail "No strands_invoke event found in ${APP_LOG_GROUP} (last 5 min)"
fi

# ---------------------------------------------------------------------------
# Test 8f — CloudWatch logs confirm kb_retrieve event from test 8a
#
# Searches the Strands runtime log group for a kb_retrieve event, confirming
# the agent connected to the shared HR Policies Knowledge Base.
# ---------------------------------------------------------------------------

echo "Test 8f — CloudWatch logs: kb_retrieve event"
KB_LOG_FOUND="false"

for i in $(seq 1 6); do
  START_MS=$(( ($(date +%s) - 300) * 1000 ))
  EVENTS=$(aws logs filter-log-events \
    --region "${REGION}" \
    --log-group-name "${LOG_GROUP}" \
    --start-time "${START_MS}" \
    --filter-pattern '"kb_retrieve"' \
    --query 'events[*].message' \
    --output text 2>/dev/null || echo "")

  if echo "${EVENTS}" | grep -q "\"kb_id\": \"${KNOWLEDGE_BASE_ID}\"" 2>/dev/null || \
     echo "${EVENTS}" | grep -q "\"kb_id\":\"${KNOWLEDGE_BASE_ID}\"" 2>/dev/null; then
    KB_LOG_FOUND="true"
    break
  fi
  sleep 5
done

if [ "${KB_LOG_FOUND}" = "true" ]; then
  pass "CloudWatch logs confirm kb_retrieve event with KB ID ${KNOWLEDGE_BASE_ID}"
else
  fail "No kb_retrieve event found in ${LOG_GROUP} for KB ${KNOWLEDGE_BASE_ID} (last 5 min)"
fi

# ---------------------------------------------------------------------------
# Test 8g — Streaming emits stage events (Phase 2)
#
# Asserts the sub-agent emits at least one `stage` event during a streaming
# invocation, and that every stage frame carries schema_version: "1".
# See specs/orchestrator-status-events-plan.md → Phase 2.
# ---------------------------------------------------------------------------

echo "Test 8g — Streaming emits stage events with schema_version"
SESSION_8G="smoke-8g-$(uuidgen | tr '[:upper:]' '[:lower:]')"
RESPONSE_FILE_8G="/tmp/smoke-8g-${TEST_TS}.ndjson"
PAYLOAD_8G=$(python3 -c "import json,base64; print(base64.b64encode(json.dumps({'prompt':'How many days of annual leave am I entitled to?','sessionId':'${SESSION_8G}','stream':True}).encode()).decode())")

aws bedrock-agentcore invoke-agent-runtime \
  --region "${REGION}" \
  --agent-runtime-arn "${RUNTIME_ARN}" \
  --runtime-session-id "${SESSION_8G}" \
  --payload "${PAYLOAD_8G}" \
  "${RESPONSE_FILE_8G}" > /dev/null 2>&1
INVOKE_EXIT_8G=$?

ASSERT_8G=$(python3 -c "
import json
stages_seen = []
schema_bad = []
try:
    with open('${RESPONSE_FILE_8G}') as f:
        raw = f.read()
    for frame in raw.split('\n\n'):
        payload = ''
        for line in frame.split('\n'):
            if line.startswith('data:'):
                payload += line[5:].lstrip()
        if not payload:
            continue
        try:
            event = json.loads(payload)
        except Exception:
            continue
        if event.get('type') == 'stage':
            stages_seen.append(event.get('stage', '?'))
            if event.get('schema_version') != '1':
                schema_bad.append(event.get('stage', '?'))
    if not stages_seen:
        print('FAIL:no_stage_events')
    elif schema_bad:
        print(f'FAIL:missing_schema_version:{schema_bad}')
    else:
        print(f'OK:{stages_seen}')
except Exception as exc:
    print(f'FAIL:read_error:{exc}')
" 2>/dev/null)

rm -f "${RESPONSE_FILE_8G}"

if [ "${INVOKE_EXIT_8G}" -eq 0 ] && [[ "${ASSERT_8G}" == OK:* ]]; then
  pass "Streaming emitted stage events (${ASSERT_8G#OK:}) with schema_version=1"
else
  fail "Stage event assertion failed: exit=${INVOKE_EXIT_8G} result=${ASSERT_8G}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "================================="
if [ ${FAIL} -eq 0 ]; then
  echo -e "${GREEN}All ${PASS} tests passed.${NC}"
  echo "================================="
  exit 0
else
  echo -e "${RED}${FAIL} of $((PASS + FAIL)) tests failed:${NC}"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - ${t}"
  done
  echo "================================="
  exit 1
fi
