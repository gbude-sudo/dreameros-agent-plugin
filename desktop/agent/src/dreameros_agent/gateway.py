"""Authenticated client for the DreamerOS desktop runtime contract."""
from __future__ import annotations

from dataclasses import dataclass

import httpx


class GatewayError(RuntimeError):
    pass


@dataclass
class GatewayClient:
    access_token: str
    base_url: str = "https://mcp.dreameros.app"
    client: httpx.Client | None = None

    def __post_init__(self):
        if not self.access_token:
            raise GatewayError("OAuth access token is unavailable")
        self.base_url = self.base_url.rstrip("/")
        self.client = self.client or httpx.Client(timeout=httpx.Timeout(20.0, connect=5.0))

    @property
    def headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.access_token}", "Accept": "application/json"}

    def _request(self, method: str, path: str, **kwargs) -> dict:
        try:
            response = self.client.request(method, self.base_url + path, headers=self.headers, **kwargs)  # type: ignore[union-attr]
            response.raise_for_status()
            payload = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise GatewayError(f"Gateway request failed: {method} {path}") from exc
        if not isinstance(payload, dict):
            raise GatewayError("Gateway returned an invalid response")
        return payload

    def register_installation(self, *, client_id: str, platform: str, version: str, adapters: list[dict]) -> dict:
        return self._request("POST", "/api/v1/desktop/installations", json={
            "client_id": client_id, "platform": platform, "agent_version": version, "adapters": adapters,
        })

    def heartbeat(self, installation_id: str, payload: dict) -> dict:
        bounded = {key: payload[key] for key in (
            "agent_version", "adapters", "boot_contract_version", "manifest_schema_version",
            "boot_pack_version", "boot_pack_sha256",
        ) if key in payload}
        return self._request("POST", f"/api/v1/desktop/installations/{installation_id}/heartbeat", json=bounded)

    def installation_state(self, installation_id: str) -> dict:
        return self._request("GET", f"/api/v1/desktop/installations/{installation_id}")

    def verify(self, installation_id: str) -> dict:
        return self._request("POST", f"/api/v1/desktop/installations/{installation_id}/verify")

    def revoke(self, installation_id: str) -> dict:
        return self._request("POST", f"/api/v1/desktop/installations/{installation_id}/revoke")

    def release_metadata(self) -> dict:
        return self._request("GET", "/api/v1/desktop/release")
