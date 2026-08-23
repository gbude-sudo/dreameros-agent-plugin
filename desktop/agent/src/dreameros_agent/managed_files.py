"""Owned-block and semantic JSON updates with atomic replacement."""
from __future__ import annotations

import json
import os
import shutil
import tempfile
from pathlib import Path


class ManagedFileError(ValueError):
    pass


def render_owned_block(existing: str, payload: str, marker: str) -> str:
    begin = f"# BEGIN {marker}"
    end = f"# END {marker}"
    if existing.count(begin) > 1 or existing.count(end) > 1:
        raise ManagedFileError("duplicate managed block markers")
    block = f"{begin}\n{payload.rstrip()}\n{end}"
    if begin in existing or end in existing:
        if begin not in existing or end not in existing:
            raise ManagedFileError("incomplete managed block markers")
        start = existing.index(begin)
        finish = existing.index(end, start) + len(end)
        return existing[:start] + block + existing[finish:]
    separator = "" if not existing else ("" if existing.endswith("\n\n") else "\n\n")
    return existing + separator + block + "\n"


def atomic_write(path: Path, content: bytes, backup_dir: Path) -> Path | None:
    path.parent.mkdir(parents=True, exist_ok=True)
    backup: Path | None = None
    if path.exists():
        backup_dir.mkdir(parents=True, exist_ok=True)
        backup = backup_dir / f"{path.name}.bak"
        shutil.copy2(path, backup)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return backup


def update_json_entry(path: Path, section: str, name: str, value: dict, backup_dir: Path, *, replace_values: tuple[dict, ...] = ()) -> bool:
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8-sig"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ManagedFileError(f"refusing malformed JSON: {path}") from exc
        if not isinstance(data, dict):
            raise ManagedFileError("JSON configuration root must be an object")
    else:
        data = {}
    target = data.setdefault(section, {})
    if not isinstance(target, dict):
        raise ManagedFileError(f"JSON section {section} must be an object")
    if name in target and target[name] != value and target[name] not in replace_values:
        raise ManagedFileError(f"refusing to replace unmanaged JSON entry: {section}.{name}")
    if target.get(name) == value:
        return False
    target[name] = value
    encoded = (json.dumps(data, indent=2, ensure_ascii=True) + "\n").encode("utf-8")
    atomic_write(path, encoded, backup_dir)
    return True
