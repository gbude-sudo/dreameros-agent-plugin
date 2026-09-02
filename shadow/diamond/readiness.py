"""Fail-closed readiness gate for the proposed Diamond shadow compiler.

This module does not compile directives and does not write files. It checks
whether the separately reviewed prerequisites permit compiler work to begin.
Exit 0 means the prerequisites are ready. Exit 2 means they are blocked. Exit
1 means an input could not be parsed or evaluated.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable


SCHEMA_VERSION = "0.1.0"
LOCAL_GIT_TIMEOUT_SECONDS = 5
REMOTE_GIT_TIMEOUT_SECONDS = 20
EXPECTED_SOURCE_IDS = ("P", "G", "O", "R")
REQUIRED_GIT_FIELDS = (
    "repo",
    "branch",
    "head",
    "origin_main",
    "origin",
    "source_status",
    "last_path_commit",
    "repo_dirty_entry_count",
    "repo_status_sha256",
)
HISTORICAL_SOURCE_IDS = frozenset({"G", "O"})
KNOWN_CONFLICT_IDS = frozenset(
    {
        "G:L0060-L0065:10E5BF5C7D21",
        "O:L0060-L0065:10E5BF5C7D21",
        "O:L0889-L0893:EA96367741BD",
    }
)
HEX64 = re.compile(r"^[0-9A-F]{64}$")
HEX40 = re.compile(r"^[0-9a-fA-F]{40}$")
PLAN_MANIFEST_PATH = "gateway/cognitive_registry/plan_ir/MANIFEST.json"
GATEWAY_REMOTE_URL = "https://github.com/gbude-sudo/dreameros-scs-gateway"
DECISION_REMOTE_URLS = frozenset(
    {"https://github.com/gbude-sudo/dreameros-agent-plugin"}
)
DECISION_PATH_RE = re.compile(
    r"^governance/decisions/DIAMOND_DIRECTIVE_DECISIONS_v\d+_\d+_\d+\.json$"
)
DECISION_DRAFT_PATH_RE = re.compile(
    r"^governance/decisions/DIAMOND_DIRECTIVE_DECISIONS_DRAFT_v\d+_\d+_\d+\.json$"
)
REQUIRED_PLAN_ARTIFACTS = frozenset(
    {
        "gateway/cognitive_registry/plan_ir/schema_v0_2_0.json",
        "gateway/cognitive_registry/plan_ir/validator.py",
        "gateway/cognitive_registry/plan_ir/__init__.py",
        "gateway/cognitive_registry/plan_ir/build_strategy_registry_v0_2.py",
        "gateway/cognitive_registry/registry_v0_2_0.yaml",
        "gateway/cognitive_registry/schema_v0_2_0.json",
        "gateway/cognitive_registry/plan_ir/fixtures/valid_minimal.json",
        "gateway/cognitive_registry/plan_ir/fixtures/invalid_unreachable_node.json",
        "gateway/cognitive_registry/plan_ir/fixtures/invalid_unjoined_branch.json",
        "gateway/cognitive_registry/plan_ir/fixtures/invalid_side_effect_without_permission.json",
        "gateway/cognitive_registry/plan_ir/fixtures/invalid_retry_without_idempotency.json",
        "tests/test_cognitive_plan_ir.py",
    }
)


class ReadinessInputError(ValueError):
    """Raised when an input cannot be evaluated safely."""


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest().upper()


def sha256_text(value: str) -> str:
    return sha256_bytes(value.encode("utf-8"))


def sha256_lf_text_bytes(value: bytes) -> str:
    text = value.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
    return sha256_text(text)


def load_json_bytes(value: bytes, label: str) -> dict[str, Any]:
    try:
        decoded = json.loads(value.decode("utf-8"))
    except Exception as exc:  # pragma: no cover - error text is CLI behavior
        raise ReadinessInputError(f"JSON_INPUT_INVALID:{label}:{exc}") from exc
    if not isinstance(decoded, dict):
        raise ReadinessInputError(f"JSON_INPUT_NOT_OBJECT:{label}")
    return decoded


def _dedupe(values: Iterable[str]) -> list[str]:
    return list(dict.fromkeys(values))


def decision_registry(
    hc_decisions: dict[str, Any] | None,
) -> tuple[dict[str, dict[str, Any]], list[str]]:
    if hc_decisions is None:
        return {}, ["HC_DECISION_LEDGER_MISSING"]
    decisions = hc_decisions.get("decisions")
    if not isinstance(decisions, list):
        return {}, ["HC_DECISIONS_NOT_LIST"]
    registry: dict[str, dict[str, Any]] = {}
    diagnostics: list[str] = []
    for index, decision in enumerate(decisions):
        if not isinstance(decision, dict):
            diagnostics.append(f"HC_DECISION_NOT_OBJECT:{index}")
            continue
        decision_id = decision.get("decision_id")
        if not isinstance(decision_id, str) or not decision_id:
            diagnostics.append(f"HC_DECISION_ID_MISSING:{index}")
            continue
        if decision_id in registry:
            diagnostics.append(f"HC_DECISION_ID_DUPLICATE:{decision_id}")
        if decision.get("status") != "ratified":
            diagnostics.append(f"HC_DECISION_NOT_RATIFIED:{decision_id}")
        if decision.get("approved_by") != "human_conductor":
            diagnostics.append(f"HC_DECISION_APPROVER_INVALID:{decision_id}")
        for field in ("approved_clause_ids", "approved_group_keys"):
            values = decision.get(field)
            if not isinstance(values, list) or any(
                not isinstance(value, str) or not value for value in values
            ):
                diagnostics.append(f"HC_DECISION_SCOPE_INVALID:{decision_id}:{field}")
        source_ref = decision.get("source_ref")
        if not isinstance(source_ref, str) or not source_ref:
            diagnostics.append(f"HC_DECISION_SOURCE_REF_MISSING:{decision_id}")
        registry[decision_id] = decision
    return registry, diagnostics


def decision_chain_diagnostics(
    hc_decisions: dict[str, Any] | None,
    approved_draft: dict[str, Any] | None,
    approved_draft_sha256: str | None,
) -> list[str]:
    """Bind a ratified ledger to the exact HC-approved pending draft."""

    if hc_decisions is None or hc_decisions.get("status") != "ratified":
        return []
    diagnostics: list[str] = []
    if approved_draft is None:
        return ["HC_APPROVED_DRAFT_MISSING"]
    if approved_draft_sha256 is None:
        diagnostics.append("HC_APPROVED_DRAFT_HASH_UNVERIFIED")
    elif hc_decisions.get("approved_draft_sha256") != approved_draft_sha256:
        diagnostics.append("HC_APPROVED_DRAFT_HASH_MISMATCH")
    if approved_draft.get("status") != "draft_pending_human_conductor":
        diagnostics.append("HC_APPROVED_DRAFT_STATUS_INVALID")
    if approved_draft.get("authority_state") != "NO_APPROVAL_INFERRED":
        diagnostics.append("HC_APPROVED_DRAFT_AUTHORITY_INVALID")
    if approved_draft.get("writes"):
        diagnostics.append("HC_APPROVED_DRAFT_WRITES_NONEMPTY")
    if approved_draft.get("activation_targets"):
        diagnostics.append("HC_APPROVED_DRAFT_ACTIVATION_NONEMPTY")

    approval_source_ref = hc_decisions.get("approval_source_ref")
    if not isinstance(approval_source_ref, str) or not approval_source_ref.startswith(
        "hc-chat:"
    ):
        diagnostics.append("HC_APPROVAL_SOURCE_REF_INVALID")
    if hc_decisions.get("ratified_authority_decisions") != approved_draft.get(
        "proposed_authority_decisions"
    ):
        diagnostics.append("HC_AUTHORITY_DECISIONS_DRIFT")

    draft_rows = approved_draft.get("decisions")
    final_rows = hc_decisions.get("decisions")
    if not isinstance(draft_rows, list) or not isinstance(final_rows, list):
        diagnostics.append("HC_DECISION_CHAIN_ROWS_INVALID")
        return _dedupe(diagnostics)
    draft_by_id = {
        row.get("decision_id"): row for row in draft_rows if isinstance(row, dict)
    }
    final_by_id = {
        row.get("decision_id"): row for row in final_rows if isinstance(row, dict)
    }
    if set(draft_by_id) != set(final_by_id):
        diagnostics.append("HC_DECISION_CHAIN_ID_MISMATCH")
    for decision_id, draft_row in draft_by_id.items():
        final_row = final_by_id.get(decision_id)
        if not isinstance(final_row, dict):
            continue
        if final_row.get("status") != "ratified":
            diagnostics.append(f"HC_DECISION_CHAIN_STATUS:{decision_id}")
        if final_row.get("approved_by") != "human_conductor":
            diagnostics.append(f"HC_DECISION_CHAIN_APPROVER:{decision_id}")
        if final_row.get("source_ref") != approval_source_ref:
            diagnostics.append(f"HC_DECISION_CHAIN_SOURCE_REF:{decision_id}")
        if final_row.get("approved_clause_ids") != draft_row.get(
            "proposed_clause_ids"
        ):
            diagnostics.append(f"HC_DECISION_CHAIN_CLAUSE_SCOPE:{decision_id}")
        if final_row.get("approved_group_keys") != draft_row.get(
            "proposed_group_keys"
        ):
            diagnostics.append(f"HC_DECISION_CHAIN_GROUP_SCOPE:{decision_id}")
        if final_row.get("resolution") != draft_row.get("resolution"):
            diagnostics.append(f"HC_DECISION_CHAIN_RESOLUTION:{decision_id}")
        proposed_by_clause = draft_row.get("proposed_resolution_by_clause")
        if proposed_by_clause is not None and final_row.get(
            "resolution_by_clause"
        ) != proposed_by_clause:
            diagnostics.append(
                f"HC_DECISION_CHAIN_CONFLICT_RESOLUTION:{decision_id}"
            )
    return _dedupe(diagnostics)


def semantic_gate_diagnostics(
    clause_map: dict[str, Any], hc_decisions: dict[str, Any] | None = None
) -> tuple[list[str], dict[str, int]]:
    clauses = clause_map.get("clauses")
    if not isinstance(clauses, list):
        return ["CLAUSES_NOT_LIST"], {"clauses": 0, "pending_hc_groups": 0, "conflicts": 0}

    pending_groups: set[tuple[str, str]] = set()
    conflict_ids: list[str] = []
    seen_clause_ids: set[str] = set()
    clause_by_id: dict[str, dict[str, Any]] = {}
    diagnostics: list[str] = []
    decisions, decision_diagnostics = decision_registry(hc_decisions)
    diagnostics.extend(decision_diagnostics)

    for index, clause in enumerate(clauses):
        if not isinstance(clause, dict):
            diagnostics.append(f"CLAUSE_NOT_OBJECT:{index}")
            continue
        clause_id = clause.get("clause_id")
        if not isinstance(clause_id, str) or not clause_id:
            diagnostics.append(f"CLAUSE_ID_MISSING:{index}")
            continue
        if clause_id in seen_clause_ids:
            diagnostics.append(f"CLAUSE_ID_DUPLICATE:{clause_id}")
        seen_clause_ids.add(clause_id)
        clause_by_id[clause_id] = clause

        review_state = clause.get("semantic_review_state", "")
        decision_ref = clause.get("hc_decision_ref")
        decision = decisions.get(decision_ref) if isinstance(decision_ref, str) else None
        group_key = str(clause.get("normalized_sha256")) + ":" + str(
            clause.get("target_rule_id")
        )
        decision_clause_ids = (
            set(decision.get("approved_clause_ids", [])) if decision else set()
        )
        decision_group_keys = (
            set(decision.get("approved_group_keys", [])) if decision else set()
        )
        decision_covers_clause = bool(
            decision
            and decision.get("status") == "ratified"
            and decision.get("approved_by") == "human_conductor"
            and (
                clause_id in decision_clause_ids or group_key in decision_group_keys
            )
        )
        historical_semantic = (
            clause.get("source_id") in HISTORICAL_SOURCE_IDS
            and clause.get("axis") != "structural"
            and not clause.get("duplicate_of_clause_id")
        )
        unresolved_historical = historical_semantic and not (
            review_state == "hc_ratified"
            and decision_covers_clause
        )
        if unresolved_historical:
            normalized = clause.get("normalized_sha256")
            target = clause.get("target_rule_id")
            if not isinstance(normalized, str) or not isinstance(target, str):
                diagnostics.append(f"PENDING_GROUP_KEY_INVALID:{clause_id}")
            else:
                pending_groups.add((normalized, target))

        conflict_state = clause.get("conflict_state", "")
        resolution_by_clause = (
            decision.get("resolution_by_clause") if decision else None
        )
        clause_resolution = (
            resolution_by_clause.get(clause_id)
            if isinstance(resolution_by_clause, dict)
            else None
        )
        known_conflict_unresolved = clause_id in KNOWN_CONFLICT_IDS and not (
            review_state == "hc_ratified"
            and decision_covers_clause
            and clause_id in decision_clause_ids
            and isinstance(clause_resolution, str)
            and bool(clause_resolution.strip())
            and clause.get("disposition") != "conflict"
        )
        if known_conflict_unresolved or clause.get("disposition") == "conflict" or (
            isinstance(conflict_state, str) and "pending_hc_decision" in conflict_state
        ):
            conflict_ids.append(clause_id)

    missing_known_conflicts = sorted(KNOWN_CONFLICT_IDS - seen_clause_ids)
    for clause_id in missing_known_conflicts:
        diagnostics.append(f"KNOWN_CONFLICT_CLAUSE_MISSING:{clause_id}")

    for clause in clauses:
        if not isinstance(clause, dict):
            continue
        duplicate_id = clause.get("duplicate_of_clause_id")
        if not duplicate_id:
            continue
        clause_id = clause.get("clause_id", "unknown")
        referenced = clause_by_id.get(duplicate_id)
        if referenced is None:
            diagnostics.append(f"DUPLICATE_REFERENCE_MISSING:{clause_id}:{duplicate_id}")
            continue
        if duplicate_id == clause_id:
            diagnostics.append(f"DUPLICATE_REFERENCE_SELF:{clause_id}")
        for field in ("normalized_sha256", "target_rule_id"):
            if clause.get(field) != referenced.get(field):
                diagnostics.append(
                    f"DUPLICATE_REFERENCE_MISMATCH:{clause_id}:{field}"
                )

    if pending_groups:
        diagnostics.append(f"UNRESOLVED_HC_GROUPS:{len(pending_groups)}")
    if conflict_ids:
        diagnostics.append(
            "SEMANTIC_CONFLICTS:"
            + str(len(conflict_ids))
            + ":"
            + ",".join(sorted(conflict_ids))
        )

    summary = clause_map.get("summary")
    if not isinstance(summary, dict):
        diagnostics.append("SUMMARY_NOT_OBJECT")
    else:
        expected = {
            "clause_count": len(clauses),
            "pending_hc_group_count": len(pending_groups),
            "known_conflict_clause_count": len(conflict_ids),
        }
        for key, actual in expected.items():
            if summary.get(key) != actual:
                diagnostics.append(
                    f"SUMMARY_MISMATCH:{key}:stored={summary.get(key)!r}:actual={actual}"
                )

    acceptance = clause_map.get("acceptance")
    if not isinstance(acceptance, dict):
        diagnostics.append("ACCEPTANCE_NOT_OBJECT")
    else:
        if acceptance.get("compiler_cutover_allowed") is not True:
            diagnostics.append("COMPILER_CUTOVER_NOT_ALLOWED")
        semantic_state = acceptance.get("semantic_consolidation")
        if not isinstance(semantic_state, str) or "pending" in semantic_state or semantic_state == "review_required":
            diagnostics.append(f"SEMANTIC_CONSOLIDATION_NOT_RATIFIED:{semantic_state!r}")

    counts = {
        "clauses": len(clauses),
        "pending_hc_groups": len(pending_groups),
        "conflicts": len(conflict_ids),
    }
    return _dedupe(diagnostics), counts


def structural_gate_diagnostics(clause_map: dict[str, Any]) -> list[str]:
    sources = clause_map.get("sources")
    clauses = clause_map.get("clauses")
    if not isinstance(sources, list) or not isinstance(clauses, list):
        return ["STRUCTURAL_INPUT_INVALID"]

    diagnostics: list[str] = []
    source_by_id: dict[str, dict[str, Any]] = {}
    for source in sources:
        if not isinstance(source, dict):
            diagnostics.append("SOURCE_NOT_OBJECT")
            continue
        source_id = source.get("source_id")
        if not isinstance(source_id, str) or not source_id:
            diagnostics.append("SOURCE_ID_MISSING")
            continue
        if source_id in source_by_id:
            diagnostics.append(f"SOURCE_ID_DUPLICATE:{source_id}")
        source_by_id[source_id] = source

    if tuple(sorted(source_by_id)) != tuple(sorted(EXPECTED_SOURCE_IDS)):
        diagnostics.append(
            "SOURCE_SET_MISMATCH:expected="
            + ",".join(EXPECTED_SOURCE_IDS)
            + ":actual="
            + ",".join(sorted(source_by_id))
        )

    coverage: dict[str, list[int]] = {}
    for source_id, source in source_by_id.items():
        lines = source.get("lines")
        if not isinstance(lines, int) or lines < 1:
            diagnostics.append(f"SOURCE_LINE_COUNT_INVALID:{source_id}")
            continue
        coverage[source_id] = [0] * (lines + 1)

    for clause in clauses:
        if not isinstance(clause, dict):
            continue
        clause_id = clause.get("clause_id", "unknown")
        source_id = clause.get("source_id")
        start = clause.get("start_line")
        end = clause.get("end_line")
        if source_id not in coverage:
            diagnostics.append(f"CLAUSE_SOURCE_UNKNOWN:{clause_id}:{source_id}")
            continue
        if not isinstance(start, int) or not isinstance(end, int) or start < 1 or end < start or end >= len(coverage[source_id]):
            diagnostics.append(f"CLAUSE_RANGE_INVALID:{clause_id}:{start}-{end}")
            continue
        for line in range(start, end + 1):
            coverage[source_id][line] += 1

    for source_id in sorted(coverage):
        for line, count in enumerate(coverage[source_id][1:], start=1):
            if count == 0:
                diagnostics.append(f"COVERAGE_GAP:{source_id}:{line}")
            elif count > 1:
                diagnostics.append(f"COVERAGE_OVERLAP:{source_id}:{line}:{count}")

    quote_map = clause_map.get("quote_map")
    if not isinstance(quote_map, dict) or quote_map.get("entry_count") != 15:
        diagnostics.append(
            f"QUOTE_COUNT_MISMATCH:expected=15:actual={quote_map.get('entry_count') if isinstance(quote_map, dict) else None}"
        )

    return _dedupe(diagnostics)


def plan_gate_diagnostics(plan_manifest: dict[str, Any]) -> list[str]:
    diagnostics: list[str] = []
    approval = plan_manifest.get("hc_approval_state")
    if approval not in {"approved", "ratified"}:
        diagnostics.append(f"PLAN_IR_HC_APPROVAL:{approval!r}")

    publication = plan_manifest.get("publication_git_revision")
    if (
        not isinstance(publication, str)
        or not HEX40.fullmatch(publication)
        or publication.lower() == "0" * 40
    ):
        diagnostics.append("PLAN_IR_UNPUBLISHED")

    status = plan_manifest.get("status")
    if status != "published":
        diagnostics.append(f"PLAN_IR_STATUS_NOT_PUBLISHED:{status!r}")

    bundle_sha = plan_manifest.get("bundle_sha256")
    if (
        not isinstance(bundle_sha, str)
        or not HEX64.fullmatch(bundle_sha.upper())
        or bundle_sha.upper() == "0" * 64
    ):
        diagnostics.append("PLAN_IR_BUNDLE_SHA256_INVALID")

    return diagnostics


def _run_git(repo: Path, *args: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", "--no-optional-locks", "-C", str(repo), *args],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=LOCAL_GIT_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def _run_git_bytes(repo: Path, *args: str) -> bytes | None:
    try:
        result = subprocess.run(
            ["git", "--no-optional-locks", "-C", str(repo), *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=LOCAL_GIT_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout


def _normalize_remote_url(value: str) -> str:
    return value.strip().removesuffix(".git").replace("\\", "/")


def _remote_main_sha(repo: Path) -> str | None:
    env = os.environ.copy()
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_OPTIONAL_LOCKS"] = "0"
    try:
        result = subprocess.run(
            [
                "git",
                "--no-optional-locks",
                "-C",
                str(repo),
                "ls-remote",
                "origin",
                "refs/heads/main",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=REMOTE_GIT_TIMEOUT_SECONDS,
            check=False,
            env=env,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0 or not result.stdout.strip():
        return None
    return result.stdout.split()[0]


def remote_main_diagnostics(
    repo: Path, *, allowed_urls: frozenset[str], prefix: str
) -> list[str]:
    diagnostics: list[str] = []
    remote_url = _run_git(repo, "remote", "get-url", "origin")
    if remote_url is None:
        return [f"{prefix}_ORIGIN_MISSING"]
    normalized = _normalize_remote_url(remote_url)
    if normalized not in allowed_urls:
        diagnostics.append(f"{prefix}_ORIGIN_NOT_ALLOWED:{normalized}")
    local_main = _run_git(repo, "rev-parse", "origin/main")
    remote_main = _remote_main_sha(repo)
    if local_main is None:
        diagnostics.append(f"{prefix}_LOCAL_ORIGIN_MAIN_MISSING")
    if remote_main is None:
        diagnostics.append(f"{prefix}_REMOTE_MAIN_UNVERIFIED")
    if local_main is not None and remote_main is not None and local_main != remote_main:
        diagnostics.append(
            f"{prefix}_ORIGIN_MAIN_STALE:local={local_main}:remote={remote_main}"
        )
    return diagnostics


def decision_filesystem_diagnostics(
    decision_path: Path,
    hc_decisions: dict[str, Any],
    approved_draft: dict[str, Any] | None = None,
) -> list[str]:
    diagnostics: list[str] = []
    top = _run_git(decision_path.parent, "rev-parse", "--show-toplevel")
    if top is None:
        return ["HC_DECISION_LEDGER_GIT_UNBOUND"]
    repo = Path(top)
    try:
        relative = decision_path.resolve().relative_to(repo.resolve()).as_posix()
    except ValueError:
        return ["HC_DECISION_LEDGER_OUTSIDE_REPO"]
    if not DECISION_PATH_RE.fullmatch(relative):
        diagnostics.append(f"HC_DECISION_LEDGER_PATH_INVALID:{relative}")
    if isinstance(approved_draft, dict):
        expected_path = (
            approved_draft.get("proposed_authority_decisions", {})
            .get("decision_ledger_target_path")
        )
        if isinstance(expected_path, str) and relative != expected_path:
            diagnostics.append(
                f"HC_DECISION_LEDGER_TARGET_PATH_MISMATCH:expected={expected_path}:actual={relative}"
            )
    diagnostics.extend(
        remote_main_diagnostics(
            repo, allowed_urls=DECISION_REMOTE_URLS, prefix="HC_DECISION_LEDGER"
        )
    )
    published = _run_git_bytes(repo, "show", "origin/main:" + relative)
    if published is None:
        diagnostics.append("HC_DECISION_LEDGER_NOT_PUBLISHED")
    elif sha256_lf_text_bytes(published) != sha256_lf_text_bytes(
        decision_path.read_bytes()
    ):
        diagnostics.append("HC_DECISION_LEDGER_DIFFERS_FROM_ORIGIN_MAIN")
    if hc_decisions.get("status") != "ratified":
        diagnostics.append(
            f"HC_DECISION_LEDGER_STATUS_NOT_RATIFIED:{hc_decisions.get('status')!r}"
        )
    return _dedupe(diagnostics)


def decision_draft_filesystem_diagnostics(
    decision_path: Path, approved_draft: dict[str, Any]
) -> list[str]:
    diagnostics: list[str] = []
    top = _run_git(decision_path.parent, "rev-parse", "--show-toplevel")
    if top is None:
        return ["HC_APPROVED_DRAFT_GIT_UNBOUND"]
    repo = Path(top)
    try:
        relative = decision_path.resolve().relative_to(repo.resolve()).as_posix()
    except ValueError:
        return ["HC_APPROVED_DRAFT_OUTSIDE_REPO"]
    if not DECISION_DRAFT_PATH_RE.fullmatch(relative):
        diagnostics.append(f"HC_APPROVED_DRAFT_PATH_INVALID:{relative}")
    expected_path = (
        approved_draft.get("proposed_authority_decisions", {})
        .get("approved_draft_target_path")
    )
    if isinstance(expected_path, str) and relative != expected_path:
        diagnostics.append(
            f"HC_APPROVED_DRAFT_TARGET_PATH_MISMATCH:expected={expected_path}:actual={relative}"
        )
    diagnostics.extend(
        remote_main_diagnostics(
            repo, allowed_urls=DECISION_REMOTE_URLS, prefix="HC_APPROVED_DRAFT"
        )
    )
    published = _run_git_bytes(repo, "show", "origin/main:" + relative)
    if published is None:
        diagnostics.append("HC_APPROVED_DRAFT_NOT_PUBLISHED")
    elif sha256_lf_text_bytes(published) != sha256_lf_text_bytes(
        decision_path.read_bytes()
    ):
        diagnostics.append("HC_APPROVED_DRAFT_DIFFERS_FROM_ORIGIN_MAIN")
    if approved_draft.get("status") != "draft_pending_human_conductor":
        diagnostics.append(
            f"HC_APPROVED_DRAFT_STATUS_INVALID:{approved_draft.get('status')!r}"
        )
    return _dedupe(diagnostics)


def plan_filesystem_diagnostics(
    plan_path: Path, plan_manifest: dict[str, Any]
) -> list[str]:
    diagnostics: list[str] = []
    top = _run_git(plan_path.parent, "rev-parse", "--show-toplevel")
    if top is None:
        return ["PLAN_IR_GIT_UNBOUND"]
    repo = Path(top)
    diagnostics.extend(
        remote_main_diagnostics(
            repo,
            allowed_urls=frozenset({GATEWAY_REMOTE_URL}),
            prefix="PLAN_IR",
        )
    )
    try:
        manifest_relative = plan_path.resolve().relative_to(repo.resolve()).as_posix()
    except ValueError:
        return ["PLAN_IR_MANIFEST_OUTSIDE_REPO"]
    if manifest_relative != PLAN_MANIFEST_PATH:
        diagnostics.append(
            f"PLAN_IR_MANIFEST_PATH_INVALID:expected={PLAN_MANIFEST_PATH}:actual={manifest_relative}"
        )

    origin_main = _run_git(repo, "rev-parse", "origin/main")
    if origin_main is None:
        diagnostics.append("PLAN_IR_ORIGIN_MAIN_MISSING")
    else:
        published_manifest = _run_git_bytes(
            repo, "show", "origin/main:" + manifest_relative
        )
        if published_manifest is None:
            diagnostics.append("PLAN_IR_MANIFEST_NOT_PUBLISHED")
        elif sha256_lf_text_bytes(published_manifest) != sha256_lf_text_bytes(
            plan_path.read_bytes()
        ):
            diagnostics.append("PLAN_IR_MANIFEST_DIFFERS_FROM_ORIGIN_MAIN")

    artifacts = plan_manifest.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        return ["PLAN_IR_ARTIFACTS_MISSING"]

    records: list[str] = []
    publication = plan_manifest.get("publication_git_revision")
    valid_publication = (
        isinstance(publication, str)
        and bool(HEX40.fullmatch(publication))
        and publication.lower() != "0" * 40
    )
    if valid_publication and _run_git(repo, "cat-file", "-e", publication + "^{commit}") is None:
        diagnostics.append("PLAN_IR_PUBLICATION_REVISION_MISSING")
        valid_publication = False
    if valid_publication and _run_git(
        repo, "merge-base", "--is-ancestor", publication, "origin/main"
    ) is None:
        diagnostics.append("PLAN_IR_PUBLICATION_NOT_ON_ORIGIN_MAIN")
        valid_publication = False

    listed_artifacts = {
        artifact.get("path")
        for artifact in artifacts
        if isinstance(artifact, dict) and isinstance(artifact.get("path"), str)
    }
    for missing in sorted(REQUIRED_PLAN_ARTIFACTS - listed_artifacts):
        diagnostics.append(f"PLAN_IR_REQUIRED_ARTIFACT_MISSING:{missing}")

    for index, artifact in enumerate(artifacts):
        if not isinstance(artifact, dict):
            diagnostics.append(f"PLAN_IR_ARTIFACT_NOT_OBJECT:{index}")
            continue
        relative = artifact.get("path")
        expected_sha = artifact.get("sha256")
        expected_bytes = artifact.get("bytes")
        if not isinstance(relative, str) or not isinstance(expected_sha, str):
            diagnostics.append(f"PLAN_IR_ARTIFACT_PIN_INVALID:{index}")
            continue
        candidate = (repo / Path(relative)).resolve()
        try:
            candidate.relative_to(repo.resolve())
        except ValueError:
            diagnostics.append(f"PLAN_IR_ARTIFACT_PATH_ESCAPE:{relative}")
            continue
        if not candidate.is_file():
            diagnostics.append(f"PLAN_IR_ARTIFACT_MISSING:{relative}")
            continue
        data = candidate.read_bytes()
        actual_sha = sha256_bytes(data)
        if actual_sha != expected_sha.upper():
            diagnostics.append(f"PLAN_IR_ARTIFACT_SHA256_MISMATCH:{relative}")
        if not isinstance(expected_bytes, int) or expected_bytes != len(data):
            diagnostics.append(f"PLAN_IR_ARTIFACT_SIZE_MISMATCH:{relative}")
        records.append(relative + ":" + expected_sha.upper())

        if valid_publication:
            published = _run_git_bytes(repo, "show", publication + ":" + relative)
            if published is None:
                diagnostics.append(f"PLAN_IR_ARTIFACT_NOT_PUBLISHED:{relative}")
            elif sha256_bytes(published) != expected_sha.upper():
                diagnostics.append(
                    f"PLAN_IR_PUBLISHED_ARTIFACT_SHA256_MISMATCH:{relative}"
                )

    bundle_sha = plan_manifest.get("bundle_sha256")
    actual_bundle_sha = sha256_text("\n".join(records))
    if isinstance(bundle_sha, str) and actual_bundle_sha != bundle_sha.upper():
        diagnostics.append(
            f"PLAN_IR_BUNDLE_SHA256_MISMATCH:stored={bundle_sha.upper()}:actual={actual_bundle_sha}"
        )
    return _dedupe(diagnostics)


def source_gate_diagnostics(clause_map: dict[str, Any]) -> list[str]:
    sources = clause_map.get("sources")
    if not isinstance(sources, list):
        return ["SOURCES_NOT_LIST"]

    diagnostics: list[str] = []
    for source in sources:
        if not isinstance(source, dict):
            continue
        source_id = source.get("source_id", "unknown")
        path_value = source.get("path")
        expected_sha = source.get("sha256")
        if not isinstance(path_value, str) or not isinstance(expected_sha, str):
            diagnostics.append(f"SOURCE_PIN_INVALID:{source_id}")
            continue
        path = Path(path_value)
        if not path.is_file():
            diagnostics.append(f"SOURCE_MISSING:{source_id}")
            continue
        if sha256_bytes(path.read_bytes()) != expected_sha.upper():
            diagnostics.append(f"SOURCE_SHA256_MISMATCH:{source_id}")
        try:
            actual_line_count = len(
                path.read_text(encoding="utf-8-sig").splitlines()
            )
        except UnicodeDecodeError:
            diagnostics.append(f"SOURCE_TEXT_DECODE_FAILED:{source_id}")
            actual_line_count = None
        if actual_line_count is not None and source.get("lines") != actual_line_count:
            diagnostics.append(
                f"SOURCE_LINE_COUNT_MISMATCH:{source_id}:stored={source.get('lines')!r}:actual={actual_line_count}"
            )

        git_record = source.get("git")
        if not isinstance(git_record, dict):
            diagnostics.append(f"SOURCE_GIT_RECORD_MISSING:{source_id}")
            continue
        for field in REQUIRED_GIT_FIELDS:
            if field not in git_record:
                diagnostics.append(f"SOURCE_GIT_FIELD_MISSING:{source_id}:{field}")
        repo_value = git_record.get("repo")
        if not isinstance(repo_value, str):
            diagnostics.append(f"SOURCE_GIT_UNBOUND:{source_id}")
            continue
        repo = Path(repo_value)
        try:
            relative = path.resolve().relative_to(repo.resolve()).as_posix()
        except ValueError:
            diagnostics.append(f"SOURCE_OUTSIDE_REPO:{source_id}")
            continue

        actual_status = _run_git(repo, "status", "--porcelain")
        actual_source_status = _run_git(repo, "status", "--porcelain", "--", relative)
        if actual_status is None:
            diagnostics.append(f"SOURCE_GIT_COMMAND_FAILED:{source_id}:status")
            actual_status = ""
        if actual_source_status is None:
            diagnostics.append(f"SOURCE_GIT_COMMAND_FAILED:{source_id}:source_status")
            actual_source_status = ""
        if actual_status:
            diagnostics.append(
                f"SOURCE_REPO_DIRTY:{source_id}:{len(actual_status.splitlines())}"
            )
        if actual_source_status:
            diagnostics.append(f"SOURCE_PATH_DIRTY:{source_id}")
        remote_names = _run_git(repo, "remote")
        if remote_names is None:
            diagnostics.append(f"SOURCE_GIT_COMMAND_FAILED:{source_id}:remote")
            actual_origin = None
            actual_origin_main = None
        elif "origin" in remote_names.splitlines():
            actual_origin = _run_git(repo, "remote", "get-url", "origin")
            actual_origin_main = _run_git(repo, "rev-parse", "origin/main")
            if actual_origin is None:
                diagnostics.append(f"SOURCE_GIT_COMMAND_FAILED:{source_id}:origin")
            if actual_origin_main is None:
                diagnostics.append(
                    f"SOURCE_GIT_COMMAND_FAILED:{source_id}:origin_main"
                )
        else:
            actual_origin = None
            actual_origin_main = None

        actual = {
            "branch": _run_git(repo, "branch", "--show-current"),
            "head": _run_git(repo, "rev-parse", "HEAD"),
            "origin_main": actual_origin_main,
            "origin": actual_origin,
            "source_status": actual_source_status or "clean_for_source_path",
            "last_path_commit": _run_git(repo, "log", "-1", "--format=%H", "--", relative),
            "repo_dirty_entry_count": len(actual_status.splitlines()) if actual_status else 0,
            "repo_status_sha256": sha256_text(actual_status or ""),
        }
        for key, value in actual.items():
            if git_record.get(key) != value:
                diagnostics.append(f"SOURCE_GIT_MISMATCH:{source_id}:{key}")

    return _dedupe(diagnostics)


def assess_readiness(
    clause_map: dict[str, Any],
    plan_manifest: dict[str, Any],
    *,
    hc_decisions: dict[str, Any] | None = None,
    approved_hc_draft: dict[str, Any] | None = None,
    approved_hc_draft_sha256: str | None = None,
    verify_sources: bool = True,
    plan_manifest_path: Path | None = None,
    hc_decisions_path: Path | None = None,
    approved_hc_draft_path: Path | None = None,
) -> tuple[list[str], dict[str, int]]:
    semantic, counts = semantic_gate_diagnostics(clause_map, hc_decisions)
    diagnostics = (
        structural_gate_diagnostics(clause_map)
        + semantic
        + decision_chain_diagnostics(
            hc_decisions, approved_hc_draft, approved_hc_draft_sha256
        )
        + plan_gate_diagnostics(plan_manifest)
    )
    if verify_sources:
        diagnostics.extend(source_gate_diagnostics(clause_map))
    if plan_manifest_path is not None:
        diagnostics.extend(plan_filesystem_diagnostics(plan_manifest_path, plan_manifest))
    if hc_decisions is not None and hc_decisions_path is not None:
        diagnostics.extend(
            decision_filesystem_diagnostics(
                hc_decisions_path, hc_decisions, approved_hc_draft
            )
        )
    if approved_hc_draft is not None and approved_hc_draft_path is not None:
        diagnostics.extend(
            decision_draft_filesystem_diagnostics(
                approved_hc_draft_path, approved_hc_draft
            )
        )
    return _dedupe(diagnostics), counts


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clause-map", type=Path, required=True)
    parser.add_argument("--plan-ir-manifest", type=Path, required=True)
    parser.add_argument("--expected-map-sha256", required=True)
    parser.add_argument("--expected-plan-manifest-sha256", required=True)
    parser.add_argument("--hc-decisions", type=Path)
    parser.add_argument("--expected-hc-decisions-sha256")
    parser.add_argument("--approved-hc-draft", type=Path)
    parser.add_argument("--expected-approved-hc-draft-sha256")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        for label, value in (
            ("expected-map", args.expected_map_sha256),
            ("expected-plan-manifest", args.expected_plan_manifest_sha256),
        ):
            if not HEX64.fullmatch(value.upper()) or value.upper() == "0" * 64:
                raise ReadinessInputError(f"EXPECTED_SHA256_INVALID:{label}")

        map_bytes = args.clause_map.read_bytes()
        plan_bytes = args.plan_ir_manifest.read_bytes()
        clause_map = load_json_bytes(map_bytes, str(args.clause_map))
        plan_manifest = load_json_bytes(plan_bytes, str(args.plan_ir_manifest))
        diagnostics: list[str] = []
        hc_decisions = None
        actual_decisions_sha = None
        approved_hc_draft = None
        actual_draft_sha = None
        if bool(args.hc_decisions) != bool(args.expected_hc_decisions_sha256):
            raise ReadinessInputError("HC_DECISION_INPUT_INCOMPLETE")
        if args.hc_decisions is not None:
            if (
                not HEX64.fullmatch(args.expected_hc_decisions_sha256.upper())
                or args.expected_hc_decisions_sha256.upper() == "0" * 64
            ):
                raise ReadinessInputError("EXPECTED_SHA256_INVALID:hc-decisions")
            decision_bytes = args.hc_decisions.read_bytes()
            actual_decisions_sha = sha256_bytes(decision_bytes)
            if actual_decisions_sha != args.expected_hc_decisions_sha256.upper():
                diagnostics.append(
                    "HC_DECISIONS_SHA256_MISMATCH:expected="
                    + args.expected_hc_decisions_sha256.upper()
                    + ":actual="
                    + actual_decisions_sha
                )
            hc_decisions = load_json_bytes(decision_bytes, str(args.hc_decisions))
        if bool(args.approved_hc_draft) != bool(
            args.expected_approved_hc_draft_sha256
        ):
            raise ReadinessInputError("HC_APPROVED_DRAFT_INPUT_INCOMPLETE")
        if args.approved_hc_draft is not None and args.hc_decisions is None:
            raise ReadinessInputError("HC_APPROVED_DRAFT_WITHOUT_LEDGER")
        if args.approved_hc_draft is not None:
            if (
                not HEX64.fullmatch(
                    args.expected_approved_hc_draft_sha256.upper()
                )
                or args.expected_approved_hc_draft_sha256.upper() == "0" * 64
            ):
                raise ReadinessInputError(
                    "EXPECTED_SHA256_INVALID:approved-hc-draft"
                )
            draft_bytes = args.approved_hc_draft.read_bytes()
            actual_draft_sha = sha256_bytes(draft_bytes)
            if actual_draft_sha != args.expected_approved_hc_draft_sha256.upper():
                diagnostics.append(
                    "HC_APPROVED_DRAFT_SHA256_MISMATCH:expected="
                    + args.expected_approved_hc_draft_sha256.upper()
                    + ":actual="
                    + actual_draft_sha
                )
            approved_hc_draft = load_json_bytes(
                draft_bytes, str(args.approved_hc_draft)
            )
        actual_map_sha = sha256_bytes(map_bytes)
        actual_plan_sha = sha256_bytes(plan_bytes)
        if actual_map_sha != args.expected_map_sha256.upper():
            diagnostics.append(
                f"MAP_SHA256_MISMATCH:expected={args.expected_map_sha256.upper()}:actual={actual_map_sha}"
            )
        if actual_plan_sha != args.expected_plan_manifest_sha256.upper():
            diagnostics.append(
                "PLAN_MANIFEST_SHA256_MISMATCH:expected="
                + args.expected_plan_manifest_sha256.upper()
                + ":actual="
                + actual_plan_sha
            )

        evaluated, counts = assess_readiness(
            clause_map,
            plan_manifest,
            hc_decisions=hc_decisions,
            approved_hc_draft=approved_hc_draft,
            approved_hc_draft_sha256=actual_draft_sha,
            plan_manifest_path=args.plan_ir_manifest,
            hc_decisions_path=args.hc_decisions,
            approved_hc_draft_path=args.approved_hc_draft,
        )
        diagnostics.extend(evaluated)
        diagnostics = _dedupe(diagnostics)
        status = "READY" if not diagnostics else "BLOCKED"
        payload = {
            "schema_version": SCHEMA_VERSION,
            "status": status,
            "counts": counts,
            "diagnostics": diagnostics,
            "inputs": {
                "clause_map_sha256": actual_map_sha,
                "plan_ir_manifest_sha256": actual_plan_sha,
                "hc_decisions_sha256": actual_decisions_sha,
                "approved_hc_draft_sha256": actual_draft_sha,
            },
            "writes": [],
            "activation_targets": [],
        }
        print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
        return 0 if status == "READY" else 2
    except (OSError, ReadinessInputError) as exc:
        print(
            json.dumps(
                {
                    "schema_version": SCHEMA_VERSION,
                    "status": "INVALID_INPUT",
                    "diagnostics": [str(exc)],
                    "writes": [],
                    "activation_targets": [],
                },
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
