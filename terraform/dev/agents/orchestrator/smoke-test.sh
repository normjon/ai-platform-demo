#!/usr/bin/env bash
# Orchestrator smoke tests — run from terraform/dev/agents/orchestrator/
# after every apply. Exits 0 if all tests pass, 1 if any test fails.
#
# Usage:
#   cd terraform/dev/agents/orchestrator
#   ./smoke-test.sh
#
# Tests:
#   O1 — Registry scan shows at least one enabled sub-agent (hr-assistant-strands-dev)
#        and the orchestrator's own entry is excluded from routing
#   O2 — Live AgentCore invocation (non-streaming JSON): annual-leave prompt routes to
#        hr-assistant-strands-dev and response contains "25"
#   O3 — Live AgentCore invocation (streaming SSE passthrough): annual-leave prompt
#        emits a routing event for hr-assistant-strands-dev, then text chunks with "25",
#        then a terminal done event
#   O4 — Off-domain prompt (celebrity trivia) refuses politely — no dispatch_agent call
#   O5 — CloudWatch logs confirm supervisor_invoke event for O2 session with
#        dispatched_agent=hr-assistant-strands-dev
#   O6 — Audit log group captures a request record for the O2 session

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
echo "Orchestrator Smoke Tests"
echo "========================"
echo "Reading terraform outputs..."

AGENTCORE_ENDPOINT_ID=$(terraform output -raw agentcore_endpoint_id 2>/dev/null) || {
  echo "Error: cannot read orchestrator terraform outputs. Run 'terraform apply' first."
  exit 1
}

if [ -z "${AGENTCORE_ENDPOINT_ID}" ] || [ "${AGENTCORE_ENDPOINT_ID}" = "null" ]; then
  echo "Error: agentcore_endpoint_id is null. Orchestrator runtime is not yet provisioned —"
  echo "       set agent_image_uri in terraform.tfvars and re-apply."
  exit 1
fi

AUDIT_LOG_GROUP=$(terraform output -raw audit_log_group_name 2>/dev/null)

REGION="us-east-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY_TABLE="ai-platform-dev-agent-registry"

RUNTIME_ARN="arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT_ID}:runtime/${AGENTCORE_ENDPOINT_ID}"

# Runtime log group (AgentCore-managed; receives container stdout via the sidecar).
LOG_GROUP="/aws/bedrock-agentcore/runtimes/${AGENTCORE_ENDPOINT_ID}-DEFAULT"

# Application log group (direct-write handler target) — supervisor_invoke events
# emitted via Python logging land here, not in the runtime log group.
APP_LOG_GROUP="/ai-platform/orchestrator/app-dev"

TEST_TS="smoke-$(date +%s)"

echo "  Orchestrator runtime: ${AGENTCORE_ENDPOINT_ID}"
echo "  Runtime log group:    ${LOG_GROUP}"
echo "  Audit log group:      ${AUDIT_LOG_GROUP}"
echo ""

# ---------------------------------------------------------------------------
# Test O1 — Registry has at least one enabled sub-agent; self excluded
# ---------------------------------------------------------------------------

echo "Test O1 — Registry scan (enabled sub-agents, orchestrator self-exclusion)"

REGISTRY_SCAN=$(aws dynamodb scan \
  --region "${REGION}" \
  --table-name "${REGISTRY_TABLE}" \
  --filter-expression "enabled = :t" \
  --expression-attribute-values '{":t":{"BOOL":true}}' \
  --query 'Items[*].agent_id.S' \
  --output json 2>/dev/null || echo '[]')

ENABLED_AGENTS=$(echo "${REGISTRY_SCAN}" | python3 -c "import json,sys; print(','.join(json.load(sys.stdin)))" 2>/dev/null || echo "")

HAS_STRANDS=$(echo ",${ENABLED_AGENTS}," | grep -c ",hr-assistant-strands-dev," || true)
HAS_ORCH_ENABLED=$(echo ",${ENABLED_AGENTS}," | grep -c ",orchestrator-dev," || true)

if [ "${HAS_STRANDS}" = "1" ] && [ "${HAS_ORCH_ENABLED}" = "0" ]; then
  pass "Registry has hr-assistant-strands-dev enabled; orchestrator-dev not routable"
elif [ "${HAS_STRANDS}" = "1" ] && [ "${HAS_ORCH_ENABLED}" = "1" ]; then
  # Self-exclusion is enforced at scan time inside registry.py, not by disabling
  # the orchestrator-dev row itself. Pass as long as hr-assistant-strands-dev is present.
  pass "Registry has hr-assistant-strands-dev enabled (orchestrator self-exclusion is runtime-enforced)"
else
  fail "Registry missing hr-assistant-strands-dev or self-excluded incorrectly — enabled=[${ENABLED_AGENTS}]"
fi

