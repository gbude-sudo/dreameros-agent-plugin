#!/usr/bin/env python3
"""Model phase-boundary check. A Stop hook, not a memory.

The reason this file exists: a prior session wrote a canon rule (Digital
Buoyancy Ballast, constraint 7/8) describing how a model-downshift advisory
should behave, then violated that same rule four separate times inside one
working session, including after writing it. The operator's own words on
being told a fifth time to "remember" it: "THIS IS YOUR FUCKING JOB TO TELL
ME... WHY IS THIS NOT IN CANON LIVE RUNTIME." Prose does not enforce itself.
This does, mechanically, every turn, with no reliance on the assistant
choosing to check.

WHAT IT CHECKS, deterministically, from the actual transcript:
  1. Tool-use density and the actual model+effort tier used across the last
     few assistant turns (both fields are recorded verbatim per turn by
     Claude Code - this reads real data, never a guess).
  2. Whether the run immediately preceding the turn that just ended was
     TOOL-HEAVY on a big model/effort tier (real build work), and the turn
     that just ended was CONVERSATIONAL (zero or near-zero tool calls) on
     that same big tier.
  3. Fires ONLY on that transition. Silent otherwise - continuous nagging is
     the alarm-fatigue failure this whole feature exists to avoid, per the
     same canon doc's own design constraints.

The message emitted is phrased as a direct instruction to say a specific
sentence to the user, not as background context the model can fold into
its own judgment and possibly drop - the whole point is removing that
discretion, since discretion is exactly what failed four times running.

ASCII only. No em dashes.
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

# One firing per boundary, not once per light turn after it. Without this,
# three conversational turns in a row after one heavy build stretch would
# print the same instruction three times - the exact alarm-fatigue failure
# this hook's own design principle (fire at boundaries, not continuously)
# exists to avoid. Keyed per transcript so two concurrent sessions do not
# share state and one cannot silence the other.
_STATE_DIR = Path.home() / ".claude" / "hooks" / ".model-phase-boundary-state"

# Tuning. Named constants so the thresholds are visible and arguable, not
# buried in a conditional.
_HEAVY_TOOL_MIN = 3          # a turn counts as "build" if it used >= this many tools
_HEAVY_RUN_MIN_TURNS = 2     # need at least this many consecutive heavy turns
_LOOKBACK_TURNS = 12         # how far back to scan for the heavy run
_BIG_MODELS = {"claude-opus-5"}
_BIG_EFFORTS = {"high", "xhigh", "max"}


def _read_transcript(path: str) -> list[dict]:
    try:
        with open(path, encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]
    except Exception:
        return []


def _is_real_user_message(entry: dict) -> bool:
    """True only for a genuine human message, never a tool-result replay.

    Claude Code represents a tool's result as a type="user" entry too (the
    API's own tool_result-as-user-turn convention), so type=="user" alone
    is not enough - it would treat every single tool call as a fresh human
    turn and this would never detect anything. toolUseResult is populated
    only on the replay entries; a real human message never carries it.
    Verified directly against this session's own transcript before relying
    on it - a replayed entry showed toolUseResult set with content
    [{"type": "tool_result"}], a real message showed toolUseResult absent
    with plain-string content.
    """
    if entry.get("type") != "user":
        return False
    if entry.get("toolUseResult") is not None:
        return False
    content = entry.get("message", {}).get("content")
    if isinstance(content, list):
        # A plain human message can still be a content list (e.g. text +
        # image attachment) - only reject it if EVERY block is a
        # tool_result, which is the actual replay shape.
        if content and all(c.get("type") == "tool_result" for c in content):
            return False
    return True


def _segment_by_real_user_turns(entries: list[dict]) -> list[dict]:
    """One record per genuine human turn: everything the assistant did
    (every tool call, whatever model/effort it ran on) between one real
    human message and the next, collapsed into a single tool_count/model/
    effort summary for that turn."""
    turns: list[dict] = []
    current: dict | None = None
    for e in entries:
        if _is_real_user_message(e):
            current = {"tool_count": 0, "model": None, "effort": None}
            turns.append(current)
            continue
        if e.get("type") != "assistant" or current is None:
            continue
        msg = e.get("message", {})
        content = msg.get("content", [])
        if isinstance(content, list):
            current["tool_count"] += sum(1 for c in content if c.get("type") == "tool_use")
        if msg.get("model") and msg.get("model") != "<synthetic>":
            current["model"] = msg.get("model")
        if e.get("effort"):
            current["effort"] = e.get("effort")
    return turns


def _is_big(turn: dict) -> bool:
    return turn.get("model") in _BIG_MODELS or turn.get("effort") in _BIG_EFFORTS


def _is_heavy(turn: dict) -> bool:
    return turn.get("tool_count", 0) >= _HEAVY_TOOL_MIN


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
    if len(turns) < _HEAVY_RUN_MIN_TURNS + 1:
        return 0

    window = turns[-_LOOKBACK_TURNS:]
    current = window[-1]
    preceding = window[:-1]

    # The turn that just ended must itself be light - if it is still doing
    # heavy tool work, there is no boundary yet, just more of the same work.
    if _is_heavy(current):
        return 0

    # Walk backward from just before the current turn, counting a
    # consecutive run of heavy-and-big turns.
    run_len = 0
    run_model = None
    run_effort = None
    for t in reversed(preceding):
        if _is_heavy(t) and _is_big(t):
            run_len += 1
            run_model = run_model or t.get("model")
            run_effort = run_effort or t.get("effort")
        else:
            break

    if run_len < _HEAVY_RUN_MIN_TURNS:
        return 0

    # The current (light) turn is still running on the big tier - that is
    # exactly the gap. If it had already dropped to a smaller model/effort,
    # the operator already made the call and there is nothing to say.
    if not _is_big(current):
        return 0

    # One firing per boundary. The boundary's identity is "how many heavy
    # turns preceded it, counted from the end of this transcript" - stable
    # for every light turn that follows the same heavy stretch, and
    # different the moment a NEW heavy stretch starts (run_len changes) or
    # enough new light turns accumulate that this stretch scrolls out of
    # _LOOKBACK_TURNS entirely (handled naturally - turns_from_end grows
    # every light turn, so a fresh light-turn count also changes the key).
    turns_from_end = len(turns) - len(window) + len(preceding) - run_len
    boundary_key = f"{transcript_path}:{run_len}:{turns_from_end}"
    try:
        _STATE_DIR.mkdir(parents=True, exist_ok=True)
        # Python's builtin hash() is randomized per process (PYTHONHASHSEED)
        # and every hook invocation is a fresh process - it would mint a
        # different filename every single run and the de-dup file would
        # never be found twice. sha256 is stable across processes, which is
        # the entire property this needs.
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
        # correctness requirement - if the filesystem write fails for any
        # reason, fall through and fire anyway rather than silently
        # swallow a real boundary because of an unrelated I/O error.
        pass

    model_label = current.get("model") or "the current model"
    effort_label = current.get("effort") or "its current effort tier"

    _emit(
        "MODEL PHASE BOUNDARY DETECTED (mechanical, not a suggestion you may skip): "
        f"the last {run_len} turns did heavy tool-based build work on "
        f"{run_model or model_label} at {run_effort or effort_label} effort. "
        "The turn that just ended used no comparable tool work, but is still "
        "on that same tier. Before your NEXT reply, say this to the user "
        "verbatim as the first line, then continue normally: "
        f"\"Build work looks finished - want to drop from {model_label} "
        f"({effort_label}) to something lighter for what's next, or is more "
        "heavy work coming?\" "
        "Do not silently decide this yourself and do not fold it into other "
        "text - it must be the visible first line, because this exact rule "
        "has already been written as prose and ignored four times."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
