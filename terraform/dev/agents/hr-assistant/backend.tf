terraform {
  backend "s3" {
    bucket         = "ai-platform-terraform-state-dev-096305373014"
    key            = "dev/agents/hr-assistant/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "ai-platform-terraform-lock-dev"
    encrypt        = true
  }
}
