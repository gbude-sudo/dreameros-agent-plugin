"""DreamerOS native public-client OAuth contract helpers."""
from __future__ import annotations

from dataclasses import dataclass
from urllib.parse import urlencode

from .pkce import challenge_s256


@dataclass(frozen=True)
class OAuthDiscovery:
    issuer: str
    authorization_endpoint: str
    token_endpoint: str
    registration_endpoint: str


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
