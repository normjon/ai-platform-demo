# Playbook: Basic Smoke Tests — Dev Environment

Verifies that the dev environment infrastructure is deployed and operating
as expected after a `terraform apply`. Run these tests in order after any
apply, after credential rotation, or when investigating a suspected
infrastructure issue.

## Quick Run — Smoke Test Scripts

Each deployment layer ships a self-contained smoke test script. Run these
after every apply for fast pass/fail feedback:

```bash
# Platform tests (Tests 1-5)
cd terraform/dev/platform && ./smoke-test.sh

# Glean tool tests (Tests 2a-2b)
cd terraform/dev/tools/glean && ./smoke-test.sh
```

Both scripts read values from `terraform output` automatically, emit colored
PASS/FAIL per test, and exit non-zero if any test fails.

The sections below document each test in detail for manual investigation and
reference.

---

**Prerequisites**

- AWS CLI configured with SSO credentials for account `096305373014` in
  `us-east-2`. Run `aws sso login --profile <your-sso-profile>` to refresh if credentials have expired.
- `jq` and `python3` available in your shell.
- Terraform outputs available: run `terraform output` from `terraform/dev/platform/`
  for platform outputs (gateway ID, endpoint ID, tables, buckets). Run from
  `terraform/dev/tools/glean/` for the Glean stub URL and gateway target ID.

---

## Test 1 — AgentCore Runtime is READY

Confirms the AgentCore runtime provisioned successfully and is accepting
invocations.

```bash
RUNTIME_ID=$(cd terraform/dev/platform && terraform output -raw agentcore_endpoint_id)

aws bedrock-agentcore-control get-agent-runtime \
  --agent-runtime-id "${RUNTIME_ID}" \
  --region us-east-2 \
  --query '{status: status, name: agentRuntimeName}' \
  --output table
```

**Expected output**

```
---------------------------------------
|           GetAgentRuntime           |
+--------------------------+----------+
|           name           | status   |
+--------------------------+----------+
|  ai_platform_dev_runtime |  READY   |
+--------------------------+----------+
```

**Pass condition:** `status = READY`

**If it fails:** Run `aws bedrock-agentcore-control list-agent-runtimes --region us-east-2`
to confirm the runtime exists. A status of `CREATING` means provisioning is
still in progress — wait and retry. Any other status indicates a deployment
problem; check CloudWatch log group `/aws/agentcore/ai-platform-dev`.

**Note:** The runtime ID changes on every `terraform destroy` + `terraform apply`
cycle. Always resolve it dynamically via `terraform output` or `list-agent-runtimes`
rather than hardcoding it.

---

## Test 2 — MCP Gateway is READY

Confirms the MCP gateway is active and configured with AWS_IAM authorization.

```bash
GATEWAY_ID=$(cd terraform/dev/platform && terraform output -raw agentcore_gateway_id)

aws bedrock-agentcore-control get-gateway \
  --gateway-identifier "${GATEWAY_ID}" \
  --region us-east-2 \
  --query '{status: status, name: name, protocol: protocolType, authType: authorizerType}' \
  --output table
```

**Expected output**

```
-------------------------------------------------------------------
|                           GetGateway                            |
+----------+-------------------------------+-----------+----------+
| authType |             name              | protocol  | status   |
+----------+-------------------------------+-----------+----------+
|  AWS_IAM |  ai-platform-dev-mcp-gateway  |  MCP      |  READY   |
+----------+-------------------------------+-----------+----------+
```

**Pass condition:** `status = READY`, `authType = AWS_IAM`, `protocol = MCP`

**If it fails:** Confirm the gateway ID matches `terraform output agentcore_gateway_id`
from `terraform/dev/platform/`. If the gateway is in a `FAILED` state, re-run
`terraform apply` in `terraform/dev/platform/` to recreate it.

---

## Test 2a — MCP Gateway Target (Glean Stub) is READY

Confirms the Glean stub Lambda is registered as a READY gateway target.

```bash
GATEWAY_ID=$(cd terraform/dev/platform && terraform output -raw agentcore_gateway_id)

aws bedrock-agentcore-control get-gateway-target \
  --gateway-identifier "${GATEWAY_ID}" \
  --target-id $(aws bedrock-agentcore-control list-gateway-targets \
    --gateway-identifier "${GATEWAY_ID}" \
    --region us-east-2 \
    --query 'items[?name==`glean-stub`].targetId' \
    --output text) \
  --region us-east-2 \
  --query '{name: name, status: status}' \
  --output table
```

**Expected output**

```
-----------------------------
|      GetGatewayTarget     |
+-------------+-------------+
|    name     |   status    |
+-------------+-------------+
| glean-stub  |   READY     |
+-------------+-------------+
```

**Pass condition:** `status = READY`

