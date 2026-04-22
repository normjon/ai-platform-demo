# Stub-agent container — arm64/Graviton (ADR-004)
# Deterministic echo only. No Strands, no Bedrock, no AWS SDK runtime calls.
# Port: 8080 (AgentCore default)

FROM --platform=linux/arm64 public.ecr.aws/docker/library/python:3.12-slim AS builder

WORKDIR /build

RUN pip install --no-cache-dir uv==0.5.21

COPY requirements.txt .

RUN uv pip install \
    --python-platform aarch64-manylinux2014 \
    --python-version "3.12" \
    --target=/build/deps \
    --only-binary=:all: \
    -r requirements.txt

# ---------------------------------------------------------------------------
# Runtime image
# ---------------------------------------------------------------------------

FROM --platform=linux/arm64 public.ecr.aws/docker/library/python:3.12-slim

WORKDIR /app

COPY --from=builder /build/deps /app/deps
COPY app/ /app/app/

ENV PYTHONPATH=/app/deps
ENV PORT=8080

EXPOSE 8080

RUN useradd -m -u 1000 agent
USER agent

CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log", "--log-level", "warning"]
