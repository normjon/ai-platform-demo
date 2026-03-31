# Glean Tool Layer — `terraform/dev/tools/glean/`

MCP tool that exposes Glean enterprise search to the AgentCore MCP Gateway.
Independently deployable — platform must be applied first, but this layer
can be destroyed and reapplied without touching the platform or foundation.

---

## Purpose

Registers the Glean search capability as an MCP tool on the platform gateway.
In the dev environment, the tool endpoint is a Lambda stub that returns mock
search results. When a real Glean MCP endpoint is available, only the
gateway target endpoint value changes — no infrastructure modifications are
required.

---

## Resources

| Resource | What it creates |
|---|---|
| `aws_iam_role.glean_lambda` | Lambda execution role — CloudWatch logs only |
| `aws_iam_role_policy.glean_lambda` | Inline policy scoped to `/aws/lambda/*` log groups |
| `module.glean_stub` | Lambda function (arm64, Python 3.12) + Function URL |
| `aws_bedrockagentcore_gateway_target.glean_stub` | Gateway target registered against the platform MCP gateway |

### Lambda Function

| Attribute | Value |
|---|---|
| Name | `ai-platform-dev-glean-stub` |
| Runtime | Python 3.12, arm64 |
| Timeout | 30s |
| URL auth | NONE (public HTTPS — gateway authenticates callers via AWS IAM) |
| Handler | `handler.handler` in `modules/glean-stub/handler.py` |

The Lambda implements the MCP JSON-RPC protocol:
- `initialize` — version negotiation, echoes client's requested protocol version
- `tools/list` — returns the `search` tool schema
- `tools/call` — executes `search`, returns mock results tagged `[STUB]`

---

## Dependencies

Reads the following output from the platform layer via `terraform_remote_state`:

| Platform output | Used for |
|---|---|
| `agentcore_gateway_id` | Registers `aws_bedrockagentcore_gateway_target` against the correct gateway |

---

## Prerequisites

- Platform layer applied and `agentcore_gateway_id` output available:
  ```bash
  terraform -chdir=terraform/dev/platform output agentcore_gateway_id
  ```
- `terraform.tfvars` created (copy from `.example`).

---

## First-Time Setup

```bash
cd terraform/dev/tools/glean

# One-time per machine
terraform init

# Create tfvars
cp terraform.tfvars.example terraform.tfvars
# Only account_id is required

terraform plan -out=tfplan
# Review — expect 5 resources: IAM role + policy, Lambda, Lambda URL, gateway target
terraform apply tfplan
```

---

## Iterative Cycle

This layer is designed for fast destroy/apply cycles.

```bash
cd terraform/dev/tools/glean

terraform destroy -auto-approve
# ~10 seconds

terraform plan -out=tfplan
terraform apply tfplan
# ~25 seconds
```

**Important:** If the platform layer was redeployed since the last apply here,
the gateway ID will have changed. Destroy and reapply this layer to register
against the new gateway.

---

## Transitioning to a Real Glean Endpoint

When a live Glean MCP endpoint is available:

1. Update the `endpoint` in `main.tf`:
   ```hcl
   target_configuration {
     mcp {
       mcp_server {
         endpoint = "https://<your-glean-mcp-endpoint>"
       }
     }
   }
   ```
2. Remove `module.glean_stub` and its IAM resources from `main.tf`.
3. Run `terraform plan -out=tfplan` and review.
4. Run `terraform apply tfplan`.

No changes to the platform layer or any other layer are required.

---

## Tests

Run after every apply.

```bash
cd terraform/dev/tools/glean
./smoke-test.sh
```

The script reads all values from `terraform output` and the platform layer outputs — no
arguments needed. It exits 0 if both tests pass and 1 if any fail.

**Tests covered:**

| Test | What it checks | Pass condition |
|---|---|---|
| 2a | Gateway target registered and status | `READY` |
| 2b | Glean stub tool call via MCP JSON-RPC | Response contains `[STUB]` and query text |

---

## Observability

Lambda logs are written to CloudWatch automatically:

| Log group | Content |
|---|---|
| `/aws/lambda/ai-platform-dev-glean-stub` | Structured JSON — every MCP request and tool call |

Query for recent tool calls:

```bash
aws logs filter-log-events \
  --log-group-name /aws/lambda/ai-platform-dev-glean-stub \
  --region us-east-2 \
  --filter-pattern '{ $.message = "tool_call" }' \
  --start-time $(date -v-1H +%s000) \
  --query 'events[].message' \
  --output text
```

Query for errors:

```bash
aws logs filter-log-events \
  --log-group-name /aws/lambda/ai-platform-dev-glean-stub \
  --region us-east-2 \
  --filter-pattern '{ $.level = "ERROR" }' \
  --start-time $(date -v-1H +%s000) \
  --query 'events[].message' \
  --output text
```

---

## Known Issues

**Gateway target validation requires a live endpoint**

AWS validates TCP connectivity to the MCP endpoint at
`aws_bedrockagentcore_gateway_target` create time. If the Lambda URL is not
reachable (e.g. Lambda failed to deploy), the gateway target will be created
in `FAILED` state and cannot be updated — it must be deleted and recreated.

Run `terraform destroy -auto-approve && terraform apply tfplan` to recover.

**Gateway target must be destroyed before platform destroy**

If `terraform destroy` on the platform layer fails with "Gateway has targets
associated with it", destroy this layer first:

```bash
cd terraform/dev/tools/glean && terraform destroy -auto-approve
# Then retry platform destroy
```

**`list-gateway-targets` API response key is `items`, not `gatewayTargets`**

When querying targets manually via the AWS CLI, use:
```bash
aws bedrock-agentcore-control list-gateway-targets \
  --gateway-identifier <gateway-id> --region us-east-2 \
  --query 'items[].{targetId:targetId,name:name,status:status}' \
  --output table
```
