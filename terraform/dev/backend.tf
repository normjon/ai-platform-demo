terraform {
  backend "s3" {
    # Replace <account-id> with your AWS account ID before running terraform init.
    # The S3 bucket and DynamoDB table must be created manually first — see CLAUDE.md.
    bucket         = "ai-platform-terraform-state-dev-<account-id>"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "ai-platform-terraform-lock-dev"
    encrypt        = true
  }
}
