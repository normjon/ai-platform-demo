# Module: kms

Platform storage encryption key. Lives in the foundation layer.

## Purpose

Creates a single KMS Customer Managed Key (CMK) used by the platform layer
to encrypt S3 buckets, DynamoDB tables, and CloudWatch log groups.

The key is placed in the foundation layer — not the platform layer — because
it must survive platform, tools, and agents destroy/apply cycles. Versioned
S3 buckets retain object versions after bucket deletion; those versions cannot
be decrypted if the key is destroyed while data is in place.

## Resources

| Resource | Purpose |
| --- | --- |
| `aws_kms_key.storage` | CMK — 30-day deletion window, automatic key rotation enabled. |
| `aws_kms_alias.storage` | Human-readable alias: `alias/<project>-<env>-storage`. |
| `aws_kms_key_policy.storage` | Root account IAM delegation + CloudWatch Logs service grant. |

## Key Policy

Two statements are required:

1. **Root account delegation** — Without this, no IAM policy can grant access
   to the key. AWS requires the root account statement on all CMKs.

2. **CloudWatch Logs service principal** — CloudWatch requires an explicit key
   policy grant to encrypt log groups. IAM policies alone are not sufficient
   for the `logs.<region>.amazonaws.com` service principal.

## Consumed by

- `terraform/dev/foundation/` — creates this module and exports `storage_kms_key_arn`
- `terraform/dev/platform/` — reads `storage_kms_key_arn` from foundation remote state,
  passes it to `modules/storage` and `modules/observability`

## History

This module was extracted from `modules/iam/` during the four-layer restructure
(foundation / platform / tools / agents). The `modules/iam/` directory is
retained for git history but contains no active resources.
