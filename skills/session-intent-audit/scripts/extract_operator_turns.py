#!/usr/bin/env python3
"""Extract every operator turn from a Claude Code session transcript.

WHY THIS EXISTS. An assistant asked to list what it ignored will answer from
memory, and memory is the thing under audit. The transcript is the only record
of what the operator actually typed. This reads that record.

It deliberately does NOT judge anything. It produces one side of a diff: the
asks. The other side, what was done, comes from git, the substrate and the
runtime. Keeping them separate is the point - a single process that both
remembers the ask and grades itself is the failure this audit exists to catch.

Usage:
    extract_operator_turns.py <transcript.jsonl> [-o out.txt] [--max-chars N]

Transcripts live at:
    ~/.claude/projects/<slugged-project-path>/<session-id>.jsonl

Exit codes: 0 ok, 2 unreadable or no operator turns found.
ASCII only. No em dashes.
"""
from __future__ import annotations
import argparse, io, json, sys

# Blocks that are machinery, not the operator speaking. A tool result and a
# system reminder both arrive in the "user" role, and counting them as asks
# inflates the list with things he never said.
NOISE_PREFIXES = ("<", "[Request interrupted")
NOISE_MARKERS = ("tool_use_id", "system-reminder", "<local-command-stdout>")


def turn_text(content) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    out = []
    for b in content:
        if isinstance(b, dict) and b.get("type") == "text":
            out.append(str(b.get("text", "")))
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("transcript")
    ap.add_argument("-o", "--out", default=None)
    ap.add_argument("--max-chars", type=int, default=2000,
                    help="truncate each turn; 0 means no limit")
    a = ap.parse_args()

    try:
        fh = io.open(a.transcript, encoding="utf-8", errors="replace")
    except OSError as exc:
        print("cannot read transcript: %s" % exc, file=sys.stderr)
        return 2

    turns, scanned = [], 0
    with fh:
        for line in fh:
            scanned += 1
            try:
                e = json.loads(line)
            except Exception:
                continue  # a partial last line is normal on a live session
            m = e.get("message") or {}
            if m.get("role") != "user":
                continue
            t = turn_text(m.get("content")).strip()
            if not t:
                continue
            if t.startswith(NOISE_PREFIXES) or any(k in t[:400] for k in NOISE_MARKERS):
                continue
            turns.append(t)

    # A zero here is a finding, not a clean result. Say so loudly, because an
    # empty list reads as "he asked for nothing" and that is never true.
    if not turns:
        print("NO OPERATOR TURNS FOUND in %d lines. The extractor found "
              "nothing, which means the transcript shape changed or the path "
              "is wrong. Do NOT report this as 'he asked for nothing'."
              % scanned, file=sys.stderr)
        return 2

    body = []
    for i, t in enumerate(turns, 1):
        s = t if a.max_chars <= 0 else t[:a.max_chars]
        body.append("=== TURN %d ===\n%s\n" % (i, s))
    text = "\n".join(body)

    if a.out:
        with io.open(a.out, "w", encoding="utf-8") as w:
            w.write(text)
        print("lines scanned: %d" % scanned)
        print("operator turns: %d" % len(turns))
        print("written: %s" % a.out)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
