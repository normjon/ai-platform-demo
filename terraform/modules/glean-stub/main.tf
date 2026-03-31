# ---------------------------------------------------------------------------
# Glean MCP Stub — Lambda + Function URL
#
# Provides a real HTTPS MCP endpoint for the AgentCore MCP Gateway target
# in the dev environment. The gateway validates live connectivity at target
# create time so a real endpoint is required.
#
# This stub returns mock search results. Replace the gateway target endpoint
# value with the real Glean MCP URL when it becomes available — no Lambda
# or module changes are required.
#
# ADR-004: arm64 architecture. No native Python dependencies so cross-compile
#          is not required — the standard Lambda runtime handles pure Python.
# ADR-001: Lambda execution role is passed in from the iam/ module (IRSA).
# ADR-003: Structured JSON logging to stdout.
# ---------------------------------------------------------------------------

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/handler.py"
  output_path = "${path.module}/glean-stub.zip"
}

resource "aws_lambda_function" "glean_stub" {
  function_name    = "${var.name_prefix}-glean-stub"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  handler          = "handler.handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  role             = var.lambda_role_arn
  timeout          = 30
  description      = "Glean MCP stub - returns mock search results for dev environment testing."

  environment {
    variables = {
      LOG_LEVEL  = "INFO"
      LOG_FORMAT = "json"
    }
  }

  tags = var.tags
}

resource "aws_lambda_function_url" "glean_stub" {
  function_name      = aws_lambda_function.glean_stub.function_name
  authorization_type = "NONE"
}
