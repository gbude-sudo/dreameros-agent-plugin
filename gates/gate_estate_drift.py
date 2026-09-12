"""Estate drift gate. A Stop hook that runs the standing check the operator
should never have had to ask for.

WHY THIS EXISTS, and the count is the reason. On 2026-09-11 into 2026-09-12 the
operator typed this sentence NINE times in one session, nearly word for word:

    "you know what we were tyring to do.. check offload, git, dreamoeros..
     keeping as much computer as possblie local"

Turns 107, 111, 115, 120, 121, 123, 126, 129, and again after the inventory
that counted the first eight. He was not repeating himself for emphasis. He was
reinstalling a standing instruction by hand, because the session kept dropping
it, and each retype cost him a turn.

An instruction said once is a request. An instruction said nine times is a
thing the assistant cannot be trusted to remember, and the fix for that is not
a better memory. It is a machine that does the check whether anybody remembers
or not.

WHAT IT CHECKS, and it is exactly what he asks for every time:
  OFFLOAD   is the local record repository committed
  GIT       does local main match cloud main in every estate repo
  ALL       is anything uncommitted anywhere, which is how work gets lost

WHEN IT HOLDS THE TURN. Only when something could actually be LOST: an
uncommitted file in a repository. Divergence between local and cloud main is
reported but does not hold, because a branch behind its remote loses nothing
and holding on it would make the gate obnoxious enough to be removed. Being
removed is the only way a gate truly fails.

COST. Measured 2026-09-12: the no-network sweep of six repositories takes about
1.0 seconds, and one network fetch about 1.35 seconds. Fetches are throttled to
once every ten minutes through a marker file, so the common case stays near a
second and the hook fits comfortably inside a Stop budget.

FAIL-OPEN, ALWAYS. Any exception, missing repository or unexpected shape exits
0 and lets the turn end. A gate that crashes the session is worse than the
problem it guards.

ASCII only. No em dashes.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time

ROOT = r"C:\Users\PC\Documents\DreamerOS"
REPOS = [
    "dreameros-app-site",
    "dreameros-scs-gateway",
    "dreamerOS",
    "dreameros-agent-plugin",
    "dreameros-app-frontend",
    "Offline_Repo",
]
FETCH_EVERY_SECONDS = 600
MARK = os.path.join(os.path.expanduser("~"), ".claude", "hook-marks", "estate_drift_fetch")


def git(repo: str, *args: str, timeout: int = 20) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", os.path.join(ROOT, repo)] + list(args),
            capture_output=True, text=True, timeout=timeout,
        )
        return (out.stdout or "").strip()
    except Exception:
        return ""


def should_fetch() -> bool:
    try:
        os.makedirs(os.path.dirname(MARK), exist_ok=True)
        if os.path.exists(MARK):
            if time.time() - os.path.getmtime(MARK) < FETCH_EVERY_SECONDS:
                return False
        with open(MARK, "w", encoding="utf-8") as fh:
            fh.write(str(time.time()))
        return True
    except Exception:
        return False


def main() -> int:
    try:
        fetch = should_fetch()
        dirty, diverged, missing = [], [], []

        for r in REPOS:
            path = os.path.join(ROOT, r, ".git")
            if not os.path.exists(path):
                missing.append(r)
                continue
            if fetch:
                git(r, "fetch", "origin", "-q", timeout=25)

            status = git(r, "status", "--porcelain")
            if status:
                n = len([ln for ln in status.splitlines() if ln.strip()])
                tracked = len([ln for ln in status.splitlines()
                               if ln[:2].strip() and not ln.startswith("??")])
                dirty.append((r, n, tracked))

            # Offline_Repo is local by design and has no remote. Comparing it
            # against a cloud main it was never meant to have would report a
            # permanent false drift, and a gate that cries wolf gets removed.
            local = git(r, "rev-parse", "--short", "main")
            cloud = git(r, "rev-parse", "--short", "origin/main")
            if local and cloud and local != cloud:
                diverged.append((r, local, cloud))

        # Nothing to say. Silence is the right output for a clean estate.
        if not dirty and not diverged and not missing:
            return 0

        lines = ["ESTATE DRIFT, checked automatically so it does not have to be asked for."]
        if dirty:
            lines.append("")
            lines.append("UNCOMMITTED, this is how work gets lost:")
            for r, n, tracked in dirty:
                lines.append("  %-24s %d entries, %d of them tracked edits" % (r, n, tracked))
        if diverged:
            lines.append("")
            lines.append("LOCAL AND CLOUD MAIN DISAGREE, reported only:")
            for r, l, c in diverged:
                lines.append("  %-24s local:%-10s cloud:%s" % (r, l, c))
        if missing:
            lines.append("")
            lines.append("NOT A CHECKOUT: " + ", ".join(missing))

        body = "\n".join(lines)

        # Only untracked-or-tracked CHANGES can be lost. Divergence alone is
        # recoverable with a pull and never justifies holding the turn.
        tracked_edits = sum(t for _, _, t in dirty)
        if tracked_edits > 0:
            print(json.dumps({
                "continue": False,
                "stopReason": (
                    body
                    + "\n\nTracked edits are uncommitted. Commit them by explicit "
                      "path, or say plainly in the reply that they are being left "
                      "and why. Do not end a turn leaving edited files unsaved: "
                      "that is the thing he keeps asking about."
                ),
                "systemMessage": "Hold on - there are uncommitted edits. Saving them before this turn ends.",
            }))
            return 0

        # Untracked junk or a behind branch: say it, do not hold.
        print(json.dumps({"systemMessage": body}))
        return 0

    except Exception:
        return 0  # fail open, always


if __name__ == "__main__":
    sys.exit(main())
