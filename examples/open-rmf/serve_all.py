#!/usr/bin/env python3
"""
Unified server: rmf-web API + dashboard on a single port.

Serves the FastAPI/Socket.IO API server with dashboard static files
mounted as a fallback. No reverse proxy needed — WebSocket, REST, and
static files all work through the same uvicorn instance.
"""

import os
import sys

sys.path.insert(0, "/opt/rmf-web/packages/api-server")
os.chdir("/opt/rmf-web/packages/api-server")

from api_server.app import app  # noqa: E402
from starlette.staticfiles import StaticFiles  # noqa: E402

DASHBOARD_DIR = os.environ.get("DASHBOARD_DIR", "/opt/rmf-web/dashboard-dist")

if os.path.isdir(DASHBOARD_DIR):
    app.mount("/", StaticFiles(directory=DASHBOARD_DIR, html=True))

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="warning")
