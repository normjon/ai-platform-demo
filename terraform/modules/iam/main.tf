# ---------------------------------------------------------------------------
# DEPRECATED — This module has been removed as part of the four-layer
# restructure (foundation / platform / tools / agents).
#
# KMS key management moved to:  modules/kms/
#
# IAM role management is now inline in each deployment layer (Option B):
#   Platform roles (AgentCore runtime, Bedrock KB):  terraform/dev/platform/main.tf
#   Tool roles (e.g. Glean Lambda):                  terraform/dev/tools/<tool>/main.tf
#   Agent roles:                                     terraform/dev/agents/<agent>/main.tf
#
# This directory is retained to preserve git history. It contains no active
# Terraform resources and will produce zero-resource plans if initialised.
# ---------------------------------------------------------------------------
