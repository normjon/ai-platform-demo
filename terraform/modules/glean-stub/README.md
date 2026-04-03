# Module: glean-stub

Lambda-backed MCP server stub for the dev environment. Provides a real HTTPS
endpoint for the AgentCore MCP Gateway target so the Glean Search tool can be
registered as READY and exercised end-to-end without a live Glean connection.

## Purpose

The AgentCore MCP Gateway validates live connectivity to any registered target
at create time. A placeholder URL always fails with "Failed to connect and
fetch tools from the provided MCP target server." This module provides a real
HTTPS endpoint backed by a Lambda function that implements the MCP JSON-RPC
protocol and returns mock search results.

When a real Glean MCP endpoint is available, update only the gateway target
endpoint value — this module and Lambda do not need to change.

## Resources

| Resource | Purpose |
| --- | --- |
| `aws_lambda_function.glean_stub` | arm64 Python 3.12 Lambda. Handles MCP `initialize`, `tools/list`, `tools/call`. |
| `aws_lambda_function_url.glean_stub` | Public HTTPS endpoint (`authorization_type = NONE`). Required for the gateway to reach the stub. |

## MCP Protocol Handled

| Method | Response |
| --- | --- |
| `initialize` | Returns protocol version `2024-11-05` and tool capabilities |
| `notifications/initialized` | Returns HTTP 200 empty body (notification, no JSON-RPC response) |
| `tools/list` | Returns the `search` tool with its input schema |
| `tools/call` (search) | Returns numbered mock results containing the query text |

## Transitioning to Real Glean

When a live Glean MCP endpoint is ready:

1. Verify the endpoint responds correctly to `tools/list`:
   ```bash
   curl -s -X POST https://<glean-endpoint> \
     -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq .
   ```

2. Delete the stub gateway target:
   ```bash
   GATEWAY_ID=$(cd terraform/dev/app && terraform output -raw agentcore_gateway_id)
   aws bedrock-agentcore-control delete-gateway-target \
     --gateway-identifier "${GATEWAY_ID}" \
     --target-id <stub-target-id> \
     --region us-east-2
   ```

3. Update `terraform/dev/app/main.tf` — change the gateway target `endpoint`
   from `module.glean_stub.function_url` to the real Glean URL.

4. Apply the app layer. The new target will be registered against the real endpoint.

5. Remove this module call from `app/main.tf` once the real target is verified READY.

## Security Notes

- `authorization_type = NONE` makes the Function URL publicly accessible.
  This is intentional for a stub returning mock data. The real Glean endpoint
  will use proper authentication configured at the Glean side.
- The Lambda execution role is scoped to the minimum permissions required
  (Bedrock Haiku invocation, S3, DynamoDB) — it cannot access production data.
- The stub returns only static mock text — no real data, no external calls.
