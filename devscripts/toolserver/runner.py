"""Subprocess execution as a stream of SSE-shaped events."""

from __future__ import annotations

import os
import queue
import subprocess
import threading
import time
from pathlib import Path
from typing import Generator

HEARTBEAT_INTERVAL_SECONDS = 20.0


class CommandTimedOut(RuntimeError):
    def __init__(self, args: list[str], timeout: float) -> None:
        self.args = args
        self.timeout = timeout
        super().__init__(f"command timed out after {timeout}s: {args[0]}")


class CommandSpawnFailed(RuntimeError):
    def __init__(self, args: list[str], cause: Exception) -> None:
        self.args = args
        self.cause = cause
        super().__init__(f"failed to spawn {args[0]!r}: {cause}")


def run_command(
    args: list[str],
    cwd: Path,
    timeout: float,
    env: dict[str, str] | None = None,
) -> Generator[tuple[str, dict], None, int]:
    """Run a single subprocess; yield (event, data) tuples; return its exit code.

    Yielded events:
      ("stdout",    {"data": "<line>\n"})
      ("stderr",    {"data": "<line>\n"})
      ("heartbeat", {"elapsed_seconds": <float>})

    Raises CommandTimedOut if the deadline passes; CommandSpawnFailed if the
    process can't be launched. The exit code is returned via StopIteration —
    callers should use ``exit_code = yield from run_command(...)``.
    """
    proc_env = os.environ.copy()
    if env:
        proc_env.update(env)
    try:
        proc = subprocess.Popen(
            args,
            cwd=str(cwd),
            env=proc_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
    except OSError as exc:
        raise CommandSpawnFailed(args, exc) from exc

    events: queue.Queue = queue.Queue()
    EOF = object()

    def pump(stream, name: str) -> None:
        try:
            for line in iter(stream.readline, ""):
                events.put((name, line))
        finally:
            events.put((name, EOF))
            stream.close()

    threading.Thread(target=pump, args=(proc.stdout, "stdout"), daemon=True).start()
    threading.Thread(target=pump, args=(proc.stderr, "stderr"), daemon=True).start()

    start = time.monotonic()
    deadline = start + timeout
    eof_seen = 0
    timed_out = False

    while eof_seen < 2:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            timed_out = True
            break
        try:
            stream_name, item = events.get(timeout=min(HEARTBEAT_INTERVAL_SECONDS, remaining))
        except queue.Empty:
            yield ("heartbeat", {"elapsed_seconds": round(time.monotonic() - start, 3)})
            continue
        if item is EOF:
            eof_seen += 1
            continue
        yield (stream_name, {"data": item})

    if timed_out:
        proc.kill()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        raise CommandTimedOut(args, timeout)

    return proc.wait()
