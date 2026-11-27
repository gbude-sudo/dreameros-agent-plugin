"""Tests for gate_main_thread_offload.py (boot canon R7 runtime half)."""
import importlib.util
import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(HERE, "..", "payload", "hooks", "gate_main_thread_offload.py")
spec = importlib.util.spec_from_file_location("gate_offload", PATH)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def bash(cmd, **extra):
    return dict({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": cmd}}, **extra)


class DecideTests(unittest.TestCase):
    def test_fourth_mechanical_call_denied(self):
        count = 0
        for _ in range(3):
            action, count = gate.decide(bash("git log --oneline"), count)
            self.assertEqual(action, "allow")
        self.assertEqual(gate.decide(bash("grep -rn x ."), count)[0], "deny")

    def test_subagent_never_counted_or_denied(self):
        self.assertEqual(gate.decide(bash("grep x .", agent_id="a1"), 99), ("allow", 99))

    def test_prompt_resets(self):
        self.assertEqual(gate.decide({"hook_event_name": "UserPromptSubmit"}, 7), ("reset", 0))

    def test_grep_and_glob_tools_count(self):
        for tool in ("Grep", "Glob"):
            self.assertEqual(gate.decide({"hook_event_name": "PreToolUse", "tool_name": tool}, 3)[0], "deny")

    def test_never_blocked(self):
        for cmd in ("git commit -m x", "git push origin b", "gh pr create --title t", "gh pr merge 3",
                    "sed -i s/a/b/ f", "echo x > f.txt", "git status && git commit -m y",
                    "grep x . # --hc-override", "curl -X POST http://x", "gh api -X POST repos/a/b",
                    "gh api repos/a/b -f k=v", "git branch -D x", "rm -rf build"):
            self.assertEqual(gate.decide(bash(cmd), 3)[0], "allow", cmd)

    def test_mechanical_commands_counted(self):
        for cmd in ("gh api repos/a/b/pulls", "git -C /r log -3", "git ls-tree HEAD", "git diff a...b",
                    "rg foo | wc -l", "find . -name x", "sha256sum f", "curl -s http://x | jq .",
                    "python scripts/check_x.py", "python -m pytest -q", "git show abc"):
            self.assertEqual(gate.decide(bash(cmd), 3)[0], "deny", cmd)

    def test_other_tools_ignored(self):
        self.assertEqual(gate.decide({"hook_event_name": "PreToolUse", "tool_name": "Edit"}, 3)[0], "allow")


class FailOpenTests(unittest.TestCase):
    def run_hook(self, stdin):
        return subprocess.run([sys.executable, PATH], input=stdin, capture_output=True, text=True, timeout=20)

    def test_garbage_input_allows(self):
        out = self.run_hook("not json")
        self.assertEqual(out.returncode, 0)
        self.assertEqual(out.stdout, "")
        self.assertIn("failed open", out.stderr)

    def test_self_test_passes(self):
        out = subprocess.run([sys.executable, PATH, "--self-test"], capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)

    def test_fragment_registers_both_events(self):
        frag = json.load(open(os.path.join(HERE, "..", "payload", "settings.fragment.json")))
        pre = [g for g in frag["hooks"]["PreToolUse"] if g.get("matcher") == "Bash|Grep|Glob"]
        self.assertEqual(len(pre), 1)
        ups = [h["command"] for g in frag["hooks"]["UserPromptSubmit"] for h in g["hooks"]]
        self.assertEqual(sum("gate_main_thread_offload.py" in c for c in ups), 1)


if __name__ == "__main__":
    unittest.main()
