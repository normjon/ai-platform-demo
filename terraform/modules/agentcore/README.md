# Module: agentcore

AgentCore runtime endpoint and MCP Gateway for the dev environment.

## Resources

| Resource | Purpose |
|---|---|
| `aws_ecr_repository.agent` | ECR repository for the HR Assistant agent image. |
| `aws_bedrockagentcore_agent_runtime.dev` | Single dev runtime endpoint. Private VPC mode. arm64/Graviton. |
| `aws_bedrockagentcore_gateway.mcp` | MCP Gateway that brokers tool calls from agent to registered tools. |
| `aws_bedrockagentcore_gateway_target.glean_search` | Registers the Glean Enterprise Search MCP tool in the Gateway. |

## Critical constraints

| Constraint | Rule | ADR |
|---|---|---|
| Architecture | Container must target `arm64`. Never `x86_64`. | ADR-004 |
| Image tag | Must be a git SHA. Never `latest`. | ADR-009 |
| Network | `assign_public_ip = false`. AgentCore endpoint is private in dev. | CLAUDE.md |
| Credentials | Runtime uses `agentcore_role_arn` (IRSA). No env-var credentials. | ADR-001 |
| MCP validation | Gateway validates inputs against schema before execution. | ADR-018 |
| Logs | Agent must emit structured JSON to stdout. See observability module. | ADR-003 |

## First-Time Apply Sequence

The AgentCore runtime validates that the container image exists in ECR at
create time. This creates a two-pass apply requirement on first deployment:

**Pass 1 — create infrastructure including the ECR repository:**
```bash
terraform apply -target=module.agentcore.aws_ecr_repository.agent \
                -target=module.networking \
                -target=module.iam \
                -target=module.storage \
                -target=module.observability
```

**Push the agent image:**
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

# Update terraform.tfvars with the real URI
echo "agent_image_uri = \"${IMAGE_URI}\"" >> terraform.tfvars
```

**Pass 2 — create the AgentCore runtime and gateway:**
```bash
terraform apply
```

On subsequent applies (after the image already exists in ECR), a single
`terraform apply` is sufficient.

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
