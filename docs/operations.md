# Operations Runbook

One-page operator reference for the dev environment. Use this when you need
to do, not to learn. For design, read the architecture document
(`Enterprise_AI_Platform_Architecture.md`). For layer-specific nuance, read
the layer's own `README.md`.

---

## Credential Refresh

SSO session expired? Run:

```bash
awssandbox
```

Every smoke test, `terraform plan`, and `aws ...` call needs fresh
credentials. If commands hang or return `ExpiredToken`, refresh first.

---

## Apply Order (cold start)

```
foundation → platform → tools/<each> → agents/<each>
```

Full sequence with flags:

```bash
# 1. Foundation (long-lived; apply once)
cd terraform/dev/foundation
terraform init && terraform plan -out=tfplan && terraform apply tfplan

# 2. Platform
cd ../platform
terraform init && terraform plan -out=tfplan && terraform apply tfplan

# 3. Tools — each independent
cd ../tools/glean
terraform init && terraform plan -out=tfplan && terraform apply tfplan

# 4. Agents — each independent, two-step apply per agent
cd ../../agents/hr-assistant
# First apply with agent_image_uri = "" → creates ECR + IAM
terraform init && terraform plan -out=tfplan && terraform apply tfplan
# Build + push the container (see terraform/dev/agents/README.md → Container build and push)
# Second apply with real agent_image_uri → lands runtime + registry
terraform plan -out=tfplan && terraform apply tfplan

# Repeat two-step apply for hr-assistant-strands, stub-agent,
# orchestrator in any order (orchestrator requires at least one
# enabled sub-agent in the registry).
#
# Step 2 fails the first time with ResourceAlreadyExistsException on
# the /aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT log group —
# AgentCore pre-creates it. Import and re-apply:
#   terraform import aws_cloudwatch_log_group.<name> <log-group-name>
#   terraform apply -auto-approve
# Full explanation + count-gated variant:
# docs/patterns/layers/agents-tree.md → "Runtime log group collision on first apply"
```

Never skip or reverse the order. Tools and agents read platform remote
state; platform reads foundation remote state.

---

## Teardown Order (reverse + S3 purge + ECR purge)

```
agents → tools → platform (with S3 purge) → foundation
```

```bash
# 1. Agents — each layer standalone; when=destroy provisioners
# remove registry entries automatically.
cd terraform/dev/agents/orchestrator && terraform destroy -auto-approve
cd ../stub-agent                     && terraform destroy -auto-approve
cd ../hr-assistant-strands           && terraform destroy -auto-approve
cd ../hr-assistant                   && terraform destroy -auto-approve
# hr-assistant is the remaining outlier without when=destroy — manually
# delete its registry item if orphaned; see hr-assistant/README.md.

# 2. Purge ECR images for each agent before destroy
# (non-empty repo blocks destroy)
for REPO in ai-platform-dev-hr-assistant \
            ai-platform-dev-hr-assistant-strands \
            ai-platform-dev-stub-agent \
            ai-platform-dev-orchestrator; do
  IMAGES=$(aws ecr list-images --region us-east-2 --repository-name "$REPO" \
             --query 'imageIds[*]' --output json 2>/dev/null)
  if [ "$IMAGES" != "[]" ] && [ -n "$IMAGES" ]; then
    aws ecr batch-delete-image --region us-east-2 \
      --repository-name "$REPO" --image-ids "$IMAGES"
  fi
done

# 3. Tools
cd terraform/dev/tools/glean && terraform destroy -auto-approve

# 4. Platform — PURGE S3 VERSIONED BUCKETS FIRST, else destroy fails
for BUCKET in ai-platform-dev-document-landing-096305373014 \
              ai-platform-dev-prompt-vault-096305373014; do
  VERSIONS=$(aws s3api list-object-versions --bucket "$BUCKET" --region us-east-2 \
               --query 'Versions[].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null)
  if [ "$VERSIONS" != "null" ] && [ "$VERSIONS" != "[]" ] && [ -n "$VERSIONS" ]; then
    DELETE_JSON=$(echo "$VERSIONS" | python3 -c \
      "import sys,json; v=json.load(sys.stdin); print(json.dumps({'Objects':v,'Quiet':True}))")
    aws s3api delete-objects --bucket "$BUCKET" --region us-east-2 --delete "$DELETE_JSON"
  fi
  MARKERS=$(aws s3api list-object-versions --bucket "$BUCKET" --region us-east-2 \
              --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null)
  if [ "$MARKERS" != "null" ] && [ "$MARKERS" != "[]" ] && [ -n "$MARKERS" ]; then
    DELETE_JSON=$(echo "$MARKERS" | python3 -c \
      "import sys,json; v=json.load(sys.stdin); print(json.dumps({'Objects':v,'Quiet':True}))")
    aws s3api delete-objects --bucket "$BUCKET" --region us-east-2 --delete "$DELETE_JSON"
  fi
done
cd terraform/dev/platform && terraform destroy -auto-approve

# 5. Foundation — only when decommissioning the environment.
# bedrock-runtime + logs interface endpoints leave behind ENIs;
# destroy polls ~20 minutes. AgentCore VPC ENIs block subnet
# deletion for 15–30 min post platform destroy. Wait and retry on
# DependencyViolation — do not force.
cd terraform/dev/foundation && terraform destroy -auto-approve
```

