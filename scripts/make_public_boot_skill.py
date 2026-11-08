"""Build the PUBLIC edition of the dreameros-boot skill.

The master boot canon keeps the operator's own words as evidence. Those words
are private and must never ship in the public plugin. This script reads the
generated full skill and writes the public edition: same rules, no verbatim
operator quotes.

    python scripts/make_public_boot_skill.py           write skills/dreameros-boot/SKILL.md
    python scripts/make_public_boot_skill.py --check   exit 1 if the published file differs

Input : bootpack/out/skill/dreameros-boot/SKILL.md  (generated, never edited here)
Output: skills/dreameros-boot/SKILL.md
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "bootpack" / "out" / "skill" / "dreameros-boot" / "SKILL.md"
TARGET = ROOT / "skills" / "dreameros-boot" / "SKILL.md"

NOTE = "Public edition: verbatim operator quotes are omitted. The rules are unchanged."
TITLE_PREFIX = "# DreamerOS Boot Canon v"
# Whole paragraphs that tell a private incident in the operator's own words.
DROP_STARTS = (
    "HC, 2026-09-11. He attached eleven diagrams",
    "HC verbatim:",
)


def build(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    paragraphs = text.split("\n\n")

    def is_quote(par: str) -> bool:
        lines = [line for line in par.split("\n") if line.strip()]
        return bool(lines) and all(line.startswith(">") for line in lines)

    keep: list[str | None] = []
    for index, par in enumerate(paragraphs):
        if is_quote(par) or par.startswith(DROP_STARTS):
            keep.append(None)
            continue
        keep.append(par)

    # A paragraph that only introduces a dropped quote ("His words, kept exact:") goes too.
    for index in range(len(keep) - 1):
        par = keep[index]
        if par is None:
            continue
        nxt = index + 1
        while nxt < len(keep) and keep[nxt] is None and not is_quote(paragraphs[nxt]) and not paragraphs[nxt].startswith(DROP_STARTS):
            nxt += 1
        following_is_dropped_quote = nxt < len(keep) and keep[nxt] is None and is_quote(paragraphs[nxt])
        if following_is_dropped_quote and par.rstrip().endswith(":"):
            keep[index] = None

    result = "\n\n".join(par for par in keep if par is not None)

    lines = result.split("\n")
    for position, line in enumerate(lines):
        if line.startswith(TITLE_PREFIX):
            lines[position + 1:position + 1] = ["", NOTE]
            break
    else:
        raise SystemExit("title line not found; the generated skill changed shape")
    return "\n".join(lines)


def main() -> int:
    public = build(SOURCE.read_text(encoding="utf-8"))
    if "--check" in sys.argv[1:]:
        current = TARGET.read_text(encoding="utf-8").replace("\r\n", "\n")
        if current != public:
            print("FAIL published dreameros-boot skill differs from make_public_boot_skill.py output")
            return 1
        print("OK published dreameros-boot skill matches the public edition")
        return 0
    TARGET.write_text(public, encoding="utf-8", newline="\n")
    print(f"wrote {TARGET.relative_to(ROOT).as_posix()} ({len(public.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
