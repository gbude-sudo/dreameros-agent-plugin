"""Install the signed vendor-neutral DreamerOS boot pack."""
from __future__ import annotations

import io
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

import httpx

from .managed_files import atomic_write
from .release_manifest import ManifestVerificationError, verify_artifact, verify_manifest


BEGIN = "<!-- BEGIN DREAMEROS-BOOT-CANON"
END = "<!-- END DREAMEROS-BOOT-CANON"


def _splice(existing: str, block: str) -> str:
    begin = block.find(BEGIN)
    end = block.find(END)
    if begin < 0 or end < begin:
        raise ManifestVerificationError("boot pack instruction markers are missing")
    end = block.find("-->", end)
    if end < 0:
        raise ManifestVerificationError("boot pack end marker is incomplete")
    owned = block[begin : end + 3].strip()
    old_begin = existing.find(BEGIN)
    if old_begin < 0:
        separator = "" if not existing else ("" if existing.endswith("\n\n") else "\n\n")
        return existing + separator + owned + "\n"
    old_end = existing.find(END, old_begin)
    old_end = existing.find("-->", old_end)
    if old_end < 0:
        raise ManifestVerificationError("installed boot pack marker is incomplete")
    return existing[:old_begin] + owned + existing[old_end + 3 :]


def _safe_members(archive: zipfile.ZipFile) -> None:
    for info in archive.infolist():
        path = PurePosixPath(info.filename.replace("\\", "/"))
        if path.is_absolute() or ".." in path.parts:
            raise ManifestVerificationError("boot pack archive contains an unsafe path")


def install_bootpack(
    release: dict,
    pinned_keys: dict[str, str],
    *,
    home: Path,
    staging_dir: Path,
    client: httpx.Client | None = None,
) -> dict[str, str]:
    manifest_url = release.get("manifest_url")
    signature_url = release.get("signature_url")
    if not manifest_url or not signature_url:
        raise ManifestVerificationError("release registry has no signed boot pack")
    http = client or httpx.Client(timeout=httpx.Timeout(60.0, connect=10.0), follow_redirects=True)
    manifest_response = http.get(manifest_url)
    signature_response = http.get(signature_url)
    manifest_response.raise_for_status()
    signature_response.raise_for_status()
    manifest = verify_manifest(
        manifest_response.content,
        signature_response.text.strip(),
        pinned_keys,
    )
    bootpack = manifest.get("bootpack")
    if not isinstance(bootpack, dict):
        raise ManifestVerificationError("release manifest has no boot pack")
    archive_url = bootpack.get("archive_url")
    archive_sha = bootpack.get("archive_sha256")
    source_sha = bootpack.get("source_sha256")
    version = bootpack.get("version")
    if not all(isinstance(value, str) and value for value in (archive_url, archive_sha, source_sha, version)):
        raise ManifestVerificationError("boot pack metadata is incomplete")
    response = http.get(archive_url)
    response.raise_for_status()
    staging_dir.mkdir(parents=True, exist_ok=True)
    archive_path = staging_dir / "dreameros-bootpack.zip"
    archive_path.write_bytes(response.content)
    verify_artifact(archive_path, archive_sha)

    with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
        _safe_members(archive)
        claude_block = archive.read("claude/CLAUDE.md.block").decode("utf-8-sig")
        codex_block = archive.read("codex/AGENTS.md.block").decode("utf-8-sig")
        cursor_rule = archive.read("cursor/dreameros-boot-canon.mdc")
        skill = archive.read("skill/dreameros-boot/SKILL.md")

    for path, block in (
        (home / ".claude" / "CLAUDE.md", claude_block),
        (home / ".codex" / "AGENTS.md", codex_block),
    ):
        existing = path.read_text(encoding="utf-8-sig") if path.exists() else ""
        rendered = _splice(existing, block)
        if rendered != existing:
            atomic_write(path, rendered.encode("utf-8"), home / ".dreameros" / "backups")
    atomic_write(
        home / ".cursor" / "rules" / "dreameros-boot-canon.mdc",
        cursor_rule,
        home / ".dreameros" / "backups",
    )
    for root in (home / ".claude", home / ".codex", home / ".agents"):
        atomic_write(
            root / "skills" / "dreameros-boot" / "SKILL.md",
            skill,
            home / ".dreameros" / "backups",
        )
    return {"boot_pack_version": version, "boot_pack_sha256": source_sha}
