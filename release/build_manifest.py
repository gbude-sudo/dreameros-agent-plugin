"""Build and sign the stable DreamerOS desktop release manifest."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def private_key(encoded: str) -> Ed25519PrivateKey:
    raw = base64.b64decode(encoded, validate=True)
    if len(raw) == 32:
        return Ed25519PrivateKey.from_private_bytes(raw)
    key = serialization.load_pem_private_key(raw, password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError("desktop manifest key is not Ed25519")
    return key


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--asset-dir", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--bootpack-source", type=Path, required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--private-key-env", default="DESKTOP_ED25519_PRIVATE_KEY_B64")
    parser.add_argument("--windows-subject", required=True)
    parser.add_argument("--linux-key-id", required=True)
    args = parser.parse_args()

    names = {
        "windows-x86_64": "DreamerOSAgentSetup.exe",
        "macos-arm64": "DreamerOSAgent.pkg",
        "linux-x86_64": f"dreameros-desktop-agent_{args.version}_amd64.deb",
    }
    bootpack_name = "dreameros-bootpack.zip"
    for name in [*names.values(), bootpack_name]:
        if not (args.asset_dir / name).is_file():
            raise FileNotFoundError(name)

    base = f"https://github.com/{args.repository}/releases/download/{args.tag}"
    now = datetime.now(timezone.utc)
    artifacts = {}
    for key, name in names.items():
        item = {
            "url": f"{base}/{name}",
            "sha256": sha256(args.asset_dir / name),
        }
        if key.startswith("windows"):
            item["authenticode_subject"] = args.windows_subject
        elif key.startswith("macos"):
            item["notarized"] = True
        else:
            item["package_signing_key_id"] = args.linux_key_id
        artifacts[key] = item

    manifest = {
        "schema_version": "1.0",
        "release_id": args.tag,
        "channel": "stable",
        "published_at": now.isoformat(),
        "expires_at": (now + timedelta(days=45)).isoformat(),
        "signing_key_id": args.key_id,
        "minimum_agent_version": args.version,
        "agent": {"version": args.version, "artifacts": artifacts},
        "bootpack": {
            "version": args.version,
            "source_sha256": sha256(args.bootpack_source),
            "archive_url": f"{base}/{bootpack_name}",
            "archive_sha256": sha256(args.asset_dir / bootpack_name),
        },
    }
    manifest_path = args.asset_dir / "release-manifest.json"
    payload = json.dumps(manifest, separators=(",", ":"), sort_keys=True).encode("utf-8")
    manifest_path.write_bytes(payload)
    encoded_private_key = os.environ.get(args.private_key_env, "")
    if not encoded_private_key:
        raise ValueError(f"release signing key environment value is missing: {args.private_key_env}")
    key = private_key(encoded_private_key)
    (args.asset_dir / "release-manifest.sig").write_text(
        base64.b64encode(key.sign(payload)).decode("ascii"), encoding="ascii"
    )
    public = key.public_key().public_bytes(
        serialization.Encoding.Raw,
        serialization.PublicFormat.Raw,
    )
    (args.asset_dir / "release-public-key.json").write_text(
        json.dumps({"key_id": args.key_id, "public_key_b64": base64.b64encode(public).decode("ascii")}, indent=2) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
