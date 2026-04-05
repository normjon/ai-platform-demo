# Module: agentcore

AgentCore runtime endpoint and MCP Gateway for the dev environment.

## Resources

| Resource | Purpose |
| --- | --- |
| `aws_bedrockagentcore_agent_runtime.dev` | Single dev runtime endpoint. Private VPC mode. arm64/Graviton. |
| `aws_bedrockagentcore_gateway.mcp` | MCP Gateway that brokers tool calls from agent to registered tools. |

The ECR repository is managed by the **foundation layer** (`terraform/dev/foundation/`).
The module receives `ecr_repository_url` as an input variable.

The **MCP Gateway Target** is managed directly in `terraform/dev/app/main.tf` as
`aws_bedrockagentcore_gateway_target.glean_stub` — not inside this module. It
depends on both this module (gateway_id) and the glean-stub module (function_url),
so it lives at the app layer root. In dev, the target points to the Lambda-backed
MCP stub (`modules/glean-stub`). See the Gateway Target Deployment section for
how to transition to a real Glean endpoint.

## Input Variables

| Variable | Type | Description |
| --- | --- | --- |
| `name_prefix` | string | Prefix for all resource names |
| `aws_region` | string | AWS region |
| `account_id` | string | AWS account ID |
| `model_arn_primary` | string | Primary model ARN passed as `BEDROCK_MODEL_ID` env var |
| `agent_image_uri` | string | ECR image URI (tag must be git SHA — ADR-009) |
| `ecr_repository_url` | string | ECR repository URL (from foundation outputs) |
| `subnet_ids` | list(string) | Private subnets for AgentCore VPC placement |
| `agentcore_sg_id` | string | Security group ID for AgentCore runtime |
| `session_memory_table` | string | DynamoDB table name for session memory |
| `agent_registry_table` | string | DynamoDB table name for agent registry |
| `agentcore_role_arn` | string | IAM role ARN assumed by AgentCore runtime (IRSA) |
| `log_group_agentcore` | string | CloudWatch log group name for invocation logs |
| `tags` | map(string) | Tags applied to all resources |

## Critical constraints

| Constraint | Rule | ADR |
| --- | --- | --- |
| Architecture | Container must target `arm64`. Never `x86_64`. | ADR-004 |
| Image tag | Must be a git SHA. Never `latest`. | ADR-009 |
| Network | `assign_public_ip = false`. AgentCore endpoint is private in dev. | CLAUDE.md |
| Credentials | Runtime uses `agentcore_role_arn` (IRSA). No env-var credentials. | ADR-001 |
| MCP validation | Gateway validates inputs against schema before execution. | ADR-018 |
| Logs | Agent must emit structured JSON to stdout. See observability module. | ADR-003 |

## First-Time Apply Sequence

The AgentCore runtime validates that the container image exists in ECR at
create time. Because ECR lives in the foundation layer, follow this sequence:

**Step 1 — apply foundation (creates ECR repository):**
```bash
cd terraform/dev/foundation
terraform apply
```

**Step 2 — push the agent image:**
```bash
GIT_SHA=$(git rev-parse --short HEAD)
ECR_URL=$(terraform output -raw ecr_repository_url)
IMAGE_URI="${ECR_URL}:${GIT_SHA}"

aws ecr get-login-password --region us-east-2 \
  | docker login --username AWS --password-stdin "${ECR_URL}"

docker buildx build \
  --platform linux/arm64 \
  --push \
  -t "${IMAGE_URI}" .

# Update app/terraform.tfvars with the real URI
echo "agent_image_uri = \"${IMAGE_URI}\"" >> ../app/terraform.tfvars
```

**Step 3 — apply app layer (creates runtime and gateway):**
```bash
cd ../app
terraform apply
```

On subsequent app layer applies (after the image already exists in ECR),
no changes to the foundation layer are needed.

## Gateway Target Deployment (Glean Search)

The `aws_bedrockagentcore_gateway_target` resource is **not managed by
Terraform** because AWS validates live connectivity to the MCP endpoint at
create time. A placeholder or unreachable URL always produces a `FAILED`
target, which cannot be deleted and blocks gateway deletion on destroy.

Once a real Glean MCP endpoint is reachable from the VPC, deploy the target
manually:

```bash
GATEWAY_ID=$(cd terraform/dev/app && terraform output -raw agentcore_gateway_id 2>/dev/null \
  || aws bedrock-agentcore-control list-gateways --region us-east-2 \
     --query 'gateways[?name==`ai-platform-dev-mcp-gateway`].gatewayId' \
     --output text)

aws bedrock-agentcore-control create-gateway-target \
  --gateway-identifier "${GATEWAY_ID}" \
  --name "glean-search" \
  --description "Glean Enterprise Search MCP tool" \
  --target-configuration '{
    "mcp": {
      "mcpServer": {
        "endpoint": "https://<your-glean-mcp-endpoint>"
      }
    }
  }' \
  --region us-east-2
```

**Before destroying the app layer**, delete any registered targets first or
`terraform destroy` will fail with "Gateway has targets associated with it":

```bash
# List targets (response key is "items", not "gatewayTargets")
aws bedrock-agentcore-control list-gateway-targets \
  --gateway-identifier "${GATEWAY_ID}" --region us-east-2 \
  --query 'items[].{targetId:targetId,name:name,status:status}' \
  --output table

# Delete each target
aws bedrock-agentcore-control delete-gateway-target \
  --gateway-identifier "${GATEWAY_ID}" \
  --target-id <target-id> \
  --region us-east-2
```

**Required IAM actions** for gateway target management:
`bedrock-agentcore:CreateGatewayTarget`, `bedrock-agentcore:DeleteGatewayTarget`,
`bedrock-agentcore:ListGatewayTargets`, `bedrock-agentcore:GetGatewayTarget`

These are granted to the `agentcore_runtime` role by the `iam/` module.
If your SSO admin role is denied these actions, check for an SCP blocking
`bedrock-agentcore:*` actions in the account — this is a known behaviour
for recently-GA'd AgentCore APIs.

## Agent Container Documentation

Full documentation on the HR Assistant container — purpose, arm64 requirement,
placeholder vs real image, image tag policy, ECR repository, and rebuild
workflow — is at `terraform/dev/agents/hr-assistant/README.md`.

## Building Python dependencies for arm64

When packaging Python dependencies for the agent container, always cross-compile:

```bash
uv pip install \
  --python-platform aarch64-manylinux2014 \
  --python-version "3.12" \
  --target="$BUILD_DIR" \
  --only-binary=:all:
```

Never omit `--only-binary=:all:` — it is required for cross-platform compatibility (ADR-004).
