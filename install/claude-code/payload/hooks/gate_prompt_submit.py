#!/usr/bin/env python3
"""Claude native prompt gate for the DreamerOS Life of Intent.

The hook does not call MCP tools. It repeats the exact boot requirement until
the active transcript contains a real session-package tool call, and adds a
bounded instruction to load matching skills before acting.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import sys

MAX_TRANSCRIPT_BYTES = 1_000_000
BOOT = re.compile(r"(^|__)(dreameros_session_package)$")
SAFE = re.compile(r"[^A-Za-z0-9_.-]")

def _marker(session_id: str) -> Path:
    return Path.home() / ".claude" / "hook-state" / ("boot-package-" + SAFE.sub("_", session_id or "unknown"))

def _called(payload: dict) -> bool:
    path = Path(str(payload.get("transcript_path") or ""))
    if not path.is_file(): return False
    try:
        with path.open("rb") as stream:
            stream.seek(0, 2); size = stream.tell(); stream.seek(max(0, size - MAX_TRANSCRIPT_BYTES))
            if size > MAX_TRANSCRIPT_BYTES: stream.readline()
            lines = stream.read().decode("utf-8-sig", "ignore").splitlines()
    except OSError: return False
    for line in lines:
        try: event = json.loads(line)
        except Exception: continue
        content = (event.get("message") or {}).get("content") if isinstance(event, dict) else None
        if not isinstance(content, list): continue
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_use" and BOOT.search(str(block.get("name") or "")):
                return True
    return False

def main() -> int:
    try: payload = json.load(sys.stdin)
    except Exception: return 0
    if not isinstance(payload, dict): return 0
    session_id = str(payload.get("session_id") or "")
    marker = _marker(session_id)
    if not marker.is_file() and _called(payload):
        try: marker.parent.mkdir(parents=True, exist_ok=True); marker.write_text("attempted\n", encoding="ascii")
        except OSError: pass
    if marker.is_file(): return 0
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "DREAMEROS GATEWAY BOOT NOT YET CONFIRMED FOR THIS SESSION. Before substantive work, call the exact exposed dreameros_session_package MCP tool. Do not simulate it with shell or HTTP. If unavailable, report DreamerOS BLOCKED and continue only safe local work as STANDALONE."}}))
    return 0
if __name__ == "__main__": raise SystemExit(main())
