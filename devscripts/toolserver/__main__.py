"""CLI entry point: ``uv run toolserver`` (or ``python -m toolserver``)."""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from .server import create_app

# devscripts/toolserver/__main__.py → repo root is two directories up.
DEFAULT_REPO_ROOT = Path(__file__).resolve().parents[2]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host-side tool server for the jiminy-snippet sandbox.",
    )
    parser.add_argument(
        "--host", default="0.0.0.0",
        help="Interface to bind (default: 0.0.0.0; use 127.0.0.1 to restrict to loopback)",
    )
    parser.add_argument(
        "--port", type=int, default=8765,
        help="Port to listen on (default: 8765)",
    )
    parser.add_argument(
        "--repo-root", type=Path, default=DEFAULT_REPO_ROOT,
        help=f"Path to the jiminy-snippet repo (default: {DEFAULT_REPO_ROOT})",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="[toolserver] %(levelname)s %(name)s: %(message)s",
    )

    repo_root = args.repo_root.resolve()
    if not (repo_root / "jiminy-snippet.xcodeproj").exists():
        print(
            f"warning: jiminy-snippet.xcodeproj not found under {repo_root}",
            file=sys.stderr,
        )

    app = create_app(repo_root)
    print(f"toolserver listening on http://{args.host}:{args.port}", file=sys.stderr)
    print(f"repo root: {repo_root}", file=sys.stderr)
    app.run(host=args.host, port=args.port, threaded=True, debug=False, use_reloader=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
