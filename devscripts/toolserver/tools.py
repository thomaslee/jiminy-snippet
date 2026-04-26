"""Tool definitions exposed by the server: ``build`` and ``install``."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator

from . import runner
from .sse import ToolError

Event = tuple[str, dict]


class BadRequest(ValueError):
    """Raised by a tool's ``validate`` to reject the request body (HTTP 400)."""


@dataclass(frozen=True)
class Tool:
    name: str
    summary: str           # one-liner for GET /tools
    documentation: str     # text/plain doc for GET /tools/<name>
    validate: Callable[[dict], dict]
    run: Callable[[dict, Path], Iterator[Event]]


# ---- shared helpers ---------------------------------------------------------

VALID_CONFIGURATIONS = ("Debug", "Release")


def _require_configuration(payload: dict) -> str:
    config = payload.get("configuration", "Debug")
    if config not in VALID_CONFIGURATIONS:
        raise BadRequest(
            f"'configuration' must be one of {list(VALID_CONFIGURATIONS)}, got {config!r}"
        )
    return config


def _require_positive_number(payload: dict, key: str, default: float) -> float:
    value = payload.get(key, default)
    if not isinstance(value, (int, float)) or isinstance(value, bool) or value <= 0:
        raise BadRequest(f"'{key}' must be a positive number")
    return float(value)


def _built_app_path(repo_root: Path, configuration: str) -> Path:
    return repo_root / "build" / "Build" / "Products" / configuration / "jiminy-snippet.app"


# ---- build ------------------------------------------------------------------

VALID_BUILD_ACTIONS = ("build", "clean", "test")


def _validate_build(payload: dict) -> dict:
    config = _require_configuration(payload)
    action = payload.get("action", "build")
    if action not in VALID_BUILD_ACTIONS:
        raise BadRequest(
            f"'action' must be one of {list(VALID_BUILD_ACTIONS)}, got {action!r}"
        )
    timeout = _require_positive_number(payload, "timeout_seconds", 1800)
    return {"configuration": config, "action": action, "timeout_seconds": timeout}


def _run_build(validated: dict, repo_root: Path) -> Iterator[Event]:
    config = validated["configuration"]
    action = validated["action"]
    args = [
        "xcodebuild",
        "-project", "jiminy-snippet.xcodeproj",
        "-scheme", "jiminy-snippet",
        "-configuration", config,
        "-destination", "platform=macOS",
        "-derivedDataPath", "build",
        action,
    ]
    yield ("step", {"command": args, "cwd": str(repo_root)})
    exit_code = yield from runner.run_command(args, cwd=repo_root, timeout=validated["timeout_seconds"])
    if exit_code != 0:
        raise ToolError(f"xcodebuild {action} exited with status {exit_code}")
    if action == "build":
        yield ("info", {"app_path": str(_built_app_path(repo_root, config))})


BUILD_DOC = """\
build — invoke xcodebuild for the jiminy-snippet macOS app.

GET  /tools/build                 — this documentation
POST /tools/build                 — run xcodebuild; response is text/event-stream

Request body (JSON; all fields optional):
  {
    "configuration":   "Debug" | "Release",        # default: "Debug"
    "action":          "build" | "clean" | "test", # default: "build"
    "timeout_seconds": <positive number>           # default: 1800
  }

Response (Server-Sent Events):
  event: step       — {"command": [...], "cwd": "..."}            (one per xcodebuild invocation)
  event: stdout     — {"data": "<line>\\n"}
  event: stderr     — {"data": "<line>\\n"}
  event: heartbeat  — {"elapsed_seconds": ...}                    (every ~20s of silence)
  event: info       — {"app_path": "..."}                         (after a successful build)
  event: end        — {"duration_seconds": ...}                   (terminal: success)
  event: error      — {"error": "...", ...}                       (terminal: failure)

Validation errors come back as a single JSON 4xx response, not a stream.

On a successful "build" action, the app is written to:
  <repo>/build/Build/Products/<configuration>/jiminy-snippet.app
"""


build_tool = Tool(
    name="build",
    summary="Run xcodebuild to build, clean, or test the jiminy-snippet app",
    documentation=BUILD_DOC,
    validate=_validate_build,
    run=_run_build,
)


# ---- install ----------------------------------------------------------------

INSTALLED_PATH = Path("/Applications/jiminy-snippet.app")


def _validate_install(payload: dict) -> dict:
    config = _require_configuration(payload)
    timeout = _require_positive_number(payload, "timeout_seconds", 120)
    return {"configuration": config, "timeout_seconds": timeout}