**If it fails:** Check the Lambda function URL is reachable:
```bash
STUB_URL=$(cd terraform/dev/tools/glean && terraform output -raw glean_stub_url)
curl -s -X POST "${STUB_URL}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq .
```
A valid response confirms the Lambda is healthy. If the target is FAILED,
delete it and re-run `terraform apply` in `terraform/dev/tools/glean/`.

---

## Test 2b — Glean Stub MCP Tool Call

Confirms the Lambda stub responds correctly to a tool invocation.

```bash
STUB_URL=$(cd terraform/dev/tools/glean && terraform output -raw glean_stub_url)

curl -s -X POST "${STUB_URL}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"employee benefits policy"}}}' \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['result']['content'][0]['text'][:120])"
```

**Expected output** (first 120 characters of mock result)

```
1. [STUB] employee benefits policy — Mock Document A
   This is a placeholder result from the Glean stub Lambda.
```

**Pass condition:** Response contains `[STUB]` and the query text.

---

## Test 3 — Bedrock Model Invocation

Confirms that the Bedrock runtime endpoint is reachable and Claude Sonnet 4.6
responds via the cross-region inference profile.

```bash
aws bedrock-runtime invoke-model \
  --model-id us.anthropic.claude-sonnet-4-6 \
  --region us-east-2 \
  --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":50,"messages":[{"role":"user","content":"Reply with only the word PASS"}]}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/bedrock-test-response.json \
  && python3 -c "
import sys, json
with open('/tmp/bedrock-test-response.json') as f:
    r = json.load(f)
print('Model response:', r['content'][0]['text'])
"
```

**Expected output**

```
Model response: PASS
```

**Pass condition:** Command exits 0 and the model returns a response.

**Note:** The model ID must be the inference profile ID
`us.anthropic.claude-sonnet-4-6`, not the bare model ID
`anthropic.claude-sonnet-4-6`. On-demand invocation of Sonnet 4.6 requires
routing through an inference profile. To list all active inference profiles:

```bash
aws bedrock list-inference-profiles --region us-east-2 \
  --query 'inferenceProfileSummaries[?contains(inferenceProfileId,`claude-sonnet-4`)].{id:inferenceProfileId,status:status}' \
  --output table
```

**If it fails:** Confirm model access is enabled in the Bedrock console under
Model Access for account `096305373014` in `us-east-2`. A
`ValidationException` with "on-demand throughput isn't supported" means the
bare model ID was used instead of the inference profile ID.

---

## Test 4 — DynamoDB Session Memory Table

Confirms the session memory table is active and read/write operations work
end-to-end. The test item is written, read back, then deleted.

```bash
# Write
aws dynamodb put-item \
  --table-name ai-platform-dev-session-memory \
  --region us-east-2 \
  --item '{"session_id":{"S":"test-session-001"},"timestamp":{"S":"2026-03-30T00:00:00Z"},"content":{"S":"smoke-test"}}'

# Read back
aws dynamodb get-item \
  --table-name ai-platform-dev-session-memory \
  --region us-east-2 \
  --key '{"session_id":{"S":"test-session-001"},"timestamp":{"S":"2026-03-30T00:00:00Z"}}' \
  --query 'Item.content.S' \
  --output text

# Clean up
aws dynamodb delete-item \
  --table-name ai-platform-dev-session-memory \
  --region us-east-2 \
  --key '{"session_id":{"S":"test-session-001"},"timestamp":{"S":"2026-03-30T00:00:00Z"}}'
```

**Expected output** (read step)

```
smoke-test
```

**Pass condition:** The read returns `smoke-test` and no commands error.

**If it fails:** Run `aws dynamodb describe-table --table-name ai-platform-dev-session-memory --region us-east-2 --query 'Table.TableStatus'` and confirm status is `ACTIVE`. A `ResourceNotFoundException` means the table does not exist — re-run `terraform apply`.

---

## Test 5 — S3 Document Landing Bucket KMS Encryption

Confirms the document landing bucket is writable and that every object is
automatically encrypted with the project KMS CMK.

```bash
# Write a test object
echo "smoke-test" | aws s3 cp - \
  s3://ai-platform-dev-document-landing-096305373014/smoke-test.txt \
  --region us-east-2

# Verify KMS encryption on the object
aws s3api head-object \
  --bucket ai-platform-dev-document-landing-096305373014 \
  --key smoke-test.txt \
  --region us-east-2 \
  --query '{SSEAlgorithm: ServerSideEncryption, KMSKeyId: SSEKMSKeyId}' \
  --output table

# Clean up
aws s3 rm s3://ai-platform-dev-document-landing-096305373014/smoke-test.txt \
  --region us-east-2
```

**Expected output** (head-object step)

```
-------------------------------------------------------------------------------------------------
|                                          HeadObject                                           |
+--------------+--------------------------------------------------------------------------------+
|  KMSKeyId    |  arn:aws:kms:us-east-2:096305373014:key/7a48cb6e-c245-46a5-8751-8ae666bb57a8   |
|  SSEAlgorithm|  aws:kms                                                                       |
+--------------+--------------------------------------------------------------------------------+
```

