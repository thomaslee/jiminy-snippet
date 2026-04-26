"""Helpers for shaping a tool's event stream into Server-Sent Events bytes."""

from __future__ import annotations

import json
import time
from typing import Iterable

from .runner import CommandSpawnFailed, CommandTimedOut


class ToolError(RuntimeError):
    """Raised by a tool to terminate the stream with an SSE ``error`` event."""


def format_event(event: str, data: dict) -> bytes:
    return f"event: {event}\ndata: {json.dumps(data)}\n\n".encode("utf-8")


def stream(events: Iterable[tuple[str, dict]]) -> Iterable[bytes]:
    """Wrap a tool's (event, data) iterator with terminal ``end`` / ``error``.

    The tool yields whatever events it likes (stdout, stderr, heartbeat, step,
    info, …). This generator forwards them as SSE bytes and then appends
    exactly one terminal event:

      - ``end``   on normal completion
      - ``error`` if the tool raises ToolError, CommandTimedOut, or
                  CommandSpawnFailed
    """
    start = time.monotonic()
    try:
        for event, data in events:
            yield format_event(event, data)
    except CommandTimedOut as exc:
        yield format_event("error", {
            "error": "command timed out",
            "command": exc.args[0],
            "timeout_seconds": exc.timeout,
            "duration_seconds": round(time.monotonic() - start, 3),
        })
        return
    except CommandSpawnFailed as exc:
        yield format_event("error", {
            "error": str(exc),
            "duration_seconds": round(time.monotonic() - start, 3),
        })
        return
    except ToolError as exc:
        yield format_event("error", {
            "error": str(exc),
            "duration_seconds": round(time.monotonic() - start, 3),
        })
        return
    yield format_event("end", {"duration_seconds": round(time.monotonic() - start, 3)})