def _run_install(validated: dict, repo_root: Path) -> Iterator[Event]:
    config = validated["configuration"]
    timeout = validated["timeout_seconds"]
    src = _built_app_path(repo_root, config)
    if not src.is_dir():
        raise ToolError(
            f"app not found at {src} — run /tools/build with configuration={config!r} first"
        )

    yield ("step", {"message": "stopping any running jiminy-snippet"})
    # pkill returns 1 when no process matches; that's not a failure for us.
    yield from runner.run_command(["/usr/bin/pkill", "-x", "jiminy-snippet"], cwd=repo_root, timeout=timeout)

    yield ("step", {"message": f"removing existing {INSTALLED_PATH}"})
    code = yield from runner.run_command(["/bin/rm", "-rf", str(INSTALLED_PATH)], cwd=repo_root, timeout=timeout)
    if code != 0:
        raise ToolError(f"rm -rf {INSTALLED_PATH} exited with status {code}")

    yield ("step", {"message": f"copying {src} to {INSTALLED_PATH}"})
    code = yield from runner.run_command(
        ["/usr/bin/ditto", str(src), str(INSTALLED_PATH)],
        cwd=repo_root,
        timeout=timeout,
    )
    if code != 0:
        raise ToolError(f"ditto exited with status {code}")

    yield ("info", {"installed_path": str(INSTALLED_PATH)})


INSTALL_DOC = """\
install — copy the locally-built app to /Applications/jiminy-snippet.app.

GET  /tools/install   — this documentation
POST /tools/install   — install; response is text/event-stream

Steps performed:
  1. pkill -x jiminy-snippet           (failure-tolerant; no match is fine)
  2. rm   -rf /Applications/jiminy-snippet.app
  3. ditto <repo>/build/Build/Products/<configuration>/jiminy-snippet.app
                  /Applications/jiminy-snippet.app

The app must already be built (see /tools/build). The user account running the
toolserver must have write access to /Applications.

Request body (JSON; all fields optional):
  {
    "configuration":   "Debug" | "Release",   # default: "Debug"
    "timeout_seconds": <positive number>      # default: 120 (per step)
  }

Response (Server-Sent Events) — same event types as /tools/build, plus:
  event: step  — {"message": "..."}    (one per step above)
  event: info  — {"installed_path": "..."}   (on success)
"""


install_tool = Tool(
    name="install",
    summary="Install the built app at /Applications/jiminy-snippet.app",
    documentation=INSTALL_DOC,
    validate=_validate_install,
    run=_run_install,
)


# ---- launch -----------------------------------------------------------------


def _validate_launch(payload: dict) -> dict:
    timeout = _require_positive_number(payload, "timeout_seconds", 30)
    return {"timeout_seconds": timeout}


def _run_launch(validated: dict, repo_root: Path) -> Iterator[Event]:
    timeout = validated["timeout_seconds"]
    if not INSTALLED_PATH.is_dir():
        raise ToolError(
            f"app not found at {INSTALLED_PATH} — run /tools/install first"
        )

    yield ("step", {"message": "stopping any running jiminy-snippet"})
    # pkill returns 1 when no process matches; that's expected on first launch.
    yield from runner.run_command(["/usr/bin/pkill", "-x", "jiminy-snippet"], cwd=repo_root, timeout=timeout)

    yield ("step", {"message": f"launching {INSTALLED_PATH}"})
    code = yield from runner.run_command(
        ["/usr/bin/open", "-a", str(INSTALLED_PATH)],
        cwd=repo_root,
        timeout=timeout,
    )
    if code != 0:
        raise ToolError(f"open exited with status {code}")

    yield ("info", {"launched_path": str(INSTALLED_PATH)})


LAUNCH_DOC = """\
launch — start (or restart) the installed jiminy-snippet app.

GET  /tools/launch   — this documentation
POST /tools/launch   — launch; response is text/event-stream

Steps performed:
  1. pkill -x jiminy-snippet           (failure-tolerant; no match is fine)
  2. open  -a /Applications/jiminy-snippet.app

The app must already be installed (see /tools/install). To pick up code
changes, run /tools/build then /tools/install before /tools/launch.

Request body (JSON; all fields optional):
  {
    "timeout_seconds": <positive number>      # default: 30 (per step)
  }

Response (Server-Sent Events) — same event types as /tools/build, plus:
  event: step  — {"message": "..."}    (one per step above)
  event: info  — {"launched_path": "..."}    (on success)
"""


launch_tool = Tool(
    name="launch",
    summary="Launch (or relaunch) the installed jiminy-snippet app",
    documentation=LAUNCH_DOC,
    validate=_validate_launch,
    run=_run_launch,
)


# ---- registry ---------------------------------------------------------------

REGISTRY: dict[str, Tool] = {t.name: t for t in (build_tool, install_tool, launch_tool)}
