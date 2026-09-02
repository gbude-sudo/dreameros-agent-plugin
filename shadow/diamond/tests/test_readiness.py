from __future__ import annotations

import copy
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import readiness  # noqa: E402


def sha(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest().upper()


def ready_plan() -> dict:
    return {
        "status": "published",
        "hc_approval_state": "approved",
        "publication_git_revision": "a" * 40,
        "bundle_sha256": "B" * 64,
    }


def ready_draft(doc: dict) -> dict:
    clause_ids = []
    group_keys = []
    for clause in doc["clauses"]:
        if clause.get("source_id") in readiness.HISTORICAL_SOURCE_IDS:
            clause_ids.append(clause["clause_id"])
            group_keys.append(
                clause["normalized_sha256"] + ":" + clause["target_rule_id"]
            )
    clause_ids.extend(readiness.KNOWN_CONFLICT_IDS)
    return {
        "schema_version": "0.1.0",
        "status": "draft_pending_human_conductor",
        "authority_state": "NO_APPROVAL_INFERRED",
        "proposed_authority_decisions": {
            "directive_bundle_authoring_owner": "gbude-sudo/dreameros-agent-plugin",
            "plan_ir_owner": "gbude-sudo/dreameros-scs-gateway",
            "decision_ledger_target_path": (
                "governance/decisions/DIAMOND_DIRECTIVE_DECISIONS_v0_1_0.json"
            ),
            "approved_draft_target_path": (
                "governance/decisions/DIAMOND_DIRECTIVE_DECISIONS_DRAFT_v0_1_0.json"
            ),
        },
        "decisions": [
            {
                "decision_id": "decision:test",
                "status": "pending_human_conductor",
                "approved_by": None,
                "approved_clause_ids": [],
                "approved_group_keys": [],
                "proposed_clause_ids": sorted(set(clause_ids)),
                "proposed_group_keys": sorted(set(group_keys)),
                "proposed_resolution_by_clause": {
                    clause_id: "test resolution"
                    for clause_id in readiness.KNOWN_CONFLICT_IDS
                },
                "resolution": "test resolution",
                "source_ref": "draft:test",
            }
        ],
        "writes": [],
        "activation_targets": [],
    }


def ready_decisions(doc: dict, draft: dict | None = None) -> dict:
    draft = draft or ready_draft(doc)
    approval_source_ref = "hc-chat:test-thread:test-message"
    final_rows = []
    for row in draft["decisions"]:
        final_rows.append(
            {
                "decision_id": row["decision_id"],
                "status": "ratified",
                "approved_by": "human_conductor",
                "approved_clause_ids": list(row["proposed_clause_ids"]),
                "approved_group_keys": list(row["proposed_group_keys"]),
                "resolution": row["resolution"],
                "resolution_by_clause": copy.deepcopy(
                    row.get("proposed_resolution_by_clause", {})
                ),
                "source_ref": approval_source_ref,
            }
        )
    draft_bytes = (
        json.dumps(draft, indent=2, sort_keys=True, ensure_ascii=True) + "\n"
    ).encode("utf-8")
    return {
        "schema_version": "0.1.0",
        "status": "ratified",
        "approved_draft_sha256": sha(draft_bytes),
        "approval_source_ref": approval_source_ref,
        "ratified_authority_decisions": copy.deepcopy(
            draft["proposed_authority_decisions"]
        ),
        "decisions": final_rows,
    }


def ready_map() -> dict:
    sources = []
    clauses = []
    for source_id in readiness.EXPECTED_SOURCE_IDS:
        line_count = 2 if source_id == "G" else 3 if source_id == "O" else 1
        sources.append({"source_id": source_id, "lines": line_count})
        clause = {
                "clause_id": f"{source_id}:L0001-L0001:TEST",
                "source_id": source_id,
                "axis": "epistemic",
                "start_line": 1,
                "end_line": 1,
                "normalized_sha256": source_id * 64,
                "target_rule_id": f"RULE.{source_id}",
                "semantic_review_state": "current_source_mapping",
                "disposition": "retain",
                "conflict_state": "current_source",
            }
        if source_id in readiness.HISTORICAL_SOURCE_IDS:
            clause["semantic_review_state"] = "hc_ratified"
            clause["hc_decision_ref"] = "decision:test"
        clauses.append(clause)

    for index, conflict_id in enumerate(sorted(readiness.KNOWN_CONFLICT_IDS)):
        source_id = conflict_id[0]
        line = 2 if source_id == "G" or index == 1 else 3
        clauses.append(
            {
                "clause_id": conflict_id,
                "source_id": source_id,
                "axis": "epistemic",
                "start_line": line,
                "end_line": line,
                "normalized_sha256": f"{index + 10:064X}",
                "target_rule_id": "R1e" if "0060" in conflict_id else "R1l",
                "semantic_review_state": "hc_ratified",
                "hc_decision_ref": "decision:test",
                "disposition": "merge_into",
                "conflict_state": "resolved_by_hc",
            }
        )
    return {
        "sources": sources,
        "clauses": clauses,
        "quote_map": {"entry_count": 15},
        "summary": {
            "clause_count": 7,
            "pending_hc_group_count": 0,
            "known_conflict_clause_count": 0,
        },
        "acceptance": {
            "compiler_cutover_allowed": True,
            "semantic_consolidation": "hc_ratified",
        },
    }


class ReadinessTests(unittest.TestCase):
    def test_ready_contract_has_no_diagnostics(self) -> None:
        draft = ready_draft(ready_map())
        draft_bytes = (
            json.dumps(draft, indent=2, sort_keys=True, ensure_ascii=True) + "\n"
        ).encode("utf-8")
        diagnostics, counts = readiness.assess_readiness(
            ready_map(),
            ready_plan(),
            hc_decisions=ready_decisions(ready_map(), draft),
            approved_hc_draft=draft,
            approved_hc_draft_sha256=sha(draft_bytes),
            verify_sources=False,
        )
        self.assertEqual([], diagnostics)
        self.assertEqual(
            {"clauses": 7, "pending_hc_groups": 0, "conflicts": 0}, counts
        )

    def test_178_groups_and_three_conflicts_fail_closed(self) -> None:
        doc = ready_map()
        clauses = []
        for index in range(178):
            clause_id = (
                sorted(readiness.KNOWN_CONFLICT_IDS)[index]
                if index < 3
                else f"G:pending:{index}"
            )
            clauses.append(
                {
                    "clause_id": clause_id,
                    "source_id": "G",
                    "axis": "epistemic",
                    "normalized_sha256": f"{index:064X}",
                    "target_rule_id": f"RULE.{index}",
                    "semantic_review_state": "agent_reviewed_candidate_pending_hc_approval",
                    "disposition": "merge_into",
                    "conflict_state": "reviewed_no_known_conflict_pending_hc_approval",
                }
            )
        for index in range(3):
            clauses[index]["disposition"] = "conflict"
            clauses[index]["conflict_state"] = "known_conflict_pending_hc_decision"
        doc["clauses"] = clauses
        doc["summary"] = {
            "clause_count": 178,
            "pending_hc_group_count": 178,
            "known_conflict_clause_count": 3,
        }
        doc["acceptance"] = {
            "compiler_cutover_allowed": False,
            "semantic_consolidation": "candidate_map_complete_hc_approval_pending",
        }
        diagnostics, counts = readiness.semantic_gate_diagnostics(doc)
        self.assertIn("UNRESOLVED_HC_GROUPS:178", diagnostics)
        self.assertTrue(any(item.startswith("SEMANTIC_CONFLICTS:3:") for item in diagnostics))
        self.assertIn("COMPILER_CUTOVER_NOT_ALLOWED", diagnostics)
        self.assertEqual(178, counts["pending_hc_groups"])
        self.assertEqual(3, counts["conflicts"])

    def test_forged_zero_summary_does_not_bypass_recomputed_gate(self) -> None:
        doc = ready_map()
        decisions = ready_decisions(doc)
        doc["clauses"][1]["semantic_review_state"] = (
            "agent_reviewed_candidate_pending_hc_approval"
        )
        doc["clauses"][1].pop("hc_decision_ref", None)
        doc["summary"]["pending_hc_group_count"] = 0
        diagnostics, _ = readiness.semantic_gate_diagnostics(doc, decisions)
        self.assertIn("UNRESOLVED_HC_GROUPS:1", diagnostics)
        self.assertTrue(
            any(item.startswith("SUMMARY_MISMATCH:pending_hc_group_count") for item in diagnostics)
        )

    def test_relabeling_historical_rows_does_not_bypass_hc_decisions(self) -> None:
        doc = ready_map()
        decisions = ready_decisions(doc)
        historical = doc["clauses"][1]
        historical["semantic_review_state"] = "current_source_mapping"
        historical.pop("hc_decision_ref", None)
        doc["summary"]["pending_hc_group_count"] = 0
        diagnostics, counts = readiness.semantic_gate_diagnostics(doc, decisions)
        self.assertIn("UNRESOLVED_HC_GROUPS:1", diagnostics)
        self.assertEqual(1, counts["pending_hc_groups"])

    def test_decision_registry_requires_ratified_hc_record(self) -> None:
        registry, diagnostics = readiness.decision_registry(
            {
                "decisions": [
                    {
                        "decision_id": "decision:bad",
                        "status": "draft",
                        "approved_by": "agent",
                        "approved_clause_ids": [],
                        "approved_group_keys": [],
                        "source_ref": "",
                    }
                ]
            }
        )
        self.assertIn("decision:bad", registry)
        self.assertIn("HC_DECISION_NOT_RATIFIED:decision:bad", diagnostics)
        self.assertIn("HC_DECISION_APPROVER_INVALID:decision:bad", diagnostics)
        self.assertIn("HC_DECISION_SOURCE_REF_MISSING:decision:bad", diagnostics)

    def test_ratified_ledger_requires_approved_draft_chain(self) -> None:
        doc = ready_map()
        decisions = ready_decisions(doc)
        diagnostics = readiness.decision_chain_diagnostics(
            decisions, None, None
        )
        self.assertEqual(["HC_APPROVED_DRAFT_MISSING"], diagnostics)

    def test_conflict_resolution_must_match_approved_draft(self) -> None:
        doc = ready_map()
        draft = ready_draft(doc)
        draft_bytes = (
            json.dumps(draft, indent=2, sort_keys=True, ensure_ascii=True) + "\n"
        ).encode("utf-8")
        decisions = ready_decisions(doc, draft)
        decisions["decisions"][0]["resolution_by_clause"][
            sorted(readiness.KNOWN_CONFLICT_IDS)[0]
        ] = "WRONG BUT NONEMPTY"
        semantic, counts = readiness.semantic_gate_diagnostics(doc, decisions)
        self.assertEqual(0, counts["conflicts"])
        self.assertEqual([], semantic)
        chain = readiness.decision_chain_diagnostics(
            decisions, draft, sha(draft_bytes)
        )
        self.assertIn(
            "HC_DECISION_CHAIN_CONFLICT_RESOLUTION:decision:test", chain
        )

    def test_gateway_is_not_allowed_as_decision_ledger_owner(self) -> None:
        with (
            mock.patch.object(
                readiness,
                "_run_git",
                side_effect=[
                    readiness.GATEWAY_REMOTE_URL,
                    "a" * 40,
                ],
            ),
            mock.patch.object(readiness, "_remote_main_sha", return_value="a" * 40),
        ):
            diagnostics = readiness.remote_main_diagnostics(
                Path("."),
                allowed_urls=readiness.DECISION_REMOTE_URLS,
                prefix="HC_DECISION_LEDGER",
            )
        self.assertIn(
            "HC_DECISION_LEDGER_ORIGIN_NOT_ALLOWED:"
            + readiness.GATEWAY_REMOTE_URL,
            diagnostics,
        )

    def test_local_or_wrong_path_decision_ledger_is_not_proven(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
            ledger = repo / "decisions.json"
            document = {
                "status": "ratified",
                "decisions": ready_decisions(ready_map())["decisions"],
            }
            ledger.write_text(json.dumps(document), encoding="utf-8")
            diagnostics = readiness.decision_filesystem_diagnostics(
                ledger, document, ready_draft(ready_map())
            )
            self.assertIn(
                "HC_DECISION_LEDGER_PATH_INVALID:decisions.json", diagnostics
            )
            self.assertIn("HC_DECISION_LEDGER_ORIGIN_MISSING", diagnostics)
            self.assertIn("HC_DECISION_LEDGER_NOT_PUBLISHED", diagnostics)
            self.assertTrue(
                any(
                    item.startswith("HC_DECISION_LEDGER_TARGET_PATH_MISMATCH:")
                    for item in diagnostics
                )
            )
            draft_diagnostics = readiness.decision_draft_filesystem_diagnostics(
                ledger, ready_draft(ready_map())
            )
            self.assertTrue(
                any(
                    item.startswith("HC_APPROVED_DRAFT_TARGET_PATH_MISMATCH:")
                    for item in draft_diagnostics
                )
            )

    def test_fake_duplicate_reference_cannot_bypass_hc_decision(self) -> None:
        doc = ready_map()
        decisions = ready_decisions(doc)
        historical = doc["clauses"][1]
        historical.pop("hc_decision_ref", None)
        historical["semantic_review_state"] = "current_source_mapping"
        historical["duplicate_of_clause_id"] = doc["clauses"][0]["clause_id"]
        diagnostics, _ = readiness.semantic_gate_diagnostics(doc, decisions)
        self.assertIn(
            f"DUPLICATE_REFERENCE_MISMATCH:{historical['clause_id']}:normalized_sha256",
            diagnostics,
        )

    def test_each_conflict_blocks_independently(self) -> None:
        conflict_ids = (
            "G:L0060-L0065:10E5BF5C7D21",
            "O:L0060-L0065:10E5BF5C7D21",
            "O:L0889-L0893:EA96367741BD",
        )
        for conflict_id in conflict_ids:
            with self.subTest(conflict_id=conflict_id):
                doc = ready_map()
                decisions = ready_decisions(doc)
                doc["clauses"][0]["clause_id"] = conflict_id
                doc["clauses"][0]["source_id"] = conflict_id[0]
                doc["clauses"][0]["disposition"] = "conflict"
                doc["clauses"][0]["conflict_state"] = (
                    "known_conflict_pending_hc_decision"
                )
                doc["summary"]["known_conflict_clause_count"] = 1
                diagnostics, _ = readiness.semantic_gate_diagnostics(doc, decisions)
                self.assertTrue(
                    any(item == f"SEMANTIC_CONFLICTS:1:{conflict_id}" for item in diagnostics)
                )

    def test_structural_gap_and_overlap_are_detected(self) -> None:
        gap = ready_map()
        gap["sources"][0]["lines"] = 2
        self.assertIn("COVERAGE_GAP:P:2", readiness.structural_gate_diagnostics(gap))

        overlap = ready_map()
        duplicate = dict(overlap["clauses"][0])
        duplicate["clause_id"] = "P:L0001-L0001:DUPLICATE"
        overlap["clauses"].append(duplicate)
        self.assertIn(
            "COVERAGE_OVERLAP:P:1:2",
            readiness.structural_gate_diagnostics(overlap),
        )

    def test_plan_draft_and_missing_approval_are_blocked(self) -> None:
        diagnostics = readiness.plan_gate_diagnostics(
            {
                "status": "local_uncommitted_draft",
                "hc_approval_state": "pending",
                "publication_git_revision": None,
                "bundle_sha256": "B" * 64,
            }
        )
        self.assertIn("PLAN_IR_HC_APPROVAL:'pending'", diagnostics)
        self.assertIn("PLAN_IR_UNPUBLISHED", diagnostics)
        self.assertIn(
            "PLAN_IR_STATUS_NOT_PUBLISHED:'local_uncommitted_draft'", diagnostics
        )

    def test_unpublished_status_aliases_are_blocked(self) -> None:
        for status in ("unpublished", "not_published", "candidate", "blocked"):
            with self.subTest(status=status):
                plan = ready_plan()
                plan["status"] = status
                diagnostics = readiness.plan_gate_diagnostics(plan)
                self.assertIn(
                    f"PLAN_IR_STATUS_NOT_PUBLISHED:{status!r}", diagnostics
                )

    def test_plan_artifacts_and_publication_revision_are_proved(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
            subprocess.run(
                ["git", "-C", str(repo), "config", "user.email", "test@example.invalid"],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(repo), "config", "user.name", "Readiness Test"],
                check=True,
            )
            artifacts = []
            for index, relative in enumerate(sorted(readiness.REQUIRED_PLAN_ARTIFACTS)):
                artifact = repo / relative
                artifact.parent.mkdir(parents=True, exist_ok=True)
                data = f"artifact-{index}".encode("utf-8")
                artifact.write_bytes(data)
                artifacts.append(
                    {
                        "path": relative,
                        "bytes": len(data),
                        "sha256": sha(data),
                    }
                )
            subprocess.run(
                ["git", "-C", str(repo), "add", "."], check=True
            )
            subprocess.run(
                ["git", "-C", str(repo), "commit", "-q", "-m", "fixture"],
                check=True,
            )
            revision = subprocess.check_output(
                ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True
            ).strip()
            manifest_path = repo / readiness.PLAN_MANIFEST_PATH
            records = "\n".join(
                item["path"] + ":" + item["sha256"] for item in artifacts
            )
            plan = {
                "status": "published",
                "hc_approval_state": "approved",
                "publication_git_revision": revision,
                "bundle_sha256": sha(records.encode("utf-8")),
                "artifacts": artifacts,
            }
            manifest_path.parent.mkdir(parents=True, exist_ok=True)
            manifest_path.write_text(
                json.dumps(plan, sort_keys=True, separators=(",", ":")) + "\n",
                encoding="utf-8",
            )
            subprocess.run(
                ["git", "-C", str(repo), "add", readiness.PLAN_MANIFEST_PATH],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(repo), "commit", "-q", "-m", "manifest"],
                check=True,
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(repo),
                    "remote",
                    "add",
                    "origin",
                    readiness.GATEWAY_REMOTE_URL + ".git",
                ],
                check=True,
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(repo),
                    "update-ref",
                    "refs/remotes/origin/main",
                    "HEAD",
                ],
                check=True,
            )
            origin_main = subprocess.check_output(
                ["git", "-C", str(repo), "rev-parse", "origin/main"], text=True
            ).strip()
            with mock.patch.object(
                readiness, "_remote_main_sha", return_value=origin_main
            ):
                self.assertEqual(
                    [], readiness.plan_filesystem_diagnostics(manifest_path, plan)
                )

                artifact = repo / artifacts[0]["path"]
                artifact.write_bytes(b"changed")
                diagnostics = readiness.plan_filesystem_diagnostics(
                    manifest_path, plan
                )
                self.assertIn(
                    f"PLAN_IR_ARTIFACT_SHA256_MISMATCH:{artifacts[0]['path']}",
                    diagnostics,
                )

                artifact.write_bytes(b"artifact-0")
                plan["bundle_sha256"] = "C" * 64
                diagnostics = readiness.plan_filesystem_diagnostics(
                    manifest_path, plan
                )
                self.assertTrue(
                    any(
                        item.startswith("PLAN_IR_BUNDLE_SHA256_MISMATCH:")
                        for item in diagnostics
                    )
                )

                plan["artifacts"][0]["path"] = "../outside.txt"
                diagnostics = readiness.plan_filesystem_diagnostics(
                    manifest_path, plan
                )
                self.assertIn(
                    "PLAN_IR_ARTIFACT_PATH_ESCAPE:../outside.txt", diagnostics
                )

    def test_source_byte_drift_fails(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            source_path = Path(td) / "source.md"
            source_path.write_bytes(b"changed")
            doc = {
                "sources": [
                    {
                        "source_id": "P",
                        "path": str(source_path),
                        "sha256": sha(b"original"),
                        "git": {},
                    }
                ]
            }
            diagnostics = readiness.source_gate_diagnostics(doc)
            self.assertIn("SOURCE_SHA256_MISMATCH:P", diagnostics)

    def test_missing_explicit_null_git_fields_fail(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            source_path = Path(td) / "source.md"
            source_path.write_bytes(b"source")
            git_record = {field: None for field in readiness.REQUIRED_GIT_FIELDS}
            git_record["repo"] = td
            git_record.pop("origin")
            git_record.pop("origin_main")
            doc = {
                "sources": [
                    {
                        "source_id": "O",
                        "path": str(source_path),
                        "sha256": sha(b"source"),
                        "git": git_record,
                    }
                ]
            }
            with mock.patch.object(readiness, "_run_git", return_value=None):
                diagnostics = readiness.source_gate_diagnostics(doc)
            self.assertIn("SOURCE_GIT_FIELD_MISSING:O:origin", diagnostics)
            self.assertIn("SOURCE_GIT_FIELD_MISSING:O:origin_main", diagnostics)

    def test_json_is_parsed_from_the_pinned_bytes(self) -> None:
        value = b'{"marker":"PINNED"}'
        parsed = readiness.load_json_bytes(value, "test")
        self.assertEqual("PINNED", parsed["marker"])

    def test_git_status_failure_cannot_look_clean(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            source_path = Path(td) / "source.md"
            source_path.write_bytes(b"source")
            doc = {
                "sources": [
                    {
                        "source_id": "P",
                        "path": str(source_path),
                        "sha256": sha(b"source"),
                        "git": {"repo": td},
                    }
                ]
            }
            with mock.patch.object(readiness, "_run_git", return_value=None):
                diagnostics = readiness.source_gate_diagnostics(doc)
            self.assertIn("SOURCE_GIT_COMMAND_FAILED:P:status", diagnostics)
            self.assertIn("SOURCE_GIT_COMMAND_FAILED:P:source_status", diagnostics)

    def test_remote_probe_failure_cannot_look_like_no_remote(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            source_path = Path(td) / "source.md"
            source_path.write_bytes(b"source")
            git_record = {field: None for field in readiness.REQUIRED_GIT_FIELDS}
            git_record.update(
                {
                    "repo": td,
                    "branch": "main",
                    "head": "a" * 40,
                    "source_status": "clean_for_source_path",
                    "last_path_commit": "b" * 40,
                    "repo_dirty_entry_count": 0,
                    "repo_status_sha256": sha(b""),
                }
            )
            doc = {
                "sources": [
                    {
                        "source_id": "O",
                        "path": str(source_path),
                        "sha256": sha(b"source"),
                        "lines": 1,
                        "git": git_record,
                    }
                ]
            }

            def fake_git(_repo: Path, *args: str) -> str | None:
                values = {
                    ("status", "--porcelain"): "",
                    ("status", "--porcelain", "--", "source.md"): "",
                    ("remote",): None,
                    ("branch", "--show-current"): "main",
                    ("rev-parse", "HEAD"): "a" * 40,
                    ("log", "-1", "--format=%H", "--", "source.md"): "b" * 40,
                }
                return values.get(args)

            with mock.patch.object(readiness, "_run_git", side_effect=fake_git):
                diagnostics = readiness.source_gate_diagnostics(doc)
            self.assertIn("SOURCE_GIT_COMMAND_FAILED:O:remote", diagnostics)

    def test_dirty_repository_and_source_path_block_readiness(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            source_path = Path(td) / "source.md"
            source_path.write_bytes(b"source")
            doc = {
                "sources": [
                    {
                        "source_id": "P",
                        "path": str(source_path),
                        "sha256": sha(b"source"),
                        "git": {"repo": td},
                    }
                ]
            }
            values = iter(
                [" M other.txt", " M source.md", "main", "a" * 40, None, None, " M source.md", "b" * 40]
            )
            with mock.patch.object(readiness, "_run_git", side_effect=lambda *_: next(values)):
                diagnostics = readiness.source_gate_diagnostics(doc)
            self.assertIn("SOURCE_REPO_DIRTY:P:1", diagnostics)
            self.assertIn("SOURCE_PATH_DIRTY:P", diagnostics)

    def test_cli_is_deterministic_and_writes_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            temp = Path(td)
            clause_path = temp / "map.json"
            plan_path = temp / "plan.json"
            clause_path.write_text(json.dumps(ready_map(), sort_keys=True), encoding="utf-8")
            plan_path.write_text(json.dumps(ready_plan(), sort_keys=True), encoding="utf-8")
            command = [
                sys.executable,
                str(ROOT / "readiness.py"),
                "--clause-map",
                str(clause_path),
                "--plan-ir-manifest",
                str(plan_path),
                "--expected-map-sha256",
                sha(clause_path.read_bytes()),
                "--expected-plan-manifest-sha256",
                sha(plan_path.read_bytes()),
            ]
            before = sorted(path.name for path in temp.iterdir())
            first = subprocess.run(command, text=True, capture_output=True, check=False)
            middle = sorted(path.name for path in temp.iterdir())
            second = subprocess.run(command, text=True, capture_output=True, check=False)
            after = sorted(path.name for path in temp.iterdir())
            self.assertEqual(2, first.returncode)
            self.assertEqual(first.stdout, second.stdout)
            self.assertEqual(before, middle)
            self.assertEqual(before, after)
            payload = json.loads(first.stdout)
            self.assertEqual("BLOCKED", payload["status"])
            self.assertEqual([], payload["writes"])
            self.assertEqual([], payload["activation_targets"])

    def test_expected_map_hash_mismatch_blocks(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            temp = Path(td)
            clause_path = temp / "map.json"
            plan_path = temp / "plan.json"
            clause_path.write_text(json.dumps(ready_map()), encoding="utf-8")
            plan_path.write_text(json.dumps(ready_plan()), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "readiness.py"),
                    "--clause-map",
                    str(clause_path),
                    "--plan-ir-manifest",
                    str(plan_path),
                    "--expected-map-sha256",
                    "1" * 64,
                    "--expected-plan-manifest-sha256",
                    sha(plan_path.read_bytes()),
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(2, result.returncode)
            self.assertIn("MAP_SHA256_MISMATCH", result.stdout)


if __name__ == "__main__":
    unittest.main()