**Why agents and tools must go before platform:** tool layers register
gateway targets; destroying platform with registered targets fails with
`Gateway has targets associated with it`. Agent layers hold runtime
resources that depend on the platform AgentCore endpoint.

**Why KMS survival matters:** the foundation KMS key encrypts Prompt
Vault and document-landing S3 object versions. Destroying foundation
while encrypted versions exist makes those versions permanently
unrecoverable. Always purge the buckets before destroying platform,
and never destroy foundation while platform is alive.

---

## Smoke Test Catalogue

Every layer ships `smoke-test.sh` that reads terraform outputs and runs
with no arguments. Run after every apply. Exit 0 = pass; 1 = fail.

| Layer | Script | Checks |
|---|---|---|
| Foundation | _(no smoke script — outputs-only layer)_ | Verify via `terraform output` |
| Platform | `terraform/dev/platform/smoke-test.sh` | Tests 1–9: AgentCore runtime, gateway, KB, DynamoDB, S3, quality scorer |
| Tools / glean | `terraform/dev/tools/glean/smoke-test.sh` | Tests 2a–2b: gateway target `READY`, `tools/call` returns `[STUB]` |
| Agents / hr-assistant | `terraform/dev/agents/hr-assistant/smoke-test.sh` | Runtime invoke + app log event + KB retrieval |
| Agents / hr-assistant-strands | `terraform/dev/agents/hr-assistant-strands/smoke-test.sh` | Runtime invoke + app log event + Strands session manager |
| Agents / stub-agent | `terraform/dev/agents/stub-agent/smoke-test.sh` | Echo invoke + app log event |
| Agents / orchestrator | `terraform/dev/agents/orchestrator/smoke-test.sh` | Dispatch to `hr-assistant-strands`, PII redaction, audit log event |

Smoke tests assert against each agent's **application** log group
(`/ai-platform/<agent>/app-<env>`), not the AgentCore runtime log group.
This is intentional — the AgentCore stdout sidecar drops events on some
runtimes. Assertions against the runtime log group flake on sidecar drop
and produce false negatives.

---

## Quality Alarm Triage

The platform quality scorer runs hourly via EventBridge. Two alarms fire
in the `us-east-2` region:

| Alarm | Trigger | First action |
|---|---|---|
| `ai-platform-dev-quality-below-threshold` | >3 responses scored below threshold (0.70) in 1 hour | Scan `ai-platform-dev-quality-records` GSI `agent-threshold-index` for the offending records |
| `ai-platform-dev-quality-scorer-errors` | Quality scorer Lambda errored ≥1 time in 1 hour | Check `/aws/lambda/ai-platform-dev-quality-scorer` for stack traces |

Below-threshold triage:

```bash
aws dynamodb query --region us-east-2 \
  --table-name ai-platform-dev-quality-records \
  --index-name agent-threshold-index \
  --key-condition-expression 'agent_id = :agent AND below_threshold = :flag' \
  --expression-attribute-values '{":agent":{"S":"hr-assistant-strands"},":flag":{"N":"1"}}' \
  --query 'Items[*].{record_id:record_id.S,score:score.N,reason:reason.S,scored_at:scored_at.S}' \
  --output table
```

Scorer-error triage:

```bash
aws logs filter-log-events --region us-east-2 \
  --log-group-name /aws/lambda/ai-platform-dev-quality-scorer \
  --filter-pattern '{ $.level = "ERROR" }' \
  --start-time $(date -v-1H +%s000) \
  --query 'events[*].message' --output text
```

Relevant CloudWatch metric namespaces:

- `AIPlatform/Quality` — `QualityScore`, `BelowThreshold`, `GuardrailFired`
- `AIPlatform/AgentCore` — `GleanCallCount` and per-agent custom metrics
- `AWS/Lambda` — standard Lambda metrics (used by the scorer-errors alarm)

Grafana stat panels show "No data" between hourly scorer runs — that is
expected, not an alarm condition.

