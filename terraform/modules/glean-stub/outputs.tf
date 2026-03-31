output "function_url" {
  description = "HTTPS Function URL for the Glean stub MCP server. Used as the gateway target endpoint."
  value       = aws_lambda_function_url.glean_stub.function_url
}

output "function_name" {
  description = "Lambda function name."
  value       = aws_lambda_function.glean_stub.function_name
}
