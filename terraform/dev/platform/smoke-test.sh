#!/usr/bin/env bash
# Platform smoke tests — run from terraform/dev/platform/ after every apply.
# Exits 0 if all tests pass, 1 if any test fails.
#
# Usage:
#   cd terraform/dev/platform
#   ./smoke-test.sh

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
echo "Platform Smoke Tests"
echo "===================="
echo "Reading terraform outputs..."

RUNTIME_ID=$(terraform output -raw agentcore_endpoint_id 2>/dev/null) || {
  echo "Error: cannot read terraform outputs. Run 'terraform apply' first."
  exit 1
}
GATEWAY_ID=$(terraform output -raw agentcore_gateway_id)
SESSION_TABLE=$(terraform output -raw session_memory_table)
DOCUMENT_BUCKET=$(terraform output -raw document_landing_bucket)
REGION="us-east-2"
TEST_TS="smoke-$(date +%s)"

echo ""

# ---------------------------------------------------------------------------
# Test 1 — AgentCore Runtime is READY
# ---------------------------------------------------------------------------

echo "Test 1 — AgentCore Runtime"
STATUS=$(aws bedrock-agentcore-control get-agent-runtime \
  --agent-runtime-id "${RUNTIME_ID}" \
  --region "${REGION}" \
  --query 'status' --output text 2>/dev/null || echo "ERROR")

if [ "${STATUS}" = "READY" ]; then
  pass "AgentCore runtime status = READY  (id: ${RUNTIME_ID})"
else
  fail "AgentCore runtime status = ${STATUS}  (expected READY)"
fi

# ---------------------------------------------------------------------------
# Test 2 — MCP Gateway is READY with AWS_IAM auth
# ---------------------------------------------------------------------------

echo "Test 2 — MCP Gateway"
GW_JSON=$(aws bedrock-agentcore-control get-gateway \
  --gateway-identifier "${GATEWAY_ID}" \
  --region "${REGION}" \
  --query '{status:status,authType:authorizerType,protocol:protocolType}' \
  --output json 2>/dev/null || echo '{}')

GW_STATUS=$(echo "${GW_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','ERROR'))")
GW_AUTH=$(echo "${GW_JSON}"   | python3 -c "import sys,json; print(json.load(sys.stdin).get('authType','ERROR'))")
GW_PROTO=$(echo "${GW_JSON}"  | python3 -c "import sys,json; print(json.load(sys.stdin).get('protocol','ERROR'))")

if [ "${GW_STATUS}" = "READY" ] && [ "${GW_AUTH}" = "AWS_IAM" ] && [ "${GW_PROTO}" = "MCP" ]; then
  pass "MCP Gateway status = READY, authType = AWS_IAM, protocol = MCP"
else
  fail "MCP Gateway status=${GW_STATUS} authType=${GW_AUTH} protocol=${GW_PROTO}"
fi

# ---------------------------------------------------------------------------
# Test 3 — Bedrock model invocation
# ---------------------------------------------------------------------------

echo "Test 3 — Bedrock Model Invocation"
RESPONSE_FILE="/tmp/platform-smoke-bedrock-${TEST_TS}.json"
aws bedrock-runtime invoke-model \
  --model-id us.anthropic.claude-sonnet-4-6 \
  --region "${REGION}" \
  --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":10,"messages":[{"role":"user","content":"Reply with only the word PASS"}]}' \
  --cli-binary-format raw-in-base64-out \
  "${RESPONSE_FILE}" > /dev/null 2>&1

MODEL_RESPONSE=$(python3 -c "
import json
with open('${RESPONSE_FILE}') as f:
    r = json.load(f)
print(r['content'][0]['text'].strip())
" 2>/dev/null || echo "ERROR")

rm -f "${RESPONSE_FILE}"

if [[ "${MODEL_RESPONSE}" == *"PASS"* ]]; then
  pass "Bedrock model responded: ${MODEL_RESPONSE}"
else
  fail "Bedrock model response unexpected: ${MODEL_RESPONSE}"
fi

# ---------------------------------------------------------------------------
# Test 4 — DynamoDB session memory write / read / delete
# ---------------------------------------------------------------------------

echo "Test 4 — DynamoDB Session Memory"
ITEM_KEY="{\"session_id\":{\"S\":\"${TEST_TS}\"},\"timestamp\":{\"S\":\"2026-01-01T00:00:00Z\"}}"
ITEM="{\"session_id\":{\"S\":\"${TEST_TS}\"},\"timestamp\":{\"S\":\"2026-01-01T00:00:00Z\"},\"content\":{\"S\":\"smoke-test\"}}"

aws dynamodb put-item \
  --table-name "${SESSION_TABLE}" \
  --region "${REGION}" \
  --item "${ITEM}" > /dev/null 2>&1

READ_VALUE=$(aws dynamodb get-item \
  --table-name "${SESSION_TABLE}" \
  --region "${REGION}" \
  --key "${ITEM_KEY}" \
  --query 'Item.content.S' \
  --output text 2>/dev/null || echo "ERROR")

aws dynamodb delete-item \
  --table-name "${SESSION_TABLE}" \
  --region "${REGION}" \
  --key "${ITEM_KEY}" > /dev/null 2>&1

if [ "${READ_VALUE}" = "smoke-test" ]; then
  pass "DynamoDB write/read/delete — returned: smoke-test"
else
  fail "DynamoDB read returned: ${READ_VALUE}  (expected smoke-test)"
fi

# ---------------------------------------------------------------------------
# Test 5 — S3 document landing bucket KMS encryption
# ---------------------------------------------------------------------------

echo "Test 5 — S3 KMS Encryption"
S3_KEY="smoke-test-${TEST_TS}.txt"

echo "smoke-test" | aws s3 cp - "s3://${DOCUMENT_BUCKET}/${S3_KEY}" \
  --region "${REGION}" > /dev/null 2>&1

SSE=$(aws s3api head-object \
  --bucket "${DOCUMENT_BUCKET}" \
  --key "${S3_KEY}" \
  --region "${REGION}" \
  --query 'ServerSideEncryption' \
  --output text 2>/dev/null || echo "ERROR")

aws s3 rm "s3://${DOCUMENT_BUCKET}/${S3_KEY}" \
  --region "${REGION}" > /dev/null 2>&1

if [ "${SSE}" = "aws:kms" ]; then
  pass "S3 object encrypted with aws:kms"
else
  fail "S3 SSE algorithm = ${SSE}  (expected aws:kms)"
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
