"""DreamerOS native public-client OAuth contract helpers."""
from __future__ import annotations

import json
import threading
import time
import webbrowser
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

import httpx

from .pkce import challenge_s256, new_state, new_verifier, state_matches
from .vault import TokenVault


class OAuthError(RuntimeError):
    """OAuth failure safe to display without response bodies or credentials."""


@dataclass(frozen=True)
class OAuthDiscovery:
    issuer: str
    authorization_endpoint: str
    token_endpoint: str
    registration_endpoint: str

    @classmethod
    def from_dict(cls, value: dict) -> "OAuthDiscovery":
        required = ("issuer", "authorization_endpoint", "token_endpoint", "registration_endpoint")
        if any(not isinstance(value.get(key), str) or not value[key].startswith("https://") for key in required):
            raise OAuthError("OAuth discovery document is missing a secure endpoint")
        return cls(*(value[key] for key in required))


def registration_payload(redirect_uri: str) -> dict:
    return {
        "client_name": "DreamerOS Desktop",
        "redirect_uris": [redirect_uri],
        "token_endpoint_auth_method": "none",
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "scope": "profile mcp desktop.runtime",
    }


def authorization_url(
    discovery: OAuthDiscovery,
    *,
    client_id: str,
    redirect_uri: str,
    state: str,
    verifier: str,
) -> str:
    query = urlencode(
        {
            "response_type": "code",
            "client_id": client_id,
            "redirect_uri": redirect_uri,
            "scope": "profile mcp desktop.runtime",
            "state": state,
            "code_challenge": challenge_s256(verifier),
            "code_challenge_method": "S256",
        }
    )
    return f"{discovery.authorization_endpoint}?{query}"


@dataclass(frozen=True)
class TokenSet:
    access_token: str
    refresh_token: str | None
    expires_at: int


class _CallbackServer(ThreadingHTTPServer):
    daemon_threads = True
    result: dict | None = None


class _CallbackHandler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path != "/callback":
            self.send_error(404)
            return
        self.server.result = {key: values[0] for key, values in parse_qs(parsed.query).items()}  # type: ignore[attr-defined]
        body = b"DreamerOS connected. You can close this window."
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        return


class OAuthClient:
    def __init__(self, issuer: str, vault: TokenVault, *, client: httpx.Client | None = None, browser_open=webbrowser.open):
        self.issuer = issuer.rstrip("/")
        self.vault = vault
        self.client = client or httpx.Client(timeout=httpx.Timeout(15.0, connect=5.0), follow_redirects=False)
        self.browser_open = browser_open

    def discover(self) -> OAuthDiscovery:
        try:
            response = self.client.get(f"{self.issuer}/.well-known/oauth-authorization-server")
            response.raise_for_status()
            return OAuthDiscovery.from_dict(response.json())
        except (httpx.HTTPError, ValueError, json.JSONDecodeError) as exc:
            raise OAuthError("OAuth discovery failed") from exc

    def register(self, discovery: OAuthDiscovery, redirect_uri: str) -> str:
        try:
            response = self.client.post(discovery.registration_endpoint, json=registration_payload(redirect_uri))
            response.raise_for_status()
            client_id = response.json().get("client_id")
        except (httpx.HTTPError, ValueError, json.JSONDecodeError) as exc:
            raise OAuthError("OAuth client registration failed") from exc
        if not isinstance(client_id, str) or not client_id:
            raise OAuthError("OAuth registration did not return a client id")
        return client_id

    def connect(self, *, timeout: float = 180.0) -> tuple[str, TokenSet]:
        server = _CallbackServer(("127.0.0.1", 0), _CallbackHandler)
        redirect_uri = f"http://127.0.0.1:{server.server_port}/callback"
        discovery = self.discover()
        client_id = self.register(discovery, redirect_uri)
        state, verifier = new_state(), new_verifier()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            if not self.browser_open(authorization_url(discovery, client_id=client_id, redirect_uri=redirect_uri, state=state, verifier=verifier)):
                raise OAuthError("The system browser could not be opened")
            deadline = time.monotonic() + timeout
            while server.result is None and time.monotonic() < deadline:
                time.sleep(0.05)
            result = server.result
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
        if not result:
            raise OAuthError("OAuth callback timed out")
        if result.get("error"):
            raise OAuthError("OAuth authorization was denied")
        if not state_matches(state, result.get("state", "")):
            raise OAuthError("OAuth callback state was invalid")
        code = result.get("code")
        if not code:
            raise OAuthError("OAuth callback did not include a code")
        tokens = self._exchange(discovery.token_endpoint, {
            "grant_type": "authorization_code", "client_id": client_id, "code": code,
            "redirect_uri": redirect_uri, "code_verifier": verifier,
        })
        self._store(tokens)
        return client_id, tokens

    def refresh(self, token_endpoint: str, client_id: str) -> TokenSet:
        refresh_token = self.vault.read("refresh_token")
        if not refresh_token:
            raise OAuthError("No refresh token is available")
        tokens = self._exchange(token_endpoint, {
            "grant_type": "refresh_token", "client_id": client_id, "refresh_token": refresh_token,
        })
        if tokens.refresh_token is None:
            tokens = TokenSet(tokens.access_token, refresh_token, tokens.expires_at)
        self._store(tokens)
        return tokens

    def _exchange(self, endpoint: str, form: dict) -> TokenSet:
        try:
            response = self.client.post(endpoint, data=form)
            response.raise_for_status()
            payload = response.json()
        except (httpx.HTTPError, ValueError, json.JSONDecodeError) as exc:
            raise OAuthError("OAuth token exchange failed") from exc
        access = payload.get("access_token")
        if not isinstance(access, str) or not access:
            raise OAuthError("OAuth token response was invalid")
        try:
            expires_at = int(time.time()) + max(30, int(payload.get("expires_in", 3600)))
        except (TypeError, ValueError):
            raise OAuthError("OAuth token expiry was invalid")
        refresh = payload.get("refresh_token")
        return TokenSet(access, refresh if isinstance(refresh, str) else None, expires_at)

    def _store(self, tokens: TokenSet) -> None:
        self.vault.store("access_token", tokens.access_token)
        if tokens.refresh_token:
            self.vault.store("refresh_token", tokens.refresh_token)
        self.vault.store("expires_at", str(tokens.expires_at))
