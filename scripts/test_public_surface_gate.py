import unittest

from scripts import public_surface_gate as gate


class PublicSurfaceGateTests(unittest.TestCase):
    def test_every_pattern_fires_on_its_known_positive(self):
        self.assertEqual(gate.self_test(), [])

    def test_every_pattern_stays_quiet_on_clean_text(self):
        self.assertEqual(dict(gate.scan_text(gate.CLEAN_TEXT)), {})

    def test_scan_counts_each_match(self):
        text = "see gateway/app/a.py and gateway/app/b.py"
        self.assertEqual(gate.scan_text(text)["gateway_source_path"], 2)

    def test_a_count_above_the_baseline_fails(self):
        violations, _ = gate.compare({"a.md": {"infra_project_id": 2}}, {"a.md": {"infra_project_id": 1}})
        self.assertEqual(len(violations), 1)

    def test_a_hit_in_an_unlisted_file_fails(self):
        violations, _ = gate.compare({"new.md": {"owner_local_path": 1}}, {})
        self.assertEqual(len(violations), 1)

    def test_a_count_equal_to_the_baseline_passes(self):
        violations, shrunk = gate.compare({"a.md": {"owner_local_path": 1}}, {"a.md": {"owner_local_path": 1}})
        self.assertEqual((violations, shrunk), ([], []))

    def test_a_count_below_the_baseline_passes_and_is_reported(self):
        violations, shrunk = gate.compare({"a.md": {"owner_local_path": 1}}, {"a.md": {"owner_local_path": 3}})
        self.assertEqual(violations, [])
        self.assertEqual(len(shrunk), 1)

    def test_a_removed_file_is_reported_as_shrunk(self):
        violations, shrunk = gate.compare({}, {"gone.md": {"owner_local_path": 2}})
        self.assertEqual(violations, [])
        self.assertEqual(len(shrunk), 1)

    def test_the_gate_never_prints_matched_text(self):
        secret = "dros_" + "z" * 30
        violations, _ = gate.compare(gate.scan_text(secret) and {"f.md": dict(gate.scan_text(secret))}, {})
        self.assertTrue(violations)
        self.assertFalse(any(secret in line for line in violations))

    def test_the_repository_is_not_above_its_baseline(self):
        files, _known = gate.load_baseline()
        violations, _ = gate.compare(gate.scan_repo(), files)
        self.assertEqual(violations, [])

    def test_a_pattern_the_baseline_never_saw_is_not_checked_when_filtered_out(self):
        violations, _ = gate.compare({"a.md": {"vendor_model_name": 5}}, {}, only={"owner_local_path"})
        self.assertEqual(violations, [])

    def test_a_pattern_missing_from_the_baseline_fails_a_normal_run(self):
        violations, _ = gate.compare({"a.md": {"vendor_model_name": 5}}, {})
        self.assertEqual(len(violations), 1)

    def test_every_pattern_has_a_name_the_baseline_can_record(self):
        self.assertTrue(set(gate.ORIGINAL_PATTERN_NAMES) <= set(gate.PATTERNS))
        self.assertGreater(len(gate.PATTERNS), len(gate.ORIGINAL_PATTERN_NAMES))


if __name__ == "__main__":
    unittest.main()
