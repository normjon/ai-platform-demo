"""Direct-write CloudWatch Logs handler.

Bypasses AgentCore's stdout/stderr capture sidecar by writing log records
directly to CloudWatch Logs via boto3 PutLogEvents. The sidecar path for
the orchestrator runtime does not engage (stdout events never land in the
runtime log group), so this handler provides an independent diagnostic
channel for all application logging.

Design:
- One stream per container process: date + short host + pid
- Records buffered in a thread-safe queue
- Background daemon thread drains the queue every FLUSH_INTERVAL seconds
  (or sooner when the queue reaches BATCH_MAX_RECORDS)
- PutLogEvents failures are printed to sys.__stderr__ to avoid recursing
  back through the logger
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
import queue
import socket
import sys
import threading
import time

import boto3

from app import config

FLUSH_INTERVAL = 2.0
BATCH_MAX_RECORDS = 100
QUEUE_MAX_SIZE = 10000

_installed = False
_install_lock = threading.Lock()


class _CloudWatchLogsHandler(logging.Handler):
    def __init__(self, log_group: str, region: str) -> None:
        super().__init__()
        self._log_group = log_group
        self._client = boto3.client("logs", region_name=region)
        self._queue: queue.Queue[dict] = queue.Queue(maxsize=QUEUE_MAX_SIZE)
        self._stream = self._build_stream_name()
        self._ensure_stream()
        self._stop = threading.Event()
        self._worker = threading.Thread(
            target=self._drain_loop,
            name="cwlogs-drain",
            daemon=True,
        )
        self._worker.start()

    @staticmethod
    def _build_stream_name() -> str:
        host = socket.gethostname()[:12]
        return f"{dt.datetime.utcnow().strftime('%Y-%m-%d')}-{host}-{os.getpid()}"

    def _ensure_stream(self) -> None:
        try:
            self._client.create_log_stream(
                logGroupName=self._log_group,
                logStreamName=self._stream,
            )
        except self._client.exceptions.ResourceAlreadyExistsException:
            pass
        except Exception as exc:
            print(f"cwlogs: create_log_stream failed: {exc}", file=sys.__stderr__)

    def emit(self, record: logging.LogRecord) -> None:
        try:
            msg = self.format(record)
            event = {
                "timestamp": int(record.created * 1000),
                "message": msg,
            }
            self._queue.put_nowait(event)
        except queue.Full:
            pass
        except Exception:
            pass

    def _drain_loop(self) -> None:
        while not self._stop.is_set():
            batch: list[dict] = []
            deadline = time.monotonic() + FLUSH_INTERVAL
            while time.monotonic() < deadline and len(batch) < BATCH_MAX_RECORDS:
                timeout = max(0.0, deadline - time.monotonic())
                try:
                    event = self._queue.get(timeout=timeout)
                except queue.Empty:
                    break
                batch.append(event)
            if batch:
                batch.sort(key=lambda e: e["timestamp"])
                try:
                    self._client.put_log_events(
                        logGroupName=self._log_group,
                        logStreamName=self._stream,
                        logEvents=batch,
                    )
                except Exception as exc:
                    print(f"cwlogs: put_log_events failed ({len(batch)} records): {exc}", file=sys.__stderr__)


def install() -> None:
    """Install the handler on the root logger. Idempotent."""
    global _installed
    with _install_lock:
        if _installed:
            return
        try:
            handler = _CloudWatchLogsHandler(
                log_group=config.APP_LOG_GROUP,
                region=config.AWS_REGION,
            )
            handler.setFormatter(logging.Formatter("%(message)s"))
            handler.setLevel(logging.DEBUG)
            root = logging.getLogger()
            root.addHandler(handler)
            if root.level > logging.INFO or root.level == logging.NOTSET:
                root.setLevel(logging.INFO)
            _installed = True
            print(
                f"cwlogs: handler installed (group={config.APP_LOG_GROUP})",
                file=sys.__stderr__,
            )
        except Exception as exc:
            print(f"cwlogs: install failed: {exc}", file=sys.__stderr__)
