"""Nonsecret local installation state."""
from __future__ import annotations

import json
from pathlib import Path

from .managed_files import atomic_write

_FORBIDDEN = {"access_token", "refresh_token", "authorization", "client_secret", "code_verifier"}


class LocalState:
    def __init__(self, path: Path):
        self.path = path

    def load(self) -> dict:
        if not self.path.exists():
            return {}
        value = json.loads(self.path.read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            raise ValueError("agent state root must be an object")
        return value

    def save(self, value: dict) -> None:
        keys = {str(key).lower() for key in _walk_keys(value)}
        found = keys & _FORBIDDEN
        if found:
            raise ValueError(f"refusing to persist secret state fields: {sorted(found)}")
        encoded = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
        atomic_write(self.path, encoded, self.path.parent / "backups")

    def update(self, **values) -> dict:
        state = self.load()
        state.update(values)
        self.save(state)
        return state


def _walk_keys(value):
    if isinstance(value, dict):
        for key, child in value.items():
            yield key
            yield from _walk_keys(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk_keys(child)
