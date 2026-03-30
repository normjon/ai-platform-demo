# Module: agentcore

AgentCore runtime endpoint and MCP Gateway for the dev environment.

## Resources

| Resource | Purpose |
|---|---|
| `aws_bedrockagentcore_runtime.dev` | Single dev runtime endpoint. Private (no public IP). arm64/Graviton. |
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

## Deploying the agent image

Build and push with the git SHA as the tag:

```bash
GIT_SHA=$(git rev-parse --short HEAD)
IMAGE_URI="<account-id>.dkr.ecr.<region>.amazonaws.com/ai-platform-hr-assistant:${GIT_SHA}"

docker buildx build \
  --platform linux/arm64 \
  --push \
  -t "${IMAGE_URI}" .
```

Pass `IMAGE_URI` as the `agent_image_uri` variable before running `terraform apply`.

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
