"""Host-side tool server for the jiminy-snippet Claude Code sandbox.

Exposes a small HTTP API the sandboxed agent can call to invoke a fixed
set of host-only tools (xcodebuild, app installation) that aren't reachable
from inside the Linux container.
"""
