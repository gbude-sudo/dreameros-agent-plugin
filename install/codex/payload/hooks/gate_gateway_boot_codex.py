#!/usr/bin/env python3
"""Repeat the DreamerOS boot instruction until Codex records the MCP call."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import sys
import tempfile


BOOT_SUFFIX = "dreameros_session_package"
SAFE_ID = re.compile(r"[^A-Za-z0-9_.-]")
MAX_TRANSCRIPT_BYTES = 1_000_000


def _marker_path(session_id: str) -> Path:
    root = os.environ.get("DREAMEROS_CODEX_BOOT_MARK_DIR")
    base = Path(root) if root else Path(tempfile.gettempdir()) / "dreameros-codex-boot"
    safe = SAFE_ID.sub("_", session_id or "unknown")
    return base / f"session-package-attempted-{safe}"


def _named_boot_call(value: object) -> bool:
    if isinstance(value, list):
        return any(_named_boot_call(child) for child in value)
    if not isinstance(value, dict):
        return False
    for key, child in value.items():
        if key in {"name", "tool_name"} and isinstance(child, str):
            if child.endswith(BOOT_SUFFIX) and child.startswith(
                ("mcp__dreameros__", "mcp__codex_apps__dreameros_")
            ):
                return True
        if isinstance(child, (dict, list)) and _named_boot_call(child):
            return True
    return False


def _transcript_has_boot_call(path_value: object) -> bool:
    if not isinstance(path_value, str) or not path_value:
        return False
    path = Path(path_value)
    if not path.is_file():
        return False
    try:
        with path.open("rb") as stream:
            stream.seek(0, 2)
            size = stream.tell()
            stream.seek(max(0, size - MAX_TRANSCRIPT_BYTES))
            if size > MAX_TRANSCRIPT_BYTES:
                stream.readline()
            lines = stream.read().decode("utf-8-sig", errors="ignore").splitlines()
    except OSError:
        return False
    for line in lines:
        try:
            event = json.loads(line)
        except (json.JSONDecodeError, TypeError):
            continue
        if _named_boot_call(event):
            return True
    return False


def evaluate(payload: dict) -> dict | None:
    session_id = str(payload.get("session_id") or "")
    marker = _marker_path(session_id)
    if session_id and marker.is_file():
        return None
    if _transcript_has_boot_call(payload.get("transcript_path")):
        try:
            marker.parent.mkdir(parents=True, exist_ok=True)
            marker.write_text("attempted\n", encoding="ascii")
        except OSError:
            pass
        return None
    return {
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": (
                "DREAMEROS GATEWAY BOOT NOT YET CONFIRMED FOR THIS SESSION. Before "
                "substantive work, call the exact exposed MCP tool whose name ends "
                "dreameros_session_package. Do not simulate it with Bash, PowerShell, "
                "Get-Command, curl, or a guessed server id. Codex is the chatgpt engine "
                "family for package arguments. If the MCP tool is unavailable or fails, "
                "report DreamerOS BLOCKED and continue only safe local work as STANDALONE. "
                "This reminder repeats until the transcript records the real MCP tool call."
            ),
        }
    }


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            return 0
        result = evaluate(payload)
        if result is not None:
            print(json.dumps(result, separators=(",", ":")))
    except Exception:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
