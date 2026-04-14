# Module: agentcore

AgentCore runtime endpoint and MCP Gateway for the dev environment.

## Resources

| Resource | Purpose |
| --- | --- |
| `aws_bedrockagentcore_agent_runtime.dev` | Single dev runtime endpoint. Private VPC mode. arm64/Graviton. |
| `aws_bedrockagentcore_gateway.mcp` | MCP Gateway that brokers tool calls from agent to registered tools. |

The ECR repository is managed by the **foundation layer** (`terraform/dev/foundation/`).
The module receives `ecr_repository_url` as an input variable.

The **MCP Gateway Target** is managed by `terraform/dev/tools/glean/main.tf` as
`aws_bedrockagentcore_gateway_target.glean_stub` — not inside this module. It
depends on both this module (gateway_id) and the glean-stub module (function_url),
so it lives in the tools/glean layer. See `terraform/dev/tools/glean/README.md`
for the operational runbook and Known Issues around gateway target lifecycle.

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
| `log_group_agentcore` | string | CloudWatch log group name (platform-managed; accepted for contract completeness) |
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

# Set agent_image_uri in terraform/dev/platform/terraform.tfvars
echo "agent_image_uri = \"${IMAGE_URI}\""
```

**Step 3 — apply the platform layer (creates runtime and gateway):**
```bash
cd terraform/dev/platform
terraform apply
```

**Step 4 — apply the tools/glean layer (registers gateway target):**
```bash
cd terraform/dev/tools/glean
terraform apply
```

On subsequent applies (after the image already exists in ECR),
no changes to the foundation layer are needed.

## IAM

Gateway target management actions (`bedrock-agentcore:CreateGatewayTarget`,
`bedrock-agentcore:DeleteGatewayTarget`, `bedrock-agentcore:GetGatewayTarget`,
`bedrock-agentcore:ListGatewayTargets`, `bedrock-agentcore:UpdateGatewayTarget`)
are granted to the `agentcore_runtime` role inline in
`terraform/dev/platform/main.tf` — not in any reusable module.

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

## Agent Container Documentation

Full documentation on the HR Assistant container — purpose, arm64 requirement,
placeholder vs real image, image tag policy, ECR repository, and rebuild
workflow — is at `terraform/dev/agents/hr-assistant/README.md`.
