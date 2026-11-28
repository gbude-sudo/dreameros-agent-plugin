#!/usr/bin/env python3
"""Print what the DreamerOS done check caught in the last 7 days, from the local log."""

import json
import os
import sys
import time


def log_path():
    base = os.environ.get("CLAUDE_PLUGIN_DATA") or os.path.join(os.path.expanduser("~"), ".dreameros", "done-check")
    return os.path.join(base, "caught.jsonl")


LABELS = {
    "unpushed": "said pushed, commits were not on the remote",
    "no_upstream": "said pushed, no remote branch was set",
    "uncommitted": "said done, tracked files had uncommitted edits",
    "no_test_run": "said tests pass, no test command ran",
    "file_missing": "said a file was added, it did not exist",
}


def report(path=None, now=None, days=7):
    path = path or log_path()
    now = now or int(time.time())
    cutoff = now - days * 86400
    counts = {}
    total = 0
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if int(entry.get("ts", 0)) < cutoff:
                    continue
                total += 1
                for code in entry.get("codes", []):
                    counts[code] = counts.get(code, 0) + 1
    except OSError:
        return "The done check has no log yet. Nothing was caught, or it has not run."
    if not total:
        return "The done check caught nothing in the last %d days." % days
    lines = ["The done check caught %d stop(s) with a gap in the last %d days:" % (total, days)]
    for code, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        lines.append("- %d x %s" % (n, LABELS.get(code, code)))
    return "\n".join(lines)


if __name__ == "__main__":
    sys.stdout.write(report() + "\n")
