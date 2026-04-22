# Stub Agent — Dev

Deterministic echo sub-agent used to validate registry-driven dispatch in the
orchestrator. Given `{"prompt": "Hello"}`, returns
`{"response": "[stub-agent] received: Hello"}`.

This exists so "routing" in the orchestrator can be tested against more than
one tenant. Without this layer, the orchestrator has only
`hr-assistant-strands-dev` to dispatch to, and the registry's routing logic is
untested.

See [CLAUDE.md](./CLAUDE.md) for implementation notes and
[../../../specs/orchestrator-plan.md](../../../specs/orchestrator-plan.md)
Phase O.4 for the authoritative design.

## Apply

Two-step apply. The runtime + registry entry are count-gated on
`agent_image_uri`; during the initial apply, leave it empty to create just the
ECR repository and IAM role. Push the image, then re-apply to land the runtime.

```bash
cd terraform/dev/agents/stub-agent

# Apply 1 — scaffold
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars, leave agent_image_uri = ""
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# Build and push container
cd container
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com/ai-platform-dev-stub-agent"
GIT_SHA=$(git rev-parse --short HEAD)

aws ecr-public get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin public.ecr.aws
aws ecr get-login-password --region us-east-2 | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com"

docker build --platform linux/arm64 -t "${ECR_URI}:stub-${GIT_SHA}" .
docker push "${ECR_URI}:stub-${GIT_SHA}"

cd ..
# Apply 2 — enable runtime
# Edit terraform.tfvars, set agent_image_uri = "${ECR_URI}:stub-${GIT_SHA}"
terraform plan -out=tfplan
terraform apply tfplan
```

## Invoke directly

```bash
RUNTIME_ARN=$(terraform output -raw agentcore_runtime_arn)
SESSION_ID="stub-$(uuidgen | tr -d '-')"
PAYLOAD=$(python3 -c "import json, base64; print(base64.b64encode(json.dumps({'prompt': 'Hello', 'sessionId': '${SESSION_ID}'}).encode()).decode())")

aws bedrock-agentcore invoke-agent-runtime \
  --region us-east-2 \
  --agent-runtime-arn "${RUNTIME_ARN}" \
  --runtime-session-id "${SESSION_ID}" \
  --payload "${PAYLOAD}" \
  /dev/stdout
```

## Invoke via orchestrator

Once the stub is registered, the orchestrator discovers it on the next cache
miss (60s TTL). Any prompt that clearly requests an echo test routes to it:

```bash
ORCH_ARN=$(cd ../orchestrator && terraform output -raw agentcore_runtime_arn)
SESSION_ID="stub-orch-$(uuidgen | tr -d '-')"
PAYLOAD=$(python3 -c "import json, base64; print(base64.b64encode(json.dumps({'prompt': 'Echo test: ping', 'sessionId': '${SESSION_ID}'}).encode()).decode())")

aws bedrock-agentcore invoke-agent-runtime \
  --region us-east-2 \
  --agent-runtime-arn "${ORCH_ARN}" \
  --runtime-session-id "${SESSION_ID}" \
  --payload "${PAYLOAD}" \
  /dev/stdout
```

## Smoke tests

```bash
./smoke-test.sh
```

Runs two tests: direct echo assertion and CloudWatch `stub_invoke` log
presence. The orchestrator-side dispatch assertion lives in the orchestrator
layer's `smoke-test.sh`.

## Teardown

```bash
# Purge ECR images first (repo is IMMUTABLE with no delete-on-destroy)
aws ecr list-images --region us-east-2 --repository-name ai-platform-dev-stub-agent \
  --query 'imageIds[*]' --output json | \
  jq -c '.[]' | while read -r id; do
    aws ecr batch-delete-image --region us-east-2 \
      --repository-name ai-platform-dev-stub-agent \
      --image-ids "${id}" >/dev/null
  done

terraform destroy -auto-approve
```
