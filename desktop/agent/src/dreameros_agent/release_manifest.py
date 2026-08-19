"""Signed DreamerOS release manifest verification."""
from __future__ import annotations

import base64
import hashlib
import json
import secrets
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


class ManifestVerificationError(ValueError):
    pass


REQUIRED_FIELDS = {
    "schema_version",
    "release_id",
    "channel",
    "published_at",
    "expires_at",
    "signing_key_id",
    "minimum_agent_version",
    "agent",
    "bootpack",
}


def _parse_time(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError) as exc:
        raise ManifestVerificationError("manifest timestamp is invalid") from exc
    if parsed.tzinfo is None:
        raise ManifestVerificationError("manifest timestamp must include a timezone")
    return parsed.astimezone(timezone.utc)


def verify_manifest(
    manifest_bytes: bytes,
    signature_b64: str,
    pinned_keys: Mapping[str, str],
    *,
    now: datetime | None = None,
) -> dict:
    try:
        payload = json.loads(manifest_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ManifestVerificationError("manifest is not valid UTF-8 JSON") from exc
    missing = REQUIRED_FIELDS - set(payload)
    if missing:
        raise ManifestVerificationError(f"manifest missing fields: {sorted(missing)}")
    if payload["schema_version"] != "1.0":
        raise ManifestVerificationError("unsupported manifest schema")
    key_b64 = pinned_keys.get(payload["signing_key_id"])
    if not key_b64:
        raise ManifestVerificationError("manifest signing key is not pinned")
    try:
        key = Ed25519PublicKey.from_public_bytes(base64.b64decode(key_b64, validate=True))
        key.verify(base64.b64decode(signature_b64, validate=True), manifest_bytes)
    except Exception as exc:
        raise ManifestVerificationError("manifest signature is invalid") from exc
    current = now or datetime.now(timezone.utc)
    if _parse_time(payload["published_at"]) > current:
        raise ManifestVerificationError("manifest publication time is in the future")
    if _parse_time(payload["expires_at"]) <= current:
        raise ManifestVerificationError("manifest has expired")
    return payload


def verify_artifact(path: Path, expected_sha256: str) -> None:
    if len(expected_sha256) != 64 or any(c not in "0123456789abcdef" for c in expected_sha256):
        raise ManifestVerificationError("artifact SHA-256 is malformed")
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if not secrets.compare_digest(actual, expected_sha256):
        raise ManifestVerificationError("artifact SHA-256 does not match")
