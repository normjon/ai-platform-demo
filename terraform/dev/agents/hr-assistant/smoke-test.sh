#!/usr/bin/env bash
# HR Assistant smoke tests — run from terraform/dev/agents/hr-assistant/ after every apply.
# Exits 0 if all tests pass, 1 if any test fails.
#
# Usage:
#   cd terraform/dev/agents/hr-assistant
#   ./smoke-test.sh
#
# Phase 1 scope note:
#   The AgentCore runtime is container-based and requires a running agent container.
#   Phase 1 does not deploy an agent container (deferred to Phase 2 — see README).
#   Tests 7a and 7c therefore validate the deployed Bedrock resources (system prompt,
#   guardrail) directly via the Bedrock API rather than via live runtime invocation.
#   Test 7b validates guardrail blocking via the bedrock-runtime apply-guardrail API.
#   Test 7d validates the Prompt Vault Lambda write path via direct Lambda invocation.
#
# AgentCore invoke command (confirmed):
#   aws bedrock-agentcore invoke-agent-runtime --agent-runtime-arn <ARN> ...
#   Returns 502 in Phase 1 — no agent container deployed. Replace tests 7a/7c with
#   live invocations when the HR Assistant container is built and pushed (Phase 2).

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
echo "HR Assistant Smoke Tests"
echo "========================"
echo "Reading terraform outputs..."

SYSTEM_PROMPT_ARN=$(terraform output -raw system_prompt_version_arn 2>/dev/null) || {
  echo "Error: cannot read terraform outputs. Run 'terraform apply' first."
  exit 1
}
GUARDRAIL_ID=$(terraform output -raw guardrail_id)
GUARDRAIL_VERSION=$(terraform output -raw guardrail_version)
PROMPT_VAULT_LAMBDA_ARN=$(terraform output -raw prompt_vault_writer_arn)
PROMPT_VAULT_BUCKET=$(terraform output -raw prompt_vault_bucket)
REGION="us-east-2"
TEST_TS="smoke-$(date +%s)"
TODAY=$(date -u +%Y/%m/%d)

echo ""

# ---------------------------------------------------------------------------
# Test 7a — System prompt deployed and contains in-scope guidance
# ---------------------------------------------------------------------------
# Phase 1: validates the Bedrock Prompt resource directly.
# Phase 2: replace with a live AgentCore invocation once the HR Assistant
#          container is deployed and the runtime is wired to this agent.
# ---------------------------------------------------------------------------

echo "Test 7a — System Prompt (in-scope guidance)"
PROMPT_TEXT=$(aws bedrock-agent get-prompt \
  --region "${REGION}" \
  --prompt-identifier "${SYSTEM_PROMPT_ARN}" \
  --query 'variants[0].templateConfiguration.text.text' \
  --output text 2>/dev/null || echo "ERROR")

if [[ "${PROMPT_TEXT}" == *"glean-search"* ]] && [[ "${PROMPT_TEXT}" == *"annual leave"* ]]; then
  pass "System prompt retrieved from Bedrock — contains tool guidance and in-scope HR topics"
else
  fail "System prompt missing expected content (got: ${PROMPT_TEXT:0:100}...)"
fi

# ---------------------------------------------------------------------------
# Test 7b — Guardrail blocks legal advice input
# ---------------------------------------------------------------------------

echo "Test 7b — Guardrail block (legal advice topic)"
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
  pass "Guardrail blocked legal advice input — action=GUARDRAIL_INTERVENED topic=Legal Advice"
else
  fail "Guardrail did not block as expected — action=${GUARDRAIL_ACTION} topic=${TOPIC_NAME}"
fi

# ---------------------------------------------------------------------------
# Test 7c — System prompt contains EAP safety redirect
# ---------------------------------------------------------------------------
# Phase 1: validates the safety redirect is configured in the system prompt.
# Phase 2: replace with a live invocation using a distress input, verifying
#          the response contains 1800-EAP-HELP and no policy content.
# ---------------------------------------------------------------------------

echo "Test 7c — Safety redirect (EAP reference in system prompt)"
if [[ "${PROMPT_TEXT}" == *"1800-EAP-HELP"* ]]; then
  pass "System prompt contains EAP safety redirect: 1800-EAP-HELP"
else
  fail "System prompt missing EAP reference — check prompts/hr-assistant-system-prompt.txt"
fi

# ---------------------------------------------------------------------------
# Test 7d — Prompt Vault Lambda writes to S3
# ---------------------------------------------------------------------------

echo "Test 7d — Prompt Vault Lambda write path"
PAYLOAD_FILE="/tmp/pv-smoke-${TEST_TS}.json"
RESPONSE_FILE="/tmp/pv-response-${TEST_TS}.json"

cat > "${PAYLOAD_FILE}" << EOF
{
  "sessionId": "${TEST_TS}",
  "input": "Smoke test: how many days of annual leave am I entitled to?",
  "output": "Smoke test synthetic response.",
  "toolCalls": [{"toolName": "glean-search", "input": "annual leave policy", "output": "Policy doc retrieved."}],
  "guardrailResult": {"action": "NONE", "topicPolicyResult": "", "contentFilterResult": ""},
  "modelArn": "anthropic.claude-sonnet-4-6",
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
  "${RESPONSE_FILE}" > /dev/null 2>&1

S3_KEY=$(python3 -c "
import json
with open('${RESPONSE_FILE}') as f:
    r = json.load(f)
print(r.get('s3Key', 'ERROR'))
" 2>/dev/null || echo "ERROR")

rm -f "${PAYLOAD_FILE}" "${RESPONSE_FILE}"

# Confirm the S3 key follows the expected date-partitioned pattern.
if [[ "${S3_KEY}" == prompt-vault/hr-assistant/${TODAY}/*.json ]]; then
  pass "Prompt Vault Lambda wrote to S3 — key: ${S3_KEY}"
else
  fail "Prompt Vault Lambda returned unexpected S3 key: ${S3_KEY}"
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
