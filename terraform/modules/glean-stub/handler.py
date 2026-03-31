"""
Glean MCP Stub — Lambda-backed MCP server for dev environment testing.

Implements just enough of the MCP JSON-RPC protocol for the AgentCore MCP
Gateway to register this as a READY target and for the HR Assistant agent
to execute a test tool call through the full infrastructure path.

Replace this stub by updating the gateway target endpoint to the real Glean
MCP URL once a live Glean endpoint is available. No infrastructure changes
are required — only the gateway target endpoint value changes.

MCP protocol reference: https://spec.modelcontextprotocol.io
"""

import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TOOLS = [
    {
        "name": "search",
        "description": (
            "Search Glean enterprise knowledge base for documents, policies, "
            "and information across all indexed organisational systems. "
            "Results respect the caller's permissions."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Natural language search query."
                },
                "maxResults": {
                    "type": "integer",
                    "description": "Maximum number of results to return. Defaults to 5.",
                    "default": 5
                }
            },
            "required": ["query"]
        }
    }
]


def _ok(request_id, result):
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result})
    }


def _error(request_id, code, message):
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": code, "message": message}
        })
    }


def handler(event, context):
    logger.info(json.dumps({
        "level": "INFO",
        "message": "MCP request received",
        "method": event.get("requestContext", {}).get("http", {}).get("method"),
        "path": event.get("rawPath"),
    }))

    raw_body = event.get("body", "{}")
    try:
        body = json.loads(raw_body)
    except (json.JSONDecodeError, TypeError):
        return _error(None, -32700, "Parse error")

    method = body.get("method", "")
    request_id = body.get("id")

    if method == "initialize":
        # Echo the client's requested protocol version so the stub is
        # version-agnostic. The AgentCore gateway controls the negotiation.
        params = body.get("params", {})
        client_version = params.get("protocolVersion", "2024-11-05")
        result = {
            "protocolVersion": client_version,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "glean-stub", "version": "1.0.0"}
        }
        return _ok(request_id, result)

    if method == "notifications/initialized":
        # Notification — no JSON-RPC response body required.
        return {"statusCode": 200, "body": ""}

    if method == "tools/list":
        return _ok(request_id, {"tools": TOOLS})

    if method == "tools/call":
        params = body.get("params", {})
        tool_name = params.get("name", "")
        args = params.get("arguments", {})

        if tool_name != "search":
            return _error(request_id, -32602, f"Unknown tool: {tool_name}")

        query = args.get("query", "")
        max_results = min(int(args.get("maxResults", 5)), 10)

        mock_results = "\n\n".join([
            f"{i + 1}. [STUB] {query} — Mock Document {chr(64 + i + 1)}\n"
            f"   This is a placeholder result from the Glean stub Lambda. "
            f"Replace the gateway target endpoint with the real Glean MCP URL "
            f"to receive live, permissions-aware results."
            for i in range(max_results)
        ])

        logger.info(json.dumps({
            "level": "INFO",
            "message": "tool_call",
            "tool": "search",
            "query": query,
            "max_results": max_results,
        }))

        return _ok(request_id, {
            "content": [{"type": "text", "text": mock_results}]
        })

    return _error(request_id, -32601, f"Method not found: {method}")
