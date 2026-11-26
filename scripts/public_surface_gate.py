#!/usr/bin/env python3
"""Public surface gate.

This repository is public. This gate stops it from showing more internal
detail over time. It scans every tracked text file for a short list of
patterns and compares the counts with a saved baseline.

Rules:
  - A count above the baseline fails the gate.
  - A hit in a file the baseline does not list fails the gate.
  - A count below the baseline passes. Run --update-baseline to lock it in.
  - --update-baseline only lowers numbers. It refuses to raise one.
  - --self-test proves every pattern fires on a known positive and stays
    quiet on clean text. CI runs it first. An empty result from a pattern
    that was never proven is not a result.

Exit codes: 0 pass, 1 violation, 2 the gate could not run (fails closed).
The gate holds no secret and prints only file names, pattern names and counts.
It never prints the text that matched.
"""

import json
import os
import re
import subprocess
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE_PATH = os.path.join("scripts", "public_surface_baseline.json")
SELF_PATHS = {
    "scripts/public_surface_gate.py",
    "scripts/test_public_surface_gate.py",
    "scripts/public_surface_baseline.json",
}
MAX_BYTES = 2_000_000

# name -> (regex, a known positive built at run time, so no file holds a real-looking value)
PATTERNS = {
    "secret_member_key": (r"dros_[A-Za-z0-9]{24,}", lambda: "dros_" + "a" * 30),
    "secret_api_key": (r"sk-[A-Za-z0-9_-]{20,}", lambda: "sk-" + "A" * 25),
    "secret_github_token": (r"gh[pousr]_[A-Za-z0-9]{30,}", lambda: "ghp_" + "a" * 36),
    "secret_cloud_key": (r"AKIA[0-9A-Z]{16}", lambda: "AKIA" + "A" * 16),
    "secret_private_key_block": (
        r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
        lambda: "-----BEGIN " + "RSA PRIVATE KEY-----",
    ),
    "secret_jwt": (
        r"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}",
        lambda: "eyJ" + "a" * 12 + ".eyJ" + "b" * 12 + "." + "c" * 12,
    ),
    "secret_bearer_literal": (r"Bearer [A-Za-z0-9._-]{30,}", lambda: "Bearer " + "a" * 40),
    "secret_assignment": (
        r"(?i)(secret|token|password|api[_-]?key)\s*[:=]\s*[\"'][A-Za-z0-9/+_=-]{24,}[\"']",
        lambda: 'token = "' + "a" * 30 + '"',
    ),
    "infra_project_id": (r"prj_[A-Za-z0-9]{20,}", lambda: "prj_" + "a" * 24),
    "infra_team_id": (r"team_[A-Za-z0-9]{20,}", lambda: "team_" + "a" * 24),
    "owner_local_path": (r"C:[/\\]Users[/\\]", lambda: "C:/" + "Users/x"),
    "owner_local_store": (r"Offline_" + r"Repo", lambda: "Offline_" + "Repo"),
    "gateway_source_path": (r"gateway/app/[a-z_0-9]+\.py", lambda: "gateway/app/" + "x.py"),
    "gateway_governance_path": (
        r"governance/(00_CORE|04_OPERATIONS|proposed|handoffs)/",
        lambda: "governance/" + "00_CORE/x.md",
    ),
    "memory_or_anchor_id": (
        r"(?i)\b(substrate|memory|anchor)[ `]+[0-9a-f]{8}\b",
        lambda: "substrate " + "0a1b2c3d",
    ),
    "owner_chat_reference": (r"hc-chat:thread:", lambda: "hc-chat:" + "thread:x"),
    "owner_quote_marker": (
        r"(?i)HC verbatim|operator typed this sentence|his exact words",
        lambda: "HC " + "verbatim",
    ),
    "incident_commit_ref": (r"(?i)\bcommit [0-9a-f]{7,40}\b", lambda: "commit " + "abc1234"),
    "incident_pr_ref": (r"(?i)\b(PR|pull request) #?\d{3,5}\b", lambda: "PR " + "#1234"),
    "owner_dated_attribution": (
        r"\b(HC|operator|Human Conductor)[ ,(]+(canon[ ,]+)?(ordered[ ,]+)?20\d\d-\d\d-\d\d",
        lambda: "HC, " + "2026-01-02",
    ),
    "dated_origin_story": (r"\bBorn 20\d\d-\d\d-\d\d\b", lambda: "Born " + "2026-01-02"),
    "dated_finding_story": (
        r"(?i)\b(built|found|measured|proven|lived|caught)[ ]+(on[ ]+|in[ ]+)?20\d\d-\d\d-\d\d",
        lambda: "Built " + "2026-01-02",
    ),
    "internal_repo_name": (
        r"\b(dreameros-(hc-command-center|light-proxy|mobile)|intentfidelityprotocol-site)\b",
        lambda: "dreameros-" + "light-proxy",
    ),
    "vendor_model_name": (
        r"(?i)\b(kimi|moonshot|fireworks|deepseek|qwen|zhipu|glm-?\d|gpt-5\.\d|claude-(opus|sonnet|haiku)-\d)",
        lambda: "kimi-" + "k2",
    ),
}

