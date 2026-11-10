"""Exercise the public quote-fingerprint scanner without private fixtures."""
import contextlib
import hashlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import validate

from scripts.validate import private_quote_window_hits


class PrivateQuoteScanTests(unittest.TestCase):
    def test_detects_windows_across_whitespace_and_json_line_breaks(self):
        words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima"]
        digest = hashlib.sha256(" ".join(words).encode()).hexdigest()
        self.assertEqual(private_quote_window_hits(" ".join(words), {digest}, 12), 1)
        self.assertEqual(private_quote_window_hits(" ".join(words[:6]) + "\\n" + " ".join(words[6:]), {digest}, 12), 1)
        self.assertEqual(private_quote_window_hits(" ".join(words[:-1]), {digest}, 12), 0)

    def test_export_without_git_still_scans_files(self):
        words = "one two three four five six seven eight nine ten eleven twelve"
        digest = hashlib.sha256(words.encode()).hexdigest()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "repo"
            root.mkdir()
            private_baseline = Path(temp) / "private-baseline.json"
            private_baseline.write_text(json.dumps({"window_words": 12, "sha256": [digest], "targeted_window_words": 8, "targeted_sha256": [digest], "allowed_targeted_contexts": []}))
            (root / "public.txt").write_text(words)
            with patch.object(validate, "ROOT", root), patch.dict(validate.os.environ, {"DREAMEROS_PRIVATE_QUOTE_BASELINE": str(private_baseline)}), patch.object(validate.subprocess, "check_output", side_effect=FileNotFoundError), patch.object(validate, "FAILS", []):
                validate.check_private_quote_windows()
                self.assertTrue(any("public.txt" in failure for failure in validate.FAILS))

    def test_missing_private_baseline_reports_unverified(self):
        output = io.StringIO()
        with patch.dict(validate.os.environ, {}, clear=True), patch.object(validate, "FAILS", []), contextlib.redirect_stdout(output):
            validate.check_private_quote_windows()
            self.assertEqual(validate.FAILS, [])
            self.assertIn("COVERAGE UNVERIFIED", output.getvalue())

    def test_private_baseline_inside_repository_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            local_baseline = root / "baseline.json"
            local_baseline.write_text("{}")
            with patch.object(validate, "ROOT", root), patch.dict(validate.os.environ, {"DREAMEROS_PRIVATE_QUOTE_BASELINE": str(local_baseline)}), patch.object(validate, "FAILS", []):
                validate.check_private_quote_windows()
                self.assertTrue(any("cannot read baseline" in failure for failure in validate.FAILS))

    def test_explicit_missing_private_baseline_fails(self):
        with patch.dict(validate.os.environ, {"DREAMEROS_PRIVATE_QUOTE_BASELINE": "missing-private-baseline.json"}), patch.object(validate, "FAILS", []):
            validate.check_private_quote_windows()
            self.assertTrue(any("cannot read baseline" in failure for failure in validate.FAILS))

    def test_targeted_eight_word_window_fires_before_twelve_word_window(self):
        text = "alpha bravo charlie delta echo foxtrot golf hotel"
        digest = hashlib.sha256(text.encode()).hexdigest()
        self.assertEqual(private_quote_window_hits(text, {digest}, 8), 1)
        self.assertEqual(private_quote_window_hits(text, {digest}, 12), 0)

    def test_reviewed_context_does_not_allow_the_phrase_elsewhere(self):
        prefix = ["prefix"] * 20
        phrase = "alpha bravo charlie delta echo foxtrot golf hotel".split()
        suffix = ["suffix"] * 20
        window_hash = hashlib.sha256(" ".join(phrase).encode()).hexdigest()
        context_hash = hashlib.sha256(" ".join(prefix + phrase + suffix).encode()).hexdigest()
        allow = {(window_hash, context_hash)}
        self.assertEqual(private_quote_window_hits(" ".join(prefix + phrase + suffix), {window_hash}, 8, allow), 0)
        self.assertEqual(private_quote_window_hits(" ".join(phrase), {window_hash}, 8, allow), 1)

    def test_private_short_windows_are_checked(self):
        long_text = "one two three four five six seven eight nine ten eleven twelve"
        short_text = "cedar maple pine birch oak"
        long_hash = hashlib.sha256(long_text.encode()).hexdigest()
        short_hash = hashlib.sha256(short_text.encode()).hexdigest()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "repo"
            root.mkdir()
            baseline = Path(temp) / "baseline.json"
            baseline.write_text(json.dumps({"window_words": 12, "sha256": [long_hash], "targeted_window_words": 8, "targeted_sha256": [long_hash], "allowed_targeted_contexts": [], "extra_windows": [{"window_words": 5, "sha256": [short_hash]}]}))
            (root / "public.txt").write_text(short_text)
            with patch.object(validate, "ROOT", root), patch.dict(validate.os.environ, {"DREAMEROS_PRIVATE_QUOTE_BASELINE": str(baseline)}), patch.object(validate.subprocess, "check_output", side_effect=FileNotFoundError), patch.object(validate, "FAILS", []):
                validate.check_private_quote_windows()
                self.assertTrue(any("public.txt" in failure for failure in validate.FAILS))

    def test_ignores_unrelated_windows(self):
        digest = hashlib.sha256(b"different protected passage").hexdigest()
        self.assertEqual(private_quote_window_hits(" ".join(["word"] * 20), {digest}, 12), 0)


if __name__ == "__main__":
    unittest.main()
