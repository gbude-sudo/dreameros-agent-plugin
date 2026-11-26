#!/usr/bin/env python3
"""DreamerOS Guard: check "done" claims against real state.

Claude Code runs this when the assistant is about to stop. It reads the last
assistant message and looks for claims it can check on this machine:

  pushed   -> are there commits that are not on the remote?
  saved    -> are there uncommitted edits to tracked files?
  added X  -> does the file X exist?
  tests    -> did a test command run in this session?

If a claim does not match, it prints {"decision": "block", "reason": ...} so the
assistant must fix it or say plainly that it is left. It blocks once per turn
(stop_hook_active stops a loop). Any error means "allow": a broken guard must
never trap a session.

Privacy: nothing leaves the machine. The log keeps claim codes and a time, not
the message text.
"""

import json
import os
import re
import subprocess
import sys
import time

DONE_RE = re.compile(
    r"\b(done|all set|completed|is complete|are complete|now complete|finished|"
    r"shipped|merged|pushed|fixed|ready to merge|wrapped up)\b",
    re.IGNORECASE,
)
NEGATION_RE = re.compile(
    r"\b(not|never|yet|left|remaining|pending|todo|will|would|should|could|if|"
    r"whether|want me|shall i)\b|n't",
    re.IGNORECASE,
)
FENCE_RE = re.compile(r"```.*?```", re.DOTALL)
PUSH_RE = re.compile(r"\b(pushed|push(?:ed)? (?:to|the)|on (?:the )?remote)\b", re.IGNORECASE)
SAVE_RE = re.compile(r"\b(committed|saved|checked in)\b", re.IGNORECASE)
TEST_RE = re.compile(
    r"\b(tests? (?:pass|passed|passing|are green|all pass)|all tests pass|tests? green)\b",
    re.IGNORECASE,
)
FILE_VERB_RE = re.compile(r"\b(created|added|wrote|generated)\b", re.IGNORECASE)
BACKTICK_PATH_RE = re.compile(r"`([\w./\\-]+\.[A-Za-z0-9]{1,8})`")
TEST_CMD_RE = re.compile(
    r"\b(pytest|unittest|vitest|jest|mocha|npm (?:run )?test|pnpm (?:run )?test|"
    r"yarn test|go test|cargo test|dotnet test|mvn test|gradle test|rspec|phpunit)\b",
    re.IGNORECASE,
)

MESSAGES = {
    "unpushed": "You said the work is pushed, but {n} commit(s) are not on the remote.",
    "no_upstream": "You said the work is pushed, but this branch has no remote branch set.",
    "uncommitted": "Tracked files have {n} uncommitted edit(s), so the work is not saved.",
    "no_test_run": "You said the tests pass, but no test command ran in this session.",
    "file_missing": "You said you added `{path}`, but that file does not exist.",
}


def git(cwd, *args):
    """Return stdout of a git command, or None when git cannot answer."""
    try:
        out = subprocess.run(
            ["git", "-C", cwd] + list(args),
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout


def in_repo(cwd):
    return git(cwd, "rev-parse", "--is-inside-work-tree") is not None


def test_command_ran(transcript_path):
    """True when the session transcript holds a Bash call that looks like a test run."""
    if not transcript_path or not os.path.isfile(transcript_path):
        return None  # cannot tell
    try:
        with open(transcript_path, "r", encoding="utf-8", errors="ignore") as handle:
            for line in handle:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                message = entry.get("message") if isinstance(entry, dict) else None
                content = message.get("content") if isinstance(message, dict) else None
                if not isinstance(content, list):
                    continue
                for block in content:
                    if (
                        isinstance(block, dict)
                        and block.get("type") == "tool_use"
                        and block.get("name") == "Bash"
                        and TEST_CMD_RE.search(str((block.get("input") or {}).get("command", "")))
                    ):
                        return True
    except OSError:
        return None
    return False


def sentences(message):
    """Split into sentences, with fenced code removed. Each is checked alone."""
    text = FENCE_RE.sub(" ", message)
    return [part for part in re.split(r"(?<=[.!?])\s+|\n", text) if part.strip()]


def claims_in(message):
    """Flags for claims made in plain, non-negated sentences."""
    flags = {"done": False, "push": False, "save": False, "tests": False}
    for sentence in sentences(message):
        if NEGATION_RE.search(sentence):
            continue
        if DONE_RE.search(sentence):
            flags["done"] = True
        if PUSH_RE.search(sentence):
            flags["push"] = True
        if SAVE_RE.search(sentence):
            flags["save"] = True
        if TEST_RE.search(sentence):
            flags["tests"] = True
    return flags


def check(payload):
    """Return a list of (code, text) gaps. Empty means nothing to say."""
    message = str(payload.get("last_assistant_message") or "")
    cwd = str(payload.get("cwd") or os.getcwd())
    if not message:
        return []
    flags = claims_in(message)
    gaps = []

    if in_repo(cwd):
        if flags["push"]:
            upstream = git(cwd, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
            if upstream is None:
                gaps.append(("no_upstream", MESSAGES["no_upstream"]))
            else:
                ahead = git(cwd, "rev-list", "--count", "@{u}..HEAD")
                if ahead and ahead.strip().isdigit() and int(ahead) > 0:
                    gaps.append(("unpushed", MESSAGES["unpushed"].format(n=int(ahead))))
        if flags["push"] or flags["save"]:
            status = git(cwd, "status", "--porcelain", "--untracked-files=no")
            if status:
                n = len([ln for ln in status.splitlines() if ln.strip()])
                if n:
                    gaps.append(("uncommitted", MESSAGES["uncommitted"].format(n=n)))

    if flags["tests"]:
        ran = test_command_ran(payload.get("transcript_path"))
        if ran is False:
            gaps.append(("no_test_run", MESSAGES["no_test_run"]))

    for sentence in sentences(message):
        if NEGATION_RE.search(sentence) or not FILE_VERB_RE.search(sentence):
            continue
        for path in BACKTICK_PATH_RE.findall(sentence):
            full = path if os.path.isabs(path) else os.path.join(cwd, path)
            if not os.path.exists(full):
                gaps.append(("file_missing", MESSAGES["file_missing"].format(path=path)))
    return gaps


def log_path():
    base = os.environ.get("CLAUDE_PLUGIN_DATA") or os.path.join(os.path.expanduser("~"), ".dreameros-guard")
    return os.path.join(base, "caught.jsonl")


def record(payload, gaps, blocked):
    """Append claim codes and a time. Never the message text."""
    try:
        path = log_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        entry = {
            "ts": int(time.time()),
            "session": str(payload.get("session_id") or "")[:12],
            "codes": sorted({code for code, _ in gaps}),
            "blocked": bool(blocked),
        }
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry) + "\n")
    except OSError:
        pass


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        gaps = check(payload)
        if not gaps:
            return 0
        repeat = bool(payload.get("stop_hook_active"))
        record(payload, gaps, blocked=not repeat)
        if repeat:
            return 0  # block once per turn; never loop
        reason = (
            "Guard found %d gap(s) between what you said and what is real:\n- %s\n"
            "Fix each one, or tell the user plainly that it is left and why. "
            "Do not end with 'done' while a gap is open."
            % (len(gaps), "\n- ".join(text for _, text in gaps))
        )
        sys.stdout.write(json.dumps({"decision": "block", "reason": reason}))
        return 0
    except Exception:  # a broken guard must never trap a session
        return 0


if __name__ == "__main__":
    sys.exit(main())
