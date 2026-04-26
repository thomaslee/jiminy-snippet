"""Flask app exposing the tool registry over HTTP."""

from __future__ import annotations

import json
import logging
from pathlib import Path

from flask import Flask, Response, jsonify, request

from . import sse, tools

log = logging.getLogger(__name__)


def create_app(repo_root: Path) -> Flask:
    registry = tools.REGISTRY
    app = Flask(__name__)

    @app.get("/health")
    def health():
        return jsonify({
            "ok": True,
            "tools": sorted(registry),
            "repo_root": str(repo_root),
        })

    @app.get("/tools")
    def list_tools():
        return jsonify({
            "tools": [
                {"name": tool.name, "summary": tool.summary}
                for tool in registry.values()
            ],
        })

    @app.get("/tools/<name>")
    def tool_doc(name: str):
        tool = registry.get(name)
        if tool is None:
            return Response(
                f"unknown tool: {name}\n",
                status=404,
                mimetype="text/plain; charset=utf-8",
            )
        return Response(tool.documentation, mimetype="text/plain; charset=utf-8")

    @app.post("/tools/<name>")
    def tool_run(name: str):
        tool = registry.get(name)
        if tool is None:
            return jsonify({"error": f"unknown tool: {name}"}), 404

        raw = request.get_data(as_text=True)
        if raw.strip():
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError as exc:
                return jsonify({"error": f"invalid JSON: {exc}"}), 400
            if not isinstance(payload, dict):
                return jsonify({"error": "request body must be a JSON object"}), 400
        else:
            payload = {}

        try:
            validated = tool.validate(payload)
        except tools.BadRequest as exc:
            return jsonify({"error": str(exc)}), 400

        log.info("running tool %s with %s", tool.name, validated)
        return Response(
            sse.stream(tool.run(validated, repo_root)),
            mimetype="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
            },
        )

    return app
