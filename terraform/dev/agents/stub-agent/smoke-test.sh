#!/usr/bin/env bash
# Stub Agent Smoke Tests
# ======================
#
# Covers Phase O.5.j from specs/orchestrator-plan.md:
#   S1 — Direct invocation returns [stub-agent] received: <prompt>
#   S2 — CloudWatch runtime log contains stub_invoke event
#
# The orchestrator-side dispatch test (O.5.b) lives in
# terraform/dev/agents/orchestrator/smoke-test.sh — exercising it from here
# would couple this layer to the orchestrator unnecessarily.

set -uo pipefail

REGION="us-east-2"
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=()

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() {
  printf "  ${GREEN}PASS${NC}  %s\n" "$1"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
  printf "  ${RED}FAIL${NC}  %s\n" "$1"
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("$1")
}

echo "Stub Agent Smoke Tests"
echo "======================"
echo "Reading terraform outputs..."

AGENTCORE_ENDPOINT_ID=$(terraform output -raw agentcore_endpoint_id 2>/dev/null || echo "")
if [ -z "${AGENTCORE_ENDPOINT_ID}" ] || [ "${AGENTCORE_ENDPOINT_ID}" = "null" ]; then
  echo "ERROR: agentcore_endpoint_id is empty. Apply terraform with a valid agent_image_uri first."
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
RUNTIME_ARN="arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT_ID}:runtime/${AGENTCORE_ENDPOINT_ID}"
LOG_GROUP="/aws/bedrock-agentcore/runtimes/${AGENTCORE_ENDPOINT_ID}-DEFAULT"

echo "  Stub runtime:  ${AGENTCORE_ENDPOINT_ID}"
echo "  Log group:     ${LOG_GROUP}"
echo ""

# ---------------------------------------------------------------------------
# Test S1 — Direct invocation returns deterministic echo
# ---------------------------------------------------------------------------

echo "Test S1 — Direct stub invocation returns [stub-agent] received: echo"

SESSION_ID="stub-smoke-$(uuidgen | tr -d '-')"
PROMPT="Hello from smoke test"
PAYLOAD=$(python3 -c "import json, base64; print(base64.b64encode(json.dumps({'prompt': '${PROMPT}', 'sessionId': '${SESSION_ID}'}).encode()).decode())")

RESPONSE_FILE=$(mktemp)
aws bedrock-agentcore invoke-agent-runtime \
  --region "${REGION}" \
  --agent-runtime-arn "${RUNTIME_ARN}" \
  --runtime-session-id "${SESSION_ID}" \
  --payload "${PAYLOAD}" \
  "${RESPONSE_FILE}" >/dev/null 2>&1

RESPONSE_BODY=$(cat "${RESPONSE_FILE}" 2>/dev/null || echo "")
rm -f "${RESPONSE_FILE}"

if echo "${RESPONSE_BODY}" | grep -q "\[stub-agent\] received: ${PROMPT}"; then
  pass "Stub runtime echoed '[stub-agent] received: ${PROMPT}'"
else
  fail "Stub runtime did not echo prompt. Body: $(echo "${RESPONSE_BODY}" | head -c 200)"
fi

# ---------------------------------------------------------------------------
# Test S2 — CloudWatch runtime log contains stub_invoke event
# ---------------------------------------------------------------------------

echo "Test S2 — CloudWatch runtime log contains stub_invoke event"

STUB_LOG_FOUND="false"
for i in $(seq 1 6); do
  START_MS=$(( ($(date +%s) - 300) * 1000 ))
  EVENTS=$(aws logs filter-log-events \
    --region "${REGION}" \
    --log-group-name "${LOG_GROUP}" \
    --start-time "${START_MS}" \
    --filter-pattern '"stub_invoke"' \
    --query 'events[*].message' \
    --output text 2>/dev/null || echo "")

  if echo "${EVENTS}" | grep -q "stub_invoke"; then
    STUB_LOG_FOUND="true"
    break
  fi
  sleep 5
done

if [ "${STUB_LOG_FOUND}" = "true" ]; then
  pass "CloudWatch runtime log contains stub_invoke event"
else
  fail "No stub_invoke event in ${LOG_GROUP} (last 5 min)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "======================"
if [ "${TESTS_FAILED}" -eq 0 ]; then
  printf "${GREEN}All %d tests passed.${NC}\n" "${TESTS_PASSED}"
  echo "======================"
  exit 0
else
  printf "${RED}%d of %d tests failed:${NC}\n" "${TESTS_FAILED}" "$((TESTS_PASSED + TESTS_FAILED))"
  for f in "${FAILURES[@]}"; do
    echo "  - ${f}"
  done
  echo "======================"
  exit 1
fi