# The pattern names the baseline file knew before it began to record its own list.
ORIGINAL_PATTERN_NAMES = (
    "secret_member_key", "secret_api_key", "secret_github_token", "secret_cloud_key",
    "secret_private_key_block", "secret_jwt", "secret_bearer_literal", "secret_assignment",
    "infra_project_id", "infra_team_id", "owner_local_path", "owner_local_store",
    "gateway_source_path", "gateway_governance_path", "memory_or_anchor_id",
    "owner_chat_reference", "owner_quote_marker",
)

CLEAN_TEXT = (
    "DreamerOS connects your tools to one account. See https://dreameros.app/privacy "
    "and run the installer. Tier names are Light, Pro and Elite."
)


def scan_text(text):
    """Return a Counter of pattern name -> number of matches in text."""
    found = Counter()
    for name, (regex, _positive) in PATTERNS.items():
        n = len(re.findall(regex, text))
        if n:
            found[name] = n
    return found


def self_test():
    """Return a list of problems. An empty list means every pattern is proven."""
    problems = []
    for name, (regex, positive) in PATTERNS.items():
        sample = positive()
        if not re.search(regex, sample):
            problems.append("pattern %s did not fire on its known positive" % name)
        if re.search(regex, CLEAN_TEXT):
            problems.append("pattern %s fired on clean text" % name)
    return problems


def compare(current, baseline, only=None):
    """current, baseline: {path: {pattern: count}}. Return (violations, shrunk).

    only: when given, a set of pattern names. Other patterns are not checked.
    """
    violations, shrunk = [], []
    for path, counts in current.items():
        base = baseline.get(path, {})
        for name, n in counts.items():
            if only is not None and name not in only:
                continue
            allowed = base.get(name, 0)
            if n > allowed:
                violations.append("%s: %s has %d, baseline allows %d" % (path, name, n, allowed))
    for path, counts in baseline.items():
        cur = current.get(path, {})
        for name, allowed in counts.items():
            if cur.get(name, 0) < allowed:
                shrunk.append("%s: %s fell from %d to %d" % (path, name, allowed, cur.get(name, 0)))
    return violations, shrunk


def tracked_files():
    out = subprocess.run(
        ["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, check=True
    ).stdout
    return [p.decode("utf-8") for p in out.split(b"\0") if p]


def scan_repo():
    result = {}
    for path in tracked_files():
        if path in SELF_PATHS:
            continue
        full = os.path.join(ROOT, path)
        try:
            if os.path.getsize(full) > MAX_BYTES:
                continue
            data = open(full, "rb").read()
        except OSError:
            continue
        if b"\0" in data:
            continue
        counts = scan_text(data.decode("utf-8", errors="ignore"))
        if counts:
            result[path] = dict(counts)
    return result


def load_baseline():
    """Return (files, known_patterns). Version 1 baselines carry no pattern list."""
    with open(os.path.join(ROOT, BASELINE_PATH), "r", encoding="utf-8") as handle:
        data = json.load(handle)
    if data.get("version") not in (1, 2) or not isinstance(data.get("files"), dict):
        raise ValueError("baseline has an unknown shape")
    known = data.get("patterns") if data.get("version") == 2 else list(ORIGINAL_PATTERN_NAMES)
    if not isinstance(known, list):
        raise ValueError("baseline pattern list has an unknown shape")
    return data["files"], set(known)


def write_baseline(files):
    body = {"version": 2, "patterns": sorted(PATTERNS), "files": dict(sorted(files.items()))}
    with open(os.path.join(ROOT, BASELINE_PATH), "w", encoding="utf-8", newline="\n") as handle:
        json.dump(body, handle, indent=1, sort_keys=True)
        handle.write("\n")


def main(argv):
    problems = self_test()
    if problems:
        for line in problems:
            print("SELF-TEST FAILED: " + line)
        return 2
    if "--self-test" in argv:
        print("PUBLIC SURFACE SELF-TEST PASS: %d patterns proven" % len(PATTERNS))
        return 0
    try:
        current = scan_repo()
    except (subprocess.CalledProcessError, OSError) as exc:
        print("PUBLIC SURFACE GATE COULD NOT RUN: %s" % type(exc).__name__)
        return 2
    if "--update-baseline" in argv:
        try:
            old, known = load_baseline()
        except (OSError, ValueError):
            old, known = {}, set(PATTERNS)
        # A pattern the baseline has never seen may start above zero. Known ones may only fall.
        violations, _ = compare(current, old, only=known)
        if violations and old:
            print("REFUSED: the baseline can only go down. These rose:")
            for line in violations:
                print("  " + line)
            return 1
        write_baseline(current)
        print("BASELINE WRITTEN: %d files" % len(current))
        return 0
    try:
        baseline, _known = load_baseline()
    except (OSError, ValueError) as exc:
        print("PUBLIC SURFACE GATE COULD NOT RUN: baseline unreadable (%s)" % type(exc).__name__)
        return 2
    violations, shrunk = compare(current, baseline)
    for line in shrunk:
        print("SHRUNK (run --update-baseline to lock it in): " + line)
    if violations:
        print("PUBLIC SURFACE GATE FAILED:")
        for line in violations:
            print("  " + line)
        return 1
    total = sum(sum(c.values()) for c in current.values())
    print("PUBLIC SURFACE GATE PASS: %d files, %d matches, none above baseline" % (len(current), total))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
