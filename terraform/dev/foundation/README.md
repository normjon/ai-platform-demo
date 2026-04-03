# Foundation Layer — `terraform/dev/foundation/`

Long-lived platform infrastructure. Survives all platform, tool, and agent
destroy/apply cycles. Only destroy foundation when decommissioning the
environment entirely.

---

## Purpose

Foundation provides the infrastructure that every other layer depends on:

- **VPC and networking** — private subnets, security groups, VPC endpoints
  for Bedrock, CloudWatch, DynamoDB, and S3. All platform services run
  inside this VPC with no public internet exposure.
- **KMS encryption key** — single CMK used by platform storage (S3, DynamoDB,
  CloudWatch). Lives here so the key is never destroyed while encrypted data
  exists.
- **ECR repository** — stores the agent container image. Lives here so the
  image survives platform destroy/apply cycles.

Foundation does not contain IAM roles for platform services. IAM roles are
owned by the layer that uses them (platform/, tools/, agents/).

---

## Resources

| Module / Resource | What it creates |
| --- | --- |
| `module.networking` | VPC, 2 private subnets, route table, security group, 4 VPC endpoints |
| `module.kms` | KMS CMK + alias + key policy |
| `aws_ecr_repository.agent` | ECR repo for the HR Assistant container — IMMUTABLE tags |

### VPC Endpoints

| Endpoint | Type | Purpose |
| --- | --- | --- |
| `com.amazonaws.us-east-2.bedrock-runtime` | Interface | AgentCore model invocations stay within VPC |
| `com.amazonaws.us-east-2.logs` | Interface | CloudWatch log writes stay within VPC |
| `com.amazonaws.us-east-2.dynamodb` | Gateway | DynamoDB session memory stays within VPC |
| `com.amazonaws.us-east-2.s3` | Gateway | S3 reads/writes stay within VPC |

---

## Outputs (Platform API)

These outputs are consumed by the platform layer via `terraform_remote_state`.
Tools and agents do not read foundation outputs directly — they read from
platform, which re-exports them.

| Output | Description |
| --- | --- |
| `vpc_id` | VPC ID |
| `subnet_ids` | List of private subnet IDs |
| `agentcore_sg_id` | Security group ID for the AgentCore runtime |
| `storage_kms_key_arn` | KMS CMK ARN for storage encryption |
| `ecr_repository_url` | ECR repository URL — pass to platform as `agent_image_uri` |

---

## Prerequisites

- AWS CLI configured with SSO credentials for account `096305373014` in `us-east-2`.
  Run `awssandbox` to refresh if credentials have expired.
- Terraform >= 1.6 installed. Use `tfenv` — `brew install terraform` provides
  a deprecated version.
- Remote state bucket and lock table exist:
  - S3: `ai-platform-terraform-state-dev-096305373014`
  - DynamoDB: `ai-platform-terraform-lock-dev`

---

## First-Time Setup

```bash
cd terraform/dev/foundation

# One-time per machine
terraform init

# Create tfvars from example
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set account_id

terraform plan -out=tfplan
# Review plan — confirm only creates, no unexpected changes
terraform apply tfplan
```

---

## Pushing the Agent Container Image

The ECR repository provisioned here is the long-lived image store for
AgentCore agent containers. It lives in foundation so images survive
platform destroy/apply cycles — agents do not need to be rebuilt every
time platform is redeployed.

AgentCore validates that a container image exists in ECR at the moment
the runtime resource is created by Terraform. A valid arm64 image must
be present before running `terraform apply` in the platform layer. For
initial infrastructure validation, a plain `python:3.12-slim` placeholder
satisfies this requirement. See the agent layer README for the real
image build and push workflow.

After foundation apply, push an arm64 image to ECR before applying the
platform layer. The AgentCore runtime validates that the image exists at
create time.

```bash
GIT_SHA=$(git rev-parse --short HEAD)
ECR_URL=$(terraform output -raw ecr_repository_url)
IMAGE_URI="${ECR_URL}:${GIT_SHA}"

aws ecr get-login-password --region us-east-2 \
  | docker login --username AWS --password-stdin "${ECR_URL}"

# Placeholder image (for infrastructure validation before real agent is built)
docker pull --platform linux/arm64 python:3.12-slim
docker tag python:3.12-slim "${IMAGE_URI}"
docker push "${IMAGE_URI}"

echo "agent_image_uri = \"${IMAGE_URI}\""
# Copy this value into terraform/dev/platform/terraform.tfvars
```

See `docs/agent-container.md` for the real agent build workflow, arm64
requirement, and tag policy.

---

## Iterative Operations

Foundation is not part of the iterative destroy/apply cycle. It is applied
once and left running.

```bash
# Apply an incremental change (e.g. adding a VPC endpoint)
cd terraform/dev/foundation
terraform plan -out=tfplan
terraform apply tfplan
```

---

## Destroy

Only destroy foundation when decommissioning the environment entirely.
All other layers (platform, tools, agents) must be destroyed first.

```bash
# Verify all other layers are destroyed before proceeding
cd terraform/dev/foundation
terraform destroy -auto-approve
```

**Warning:** Destroying foundation deletes the KMS key (after the 30-day
deletion window), the VPC, and the ECR repository including all images.
This cannot be undone without re-pushing images.

---

## Observability

Foundation resources do not emit application logs. Monitor via:

- **ECR image scan results** — scan on push is enabled. Check the ECR console
  for vulnerability findings after each image push.
- **VPC Flow Logs** — not enabled by default. Enable on `module.networking.aws_vpc.this`
  if network-level debugging is needed.

---

## Known Issues

**VPC interface endpoint ENI cleanup takes 15-25 minutes on destroy**

The `bedrock-runtime` and `cloudwatch-logs` interface endpoints leave behind
Elastic Network Interfaces when deleted. Terraform polls up to ~20 minutes.
This is normal — wait or retry `terraform destroy -auto-approve`.

**AgentCore VPC-mode ENIs block subnet deletion**

After destroying the platform layer's AgentCore runtime, AWS releases the
`agentic_ai` ENIs asynchronously. If foundation destroy fails with
`DependencyViolation` on subnet deletion, wait 15-30 minutes and re-run
`terraform destroy -auto-approve`.
