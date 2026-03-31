#!/usr/bin/env bash
# Glean tool smoke tests — run from terraform/dev/tools/glean/ after every apply.
# Exits 0 if all tests pass, 1 if any test fails.
#
# Usage:
#   cd terraform/dev/tools/glean
#   ./smoke-test.sh

set -uo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
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
echo "Glean Tool Smoke Tests"
echo "======================"
echo "Reading terraform outputs..."

TARGET_ID=$(terraform output -raw gateway_target_id 2>/dev/null) || {
  echo "Error: cannot read terraform outputs. Run 'terraform apply' first."
  exit 1
}
STUB_URL=$(terraform output -raw glean_stub_url)
GATEWAY_ID=$(terraform -chdir=../../../dev/platform output -raw agentcore_gateway_id 2>/dev/null) || {
  echo "Error: cannot read platform outputs. Ensure the platform layer is applied."
  exit 1
}
REGION="us-east-2"

echo ""

# ---------------------------------------------------------------------------
# Test 2a — Gateway target is READY
# ---------------------------------------------------------------------------

echo "Test 2a — Gateway Target Status"
TARGET_JSON=$(aws bedrock-agentcore-control get-gateway-target \
  --gateway-identifier "${GATEWAY_ID}" \
  --target-id "${TARGET_ID}" \
  --region "${REGION}" \
  --query '{status:status,name:name}' \
  --output json 2>/dev/null || echo '{}')

TARGET_STATUS=$(echo "${TARGET_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','ERROR'))")
TARGET_NAME=$(echo "${TARGET_JSON}"   | python3 -c "import sys,json; print(json.load(sys.stdin).get('name','ERROR'))")

if [ "${TARGET_STATUS}" = "READY" ]; then
  pass "Gateway target status = READY  (name: ${TARGET_NAME}, id: ${TARGET_ID})"
else
  fail "Gateway target status = ${TARGET_STATUS}  (expected READY, id: ${TARGET_ID})"
fi

# ---------------------------------------------------------------------------
# Test 2b — Glean stub tool call returns mock results
# ---------------------------------------------------------------------------

echo "Test 2b — Glean Stub Tool Call"
TOOL_RESPONSE=$(curl -s -X POST "${STUB_URL}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"employee benefits"}}}' \
  2>/dev/null || echo '{}')

TOOL_TEXT=$(echo "${TOOL_RESPONSE}" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    print(r['result']['content'][0]['text'][:200])
except Exception as e:
    print('ERROR: ' + str(e))
" 2>/dev/null || echo "ERROR")

if [[ "${TOOL_TEXT}" == *"[STUB]"* ]] && [[ "${TOOL_TEXT}" == *"employee benefits"* ]]; then
  pass "Glean stub returned mock results containing [STUB] and query text"
else
  fail "Glean stub response unexpected: ${TOOL_TEXT}"
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
