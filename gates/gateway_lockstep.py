#!/usr/bin/env python3
"""Verify bounded Gateway Lockstep evidence without inferring missing work.

The record is intentionally small. It proves only four separate facts:
configured schema, a matching Gateway invocation, a matching receipt, and a
terminal completion state. A host event that does not carry this record is
UNSUPPORTED, never a pass.
"""
from __future__ import annotations

import json
import re
import sys
from dataclasses import asdict, dataclass
from typing import Any


SCHEMA_VERSION = "dreameros-gateway-lockstep-v1"
MAX_RECORD_BYTES = 8192
INTENT_ENVELOPE_SCHEMA = "dreameros-intent-envelope-v1"
RECEIPT_EVENT_SCHEMA = "dreameros-receipt-event-v1"
TERMINAL_STATES = frozenset({"completed"})
CLIENT_CAPABILITY_MATRIX = {
    "claude_stop": {"event": "Stop", "can_supply_lockstep_evidence": False},
    "cursor_after_mcp": {"event": "afterMCPExecution", "can_supply_lockstep_evidence": True},
}
MANAGED_ARTIFACTS = {
    "shared_verifier": "gates/gateway_lockstep.py",
    "claude_stop_adapter": "install/claude-code/payload/settings.fragment.json",
    "cursor_mcp_adapter": "cursor/hooks/dreameros_cursor_hook.py",
}
HOOK_EVENT_ADAPTERS = {
    "claude_stop": {"client": "claude", "event": "Stop", "evidence_field": None},
    "cursor_after_mcp": {
        "client": "cursor",
        "event": "afterMCPExecution",
        "evidence_field": "gateway_lockstep_evidence",
    },
}
_INTENT_KEY = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\Z")
_RECEIPT_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{7,127}\Z")


@dataclass(frozen=True)
class Verdict:
    status: str
    ok: bool
    reason: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _json_loads(value: str) -> Any:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        output: dict[str, Any] = {}
        for key, item in pairs:
            if key in output:
                raise ValueError("duplicate JSON key")
            output[key] = item
        return output

    return json.loads(value, object_pairs_hook=reject_duplicates)


def _configured(reason: str) -> Verdict:
    return Verdict("CONFIGURED", False, reason)


def _invoked(reason: str) -> Verdict:
    return Verdict("INVOKED", False, reason)


def _receipted(reason: str) -> Verdict:
    return Verdict("RECEIPTED", False, reason)


def verify_record(value: Any) -> Verdict:
    """Validate one complete lockstep record with no unknown fields."""
    if isinstance(value, str):
        if len(value.encode("utf-8")) > MAX_RECORD_BYTES:
            return _configured("evidence record exceeds byte limit")
        try:
            value = _json_loads(value)
        except (TypeError, ValueError, json.JSONDecodeError):
            return _configured("evidence record is not valid JSON")
    else:
        try:
            encoded = json.dumps(value, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
        except (TypeError, ValueError):
            return _configured("evidence record is not JSON serializable")
        if len(encoded) > MAX_RECORD_BYTES:
            return _configured("evidence record exceeds byte limit")

    if not isinstance(value, dict):
        return _configured("evidence record is not an object")
    required = {"schema_version", "intent_envelope_schema", "intent_key", "mcp_invocation", "receipt", "terminal_state"}
    if set(value) != required:
        return _configured("evidence record has missing or unknown fields")
    if value.get("schema_version") != SCHEMA_VERSION:
        return _configured("unsupported evidence schema")
    if value.get("intent_envelope_schema") != INTENT_ENVELOPE_SCHEMA:
        return _configured("unsupported intent envelope schema")

    intent_key = value.get("intent_key")
    if not isinstance(intent_key, str) or _INTENT_KEY.fullmatch(intent_key) is None:
        return _configured("invalid intent key")

    invocation = value.get("mcp_invocation")
    if not isinstance(invocation, dict) or set(invocation) != {"tool", "intent_key"}:
        return _configured("missing MCP invocation evidence")
    if invocation.get("tool") != "dreameros_skill":
        return _configured("MCP invocation is not dreameros_skill")
    if invocation.get("intent_key") != intent_key:
        return _configured("MCP invocation intent key does not match")

    receipt = value.get("receipt")
    if not isinstance(receipt, dict) or set(receipt) != {"schema_version", "id", "intent_key"}:
        return _invoked("missing or malformed receipt evidence")
    if receipt.get("schema_version") != RECEIPT_EVENT_SCHEMA:
        return _invoked("unsupported receipt event schema")
    receipt_id = receipt.get("id")
    if not isinstance(receipt_id, str) or _RECEIPT_ID.fullmatch(receipt_id) is None:
        return _invoked("missing or malformed receipt id")
    if receipt.get("intent_key") != intent_key:
        return _invoked("receipt intent key does not match")

    if value.get("terminal_state") not in TERMINAL_STATES:
        return _receipted("intent has not reached terminal completion")
    return Verdict("TERMINAL", True, "Gateway invocation, receipt, and terminal completion match")


def extract_from_host_payload(payload: dict[str, Any]) -> Verdict:
    """Read only an explicit evidence field from a host event payload."""
    adapter = HOOK_EVENT_ADAPTERS["cursor_after_mcp"]
    raw: Any = payload.get(adapter["evidence_field"])
    if raw is None:
        raw = payload.get("result_json", payload.get("tool_output"))
        if isinstance(raw, str):
            try:
                raw = _json_loads(raw)
            except (TypeError, ValueError, json.JSONDecodeError):
                return Verdict("UNSUPPORTED", False, "host event has no readable lockstep evidence")
        if isinstance(raw, dict):
            raw = raw.get("gateway_lockstep_evidence")
    if raw is None:
        return Verdict("UNSUPPORTED", False, "host event does not supply Gateway Lockstep evidence")
    return verify_record(raw)


def _emit_stop_verdict(verdict: Verdict) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "Stop",
            "additionalContext": (
                f"GATEWAY LOCKSTEP: {verdict.status}. {verdict.reason}. "
                "This check did not infer an MCP invocation, receipt, or completion from configuration."
            ),
        }
    }, separators=(",", ":")))


def main() -> int:
    try:
        payload = _json_loads(sys.stdin.read())
    except (TypeError, ValueError, json.JSONDecodeError):
        return 0
    if not isinstance(payload, dict):
        return 0
    if CLIENT_CAPABILITY_MATRIX["claude_stop"]["can_supply_lockstep_evidence"]:
        _emit_stop_verdict(extract_from_host_payload(payload))
    else:
        _emit_stop_verdict(Verdict("UNSUPPORTED", False, "Claude Stop does not supply Gateway Lockstep evidence"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
