#!/usr/bin/env python3
"""
Create the hr-policies-index vector index in OpenSearch Serverless.

Called from Terraform null_resource local-exec after the collection is ACTIVE
and the data access policy has propagated (60s sleep in caller).

Idempotent — silently succeeds if the index already exists.

Usage:
    python3 create-os-index.py <collection_endpoint> <region>

Dependencies (injected by uv run --with boto3 --with opensearch-py):
    boto3, opensearch-py
"""

import sys

import boto3
from opensearchpy import AWSV4SignerAuth, OpenSearch, RequestsHttpConnection


def main() -> None:
    if len(sys.argv) < 3:
        print("Usage: create-os-index.py <collection_endpoint> <region>", file=sys.stderr)
        sys.exit(1)

    endpoint = sys.argv[1].rstrip("/")
    region = sys.argv[2]
    index_name = "hr-policies-index"

    host = endpoint.replace("https://", "")

    credentials = boto3.Session().get_credentials()
    auth = AWSV4SignerAuth(credentials, region, "aoss")

    client = OpenSearch(
        hosts=[{"host": host, "port": 443}],
        http_auth=auth,
        use_ssl=True,
        verify_certs=True,
        connection_class=RequestsHttpConnection,
        timeout=60,
    )

    # Titan Embed Text v2 produces 1024-dimension vectors.
    # HNSW with faiss engine — matches Bedrock KB default configuration.
    index_body = {
        "settings": {
            "index": {
                "knn": True,
                "knn.algo_param.ef_search": 512,
            }
        },
        "mappings": {
            "properties": {
                "embedding": {
                    "type": "knn_vector",
                    "dimension": 1024,
                    "method": {
                        "name": "hnsw",
                        "engine": "faiss",
                        "space_type": "l2",
                        "parameters": {
                            "ef_construction": 512,
                            "m": 16,
                        },
                    },
                },
                "text": {"type": "text"},
                "metadata": {"type": "text"},
            }
        },
    }

    if client.indices.exists(index=index_name):
        print(f"Index '{index_name}' already exists — skipping creation.")
        return

    response = client.indices.create(index=index_name, body=index_body)
    print(f"Index '{index_name}' created successfully: {response}")


if __name__ == "__main__":
    main()