---

## trace_id Correlation

Every orchestrator dispatch generates a `trace_id` (UUID) and passes it to
the sub-agent in the dispatch payload. Both the orchestrator and the
sub-agent emit structured log events containing the `trace_id`. Use it to
reconstruct a request end-to-end:

```bash
TRACE_ID="<paste from orchestrator response>"

# Orchestrator side
aws logs filter-log-events --region us-east-2 \
  --log-group-name /ai-platform/orchestrator/app-dev \
  --filter-pattern "{ \$.trace_id = \"${TRACE_ID}\" }" \
  --start-time $(date -v-1H +%s000) \
  --query 'events[*].message' --output text

# Sub-agent side (hr-assistant-strands example)
aws logs filter-log-events --region us-east-2 \
  --log-group-name /ai-platform/hr-assistant-strands/app-dev \
  --filter-pattern "{ \$.trace_id = \"${TRACE_ID}\" }" \
  --start-time $(date -v-1H +%s000) \
  --query 'events[*].message' --output text

# Audit log (hash-only — PII redacted)
aws logs filter-log-events --region us-east-2 \
  --log-group-name /ai-platform/orchestrator/audit-dev \
  --filter-pattern "{ \$.trace_id = \"${TRACE_ID}\" }" \
  --start-time $(date -v-1H +%s000) \
  --query 'events[*].message' --output text
```

Orchestrator audit logs are **hash-only** by design — no raw prompts.
Comprehend PII redaction runs before the orchestrator's Strands Agent,
so audit trails never persist user PII.

---

## Common Failure Modes

| Symptom | Root cause | Fix |
|---|---|---|
| `dial tcp 3.x.x.x:443: i/o timeout` at container startup | AgentCore SG uses CIDR egress instead of prefix lists for S3/DynamoDB | See `terraform/dev/foundation/README.md` → "Security group egress — prefix lists, not CIDR blocks" |
| `RuntimeClientError: Runtime health check failed or timed out` on orchestrator dispatch | Missing `bedrock-agentcore` VPC interface endpoint | Re-apply foundation; verify endpoint listed in `foundation/README.md` |
| `Expected toolResult blocks at messages.X.content` | Re-used `sessionId` with corrupt tool_use/tool_result history | Use a fresh `sessionId` per invocation — see `docs/patterns/layers/agents-tree.md` → "AgentCore Runtime Invocation Contract" |
| Gateway target `FAILED` state + `ConflictException` on re-apply | Lambda crashed during MCP `initialize` at target creation | Delete the target out-of-band; see `tools/glean/README.md` → "Gateway target reaches FAILED state" |
| Smoke test passes but no app log events | `APP_LOG_GROUP` unset or log_handler not installed | Check env var + `log_handler.install()` in container startup; see `docs/patterns/layers/agents-tree.md` → "Direct-Write CloudWatch Log Handler" |
| `ResourceNotFoundException` on `InvokeAgentRuntime` | Using `agent-runtime` ARN path instead of `runtime` | `docs/patterns/layers/agents-tree.md` → "Runtime ARN format" |
| `ResourceAlreadyExistsException` on runtime `-DEFAULT` log group during agent step 2 apply | AgentCore pre-creates the log group when it provisions the runtime | `terraform import` the group, then `terraform apply` — see `docs/patterns/layers/agents-tree.md` → "Runtime log group collision on first apply" |
| `User: .../kb-role/DocumentLoaderTask-... not authorized: kms:Decrypt` during KB ingest | KB IAM role missing KMS Decrypt on the foundation KMS key | `docs/patterns/layers/agent-hr-assistant.md` → "KB IAM role — kms:Decrypt is mandatory" |
| `403 Forbidden` on `create-os-index.py` | AOSS data access policy propagation (~60s) not yet complete | Add `sleep 60` before the script; do not retry immediately |
| `ExpiredToken` on any `aws` CLI call | SSO session expired | `awssandbox` |
| `Invocation of model ID ... with on-demand throughput isn't supported` | Using bare model ID instead of `us.*` inference profile | Root CLAUDE.md → "Approved Bedrock Model ARNs" |

---

## Where to Go Next

- Need to add an agent → `terraform/dev/agents/README.md`
- Need to add a tool → `terraform/dev/tools/README.md`
- Need to author a skill → `terraform/dev/skills/README.md` (pre-implementation)
- Understanding request flow → `docs/request-flow.md`
- Platform API (outputs, registry schema) → `terraform/dev/platform/README.md`
- Architectural rationale → `docs/Enterprise_AI_Platform_Architecture.md`
- Cross-project engineering standards → `docs/adrs/`
