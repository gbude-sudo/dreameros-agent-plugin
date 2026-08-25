#!/usr/bin/env python3
"""Intent-fidelity vocabulary check. A Stop hook, not a memory.

Sibling to model-switch-ack.py - same proven pattern (read the real
transcript, force a mandatory instruction as additionalContext, never
block, never rely on the model remembering to check itself).

WHY THIS EXISTS. R19 in the boot canon already bans "governance", "DAIM",
"EDE", "IFP" in customer-facing copy, in favor of intent-fidelity
vocabulary - and this exact complaint is R14 item 5, counted NINE TIMES
before this hook was written. On 2026-08-21, in the same session that
propagated R19 to every repo and every global surface, a customer
positioning pitch ("moat-making... money-making opportunities") used
"governed" and "governance" as the core framing, repeatedly. HC: "I DONT
KNOW HOW MANY TIMES I NEED TO SAY WE DONT EVER SAY WE GOVERN THINGS."

Prose failed. R19 was live, in context, freshly written by the same
session that broke it minutes later. That is the same shape as R17's own
postmortem (engine-switch acknowledgment): a written rule does not fire
by being written. Only a hook fires.

WHAT IT DOES NOT DO. It does not block. It cannot un-send a message that
already violated the rule. R19's own internal/external line stays intact
- code identifiers, commit messages, PR bodies, and engineering
conversation about internal mechanics are explicitly fine (see the boot
canon's own text). This hook cannot reliably tell "customer positioning
draft" apart from "explaining the governance_events table to the
operator" from pattern-matching alone, so it does not try. It surfaces
every hit and asks the next turn to make that judgment call explicitly,
rather than silently deciding either way.

ASCII only. No em dashes.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

_BANNED_PATTERN = re.compile(
    r"\b(governance|governed|governs|govern)\b", re.IGNORECASE
)
_BANNED_ACRONYMS = re.compile(r"\b(DAIM|EDE|IFP)\b")


def _read_transcript(path: str) -> list[dict]:
    """Same tolerant-of-bad-lines reader as model-switch-ack.py.

    A half-written final line is the normal state at Stop time, not an
    error condition - skip the bad line, keep the rest.
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
                    continue
    except Exception:
        return []
    return entries


def _last_assistant_text(entries: list[dict]) -> str:
    """Concatenated text of the most recent real assistant turn.

    A turn can carry multiple assistant entries (tool calls interleaved
    with text). Collect all text blocks from the LAST such run of
    assistant entries, not just the final single entry, so a violation
    inside an earlier text block of a multi-step turn is still caught.

    BUG FOUND AND FIXED 2026-08-21, same session R21 shipped in: the
    original reset condition only cleared the accumulator on a genuine
    TYPED user message (type=="user", toolUseResult is None). When
    several Stop events fire back to back with no fresh typed message
    between them - exactly what happens replying to this hook's own
    injected additionalContext - the transcript carries harness
    metadata entries (types seen live: "last-prompt", "custom-title",
    "mode", "pr-link", "bridge-session", "attachment") between the
    assistant turns instead. Those matched neither branch below, so
    the accumulator was never cleared, and text from turns already
    replied to and already clean kept re-matching on every later Stop
    event. Fix: treat ANY entry that is not an assistant entry and not
    a tool-result user entry as a turn boundary, not only a typed
    message. Verified against the real session transcript, not only a
    synthetic one, per R1c.
    """
    last_run: list[dict] = []
    for e in entries:
        t = e.get("type")
        if t == "assistant":
            last_run.append(e)
        elif t == "user" and e.get("toolUseResult") is not None:
            continue  # tool-result replay: same turn, not a boundary
        else:
            last_run = []  # typed message or any other entry: boundary

    chunks: list[str] = []
    for e in last_run:
        content = e.get("message", {}).get("content")
        if isinstance(content, str):
            chunks.append(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    chunks.append(block.get("text", ""))
    return "\n".join(chunks)


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
    text = _last_assistant_text(entries)
    if not text:
        return 0

    word_hits = sorted(set(m.group(1).lower() for m in _BANNED_PATTERN.finditer(text)))
    acronym_hits = sorted(set(m.group(1) for m in _BANNED_ACRONYMS.finditer(text)))
    if not word_hits and not acronym_hits:
        return 0

    found = ", ".join(f'"{w}"' for w in word_hits + acronym_hits)
    _emit(
        f"INTENT-FIDELITY VOCABULARY CHECK (mechanical, not a suggestion "
        f"you may skip): the reply you just sent contains {found}. R19 in "
        "the boot canon bans governance / governed / governs / govern / "
        "DAIM / EDE / IFP in customer-facing copy - positioning, pitches, "
        "marketing, product descriptions, anything a customer could read. "
        "Say intent fidelity, fidelity checks, verified, checked, or "
        "receipts instead. Internal engineering talk with the operator, "
        "code identifiers, commit messages and PR bodies are still fine - "
        "this fires on the word appearing at all because it cannot tell "
        "the two apart by itself, so YOU make that call now. If what you "
        "just sent was customer-facing framing, restate it in "
        "intent-fidelity language as the first thing in your next reply. "
        "If it was genuinely internal, say so in one line and continue. "
        "This is R14 item 5, already counted nine times before this hook "
        "existed - prose alone did not stop it happening a tenth time in "
        "the same session that propagated the rule to every surface."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
