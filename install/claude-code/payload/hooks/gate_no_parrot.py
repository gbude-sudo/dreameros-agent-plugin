#!/usr/bin/env python3
"""Verbatim-echo check. A Stop hook, not a memory.

Sibling to gate_no_governance_language.py and model-switch-ack.py - same
proven pattern (read the real transcript, force a mandatory instruction as
additionalContext, never block, never rely on the model remembering to
check itself).

WHY THIS EXISTS. R19 already says "never parrot the operator... take the
intent, write it in his register, keep his actual words only when he says
copy me verbatim." HC named this exact gap live, in his own words: "I
always have to say things like 'dont copy and paste what i say'" - meaning
the written rule is not reliably firing, the same shape of failure R21
already fixed for the governance-vocabulary ban. This hook is the same fix
applied to the parrot rule: R19 was already correct prose; prose alone did
not stop the pattern HC is naming as a repeated, lived frustration.

WHAT IT DOES NOT DO. It does not block, and it cannot un-send a reply that
already parroted. It cannot perfectly tell a legitimate quote (an error
message, a real citation, a file's own text, something HC explicitly said
to copy verbatim) from an actual parrot by pattern alone, so it does not
try. It surfaces every long verbatim run and asks the next turn to make
that judgment call explicitly, rather than silently deciding either way -
identical philosophy to gate_no_governance_language.py.

NAMED GAP, not solved here: HC also described two other lived failures in
the same message - conversational topic drift over a long session ("we
talking about this... you totally go off the reservation") and generally
spotty intent measurement. Neither has a reliable mechanical check the way
a verbatim-substring match does; forcing a fragile heuristic in here would
itself become "a gate that cannot fire reliably," the exact failure this
whole hook family exists to avoid (R1c). Left as an explicit, named,
prose-only gap in R22 rather than falsely claimed as covered.

ASCII only. No em dashes.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

# 8 consecutive words is long enough that incidental short overlaps
# ("the connect page", "on the gateway") do not fire, short enough that a
# real lifted sentence does. Word-based, not character-based, so it is
# robust to whitespace/formatting differences between HC's dictated input
# and however the reply renders it.
_MIN_RUN_WORDS = 8

_WORD_RE = re.compile(r"[a-z0-9']+")


def _read_transcript(path: str) -> list[dict]:
    """Same tolerant-of-bad-lines reader as the sibling hooks.

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


def _entry_text(entry: dict) -> str:
    content = entry.get("message", {}).get("content")
    if isinstance(content, str):
        return content
    chunks: list[str] = []
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                chunks.append(block.get("text", ""))
    return "\n".join(chunks)


def _last_assistant_text(entries: list[dict]) -> str:
    """Concatenated text of the most recent real assistant turn.

    Same turn-boundary logic as gate_no_governance_language.py, fixed
    2026-08-21 in that hook and reused verbatim here: any entry that is
    not an assistant entry and not a tool-result user replay
    (type=="user" with toolUseResult present) is a turn boundary, not
    only a genuinely typed message. See that hook's own docstring for the
    lived incident this fixed.
    """
    last_run: list[dict] = []
    for e in entries:
        t = e.get("type")
        if t == "assistant":
            last_run.append(e)
        elif t == "user" and e.get("toolUseResult") is not None:
            continue
        else:
            last_run = []
    return "\n".join(_entry_text(e) for e in last_run)


def _last_typed_user_text(entries: list[dict]) -> str:
    """Text of the most recent genuinely typed user message.

    type=="user" AND toolUseResult absent AND the content is not a
    harness metadata entry (those carry no "message" key the same way,
    or carry empty/non-text content - _entry_text already returns "" for
    those, so an empty result here is skipped by the caller).
    """
    for e in reversed(entries):
        if e.get("type") != "user":
            continue
        if e.get("toolUseResult") is not None:
            continue
        text = _entry_text(e)
        if text.strip():
            return text
    return ""


def _find_verbatim_runs(user_text: str, reply_text: str, min_words: int) -> list[str]:
    """Return maximal, non-overlapping runs of min_words+ consecutive
    words that appear, in the same order, in both the user's message and
    the reply.

    Lowercased and tokenized to words only, so case/punctuation/whitespace
    differences between how HC typed it and how the reply rendered it do
    not defeat the match. "Maximal" matters: a naive sliding-window scan
    reports one 15-word parrot as eight overlapping 8-word fragments,
    which reads as noise instead of one clear hit. This extends every
    match as far as it keeps matching, keeps only the longest run
    starting at each reply position, then greedily selects non-
    overlapping runs longest-first so one parrot is reported once.
    """
    user_words = _WORD_RE.findall(user_text.lower())
    reply_words = _WORD_RE.findall(reply_text.lower())
    if len(user_words) < min_words or len(reply_words) < min_words:
        return []

    user_positions: dict[str, list[int]] = {}
    for j, w in enumerate(user_words):
        user_positions.setdefault(w, []).append(j)

    n = len(reply_words)
    m = len(user_words)
    best_len_at: dict[int, int] = {}
    for i in range(n):
        best = 0
        for j in user_positions.get(reply_words[i], []):
            k = 0
            while i + k < n and j + k < m and reply_words[i + k] == user_words[j + k]:
                k += 1
            if k > best:
                best = k
        if best >= min_words:
            best_len_at[i] = best

    spans_by_length = sorted(best_len_at.items(), key=lambda kv: -kv[1])
    taken: list[tuple[int, int]] = []
    for start, length in spans_by_length:
        end = start + length
        if any(start < t_end and end > t_start for t_start, t_end in taken):
            continue
        taken.append((start, end))
    taken.sort()

    return [" ".join(reply_words[s:e]) for s, e in taken]


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
    reply_text = _last_assistant_text(entries)
    user_text = _last_typed_user_text(entries)
    if not reply_text or not user_text:
        return 0

    hits = _find_verbatim_runs(user_text, reply_text, _MIN_RUN_WORDS)
    if not hits:
        return 0

    quoted = "; ".join(f'"{h}"' for h in hits[:5])
    more = f" (+{len(hits) - 5} more)" if len(hits) > 5 else ""
    _emit(
        f"VERBATIM-ECHO CHECK (mechanical, not a suggestion you may skip): "
        f"the reply you just sent repeats {len(hits)} run(s) of 8+ words "
        f"straight from HC's own message: {quoted}{more}. R19 says never "
        "parrot the operator - take the intent, write it in his register, "
        "keep his exact words only when he explicitly says copy me "
        "verbatim, or when quoting a real external source (an error "
        "message, a citation, a file's own text) where the words "
        "themselves are the evidence. This hook cannot tell those cases "
        "apart from an actual parrot by pattern alone, so it surfaces "
        "every long verbatim run and asks YOU to make that call now. If "
        "the reply just lifted his phrasing instead of restating the "
        "intent, say so in one line and do it properly next time. If "
        "every hit above was a legitimate quote or an explicit "
        "copy-me-verbatim instruction, say so in one line and continue."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
