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
# ADR-004: arm64 architecture. aws_xray_sdk is the only dependency and is pure
#          Python — no cross-compilation required (ADR-004 flag only for C extensions).
# ADR-001: Lambda execution role is passed in from the iam/ module (IRSA).
# ADR-003: Structured JSON logging to stdout.
# ---------------------------------------------------------------------------

# Install aws_xray_sdk into build/ then copy handler.py so the ZIP contains
# the SDK alongside the handler. aws_xray_sdk is pure Python — no
# cross-compilation required (ADR-004 platform flag only needed for C extensions).
resource "null_resource" "lambda_build" {
  triggers = {
    requirements = filemd5("${path.module}/requirements.txt")
    handler      = filemd5("${path.module}/handler.py")
  }

  provisioner "local-exec" {
    command = <<-CMD
      uv pip install \
        --target "${path.module}/build" \
        --quiet \
        -r "${path.module}/requirements.txt"
      cp "${path.module}/handler.py" "${path.module}/build/handler.py"
    CMD
  }
}

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/build"
  output_path = "${path.module}/glean-stub.zip"
  depends_on  = [null_resource.lambda_build]
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

  tracing_config {
    mode = "Active"
  }

  tags = var.tags
}

resource "aws_lambda_function_url" "glean_stub" {
  function_name      = aws_lambda_function.glean_stub.function_name
  authorization_type = "NONE"
}
