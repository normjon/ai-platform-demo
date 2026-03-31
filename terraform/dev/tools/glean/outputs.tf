output "glean_stub_url" {
  description = "Lambda Function URL for the Glean stub MCP server."
  value       = module.glean_stub.function_url
}

output "gateway_target_id" {
  description = "ID of the Glean gateway target registered with the MCP gateway."
  value       = aws_bedrockagentcore_gateway_target.glean_stub.target_id
}
