"""Tests for gate_dispatch_names_model.py (boot canon R7a runtime half)."""
import importlib.util
import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(HERE, "..", "payload", "hooks", "gate_dispatch_names_model.py")
spec = importlib.util.spec_from_file_location("gate_dispatch", PATH)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def call(tool, tool_input, **extra):
    return dict({"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": tool_input}, **extra)


class DecideTests(unittest.TestCase):
    def test_missing_model_denied(self):
        for tool in ("Agent", "Task"):
            self.assertEqual(gate.decide(call(tool, {"subagent_type": "general-purpose", "prompt": "p"})), "deny")

    def test_empty_model_denied(self):
        for bad in ("", "   ", None, 5):
            self.assertEqual(gate.decide(call("Agent", {"prompt": "p", "model": bad})), "deny", repr(bad))

    def test_model_present_allowed(self):
        self.assertEqual(gate.decide(call("Agent", {"prompt": "p", "model": "haiku"})), "allow")

    def test_fork_allowed(self):
        self.assertEqual(gate.decide(call("Agent", {"subagent_type": "fork", "prompt": "p"})), "allow")

    def test_applies_in_subagents(self):
        self.assertEqual(gate.decide(call("Agent", {"prompt": "p"}, agent_id="a1")), "deny")

    def test_other_tools_ignored(self):
        self.assertEqual(gate.decide(call("Bash", {"command": "ls"})), "allow")


class RunTests(unittest.TestCase):
    def test_deny_json_shape(self):
        out = json.loads(gate.run(json.dumps(call("Agent", {"prompt": "p"}))))
        hso = out["hookSpecificOutput"]
        self.assertEqual(hso["permissionDecision"], "deny")
        self.assertEqual(hso["hookEventName"], "PreToolUse")
        self.assertIn("R7a", hso["permissionDecisionReason"])

    def test_allow_has_no_output(self):
        self.assertIsNone(gate.run(json.dumps(call("Agent", {"prompt": "p", "model": "opus"}))))


class FailOpenTests(unittest.TestCase):
    def run_hook(self, stdin):
        return subprocess.run([sys.executable, PATH], input=stdin, capture_output=True, text=True, timeout=20)

    def test_garbage_input_allows(self):
        out = self.run_hook("not json")
        self.assertEqual(out.returncode, 0)
        self.assertEqual(out.stdout, "")
        self.assertIn("failed open", out.stderr)

    def test_non_dict_tool_input_allows(self):
        out = self.run_hook(json.dumps(call("Agent", "oops")))
        self.assertEqual(out.returncode, 0)
        self.assertEqual(out.stdout, "")

    def test_self_test_passes(self):
        out = subprocess.run([sys.executable, PATH, "--self-test"], capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)

    def test_fragment_registers_gate(self):
        frag = json.load(open(os.path.join(HERE, "..", "payload", "settings.fragment.json")))
        groups = [g for g in frag["hooks"]["PreToolUse"] if g.get("matcher") == "Agent|Task"]
        self.assertEqual(len(groups), 1)
        self.assertIn("gate_dispatch_names_model.py", groups[0]["hooks"][0]["command"])


if __name__ == "__main__":
    unittest.main()
