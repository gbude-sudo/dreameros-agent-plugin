import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HOOKS = os.path.join(os.path.dirname(HERE), "plugin")
GUARD = os.path.join(HOOKS, "done_check.py")
sys.path.insert(0, HOOKS)
import done_report as guard_report  # noqa: E402

GIT_ENV = {
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
}


def run(cmd, cwd):
    env = dict(os.environ, **GIT_ENV)
    subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, env=env)


def make_pair(tmp):
    """A working repo with a pushed commit and a bare origin."""
    origin = os.path.join(tmp, "origin.git")
    work = os.path.join(tmp, "work")
    os.makedirs(origin)
    run(["git", "init", "--bare", "-b", "main"], origin)
    os.makedirs(work)
    run(["git", "init", "-b", "main"], work)
    run(["git", "remote", "add", "origin", origin], work)
    with open(os.path.join(work, "a.txt"), "w") as handle:
        handle.write("one\n")
    run(["git", "add", "a.txt"], work)
    run(["git", "commit", "-m", "first"], work)
    run(["git", "push", "-u", "origin", "main"], work)
    return work


def guard(payload, data_dir, raw=None):
    env = dict(os.environ, CLAUDE_PLUGIN_DATA=data_dir)
    out = subprocess.run(
        [sys.executable, GUARD],
        input=raw if raw is not None else json.dumps(payload),
        capture_output=True, text=True, env=env, timeout=30,
    )
    return out.returncode, out.stdout


class DoneGuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.data = os.path.join(self.tmp, "data")
        self.work = make_pair(self.tmp)

    def test_clean_pushed_repo_is_allowed(self):
        rc, out = guard({"cwd": self.work, "last_assistant_message": "Done. I pushed the branch."}, self.data)
        self.assertEqual((rc, out), (0, ""))

    def test_unpushed_commit_with_pushed_claim_is_blocked(self):
        with open(os.path.join(self.work, "b.txt"), "w") as handle:
            handle.write("two\n")
        run(["git", "add", "b.txt"], self.work)
        run(["git", "commit", "-m", "second"], self.work)
        rc, out = guard({"cwd": self.work, "last_assistant_message": "All set, I pushed the branch."}, self.data)
        self.assertEqual(rc, 0)
        verdict = json.loads(out)
        self.assertEqual(verdict["decision"], "block")
        self.assertIn("1 commit(s) are not on the remote", verdict["reason"])

    def test_uncommitted_edit_with_a_saved_claim_is_blocked(self):
        with open(os.path.join(self.work, "a.txt"), "a") as handle:
            handle.write("edit\n")
        rc, out = guard({"cwd": self.work, "last_assistant_message": "I committed everything."}, self.data)
        self.assertIn("uncommitted", json.loads(out)["reason"])

    def test_fixed_with_uncommitted_edits_is_normal_and_allowed(self):
        with open(os.path.join(self.work, "a.txt"), "a") as handle:
            handle.write("edit\n")
        rc, out = guard({"cwd": self.work, "last_assistant_message": "Fixed the bug. Finished."}, self.data)
        self.assertEqual((rc, out), (0, ""))

    def test_negated_and_future_sentences_are_not_claims(self):
        with open(os.path.join(self.work, "b.txt"), "w") as handle:
            handle.write("two\n")
        run(["git", "add", "b.txt"], self.work)
        run(["git", "commit", "-m", "second"], self.work)
        for text in ("I have not pushed yet.", "The branch is unpushed.", "I will push after review.",
                     "Should I push this now?", "I haven't committed the rest.",
                     "Run `git push` when ready."):
            rc, out = guard({"cwd": self.work, "last_assistant_message": text}, self.data)
            self.assertEqual(out, "", text)

    def test_claims_inside_code_fences_are_ignored(self):
        with open(os.path.join(self.work, "b.txt"), "w") as handle:
            handle.write("two\n")
        run(["git", "add", "b.txt"], self.work)
        run(["git", "commit", "-m", "second"], self.work)
        text = "Example output:\n```\nDone. Pushed.\n```\nThat is the format."
        rc, out = guard({"cwd": self.work, "last_assistant_message": text}, self.data)
        self.assertEqual(out, "")

    def test_no_claim_means_no_output(self):
        with open(os.path.join(self.work, "a.txt"), "a") as handle:
            handle.write("edit\n")
        rc, out = guard({"cwd": self.work, "last_assistant_message": "Here is the plan for tomorrow."}, self.data)
        self.assertEqual((rc, out), (0, ""))

    def test_blocks_only_once_per_turn(self):
        with open(os.path.join(self.work, "a.txt"), "a") as handle:
            handle.write("edit\n")
        payload = {"cwd": self.work, "last_assistant_message": "Done.", "stop_hook_active": True}
        rc, out = guard(payload, self.data)
        self.assertEqual((rc, out), (0, ""))

    def test_missing_file_claim_is_blocked_and_present_file_is_allowed(self):
        rc, out = guard({"cwd": self.work, "last_assistant_message": "I added `CHANGELOG.md` to the repo."}, self.data)
        self.assertIn("`CHANGELOG.md`", json.loads(out)["reason"])
        with open(os.path.join(self.work, "CHANGELOG.md"), "w") as handle:
            handle.write("x\n")
        rc, out = guard({"cwd": self.work, "last_assistant_message": "I added `CHANGELOG.md` to the repo."}, self.data)
        self.assertEqual(out, "")

    def test_tests_pass_claim_needs_a_recorded_test_run(self):
        transcript = os.path.join(self.tmp, "t.jsonl")
        with open(transcript, "w") as handle:
            handle.write(json.dumps({"message": {"content": [{"type": "text", "text": "hi"}]}}) + "\n")
        payload = {"cwd": self.work, "transcript_path": transcript, "last_assistant_message": "All tests pass."}
        rc, out = guard(payload, self.data)
        self.assertIn("no test command ran", json.loads(out)["reason"])
        with open(transcript, "a") as handle:
            handle.write(json.dumps({"message": {"content": [{"type": "tool_use", "name": "Bash",
                                                              "input": {"command": "python -m pytest -q"}}]}}) + "\n")
        rc, out = guard(payload, self.data)
        self.assertEqual(out, "")

    def test_unreadable_transcript_does_not_block(self):
        payload = {"cwd": self.work, "transcript_path": os.path.join(self.tmp, "nope.jsonl"),
                   "last_assistant_message": "All tests pass."}
        rc, out = guard(payload, self.data)
        self.assertEqual(out, "")

    def test_bad_input_fails_open(self):
        self.assertEqual(guard(None, self.data, raw="not json")[0:2], (0, ""))
        self.assertEqual(guard(None, self.data, raw="")[0:2], (0, ""))

    def test_outside_a_repo_does_not_block(self):
        plain = os.path.join(self.tmp, "plain")
        os.makedirs(plain)
        rc, out = guard({"cwd": plain, "last_assistant_message": "Done. Pushed."}, self.data)
        self.assertEqual((rc, out), (0, ""))

    def test_log_holds_codes_and_never_message_text(self):
        secret = "UNIQUE-SENTENCE-9f3a"
        with open(os.path.join(self.work, "a.txt"), "a") as handle:
            handle.write("edit\n")
        guard({"cwd": self.work, "last_assistant_message": "I committed it. " + secret, "session_id": "abc"}, self.data)
        text = open(os.path.join(self.data, "caught.jsonl")).read()
        self.assertNotIn(secret, text)
        entry = json.loads(text.splitlines()[0])
        self.assertEqual(entry["codes"], ["uncommitted"])
        self.assertTrue(entry["blocked"])


class ReportTests(unittest.TestCase):
    def test_report_counts_recent_codes_and_ignores_old(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "caught.jsonl")
            now = int(time.time())
            rows = [
                {"ts": now - 100, "codes": ["unpushed"], "blocked": True},
                {"ts": now - 200, "codes": ["unpushed", "uncommitted"], "blocked": True},
                {"ts": now - 20 * 86400, "codes": ["file_missing"], "blocked": True},
            ]
            with open(path, "w") as handle:
                handle.write("\n".join(json.dumps(r) for r in rows) + "\n")
            text = guard_report.report(path=path, now=now)
            self.assertIn("caught 2 stop(s)", text)
            self.assertIn("2 x said pushed", text)
            self.assertNotIn("did not exist", text)

    def test_report_with_no_log_says_so(self):
        text = guard_report.report(path=os.path.join(tempfile.gettempdir(), "no-such-guard-log.jsonl"))
        self.assertIn("no log yet", text)


if __name__ == "__main__":
    unittest.main()
