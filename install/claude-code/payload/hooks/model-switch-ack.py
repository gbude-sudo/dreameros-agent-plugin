#!/usr/bin/env python3
"""Engine-switch acknowledgment. A Stop hook, not a memory. Sibling to
model-phase-boundary.py - same proven pattern, different trigger.

The reason this file exists: the operator switched models mid-session
(opus-5 -> sonnet-5) and got no acknowledgment until asking for one
directly. His words: "why the fuck do i have to be the one that
remembers?!" A written rule (engine-switch-banner.md memory entry) already
described the desired behavior and did not fire, because prose is not
enforcement - proven again, the same lesson model-phase-boundary.py was
built to close for the downshift-advisory case. This closes it for the
switch-happened case.

WHAT IT CHECKS, deterministically, from the actual transcript: the model
recorded on the most recent real assistant turn versus the model recorded
on the immediately preceding real assistant turn (both real, non-synthetic
values). If they differ, a switch happened between those two turns.

Fires ONCE per transition, keyed by transcript + turn index + the exact
model pair, so it never repeats for turns that follow on the new model,
and a later switch (even back to a prior model) fires again because the
turn index and/or model pair changed.

The message is phrased as a direct instruction to say a specific sentence,
not background context the model can fold in or drop - the whole point,
same as the sibling hook, is removing that discretion.

ASCII only. No em dashes.
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

_STATE_DIR = Path.home() / ".claude" / "hooks" / ".model-switch-ack-state"


def _read_transcript(path: str) -> list[dict]:
    """Parse the transcript per line, tolerating any line that will not parse.

    The earlier version wrapped the whole comprehension in one try/except, so
    a SINGLE unparseable line returned an empty list for the entire file. The
    hook then saw fewer than two modeled turns, exited 0, and the switch went
    unannounced with nothing reporting an error - the same silent-pass shape
    as the bash-reading-a-.py bug this hook already survived once.

    That is not a rare condition. Claude Code writes the transcript
    asynchronously and documents that it may lag the live conversation, so a
    half-written final line is the NORMAL state at Stop time, which is exactly
    when this hook runs. A leading byte-order mark reproduces it too.

    Skipping the bad line and keeping the rest is right for this reader: it
    only ever compares the model on the last two real turns, so one dropped
    record costs nothing, while dropping the file costs the announcement.
    encoding="utf-8-sig" strips a BOM if one is present.
    """
    entries: list[dict] = []
    try:
        with open(path, "rb") as _fb:
            _fb.seek(0, 2)
            _sz = _fb.tell()
            _fb.seek(max(0, _sz - 400_000))
            if _sz > 400_000:
                _fb.readline()  # drop the partial first line after the seek
            _lines = _fb.read().decode("utf-8-sig", "ignore").splitlines()
        for line in _lines:
                if not line.strip():
                    continue
                try:
                    entries.append(json.loads(line))
                except Exception:
                    continue  # one malformed record, not a dead transcript
    except Exception:
        return []
    return entries


def _is_real_user_message(entry: dict) -> bool:
    """True only for a genuine human message, never a tool-result replay.

    Identical logic to model-phase-boundary.py's _is_real_user_message -
    Claude Code represents a tool result as a type="user" entry too, so
    type=="user" alone is not enough. toolUseResult is populated only on
    the replay entries.
    """
    if entry.get("type") != "user":
        return False
    if entry.get("toolUseResult") is not None:
        return False
    content = entry.get("message", {}).get("content")
    if isinstance(content, list):
        if content and all(c.get("type") == "tool_result" for c in content):
            return False
    return True


def _segment_by_real_user_turns(entries: list[dict]) -> list[dict]:
    """One record per genuine human turn: the LAST non-synthetic model
    recorded on any assistant message inside that turn. If a turn used
    more than one model (a switch mid-turn), the final one is what the
    user actually saw as the reply, so that is what counts as "this
    turn's model" for comparison against the next turn.
    """
    turns: list[dict] = []
    current: dict | None = None
    for e in entries:
        if _is_real_user_message(e):
            current = {"model": None}
            turns.append(current)
            continue
        if e.get("type") != "assistant" or current is None:
            continue
        msg = e.get("message", {})
        model = msg.get("model")
        if model and model != "<synthetic>":
            current["model"] = model
    return turns


def _emit(message: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "Stop",
            "additionalContext": message,
        }
    }))


def main() -> int:
    try:
        hook_input = json.load(sys.stdin)
    except Exception:
        return 0

    transcript_path = hook_input.get("transcript_path")
    if not transcript_path or not Path(transcript_path).exists():
        return 0

    entries = _read_transcript(transcript_path)
    turns = _segment_by_real_user_turns(entries)

    # Only consider turns that actually recorded a model. A turn can be
    # empty (e.g. the last one, still in progress) or model=None if
    # something odd happened before any assistant message landed.
    modeled = [(i, t["model"]) for i, t in enumerate(turns) if t.get("model")]
    if len(modeled) < 2:
        return 0

    current_idx, current_model = modeled[-1]
    previous_idx, previous_model = modeled[-2]

    if current_model == previous_model:
        return 0

    # One firing per transition. Keyed on the turn index where the new
    # model first appears plus the exact model pair, so it is stable for
    # this specific switch and distinct from any other switch anywhere
    # else in the same transcript (including switching back later).
    boundary_key = f"{transcript_path}:{current_idx}:{previous_model}->{current_model}"
    try:
        _STATE_DIR.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256(transcript_path.encode("utf-8")).hexdigest()[:16]
        state_file = _STATE_DIR / f"{digest}.json"
        already_fired = None
        if state_file.exists():
            try:
                already_fired = json.loads(state_file.read_text(encoding="utf-8")).get("key")
            except Exception:
                already_fired = None
        if already_fired == boundary_key:
            return 0
        state_file.write_text(json.dumps({"key": boundary_key}), encoding="utf-8")
    except Exception:
        # State is an optimization against repeat noise, never a
        # correctness requirement - fall through and fire rather than
        # silently swallow a real switch because of an I/O error.
        pass

    _emit(
        "ENGINE SWITCH DETECTED (mechanical, not a suggestion you may skip): "
        f"the model recorded on this turn is {current_model}, and the "
        f"immediately preceding turn ran on {previous_model}. Before your "
        "NEXT reply, say this to the user verbatim as the first line, then "
        "continue normally: "
        f"\"Switched to {current_model} - continuing from here.\" "
        "Do not silently decide this yourself and do not fold it into other "
        "text - it must be the visible first line. This was written because "
        "the operator switched engines and got no acknowledgment until "
        "asking for one directly; a written rule already described this "
        "behavior and did not fire, because prose is not enforcement."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
