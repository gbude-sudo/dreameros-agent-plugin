#!/usr/bin/env python3
"""Done-proof discipline check. A Stop hook, not a memory.

Sibling to gate_no_governance_language.py and gate_no_parrot.py - same
proven pattern: read the real transcript, force a mandatory instruction as
additionalContext, never block, never rely on the model remembering to
check itself.

WHY THIS EXISTS. R25 in the boot canon requires every claim of completion
to ship with a claim-ask-reality table and an instrument named on the
reality cell - never overstate, never agree or disagree without checking.
R25's own text says the git-destination half is already enforced by
gate-claim-verification.sh and the state-answer half by
gate_answer_from_measurement.py, but the plain "used the big word with
nothing behind it" half had NO hook. This is that hook. The lesson R17,
R21, and R22 all wrote down: a written rule does not fire by being
written. Only a hook fires.

WHAT IT CHECKS, deterministically: the last assistant reply uses a
top-of-ladder completion word (done, fixed, live, shipped, deployed,
complete, wired up) AND shows NO measurement anywhere in the same reply -
no SHA, no command, no status code, no verdict-ladder word, no "measured".
That pair is the exact shape of an overstatement: the big word with
nothing behind it.

WHY LOW NOISE. Completion words are common, so a naive scan would fire
every turn and be tuned out - worse than no gate (R1c). Two dampers: it
stays silent whenever a measurement signal is present (the disciplined
reply already did its job), and it ignores the word "done" inside
"definition of done" and "done-proof" (discussing the framework is not a
claim). It surfaces the bare assertion and nothing else.

WHAT IT DOES NOT DO. It does not block. It cannot un-send. It cannot tell
a real completion claim from the word in passing, so it makes the next
turn decide rather than deciding silently.

ASCII only. No em dashes.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

# Top-of-ladder completion words - the ones R2/R3 forbid as a substitute
# for a measured smaller word.
_COMPLETION = re.compile(
    r"\b(done|fixed|live|shipped|deployed|complete|completed|wired up)\b",
    re.IGNORECASE,
)

# A measurement signal anywhere in the reply means the claim is backed -
# stay silent. Includes evidence tokens (SHA, command names, status codes,
# byte counts) and the disciplined verdict-ladder vocabulary. DEPLOYED and
# LIVE are deliberately NOT here: they overlap the completion words and
# would silence the very case this hook exists to catch.
_EVIDENCE = re.compile(
    r"\b[0-9a-f]{7,40}\b"
    r"|ls-remote|rev-parse|rev-list|git status|--porcelain|cmp -s|git diff"
    r"|curl |grep |HTTP\s*\d{3}|status code|\d{3}\s+(?:OK|response)"
    r"|\bmeasured\b|\binstrument\b|byte-match|\d+\s*bytes"
    r"|\bREACHABLE\b|\bMERGED\b|\bWRITTEN\b|\bPARTIAL\b|\bBLOCKED\b"
    r"|NOT ELIGIBLE|\bUNKNOWN\b",
    re.IGNORECASE,
)

# Discussing the framework is not a claim of completion.
_FRAMEWORK = re.compile(r"definition of done|done[- ]proof", re.IGNORECASE)


def _read_transcript(path: str) -> list[dict]:
    """Tolerant per-line reader. A half-written final line is the normal
    state at Stop time, not an error - skip the bad line, keep the rest."""
    entries: list[dict] = []
    try:
        with open(path, encoding="utf-8-sig") as f:
            for line in f:
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
    """Concatenated text of the most recent real assistant turn. Any entry
    that is not an assistant entry and not a tool-result user entry is a
    turn boundary (same fix as gate_no_governance_language.py, so back to
    back Stop events do not re-match an already-clean earlier turn)."""
    last_run: list[dict] = []
    for e in entries:
        t = e.get("type")
        if t == "assistant":
            last_run.append(e)
        elif t == "user" and e.get("toolUseResult") is not None:
            continue
        else:
            last_run = []

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

    # Ignore the completion word inside framework names.
    scan = _FRAMEWORK.sub(" ", text)
    completion_hits = sorted(set(m.group(1).lower() for m in _COMPLETION.finditer(scan)))
    if not completion_hits:
        return 0

    # A measurement anywhere in the reply means the claim is backed.
    if _EVIDENCE.search(text):
        return 0

    found = ", ".join(f'"{w}"' for w in completion_hits)
    _emit(
        f"DONE-PROOF CHECK (mechanical, not a suggestion you may skip): the "
        f"reply you just sent uses completion word(s) {found} but shows NO "
        "measurement anywhere in it - no SHA, no command, no status code, no "
        "verdict-ladder word (WRITTEN / MERGED / DEPLOYED / REACHABLE / "
        "PARTIAL / BLOCKED / NOT ELIGIBLE). R25 in the boot canon: never "
        "claim the big word with nothing behind it. Before your next reply, "
        "either show the measurement and the instrument that backs each "
        "completion claim, or drop to the smaller true word. If the word was "
        "about something you did not measure this turn, mark it UNKNOWN and "
        "name the instrument that would settle it. This hook stays silent "
        "when a measurement is present; it fired because none was found."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
