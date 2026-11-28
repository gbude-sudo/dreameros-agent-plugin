"""Tests for gate-stop-no-half-states.sh, the loop guard.

The defect this pins: the gate blocked, then allowed the identical state once,
then erased its own memory. So the next reply blocked again. One dirty
worktree meant one extra model turn on every reply. The gate must block when
the set of half-states CHANGES, tell the operator once, then stay quiet.

Run: python -m unittest install/claude-code/tests/test_gate_stop_no_half_states.py -v
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

GATE = Path(__file__).resolve().parents[1] / "payload" / "hooks" / "gate-stop-no-half-states.sh"
BASH = shutil.which("bash")


def git(cwd, *args):
    subprocess.run(
        ["git", "-C", str(cwd), *args],
        check=True, capture_output=True,
        env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
             "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"},
    )


@unittest.skipUnless(BASH, "bash is not installed")
class LoopGuard(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="halfstates-"))
        self.root = self.tmp / "root"
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.repo = self.root / "dreameros-scs-gateway"
        self.repo.mkdir(parents=True)
        git(self.repo, "init", "-q", "-b", "main")
        (self.repo / "a.txt").write_text("a\n")
        git(self.repo, "add", "a.txt")
        git(self.repo, "commit", "-q", "-m", "init")
        script = GATE.read_text().replace("__DREAMEROS_REPO_ROOT__", self.root.as_posix())
        self.script = self.tmp / "gate.sh"
        self.script.write_text(script)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def dirty_worktree(self, name):
        wt = self.tmp / name
        git(self.repo, "worktree", "add", "-q", "-b", name, str(wt))
        (wt / "scratch.txt").write_text("unsaved\n")
        return wt

    def run_gate(self):
        env = {**os.environ, "HOME": str(self.home)}
        out = subprocess.run(
            [BASH, str(self.script)], capture_output=True, text=True, env=env, timeout=60
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        text = out.stdout.strip()
        return json.loads(text) if text else {}

    def test_same_state_blocks_once_then_stays_quiet(self):
        self.dirty_worktree("lane-one")
        first = self.run_gate()
        self.assertIs(first.get("continue"), False, "first sight must block")
        second = self.run_gate()
        self.assertNotIn("continue", second, "second pass must allow")
        self.assertIn("GATE ESCALATION", second.get("systemMessage", ""))
        for n in range(3):
            later = self.run_gate()
            self.assertNotIn("continue", later, f"reply {n + 3} must not block again")
            self.assertNotIn("GATE ESCALATION", later.get("systemMessage", ""))

    def test_new_half_state_blocks_again(self):
        self.dirty_worktree("lane-one")
        self.run_gate()
        self.run_gate()
        self.dirty_worktree("lane-two")
        again = self.run_gate()
        self.assertIs(again.get("continue"), False, "a new dirty worktree must block")

    def test_clean_resets_the_memory(self):
        wt = self.dirty_worktree("lane-one")
        self.run_gate()
        self.run_gate()
        (wt / "scratch.txt").unlink()
        self.assertEqual(self.run_gate(), {})
        (wt / "scratch.txt").write_text("unsaved again\n")
        back = self.run_gate()
        self.assertIs(back.get("continue"), False, "dirty after clean must block again")

    def test_staged_file_in_primary_checkout_still_blocks(self):
        (self.repo / "b.txt").write_text("b\n")
        git(self.repo, "add", "b.txt")
        out = self.run_gate()
        self.assertIs(out.get("continue"), False)
        self.assertIn("STAGED", out.get("stopReason", ""))


if __name__ == "__main__":
    unittest.main()