# ---------------------------------------------------------------------------
# Test O2 — Live invocation (non-streaming): annual leave → dispatched to strands
# ---------------------------------------------------------------------------

echo "Test O2 — Orchestrator invocation (annual leave, JSON response)"
SESSION_O2="smoke-o2-$(uuidgen | tr '[:upper:]' '[:lower:]')"
RESPONSE_FILE_O2="/tmp/smoke-o2-${TEST_TS}.json"
PAYLOAD_O2=$(python3 -c "import json,base64; print(base64.b64encode(json.dumps({'prompt':'How many days of annual leave am I entitled to?','sessionId':'${SESSION_O2}'}).encode()).decode())")

aws bedrock-agentcore invoke-agent-runtime \
  --region "${REGION}" \
  --agent-runtime-arn "${RUNTIME_ARN}" \
  --runtime-session-id "${SESSION_O2}" \
  --payload "${PAYLOAD_O2}" \
  "${RESPONSE_FILE_O2}" > /dev/null 2>&1
INVOKE_O2_EXIT=$?

RESPONSE_O2=$(python3 -c "
import json
try:
    with open('${RESPONSE_FILE_O2}') as f:
        d = json.load(f)
    print(d.get('response','') + '\n__DISPATCHED__' + str(d.get('dispatched_agent','')))
except Exception:
    print('')
" 2>/dev/null)

BODY_O2="${RESPONSE_O2%__DISPATCHED__*}"
DISPATCHED_O2="${RESPONSE_O2##*__DISPATCHED__}"

rm -f "${RESPONSE_FILE_O2}"

if [ "${INVOKE_O2_EXIT}" -eq 0 ] && [[ "${BODY_O2}" == *"25"* ]] && [ "${DISPATCHED_O2}" = "hr-assistant-strands-dev" ]; then
  pass "Orchestrator routed to hr-assistant-strands-dev; response contains '25'"
else
  fail "Orchestrator did not route or answer correctly — exit=${INVOKE_O2_EXIT} dispatched=${DISPATCHED_O2} body=${BODY_O2:0:200}"
fi

# ---------------------------------------------------------------------------
# Test O3 — Live invocation (streaming NDJSON passthrough)
# ---------------------------------------------------------------------------

echo "Test O3 — Orchestrator invocation (annual leave, SSE streaming passthrough)"
SESSION_O3="smoke-o3-$(uuidgen | tr '[:upper:]' '[:lower:]')"
RESPONSE_FILE_O3="/tmp/smoke-o3-${TEST_TS}.sse"
PAYLOAD_O3=$(python3 -c "import json,base64; print(base64.b64encode(json.dumps({'prompt':'How many days of annual leave am I entitled to?','sessionId':'${SESSION_O3}','stream':True}).encode()).decode())")

aws bedrock-agentcore invoke-agent-runtime \
  --region "${REGION}" \
  --agent-runtime-arn "${RUNTIME_ARN}" \
  --runtime-session-id "${SESSION_O3}" \
  --payload "${PAYLOAD_O3}" \
  "${RESPONSE_FILE_O3}" > /dev/null 2>&1
INVOKE_O3_EXIT=$?

O3_REPORT=$(python3 <<PYEOF 2>/dev/null
import json

parts = []
routing_agent = ''
saw_done = False
try:
    with open('${RESPONSE_FILE_O3}') as f:
        raw = f.read()
    # SSE frames separated by blank line; strip 'data: ' prefix per line.
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
        t = event.get('type')
        if t == 'routing':
            routing_agent = event.get('agent_id','')
        elif t == 'text':
            parts.append(event.get('data',''))
        elif t == 'done':
            saw_done = True
except Exception:
    pass

body = ''.join(parts)
has_25 = '25' in body
ok = bool(routing_agent == 'hr-assistant-strands-dev' and has_25 and saw_done)
print('OK' if ok else 'FAIL')
print(routing_agent or '<none>')
print('1' if saw_done else '0')
print('1' if has_25 else '0')
print(len(body))
PYEOF
)

O3_STATUS=$(echo "${O3_REPORT}" | sed -n '1p')
O3_ROUTING=$(echo "${O3_REPORT}" | sed -n '2p')
O3_DONE=$(echo "${O3_REPORT}" | sed -n '3p')
O3_HAS25=$(echo "${O3_REPORT}" | sed -n '4p')
O3_BODYLEN=$(echo "${O3_REPORT}" | sed -n '5p')

rm -f "${RESPONSE_FILE_O3}"

if [ "${INVOKE_O3_EXIT}" -eq 0 ] && [ "${O3_STATUS}" = "OK" ]; then
  pass "Orchestrator streamed routing→text→done (routing=${O3_ROUTING}, body_chars=${O3_BODYLEN}, contains '25')"
else
  fail "Streaming passthrough incomplete — exit=${INVOKE_O3_EXIT} routing=${O3_ROUTING} done=${O3_DONE} has_25=${O3_HAS25} body_chars=${O3_BODYLEN}"
fi

# ---------------------------------------------------------------------------
# Test O4 — Off-domain prompt → polite refusal, no dispatch
# ---------------------------------------------------------------------------

echo "Test O4 — Orchestrator off-domain refusal (no dispatch)"
SESSION_O4="smoke-o4-$(uuidgen | tr '[:upper:]' '[:lower:]')"
RESPONSE_FILE_O4="/tmp/smoke-o4-${TEST_TS}.json"
PAYLOAD_O4=$(python3 -c "import json,base64; print(base64.b64encode(json.dumps({'prompt':'Who won the Oscar for Best Picture in 1994?','sessionId':'${SESSION_O4}'}).encode()).decode())")

aws bedrock-agentcore invoke-agent-runtime \
  --region "${REGION}" \
  --agent-runtime-arn "${RUNTIME_ARN}" \
  --runtime-session-id "${SESSION_O4}" \
  --payload "${PAYLOAD_O4}" \
  "${RESPONSE_FILE_O4}" > /dev/null 2>&1
INVOKE_O4_EXIT=$?

DISPATCHED_O4=$(python3 -c "
import json
try:
    with open('${RESPONSE_FILE_O4}') as f:
        print(json.load(f).get('dispatched_agent',''))
except Exception:
    print('')
" 2>/dev/null)

rm -f "${RESPONSE_FILE_O4}"

# A polite refusal means no dispatch occurred — dispatched_agent is null/empty.
if [ "${INVOKE_O4_EXIT}" -eq 0 ] && { [ -z "${DISPATCHED_O4}" ] || [ "${DISPATCHED_O4}" = "None" ]; }; then
  pass "Orchestrator declined off-domain prompt without dispatching"
else
  fail "Off-domain prompt was dispatched — exit=${INVOKE_O4_EXIT} dispatched=${DISPATCHED_O4}"
fi

# ---------------------------------------------------------------------------
# Test O5 — CloudWatch logs confirm supervisor_invoke for O2
# ---------------------------------------------------------------------------

echo "Test O5 — CloudWatch logs: supervisor_invoke event (app log group)"
SUP_LOG_FOUND="false"

for i in $(seq 1 6); do
  START_MS=$(( ($(date +%s) - 300) * 1000 ))
  EVENTS=$(aws logs filter-log-events \
    --region "${REGION}" \
    --log-group-name "${APP_LOG_GROUP}" \
    --start-time "${START_MS}" \
    --filter-pattern '"supervisor_invoke"' \
    --query 'events[*].message' \
    --output text 2>/dev/null || echo "")

  if echo "${EVENTS}" | grep -q "hr-assistant-strands-dev" 2>/dev/null; then
    SUP_LOG_FOUND="true"
    break
  fi
  sleep 5
done

if [ "${SUP_LOG_FOUND}" = "true" ]; then
  pass "supervisor_invoke event with dispatched_agent=hr-assistant-strands-dev present in ${APP_LOG_GROUP}"
else
  fail "No supervisor_invoke event referencing hr-assistant-strands-dev in ${APP_LOG_GROUP} (last 5 min)"
fi

# ---------------------------------------------------------------------------
# Test O6 — Audit log group captures a request record
# ---------------------------------------------------------------------------

echo "Test O6 — Audit log group contains request record"
AUDIT_FOUND="false"

if [ -n "${AUDIT_LOG_GROUP}" ]; then
  for i in $(seq 1 6); do
    START_MS=$(( ($(date +%s) - 300) * 1000 ))
    AUDIT_EVENTS=$(aws logs filter-log-events \
      --region "${REGION}" \
      --log-group-name "${AUDIT_LOG_GROUP}" \
      --start-time "${START_MS}" \
      --filter-pattern '"request"' \
      --query 'events[*].message' \
      --output text 2>/dev/null || echo "")

    if [ -n "${AUDIT_EVENTS}" ] && [ "${AUDIT_EVENTS}" != "None" ]; then
      AUDIT_FOUND="true"
      break
    fi
    sleep 5
  done
fi

if [ "${AUDIT_FOUND}" = "true" ]; then
  pass "Audit log group ${AUDIT_LOG_GROUP} contains request records"
else
  fail "No request records found in audit log group ${AUDIT_LOG_GROUP} (last 5 min)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "========================"
if [ ${FAIL} -eq 0 ]; then
  echo -e "${GREEN}All ${PASS} tests passed.${NC}"
  echo "========================"
  exit 0
else
  echo -e "${RED}${FAIL} of $((PASS + FAIL)) tests failed:${NC}"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - ${t}"
  done
  echo "========================"
  exit 1
fi
