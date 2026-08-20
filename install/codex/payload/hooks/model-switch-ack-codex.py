#!/usr/bin/env python
"""Engine-switch acknowledgment for Codex. Boot canon R17, Codex half.

Sibling of the Claude Code hook model-switch-ack.py. Same rule, same
output contract, different transcript format and a different stdin
shape. R17 requires that when the serving engine changes mid-session,
the very next reply opens by naming the new engine.

WHY CODEX GETS ITS OWN FILE RATHER THAN SHARING THE CLAUDE ONE.
The two disagree on both inputs:
  Claude Code writes one JSON object per line with type "assistant"
  and the model at message.model.
  Codex writes rollout records whose model lives at payload.model on
  records of type turn_context, and it does not mark user turns the
  same way.
A shared reader would need a branch per vendor in every function, which
is how the two drift apart silently. One file each, same contract.

TWO WAYS TO LEARN THE MODEL, and the order matters.
Codex passes turn-scoped fields on stdin, so if a "model" key is
present that is authoritative and free. When it is absent, fall back to
the rollout transcript on disk. The fallback is not decoration: it is
the only path that works if the stdin field is renamed or dropped in a
future Codex release, and it was verified against a real rollout file
carrying 12 turn_context records.

STATE, and why a file rather than memory.
A Stop hook is a fresh process every turn, so the previous turn's model
has to be written down. The state file is keyed by session so two
concurrent Codex sessions cannot read each other's last engine and
announce a switch that never happened.

ASCII only. No em dashes. Spaced hyphens only.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from pathlib import Path

_STATE_DIR = Path.home() / ".codex" / "hooks" / ".model-switch-ack-state"
_SESSIONS_DIR = Path.home() / ".codex" / "sessions"

# Codex records the model on turn_context payloads. Anything that is not
# a real model id is ignored so a placeholder never reads as a switch.
_PLACEHOLDER_MODELS = {"", "unknown", "none", "null", "<synthetic>"}


def _read_jsonl(path: Path) -> list[dict]:
    """Parse per line, tolerating any line that will not parse.

    Deliberately NOT a single try/except around a comprehension. The
    Claude sibling shipped that shape and one malformed line returned an
    empty list for the whole file, so the hook exited 0 and the switch
    went unannounced with nothing reporting an error. A rollout being
    appended to while this reads is the normal case at Stop time, so a
    half-written last line must cost one record, never the file.
    utf-8-sig strips a byte-order mark if one is present; a BOM alone
    was enough to silence the sibling.
    """
    out: list[dict] = []
    try:
        with open(path, encoding="utf-8-sig", errors="replace") as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    out.append(json.loads(line))
                except Exception:
                    continue
    except Exception:
        return []
    return out


def _model_from_record(entry: dict) -> str | None:
    payload = entry.get("payload")
    if not isinstance(payload, dict):
        return None
    model = payload.get("model")
    if not isinstance(model, str):
        return None
    model = model.strip()
    if model.lower() in _PLACEHOLDER_MODELS:
        return None
    return model


def _models_from_rollout(path: Path) -> list[str]:
    """Every model recorded in this rollout, in order, deduped only when
    consecutive. Two turns on one model are one entry; a switch and a
    switch back stay two entries, because both are real switches."""
    models: list[str] = []
    for entry in _read_jsonl(path):
        model = _model_from_record(entry)
        if model and (not models or models[-1] != model):
            models.append(model)
    return models


def _newest_rollout(session_id: str | None) -> Path | None:
    """Prefer the rollout whose filename carries this session id. Codex
    names rollouts rollout-<timestamp>-<session-uuid>.jsonl, so matching
    on the id is exact. Fall back to the newest file only when no id is
    given, because picking the newest across sessions can read another
    session's engine."""
    try:
        candidates = list(_SESSIONS_DIR.rglob("rollout-*.jsonl"))
    except Exception:
        return None
    if not candidates:
        return None
    if session_id:
        marker = str(session_id).strip().lower()
        for path in candidates:
            if marker and marker in path.name.lower():
                return path
        # An id was supplied and nothing matched. Do NOT fall back to the
        # newest file: that would read a different conversation.
        return None
    try:
        return max(candidates, key=lambda p: p.stat().st_mtime)
    except Exception:
        return None


def _emit(previous_model: str, current_model: str) -> None:
    message = (
        "ENGINE SWITCH DETECTED (mechanical, not a suggestion you may skip): "
        f"the model serving this turn is {current_model}, and the immediately "
        f"preceding turn ran on {previous_model}. Before your NEXT reply, say "
        f'this to the user verbatim as the first line, then continue normally: '
        f'"Switched to {current_model} - continuing from here." Do not fold it '
        "into other text - it must be the visible first line. Boot canon R17. "
        "The operator is paying per engine and routing work by engine, so an "
        "unannounced switch means he is reasoning about output from a model he "
        "did not know he was talking to."
    )
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "Stop",
            "additionalContext": message,
        }
    }))


def _already_announced(key: str) -> bool:
    """One announcement per boundary. Without this the hook re-announces
    the same switch on every subsequent turn, because the transcript
    keeps showing it. Returns True when this boundary was already seen."""
    try:
        _STATE_DIR.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256(key.encode("utf-8")).hexdigest()[:32]
        marker = _STATE_DIR / f"{digest}.seen"
        if marker.exists():
            return True
        marker.write_text("1", encoding="utf-8")
        return False
    except Exception:
        # If state cannot be written, announcing twice is a nuisance and
        # staying silent is a rule violation. Prefer the nuisance.
        return False


def main() -> int:
    try:
        hook_input = json.load(sys.stdin)
    except Exception:
        return 0
    if not isinstance(hook_input, dict):
        return 0

    session_id = hook_input.get("session_id") or hook_input.get("sessionId")

    # Path 1: Codex hands the active model straight to the hook.
    current_model = hook_input.get("model")
    if isinstance(current_model, str):
        current_model = current_model.strip() or None
        if current_model and current_model.lower() in _PLACEHOLDER_MODELS:
            current_model = None
    else:
        current_model = None

    # Path 2: read it off the rollout this session is writing.
    rollout = _newest_rollout(str(session_id) if session_id else None)
    models = _models_from_rollout(rollout) if rollout else []

    if current_model is None:
        if len(models) < 2:
            return 0
        current_model, previous_model = models[-1], models[-2]
    else:
        previous = [m for m in models if m != current_model]
        if not previous:
            return 0
        previous_model = previous[-1]

    if not previous_model or previous_model == current_model:
        return 0

    key = f"{session_id or 'nosession'}:{previous_model}->{current_model}:{len(models)}"
    if _already_announced(key):
        return 0

    _emit(previous_model, current_model)
    return 0


if __name__ == "__main__":
    sys.exit(main())
