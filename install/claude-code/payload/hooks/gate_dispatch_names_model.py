#!/usr/bin/env python3
"""Runtime half of boot canon R7a: every dispatch names its model.

PreToolUse gate for the Agent and Task tools. A call whose tool_input has no
non-empty "model" is denied, with one exception: a fork (subagent_type "fork")
always inherits the parent model, so it needs no model name.

The gate applies in the main thread and in subagents. A subagent that
dispatches work must name a model too.

Fail open: any internal error is logged to stderr and the call is allowed. A
bug here must never stop a session. Run `--self-test` to prove the gate fires
through the real stdin path, as R1c requires.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

DISPATCH_TOOLS = {"Agent", "Task"}
DENY_MESSAGE = (
    "R7a: every dispatch names its model. "
    "Add model haiku for gathering, sonnet for diagnosis, opus for judgement."
)


def decide(payload: dict) -> str:
    """Pure decision. Returns allow or deny."""
    if payload.get("hook_event_name") not in (None, "PreToolUse"):
        return "allow"
    if payload.get("tool_name") not in DISPATCH_TOOLS:
        return "allow"
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return "allow"  # unknown shape: fail open
    if tool_input.get("subagent_type") == "fork":
        return "allow"  # a fork inherits the parent model
    model = tool_input.get("model")
    if isinstance(model, str) and model.strip():
        return "allow"
    return "deny"


def run(raw: str) -> str | None:
    """Handle one hook payload. Return the stdout JSON, or None for no output."""
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        return None
    if decide(payload) == "deny":
        return json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": DENY_MESSAGE,
        }})
    return None


def self_test() -> int:
    """Feed real payloads through this file on stdin. Return 0 when the gate fires."""
    me = os.path.abspath(__file__)

    def call(tool: str, tool_input: dict, agent: bool = False) -> str:
        body = {"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": tool_input}
        if agent:
            body["agent_id"] = "a1"
        out = subprocess.run([sys.executable, me], input=json.dumps(body),
                             capture_output=True, text=True, timeout=20)
        return out.stdout

    if "deny" not in call("Agent", {"subagent_type": "general-purpose", "prompt": "x", "description": "d"}):
        print("SELF-TEST FAIL: dispatch with no model was not denied"); return 1
    if "deny" not in call("Task", {"prompt": "x"}, agent=True):
        print("SELF-TEST FAIL: subagent dispatch with no model was not denied"); return 1
    if "deny" in call("Agent", {"subagent_type": "general-purpose", "prompt": "x", "model": "haiku"}):
        print("SELF-TEST FAIL: dispatch with a model was denied"); return 1
    if "deny" in call("Agent", {"subagent_type": "fork", "prompt": "x"}):
        print("SELF-TEST FAIL: fork was denied"); return 1
    print("SELF-TEST OK: gate denies a dispatch with no model and allows model or fork")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    try:
        out = run(sys.stdin.read())
        if out:
            print(out)
    except Exception as exc:  # fail open
        print("gate_dispatch_names_model: failed open: %s" % exc, file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
