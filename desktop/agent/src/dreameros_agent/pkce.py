"""OAuth public-client state and PKCE helpers."""
from __future__ import annotations

import base64
import hashlib
import secrets


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def new_state() -> str:
    return _b64url(secrets.token_bytes(32))


def new_verifier() -> str:
    return _b64url(secrets.token_bytes(48))


def challenge_s256(verifier: str) -> str:
    if not 43 <= len(verifier) <= 128:
        raise ValueError("PKCE verifier must be 43 to 128 characters")
    return _b64url(hashlib.sha256(verifier.encode("ascii")).digest())


def state_matches(expected: str, received: str) -> bool:
    return bool(expected and received and secrets.compare_digest(expected, received))
