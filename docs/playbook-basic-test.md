# Playbook: Basic Smoke Tests — Dev Environment

Verifies that the dev environment infrastructure is deployed and operating
as expected after a `terraform apply`. Run these tests in order after any
apply, after credential rotation, or when investigating a suspected
infrastructure issue.

**Prerequisites**

- AWS CLI configured with SSO credentials for account `096305373014` in
  `us-east-2`. Run `awssandbox` to refresh if credentials have expired.
- `jq` and `python3` available in your shell.
- Terraform outputs available: run `terraform output` from `terraform/dev/`
  to confirm resource names if they differ from the values below.

---

## Test 1 — AgentCore Runtime is READY

Confirms the AgentCore runtime provisioned successfully and is accepting
invocations.

```bash
aws bedrock-agentcore-control get-agent-runtime \
  --agent-runtime-id ai_platform_dev_runtime-LXN4HNCjnf \
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

**If it fails:** Check `aws bedrock-agentcore-control list-agent-runtimes --region us-east-2`
to confirm the runtime exists. A status of `CREATING` means provisioning is
still in progress — wait and retry. Any other status indicates a deployment
problem; check CloudWatch log group `/aws/agentcore/ai-platform-dev`.

---

## Test 2 — MCP Gateway is READY

Confirms the MCP gateway is active and configured with AWS_IAM authorization.

```bash
aws bedrock-agentcore-control get-gateway \
  --gateway-identifier ai-platform-dev-mcp-gateway-zekfxdd0pn \
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

**If it fails:** The gateway ID is fixed post-apply. Confirm the ID matches
the `gateway_id` output from `module.agentcore`. If the gateway is in a
`FAILED` state, re-run `terraform apply` to recreate it.

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
|  KMSKeyId    |  arn:aws:kms:us-east-2:096305373014:key/814fb399-94db-4c47-a234-4bf581ebf2fe   |
|  SSEAlgorithm|  aws:kms                                                                       |
+--------------+--------------------------------------------------------------------------------+
```

**Pass condition:** `SSEAlgorithm = aws:kms` and `KMSKeyId` contains the
project KMS key ARN (`814fb399-94db-4c47-a234-4bf581ebf2fe`).

**If it fails:** An `AccessDenied` error means the caller does not have
`s3:PutObject` or `kms:GenerateDataKey` on the bucket or key. A missing
`KMSKeyId` in the response means the bucket SSE configuration was not
applied — re-run `terraform apply` and check the
`aws_s3_bucket_server_side_encryption_configuration` resource.

---

## Pass / Fail Summary

After running all five tests, use this checklist:

```
[ ] Test 1 — AgentCore runtime status = READY
[ ] Test 2 — MCP gateway status = READY, authType = AWS_IAM
[ ] Test 3 — Bedrock model responds to invocation
[ ] Test 4 — DynamoDB session memory write + read returns smoke-test
[ ] Test 5 — S3 object encrypted with project CMK
```

All five passing confirms the core infrastructure path is operational:
networking, IAM, KMS, storage, Bedrock model access, and the AgentCore
runtime are functioning as designed.

**Out of scope for this playbook:** The MCP gateway target (Glean Search)
cannot be tested until a real Glean MCP endpoint is configured in
`terraform.tfvars`. See `terraform/modules/iam/README.md` Known Issues for
the gateway target deployment procedure.

---

## Teardown Notes

Run from `terraform/dev/`:

```bash
terraform destroy -auto-approve
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
# List targets
aws bedrock-agentcore-control list-gateway-targets \
  --gateway-identifier <gateway-id> --region us-east-2

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
BUCKET="ai-platform-dev-document-landing-096305373014"

# Delete all versions
aws s3api list-object-versions --bucket $BUCKET --region us-east-2 \
  --query 'Versions[].{Key:Key,VersionId:VersionId}' --output json \
  | jq '{Objects: ., Quiet: true}' \
  | xargs -I{} aws s3api delete-objects --bucket $BUCKET --region us-east-2 --delete '{}'

# Delete all delete markers  
aws s3api list-object-versions --bucket $BUCKET --region us-east-2 \
  --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output json \
  | jq '{Objects: ., Quiet: true}' \
  | xargs -I{} aws s3api delete-objects --bucket $BUCKET --region us-east-2 --delete '{}'
```

Repeat for `ai-platform-dev-prompt-vault-096305373014`, then re-run
`terraform destroy -auto-approve`.
