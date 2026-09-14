#!/usr/bin/env python3
"""Hold a substantive Claude turn that leaves an explicit open receipt untied."""
from __future__ import annotations
import json, os, re, sys
from pathlib import Path

MIN_WORDS = 40
TERMINAL = re.compile(r"\bTERMINAL:\s*(SUCCESS|NO-OP|BLOCKED|STALLED|EXHAUSTED)\b", re.I)

def _zero():
    path = Path(os.environ.get("RECEIPT_ZERO_FILE") or Path.home() / ".claude" / "hook-state" / "zero-day.json")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if str(value.get("status", "")).lower() == "open" and value.get("receipt") else None
    except Exception: return None

def _last_text(path_value):
    try: lines = Path(path_value).read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception: return ""
    text = ""
    for line in lines:
        try: event = json.loads(line)
        except Exception: continue
        if event.get("type") != "assistant": continue
        content = (event.get("message") or {}).get("content")
        if isinstance(content, list):
            chunks = [str(block.get("text") or "") for block in content if isinstance(block, dict) and block.get("type") == "text"]
            if chunks: text = "\n".join(chunks)
    return text

def main():
    try: payload = json.load(sys.stdin)
    except Exception: return 0
    zero = _zero()
    if not zero: return 0
    text = _last_text(payload.get("transcript_path"))
    if len(re.findall(r"\S+", text)) < MIN_WORDS: return 0
    terminals = set(item.upper() for item in TERMINAL.findall(text))
    if str(zero["receipt"]).lower() in text.lower() and len(terminals) == 1: return 0
    print(json.dumps({"continue": False, "stopReason": "RECEIPT-ZERO GATE: this open process needs its receipt id named and exactly one TERMINAL: SUCCESS, NO-OP, BLOCKED, STALLED, or EXHAUSTED line before the turn closes."}))
    return 0
if __name__ == "__main__": raise SystemExit(main())
