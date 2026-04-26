#!/usr/bin/env python3
"""
Tool server for the Claude Code sandbox.

Runs on the macOS host and exposes a small HTTP API that lets the sandboxed
agent invoke a fixed allowlist of host-side commands (e.g. `xcodebuild`) that
aren't reachable from inside the Linux container.

Usage (on the host):

    python3 devscripts/toolserver.py
    # or, to bind to a specific interface/port:
    python3 devscripts/toolserver.py --host 127.0.0.1 --port 8765

From the sandbox:

    curl -N -s -X POST http://host.docker.internal:8765/run \
        -H 'Content-Type: application/json' \
        -d '{"command": "xcodebuild", "args": ["-list"]}'

The response is always a Server-Sent Events stream:

    event: stdout
    data: {"data": "Compile Foo.swift\n"}

    event: stderr
    data: {"data": "warning: ...\n"}

    event: heartbeat
    data: {"elapsed_seconds": 20.0}

    event: end
    data: {"exit_code": 0, "duration_seconds": 12.3, "cwd": "..."}

A `heartbeat` event is emitted whenever 20s pass with no output, so the
client can tell the connection is still alive. Errors (timeout, spawn
failure) arrive as `event: error` instead of `end`.

Security notes:
  - Only commands listed in ALLOWED_COMMANDS may be invoked. Each command is
    executed directly (no shell), so argument quoting/expansion does not
    happen on the server side.
  - The server binds to 0.0.0.0 by default so it accepts requests from the
    Docker bridge (host.docker.internal -> 192.168.65.254). Pass
    `--host 127.0.0.1` to restrict to loopback.
  - Working directory defaults to the repo root (parent of this file). Pass
    `cwd` in the request body to override, but it must resolve inside the
    repo root.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# Commands the sandbox is allowed to invoke. Add to this list deliberately —
# anything here can be run with arbitrary arguments by the sandbox.
ALLOWED_COMMANDS = {
    "xcodebuild",
    "xcrun",
    "swift",
    "swiftc",
    "simctl",
}

# Repo root = parent directory of devscripts/.
REPO_ROOT = Path(__file__).resolve().parent.parent

# Per-request timeout for the subprocess. Builds can be slow; tune as needed.
DEFAULT_TIMEOUT_SECONDS = 600

# Idle interval after which a streaming response emits a `heartbeat` event so
# the client knows the subprocess is still alive (e.g. mid-link in a long
# build phase).
HEARTBEAT_INTERVAL_SECONDS = 20.0


def resolve_cwd(requested: str | None) -> Path:
    if not requested:
        return REPO_ROOT
    candidate = (REPO_ROOT / requested).resolve() if not os.path.isabs(requested) else Path(requested).resolve()
    # Refuse paths outside the repo root.
    try:
        candidate.relative_to(REPO_ROOT)
    except ValueError as exc:
        raise ValueError(f"cwd {candidate} is outside repo root {REPO_ROOT}") from exc
    if not candidate.is_dir():
        raise ValueError(f"cwd {candidate} is not a directory")
    return candidate


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send_json(200, {
                "ok": True,
                "allowed_commands": sorted(ALLOWED_COMMANDS),
                "repo_root": str(REPO_ROOT),
            })
            return
        self._send_json(404, {"error": f"unknown path {self.path}"})

    def do_POST(self) -> None:
        if self.path != "/run":
            self._send_json(404, {"error": f"unknown path {self.path}"})
            return

        parsed = self._parse_run_request()
        if parsed is None:
            return  # error response already sent

        self._run_streaming(**parsed)

    def _parse_run_request(self) -> dict | None:
        """Validate the /run JSON body. Returns kwargs for the runner, or
        None after sending an error response."""
        length = int(self.headers.get("Content-Length", "0"))
        try:
            raw = self.rfile.read(length) if length > 0 else b"{}"
            req = json.loads(raw.decode("utf-8") or "{}")
        except (ValueError, UnicodeDecodeError) as exc:
            self._send_json(400, {"error": f"invalid JSON: {exc}"})
            return None

        command = req.get("command")
        if not isinstance(command, str) or not command:
            self._send_json(400, {"error": "missing 'command' string"})
            return None
        if command not in ALLOWED_COMMANDS:
            self._send_json(403, {
                "error": f"command {command!r} is not in the allowlist",
                "allowed_commands": sorted(ALLOWED_COMMANDS),
            })
            return None

        args = req.get("args", [])
        if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
            self._send_json(400, {"error": "'args' must be a list of strings"})
            return None

        try:
            cwd = resolve_cwd(req.get("cwd"))
        except ValueError as exc:
            self._send_json(400, {"error": str(exc)})
            return None

        timeout = req.get("timeout_seconds", DEFAULT_TIMEOUT_SECONDS)
        if not isinstance(timeout, (int, float)) or timeout <= 0:
            self._send_json(400, {"error": "'timeout_seconds' must be a positive number"})
            return None

        executable = shutil.which(command)
        if executable is None:
            self._send_json(404, {"error": f"command {command!r} not found on PATH"})
            return None

        env = os.environ.copy()
        # Allow the caller to add/override env vars (handy for things like
        # DEVELOPER_DIR), but never let them inherit secrets they didn't ask for.
        extra_env = req.get("env", {})
        if not isinstance(extra_env, dict) or not all(
            isinstance(k, str) and isinstance(v, str) for k, v in extra_env.items()
        ):
            self._send_json(400, {"error": "'env' must be a {string: string} object"})
            return None
        env.update(extra_env)

        return {
            "executable": executable,
            "args": args,
            "cwd": cwd,
            "env": env,
            "timeout": timeout,
        }

    def _run_streaming(self, executable: str, args: list[str], cwd: Path,
                       env: dict, timeout: float) -> None:
        """Stream subprocess output as Server-Sent Events.

        Output lines arrive as `stdout`/`stderr` events. Every
        HEARTBEAT_INTERVAL_SECONDS of silence yields a `heartbeat`. The
        stream ends with a single `end` (success/non-zero exit) or `error`
        (timeout, spawn failure, broken connection) event."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        # Force connection close so the client reads to EOF; avoids needing
        # explicit chunked transfer encoding under HTTP/1.0.
        self.send_header("Connection", "close")
        self.end_headers()

        def emit(event: str, data: dict) -> bool:
            payload = f"event: {event}\ndata: {json.dumps(data)}\n\n".encode("utf-8")
            try:
                self.wfile.write(payload)
                self.wfile.flush()
                return True
            except (BrokenPipeError, ConnectionResetError, OSError):
                return False

        start = time.monotonic()
        try:
            proc = subprocess.Popen(
                [executable, *args],
                cwd=str(cwd),
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,  # line-buffered
            )
        except OSError as exc:
            emit("error", {"error": f"failed to spawn process: {exc}"})
            return

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

        deadline = start + timeout
        eof_seen = 0
        timed_out = False
        client_gone = False

        while eof_seen < 2:
            now = time.monotonic()
            remaining = deadline - now
            if remaining <= 0:
                timed_out = True
                break
            try:
                stream_name, item = events.get(timeout=min(HEARTBEAT_INTERVAL_SECONDS, remaining))
            except queue.Empty:
                if not emit("heartbeat", {"elapsed_seconds": round(time.monotonic() - start, 3)}):
                    client_gone = True
                    break
                continue
            if item is EOF:
                eof_seen += 1
                continue
            if not emit(stream_name, {"data": item}):
                client_gone = True
                break

        if timed_out or client_gone:
            proc.kill()
        try:
            exit_code = proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            exit_code = proc.wait()

        if client_gone:
            return  # nothing to send to
        duration = time.monotonic() - start
        if timed_out:
            emit("error", {
                "error": "command timed out",
                "timeout_seconds": timeout,
                "duration_seconds": round(duration, 3),
            })
        else:
            emit("end", {
                "exit_code": exit_code,
                "duration_seconds": round(duration, 3),
                "cwd": str(cwd),
            })

    def log_message(self, format: str, *args) -> None:
        sys.stderr.write("[toolserver] %s - %s\n" % (self.address_string(), format % args))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="0.0.0.0",
                        help="Interface to bind (default: 0.0.0.0; use 127.0.0.1 to restrict to loopback)")
    parser.add_argument("--port", type=int, default=8765, help="Port to listen on (default: 8765)")
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"toolserver listening on http://{args.host}:{args.port}", file=sys.stderr)
    print(f"repo root: {REPO_ROOT}", file=sys.stderr)
    print(f"allowed commands: {', '.join(sorted(ALLOWED_COMMANDS))}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
