"""Loopback-only streaming MCP proxy. Secrets stay in the platform vault."""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable

import httpx

REMOTE_MCP_URL = "https://mcp.dreameros.app/mcp"
MAX_REQUEST_BYTES = 16 * 1024 * 1024
_HOP_HEADERS = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade", "host", "content-length"}


class ProxyServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, *, token_provider: Callable[[], str | None], installation_id: str, agent_version: str, on_mcp_success: Callable[[], None] | None = None, attestation_lock=None, client=None, remote_url: str = REMOTE_MCP_URL):
        super().__init__(address, ProxyHandler)
        self.token_provider = token_provider
        self.installation_id = installation_id
        self.agent_version = agent_version
        self.on_mcp_success = on_mcp_success
        self.attestation_lock = attestation_lock or threading.Lock()
        self.remote_url = remote_url
        self.http = client or httpx.Client(timeout=httpx.Timeout(300.0, connect=10.0))


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):  # noqa: N802
        if self.path == "/health":
            body = json.dumps({
                "status": "ok",
                "agent_version": self.server.agent_version,  # type: ignore[attr-defined]
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.split("?", 1)[0] == "/mcp":
            self._proxy("GET")
            return
        self.send_error(404)

    def do_POST(self):  # noqa: N802
        if self.path.split("?", 1)[0] != "/mcp":
            self.send_error(404)
            return
        self._proxy("POST")

    def do_DELETE(self):  # noqa: N802
        if self.path.split("?", 1)[0] != "/mcp":
            self.send_error(404)
            return
        self._proxy("DELETE")

    def _proxy(self, method: str) -> None:
        token = self.server.token_provider()  # type: ignore[attr-defined]
        if not token:
            self.send_error(401, "DreamerOS sign-in required")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400)
            return
        if length > MAX_REQUEST_BYTES:
            self.send_error(413)
            return
        body = self.rfile.read(length) if length else None
        headers = {key: value for key, value in self.headers.items() if key.lower() not in _HOP_HEADERS and key.lower() not in {"authorization", "x-dreameros-installation"}}
        headers["Authorization"] = f"Bearer {token}"
        headers["X-DreamerOS-Installation"] = self.server.installation_id  # type: ignore[attr-defined]
        request = self.server.http.build_request(method, self.server.remote_url, headers=headers, content=body)  # type: ignore[attr-defined]
        try:
            with self.server.attestation_lock:  # type: ignore[attr-defined]
                response = self.server.http.send(request, stream=True)  # type: ignore[attr-defined]
                callback = self.server.on_mcp_success  # type: ignore[attr-defined]
                if callback is not None and 200 <= response.status_code < 300:
                    try:
                        callback()
                    except (httpx.HTTPError, OSError, RuntimeError):
                        pass
            self.send_response(response.status_code)
            for key, value in response.headers.items():
                if key.lower() not in _HOP_HEADERS:
                    self.send_header(key, value)
            self.send_header("Connection", "close")
            self.end_headers()
            for chunk in response.iter_bytes(65536):
                self.wfile.write(chunk)
                self.wfile.flush()
            response.close()
        except (httpx.HTTPError, OSError):
            if not self.wfile.closed:
                self.close_connection = True

    def log_message(self, *_args):
        return


def serve_proxy(token_provider: Callable[[], str | None], installation_id: str, *, agent_version: str, on_mcp_success: Callable[[], None] | None = None, attestation_lock=None, port: int = 18765) -> ProxyServer:
    server = ProxyServer(("127.0.0.1", port), token_provider=token_provider, installation_id=installation_id, agent_version=agent_version, on_mcp_success=on_mcp_success, attestation_lock=attestation_lock)
    threading.Thread(target=server.serve_forever, name="dreameros-mcp-proxy", daemon=True).start()
    return server