**Pass condition:** `SSEAlgorithm = aws:kms` and `KMSKeyId` contains the
project KMS key ARN. The key ID changes if foundation is destroyed and reapplied —
verify the current key with `terraform output -raw kms_key_arn` from
`terraform/dev/foundation/`.

**If it fails:** An `AccessDenied` error means the caller does not have
`s3:PutObject` or `kms:GenerateDataKey` on the bucket or key. A missing
`KMSKeyId` in the response means the bucket SSE configuration was not
applied — re-run `terraform apply` and check the
`aws_s3_bucket_server_side_encryption_configuration` resource.

---

## Pass / Fail Summary

After running all five tests, use this checklist:

```
[ ] Test 1  — AgentCore runtime status = READY
[ ] Test 2  — MCP gateway status = READY, authType = AWS_IAM
[ ] Test 2a — MCP gateway target (glean-stub) status = READY
[ ] Test 2b — Glean stub tool call returns mock results
[ ] Test 3  — Bedrock model responds to invocation
[ ] Test 4  — DynamoDB session memory write + read returns smoke-test
[ ] Test 5  — S3 object encrypted with project CMK
```

All seven passing confirms the full infrastructure path is operational:
networking, IAM, KMS, storage, Bedrock model access, the AgentCore runtime,
and the MCP Gateway → Lambda stub tool call path are all functioning.

**Glean stub vs real Glean:** Tests 2a and 2b exercise the Lambda stub endpoint.
When a real Glean MCP endpoint is available, update the gateway target endpoint
in `terraform/dev/tools/glean/main.tf` and re-apply. The test commands remain the same.

---

## Teardown Notes

The dev environment uses four Terraform state layers. Destroy in reverse
dependency order. Never destroy foundation while platform is up.

```bash
# 1. Destroy tools and agents (order within this group doesn't matter)
cd terraform/dev/tools/glean && terraform destroy -auto-approve
cd terraform/dev/agents/hr-assistant && terraform destroy -auto-approve

# 2. Purge versioned S3 buckets before destroying platform (required — Terraform
#    cannot delete non-empty versioned buckets). See S3 Known Issue below.

# 3. Destroy platform layer
cd terraform/dev/platform && terraform destroy -auto-approve

# 4. Destroy foundation only when decommissioning the environment entirely
cd terraform/dev/foundation && terraform destroy -auto-approve
```

### Known Issues During Destroy

**VPC interface endpoint ENI cleanup takes 15-25 minutes**

The two interface endpoints (`bedrock-runtime`, `cloudwatch-logs`) leave
behind Elastic Network Interfaces in the subnets when deleted. Terraform
will poll for up to ~20 minutes waiting for them to clear. The subnets and
security group cannot be deleted until the ENIs are released by AWS. This
is normal — wait for the poll to complete or retry `terraform destroy` if
it times out.

**AgentCore VPC-mode ENIs block subnet deletion**

When the AgentCore runtime uses `network_mode = "VPC"`, AWS creates
`agentic_ai` type ENIs in the subnets. These are `InstanceOwnerId:
amazon-aws` and cannot be manually detached (`OperationNotPermitted` on
`ela-attach` attachments). After `terraform destroy` removes the runtime
resource, AWS releases these ENIs asynchronously. If subnet deletion fails
with `DependencyViolation`, wait 15-30 minutes and re-run
`terraform destroy -auto-approve` — Terraform will resume from the
remaining 3 resources and complete in seconds.

**Gateway target must be deleted before gateway**

If a gateway target exists outside Terraform state (e.g. from a failed
apply), `terraform destroy` will fail to delete the gateway with:
"Gateway has targets associated with it." Fix:

```bash
# List targets (response key is "items", not "gatewayTargets")
aws bedrock-agentcore-control list-gateway-targets \
  --gateway-identifier <gateway-id> --region us-east-2 \
  --query 'items[].{targetId:targetId,name:name,status:status}' \
  --output table

# Delete each orphaned target
aws bedrock-agentcore-control delete-gateway-target \
  --gateway-identifier <gateway-id> \
  --target-id <target-id> \
  --region us-east-2

# Then re-run
terraform destroy -auto-approve
```

**S3 versioned buckets not empty**

With versioning enabled, deleted objects leave delete markers. Terraform
will fail to delete the bucket with `BucketNotEmpty`. Purge all versions
and markers first:

```bash
for BUCKET in \
  ai-platform-dev-document-landing-096305373014 \
  ai-platform-dev-prompt-vault-096305373014; do

  echo "=== Purging ${BUCKET} ==="

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
```

Run this for both buckets, then re-run `terraform destroy -auto-approve` in `terraform/dev/platform/`.
