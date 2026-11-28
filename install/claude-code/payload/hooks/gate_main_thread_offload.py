#!/usr/bin/env python3
"""Runtime half of boot canon R7 and R30: few mechanical calls in the main thread.

PreToolUse gate for Bash, Grep and Glob. It only acts in the MAIN thread (a
subagent hook payload carries agent_id; the main thread does not). It counts
mechanical calls per user turn. The fourth mechanical call in one turn is
denied with a message that tells the model to batch the rest into one call
(boot canon R30 rung 1), and to use a Haiku subagent only for a large batch.

The same file is registered a second time under UserPromptSubmit. That event
resets the counter, so the count is per user turn.

Fail open: any internal error is logged to stderr and the call is allowed. A
bug here must never stop a session. Run `--self-test` to prove the gate fires
through the real stdin path, as R1c requires.

Not blocked and not counted: git commit, git push, gh pr create or merge,
file edits, any command that is not wholly mechanical, and any command that
carries the text --hc-override in a comment.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
import tempfile

LIMIT = 3
DENY_MESSAGE = (
    "R30 then R7: put the remaining mechanical commands into ONE batched "
    "script in ONE call. Use a Haiku subagent only for a large batch of "
    "independent items, and name the model."
)

READ_TOOLS = {"Grep", "Glob"}
SIMPLE_READERS = {
    "grep", "egrep", "fgrep", "rg", "find", "wc", "sha256sum", "sha1sum",
    "md5sum", "curl", "jq", "cat", "head", "tail", "ls", "sort", "uniq", "cut",
    "tr", "stat", "file", "diff", "cmp", "test", "[", "echo", "printf", "true",
    "false", "pwd", "which", "type", "date", "env", "printenv", "xargs", "tee",
}
GIT_READS = {
    "log", "diff", "show", "ls-tree", "ls-files", "rev-parse", "rev-list",
    "status", "cat-file", "grep", "blame", "ls-remote", "fetch", "shortlog",
    "describe", "name-rev", "merge-base", "for-each-ref", "diff-tree",
    "show-ref", "count-objects", "config", "branch", "tag", "remote",
}
GH_READ_NOUNS = {"pr", "issue", "run", "repo", "release", "workflow", "search"}
GH_READ_VERBS = {"view", "list", "checks", "status", "diff", "download"}
CHECK_SCRIPT = re.compile(r"(^|[/\\._-])(check|verify|audit|lint|validate|test|tests|pytest)", re.I)
WRITE_HINT = re.compile(r"(^|\s)(>|>>)(\s|\S)|\bsed\s+(-[a-zA-Z]*i|--in-place)|\btee\b")
OVERRIDE = "--hc-override"
SEPARATORS = re.compile(r"\|\||&&|;|\||\n")
SAFE_ID = re.compile(r"[^A-Za-z0-9_.-]")


def _state_path(session_id: str) -> str:
    return os.path.join(
        tempfile.gettempdir(), "dreameros-offload-" + SAFE_ID.sub("_", session_id or "unknown") + ".json"
    )


def _load(path: str) -> int:
    try:
        with open(path, "r", encoding="ascii") as handle:
            return int(json.load(handle).get("count", 0))
    except Exception:
        return 0


def _save(path: str, count: int) -> None:
    try:
        with open(path, "w", encoding="ascii") as handle:
            json.dump({"count": count}, handle)
    except Exception as exc:  # fail open
        print("gate_main_thread_offload: state write failed: %s" % exc, file=sys.stderr)


def _strip_git_options(tokens: list[str]) -> list[str]:
    """Drop `git -C path` and `git -c k=v` so the subcommand is first."""
    rest = tokens[1:]
    while rest:
        if rest[0] in ("-C", "-c", "--git-dir", "--work-tree") and len(rest) >= 2:
            rest = rest[2:]
        elif rest[0].startswith("--git-dir=") or rest[0].startswith("--work-tree=") or rest[0] in ("--no-pager", "-P"):
            rest = rest[1:]
        else:
            break
    return rest


def _segment_kind(segment: str) -> str:
    """Return 'mechanical', 'other' for one command segment."""
    try:
        tokens = shlex.split(segment, comments=True)
    except ValueError:
        return "other"
    # Leading VAR=value assignments.
    while tokens and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]):
        tokens = tokens[1:]
    if not tokens:
        return "mechanical"  # empty or comment-only segment adds nothing
    cmd = os.path.basename(tokens[0])
    args = tokens[1:]
    if cmd == "git":
        rest = _strip_git_options(tokens)
        if not rest or rest[0] not in GIT_READS:
            return "other"
        if rest[0] in ("branch", "tag", "remote", "config"):
            # Only the list or get forms are reads.
            mutating = {"-d", "-D", "-m", "-M", "-c", "-C", "add", "remove", "rm", "set-url", "rename", "--unset", "--add", "--set"}
            if any(a in mutating for a in rest[1:]):
                return "other"
            if rest[0] == "config" and not any(a in ("--get", "--get-all", "--list", "-l", "--get-regexp") for a in rest[1:]):
                return "other"
        return "mechanical"
    if cmd == "gh":
        if not args:
            return "other"
        if args[0] == "api":
            flags = " ".join(args[1:])
            if re.search(r"(^|\s)(-X|--method)(\s+|=)(POST|PUT|PATCH|DELETE)", flags, re.I):
                return "other"
            if re.search(r"(^|\s)(-f|-F|--field|--raw-field|--input)(\s|=)", flags):
                return "other"
            return "mechanical"
        if args[0] in GH_READ_NOUNS and len(args) >= 2 and args[1] in GH_READ_VERBS:
            return "mechanical"
        return "other"
    if cmd == "curl":
        if any(a in ("-X", "--request", "-d", "--data", "--data-raw", "--data-binary", "-F", "--form", "-T", "--upload-file", "-o", "-O") or a.startswith("--data") for a in args):
            return "other"
        return "mechanical"
    if cmd == "sed":
        if any(a.startswith("-i") or a == "--in-place" for a in args):
            return "other"
        return "mechanical"
    if cmd in ("tee", "xargs"):
        return "other"
    if cmd in SIMPLE_READERS:
        return "mechanical"
    if cmd in ("pytest", "py.test", "ruff", "shellcheck"):
        return "mechanical"
    if cmd in ("python", "python3", "bash", "sh", "node", "pwsh", "powershell"):
        joined = " ".join(args)
        if cmd.startswith("python") and "-m" in args:
            i = args.index("-m")
            if i + 1 < len(args) and args[i + 1] in ("pytest", "unittest"):
                return "mechanical"
        script = next((a for a in args if not a.startswith("-")), "")
        if script and CHECK_SCRIPT.search(os.path.basename(script)):
            return "mechanical"
        return "other"
    return "other"


def classify_bash(command: str) -> str:
    """Return 'mechanical' or 'other' for a whole Bash command."""
    if not command or OVERRIDE in command:
        return "other"
    if re.search(r"(^|[^<>&0-9])>{1,2}\s*[^&\s]", command) and not re.search(r">\s*/dev/null", command):
        return "other"  # redirect to a file is a write
    segments = [s.strip() for s in SEPARATORS.split(command) if s.strip()]
    if not segments:
        return "other"
    kinds = [_segment_kind(s) for s in segments]
    return "mechanical" if all(k == "mechanical" for k in kinds) else "other"


def decide(payload: dict, count: int) -> tuple[str, int]:
    """Pure decision. Returns (action, new_count). action is allow, deny or reset."""
    event = payload.get("hook_event_name")
    if event == "UserPromptSubmit":
        return "reset", 0
    if payload.get("agent_id"):
        return "allow", count  # subagent: this is where mechanical work belongs
    tool = payload.get("tool_name")
    if tool in READ_TOOLS:
        mechanical = True
    elif tool == "Bash":
        tool_input = payload.get("tool_input") or {}
        command = tool_input.get("command") if isinstance(tool_input, dict) else ""
        mechanical = classify_bash(str(command or "")) == "mechanical"
        if OVERRIDE in str(command or ""):
            return "allow", count
    else:
        return "allow", count
    if not mechanical:
        return "allow", count
    if count >= LIMIT:
        return "deny", count
    return "allow", count + 1


def run(raw: str) -> str | None:
    """Handle one hook payload. Return the stdout JSON, or None for no output."""
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        return None
    path = _state_path(str(payload.get("session_id") or ""))
    action, new_count = decide(payload, _load(path))
    if action == "reset":
        _save(path, 0)
        return None
    if action == "deny":
        return json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": DENY_MESSAGE,
        }})
    _save(path, new_count)
    return None


def self_test() -> int:
    """Feed real payloads through this file on stdin. Return 0 when the gate fires."""
    sid = "selftest-%d" % os.getpid()
    me = os.path.abspath(__file__)

    def call(event: str, tool: str = "Bash", command: str = "", agent: bool = False) -> str:
        body = {"session_id": sid, "hook_event_name": event, "tool_name": tool,
                "tool_input": {"command": command}}
        if agent:
            body["agent_id"] = "a1"
        out = subprocess.run([sys.executable, me], input=json.dumps(body), capture_output=True, text=True, timeout=20)
        return out.stdout
    try:
        call("UserPromptSubmit")
        for i in range(3):
            if "deny" in call("PreToolUse", command="git log --oneline"):
                print("SELF-TEST FAIL: denied call %d" % (i + 1)); return 1
        if "deny" not in call("PreToolUse", command="grep -rn foo ."):
            print("SELF-TEST FAIL: fourth mechanical call was not denied"); return 1
        if "deny" in call("PreToolUse", command="git commit -m x"):
            print("SELF-TEST FAIL: git commit was denied"); return 1
        if "deny" in call("PreToolUse", command="grep x .", agent=True):
            print("SELF-TEST FAIL: subagent call was denied"); return 1
        call("UserPromptSubmit")
        if "deny" in call("PreToolUse", command="grep x ."):
            print("SELF-TEST FAIL: counter did not reset"); return 1
    finally:
        try:
            os.remove(_state_path(sid))
        except OSError:
            pass
    print("SELF-TEST OK: gate fires on the fourth mechanical call and resets per turn")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    try:
        out = run(sys.stdin.read())
        if out:
            print(out)
    except Exception as exc:  # fail open
        print("gate_main_thread_offload: failed open: %s" % exc, file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
