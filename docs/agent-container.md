# HR Assistant Agent Container

## Purpose

The HR Assistant is the first test agent deployed on the Enterprise AI Platform.
It exercises the full end-to-end infrastructure path:

```
Caller → AgentCore Runtime → Bedrock (Claude Sonnet 4.6)
                           → MCP Gateway → Glean Search tool
                           → DynamoDB (session memory)
                           → CloudWatch (structured logs)
```

In the dev environment, the HR Assistant answers employee questions by reasoning
over Claude Sonnet 4.6 and retrieving permissions-aware results from Glean. It
is not a production agent — it is a platform validation vehicle.

---

## arm64 / Graviton Requirement

AgentCore runtimes in this platform run on AWS Graviton (arm64). This is an
explicit architecture decision (ADR-004) driven by cost and performance. The
constraint applies to:

- The container image itself — must be built `--platform linux/arm64`
- All Python binary dependencies — must be cross-compiled for `aarch64`

**Why this matters:** Building a container on an x86 machine and pushing it
without explicit platform targeting produces an x86 image. AgentCore will
accept it at deploy time but Python packages with native extensions (e.g.
`numpy`, `cryptography`, `pydantic-core`) will produce silent `ImportError`
failures at runtime when running on Graviton. The failure will not appear
during `terraform apply` — only when the agent is invoked.

**The safe build command (always use this):**

```bash
docker buildx build \
  --platform linux/arm64 \
  --push \
  -t "${IMAGE_URI}" .
```

**Python dependency packaging (always use this):**

```bash
uv pip install \
  --python-platform aarch64-manylinux2014 \
  --python-version "3.12" \
  --target="$BUILD_DIR" \
  --only-binary=:all:
```

Never omit `--only-binary=:all:` and never omit `--platform linux/arm64`
from the Docker build. These are non-negotiable for Graviton compatibility.

---

## Image Tag Policy

All ECR image tags must be the short git SHA of the commit that produced the
image. Never use `latest`, `dev`, `main`, or any mutable tag (ADR-009).

The ECR repository is configured with `IMMUTABLE` tag mutability — pushing to
an existing tag will be rejected by ECR. This enforces the policy at the
infrastructure level.

```bash
GIT_SHA=$(git rev-parse --short HEAD)
IMAGE_URI="${ECR_URL}:${GIT_SHA}"
```

---

## ECR Repository

The ECR repository is managed by the **foundation layer**, not the app layer.
This means the repository — and any images pushed to it — survive app layer
`terraform destroy` cycles. You do not need to re-push the image after
destroying and reapplying the app layer, as long as the foundation layer
remains in place.

Repository name: `ai-platform-dev-hr-assistant`
Registry: `096305373014.dkr.ecr.us-east-2.amazonaws.com`

---

## Placeholder Image (Infrastructure Validation)

The AgentCore runtime validates that the container image exists in ECR at
create time. Until real agent code is developed, a placeholder image is used
to satisfy this requirement and validate the infrastructure path.

The placeholder is `python:3.12-slim` pulled for `linux/arm64` and retagged
with the current git SHA. It satisfies the runtime's image existence check
and can be used for smoke testing infrastructure connectivity. It does not
implement any agent logic.

**Push the placeholder:**

```bash
GIT_SHA=$(git rev-parse --short HEAD)
ECR_URL=$(cd terraform/dev/foundation && terraform output -raw ecr_repository_url)
IMAGE_URI="${ECR_URL}:${GIT_SHA}"

# Authenticate
aws ecr get-login-password --region us-east-2 \
  | docker login --username AWS --password-stdin "${ECR_URL}"

# Pull arm64 base image and push to ECR
docker pull --platform linux/arm64 python:3.12-slim
docker tag python:3.12-slim "${IMAGE_URI}"
docker push "${IMAGE_URI}"

# Record the URI for the app layer
echo "agent_image_uri = \"${IMAGE_URI}\"" > terraform/dev/app/terraform.tfvars
```

---

## Real Agent Container Requirements

When real agent code replaces the placeholder, the container must:

1. **Target arm64** — `FROM --platform=linux/arm64 python:3.12-slim`
2. **Emit structured JSON logs to stdout** — required for CloudWatch ingestion
   (ADR-003). Use a logging config like:
   ```python
   import logging, json
   class JsonFormatter(logging.Formatter):
       def format(self, record):
           return json.dumps({
               "level": record.levelname,
               "message": record.getMessage(),
               "logger": record.name,
           })
   ```
3. **Read credentials from the environment via IRSA** — the runtime assumes
   `agentcore_role_arn`. No long-lived credentials in the image or environment
   variables (ADR-001).
4. **Read configuration from environment variables** — the runtime injects:
   - `BEDROCK_MODEL_ID` — primary model ARN
   - `SESSION_MEMORY_TABLE` — DynamoDB table for session memory
   - `AGENT_REGISTRY_TABLE` — DynamoDB agent registry table
   - `AGENT_ENV` — `dev`
   - `LOG_LEVEL` — `INFO`
   - `LOG_FORMAT` — `json`
5. **Listen on the port expected by AgentCore** — consult the AgentCore
   documentation for the runtime contract (HTTP endpoint, request/response
   schema).

---

## Rebuild and Redeploy Workflow

When agent code changes:

```bash
# 1. Build and push new image with new git SHA
GIT_SHA=$(git rev-parse --short HEAD)
ECR_URL=$(cd terraform/dev/foundation && terraform output -raw ecr_repository_url)
IMAGE_URI="${ECR_URL}:${GIT_SHA}"

aws ecr get-login-password --region us-east-2 \
  | docker login --username AWS --password-stdin "${ECR_URL}"

docker buildx build \
  --platform linux/arm64 \
  --push \
  -t "${IMAGE_URI}" .

# 2. Update app layer terraform.tfvars with the new URI
# Edit terraform/dev/app/terraform.tfvars:
#   agent_image_uri = "<new IMAGE_URI>"

# 3. Apply app layer — Terraform updates the runtime with the new image
cd terraform/dev/app
terraform apply
```
