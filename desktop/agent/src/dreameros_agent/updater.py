"""Signed cross-platform desktop update staging and rollback."""
from __future__ import annotations

import base64
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import httpx

from .release_manifest import ManifestVerificationError, verify_artifact, verify_manifest
from .state import LocalState
from .trusted_keys import PINNED_LINUX_PACKAGE_PUBLIC_KEY_B64


def artifact_key(system: str | None = None, machine: str | None = None) -> str:
    family = (system or platform.system()).lower()
    arch = (machine or platform.machine()).lower()
    normalized = "x86_64" if arch in {"amd64", "x86_64"} else "arm64" if arch in {"arm64", "aarch64"} else arch
    os_name = {"windows": "windows", "darwin": "macos", "linux": "linux"}.get(family)
    if not os_name or normalized not in {"x86_64", "arm64"}:
        raise ManifestVerificationError("no release artifact for this platform")
    return f"{os_name}-{normalized}"


def select_artifact(manifest: dict, *, system: str | None = None, machine: str | None = None) -> dict:
    artifacts = manifest.get("agent", {}).get("artifacts", {})
    selected = artifacts.get(artifact_key(system, machine))
    if not isinstance(selected, dict) or not selected.get("url") or not selected.get("sha256"):
        raise ManifestVerificationError("release manifest has no matching artifact")
    return selected


def verify_platform_signature(path: Path, artifact: dict, *, system: str | None = None, linux_public_key_b64: str | None = None, runner=subprocess.run) -> None:
    family = (system or platform.system()).lower()
    if family == "windows":
        subject = artifact.get("authenticode_subject")
        if not subject:
            raise ManifestVerificationError("stable Windows artifact lacks Authenticode identity")
        commands = [["powershell", "-NoProfile", "-Command", f"$s=Get-AuthenticodeSignature -LiteralPath '{str(path).replace("'", "''")}'; if($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notlike '*{str(subject).replace("'", "''")}*'){{exit 3}}"]]
    elif family == "darwin":
        if not artifact.get("notarized"):
            raise ManifestVerificationError("stable macOS artifact lacks notarization assertion")
        commands = [
            ["pkgutil", "--check-signature", str(path)],
            ["spctl", "-a", "-vv", "-t", "install", str(path)],
        ]
    else:
        key_id = artifact.get("package_signing_key_id")
        if not key_id:
            raise ManifestVerificationError("stable Linux package lacks signing identity")
        encoded = linux_public_key_b64 or PINNED_LINUX_PACKAGE_PUBLIC_KEY_B64
        if not encoded:
            raise ManifestVerificationError("stable Linux package public key is unavailable")
        try:
            public_key = base64.b64decode(encoded, validate=True)
        except ValueError as exc:
            raise ManifestVerificationError("stable Linux package public key is invalid") from exc
        with tempfile.TemporaryDirectory(prefix="dreameros-gpg-") as keyring:
            env = dict(os.environ, GNUPGHOME=keyring)
            imported = runner(
                ["gpg", "--batch", "--import"],
                input=public_key,
                env=env,
                check=False,
                capture_output=True,
            )
            if imported.returncode != 0:
                raise ManifestVerificationError("Linux package public key import failed")
            result = runner(
                ["dpkg-sig", "--verify", str(path)],
                env=env,
                check=False,
                capture_output=True,
                text=True,
            )
            output = f"{result.stdout}\n{result.stderr}"
            if result.returncode != 0 or "GOODSIG" not in output or str(key_id) not in output:
                raise ManifestVerificationError("Linux package signature identity is invalid")
        return
    for command in commands:
        result = runner(command, check=False, capture_output=True, text=True)
        if result.returncode != 0:
            raise ManifestVerificationError("platform package signature is invalid")
        if family == "linux":
            output = f"{result.stdout}\n{result.stderr}"
            if "GOODSIG" not in output or str(key_id) not in output:
                raise ManifestVerificationError("Linux package signature identity is invalid")


@dataclass
class UpdateManager:
    state: LocalState
    pinned_keys: dict[str, str]
    staging_dir: Path
    client: httpx.Client | None = None

    def __post_init__(self):
        self.client = self.client or httpx.Client(timeout=httpx.Timeout(60.0, connect=10.0), follow_redirects=True)

    def fetch_and_stage(self, release: dict, *, system: str | None = None, machine: str | None = None) -> tuple[dict, Path]:
        manifest_url, signature_url = release.get("manifest_url"), release.get("signature_url")
        if not manifest_url or not signature_url:
            raise ManifestVerificationError("stable releases require a signed manifest")
        manifest_response = self.client.get(manifest_url)  # type: ignore[union-attr]
        signature_response = self.client.get(signature_url)  # type: ignore[union-attr]
        manifest_response.raise_for_status()
        signature_response.raise_for_status()
        raw = manifest_response.content
        signature = signature_response.text.strip()
        manifest = verify_manifest(raw, signature, self.pinned_keys)
        if manifest.get("channel") == "stable" and not signature:
            raise ManifestVerificationError("unsigned stable release refused")
        artifact = select_artifact(manifest, system=system, machine=machine)
        self.staging_dir.mkdir(parents=True, exist_ok=True)
        destination = self.staging_dir / Path(artifact["url"]).name
        with self.client.stream("GET", artifact["url"]) as response:  # type: ignore[union-attr]
            response.raise_for_status()
            with destination.open("wb") as handle:
                for chunk in response.iter_bytes(1024 * 1024):
                    handle.write(chunk)
        verify_artifact(destination, artifact["sha256"])
        if manifest.get("channel") == "stable":
            verify_platform_signature(destination, artifact, system=system)
        return manifest, destination

    def record_install(self, manifest: dict, artifact: Path, current_executable: Path | None = None) -> None:
        backup = None
        if current_executable and current_executable.exists():
            backup = self.staging_dir / f"rollback-{current_executable.name}"
            shutil.copy2(current_executable, backup)
        self.state.update(
            pending_update={"release_id": manifest["release_id"], "expected_version": manifest["agent"]["version"], "artifact": str(artifact), "started_at": datetime.now(timezone.utc).isoformat()},
            rollback={"backup": str(backup) if backup else None, "previous_version": self.state.load().get("version")},
        )

    def finish_or_rollback(self, healthy: bool, current_executable: Path | None = None) -> bool:
        value = self.state.load()
        if healthy:
            pending = value.pop("pending_update", None)
            value.pop("rollback", None)
            if pending:
                value["last_release_id"] = pending.get("release_id")
            self.state.save(value)
            return True
        backup = Path(value.get("rollback", {}).get("backup")) if value.get("rollback", {}).get("backup") else None
        if backup and current_executable and backup.exists():
            shutil.copy2(backup, current_executable)
            value["update_status"] = "rolled_back"
            value.pop("pending_update", None)
            self.state.save(value)
            return True
        value["update_status"] = "recovery_required"
        value.pop("pending_update", None)
        self.state.save(value)
        return False


def invoke_installer(path: Path, *, system: str | None = None, runner=subprocess.run) -> None:
    family = (system or platform.system()).lower()
    if family == "windows":
        command = [str(path), "/quiet"]
    elif family == "darwin":
        quoted = str(path).replace('"', '\\"')
        command = ["osascript", "-e", f'do shell script "installer -pkg \\"{quoted}\\" -target /" with administrator privileges']
    else:
        command = ["pkexec", "dpkg", "-i", str(path)]
    runner(command, check=True)
