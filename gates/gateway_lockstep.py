#!/usr/bin/env python3
"""Shared, bounded receipt verifier for portable Gateway Lockstep adapters."""
from __future__ import annotations
import base64, hashlib, json, re, sys
from dataclasses import asdict, dataclass
from typing import Any
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
except ImportError:
    Ed25519PublicKey = None

SCHEMA_VERSION = "dreameros-gateway-lockstep-v2"
INTENT_ENVELOPE_SCHEMA = "dreameros-intent-envelope-v1"
RECEIPT_EVENT_SCHEMA = "dreameros-receipt-event-v1"
RECEIPT_KEY_SCHEMA = "dreameros-receipt-key-v1"
MAX_RECORD_BYTES = 8192
TERMINAL_STATES = frozenset({"SUCCESS", "NO-OP", "BLOCKED", "STALLED", "EXHAUSTED"})
CLIENT_CAPABILITY_MATRIX = {"claude_stop": {"event": "Stop", "enforce": False}, "cursor_after_mcp": {"event": "afterMCPExecution", "enforce": False}}
MANAGED_ARTIFACTS = {"shared_verifier": "gates/gateway_lockstep.py", "claude_stop_adapter": "install/claude-code/payload/settings.fragment.json", "cursor_mcp_adapter": "cursor/hooks/dreameros_cursor_hook.py"}
HOOK_EVENT_ADAPTERS = {"claude_stop": {"evidence_field": None}, "cursor_after_mcp": {"evidence_field": "gateway_lockstep_evidence"}}
_ANCHOR = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{7,127}\Z")

@dataclass(frozen=True)
class Verdict:
    status: str
    ok: bool
    reason: str
    def to_dict(self) -> dict[str, Any]: return asdict(self)
def _unique(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    out = {}
    for key, value in pairs:
        if key in out: raise ValueError("duplicate JSON key")
        out[key] = value
    return out
def _load(value: Any) -> Any: return json.loads(value, object_pairs_hook=_unique) if isinstance(value, str) else value
def _canon(value: Any) -> bytes: return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
def _v(status: str, reason: str, ok: bool = False) -> Verdict: return Verdict(status, ok, reason)

def verify_record(record: Any, tool_input: Any) -> Verdict:
    try:
        record, tool_input = _load(record), _load(tool_input)
        if len(_canon(record)) > MAX_RECORD_BYTES: return _v("CONFIGURED", "evidence record exceeds byte limit")
    except Exception: return _v("CONFIGURED", "record or tool input is malformed")
    if not isinstance(tool_input, dict) or set(tool_input) != {"skill", "content"} or tool_input.get("skill") != "auto" or not isinstance(tool_input.get("content"), str) or not tool_input["content"].strip(): return _v("CONFIGURED", "actual dreameros_skill input is not the portable auto path")
    if not isinstance(record, dict) or set(record) != {"schema_version", "intent_envelope_schema", "receipt", "public_key_lookup"} or record.get("schema_version") != SCHEMA_VERSION or record.get("intent_envelope_schema") != INTENT_ENVELOPE_SCHEMA: return _v("CONFIGURED", "record schema is missing or unsupported")
    receipt, lookup = record["receipt"], record["public_key_lookup"]
    rkeys = {"schema_version", "id", "intent_anchor", "terminal_state", "request_sha256", "signed_payload_b64", "signature_b64", "key_id"}
    lkeys = {"schema_version", "key_id", "public_key_b64", "source_url"}
    if not isinstance(receipt, dict) or set(receipt) != rkeys or receipt.get("schema_version") != RECEIPT_EVENT_SCHEMA: return _v("INVOKED", "receipt is missing or malformed")
    if not isinstance(lookup, dict) or set(lookup) != lkeys or lookup.get("schema_version") != RECEIPT_KEY_SCHEMA or lookup.get("key_id") != receipt.get("key_id") or not isinstance(lookup.get("source_url"), str) or not lookup["source_url"].startswith("https://") or not lookup["source_url"].endswith("/.well-known/ctci-keys.json"): return _v("INVOKED", "Gateway public receipt-key lookup is missing or malformed")
    if not isinstance(receipt.get("intent_anchor"), str) or _ANCHOR.fullmatch(receipt["intent_anchor"]) is None or receipt.get("terminal_state") not in TERMINAL_STATES or receipt.get("request_sha256") != hashlib.sha256(_canon(tool_input)).hexdigest(): return _v("INVOKED", "receipt does not bind actual input and signed intent anchor")
    try:
        signed = json.loads(base64.b64decode(receipt["signed_payload_b64"], validate=True)); signature = base64.b64decode(receipt["signature_b64"], validate=True); public = base64.b64decode(lookup["public_key_b64"], validate=True)
        expected = {"id": receipt["id"], "intent_anchor": receipt["intent_anchor"], "terminal_state": receipt["terminal_state"], "request_sha256": receipt["request_sha256"]}
        if signed != expected or Ed25519PublicKey is None: raise ValueError()
        Ed25519PublicKey.from_public_bytes(public).verify(signature, _canon(signed))
    except Exception: return _v("INVOKED", "Gateway receipt signature did not verify")
    return _v("TERMINAL", "Gateway-signed receipt binds this input and terminal state", True)

def extract_from_host_payload(payload: dict[str, Any]) -> Verdict:
    try: result, tool_input = _load(payload.get("result_json", payload.get("tool_output"))), _load(payload.get("tool_input"))
    except Exception: return _v("UNSUPPORTED", "host event lacks readable tool input or result")
    if not isinstance(result, dict) or "gateway_lockstep_evidence" not in result: return _v("UNSUPPORTED", "host event does not supply signed Gateway Lockstep evidence")
    return verify_record(result["gateway_lockstep_evidence"], tool_input)

def main() -> int:
    try: payload = _load(sys.stdin.read())
    except Exception: return 0
    if not isinstance(payload, dict) or payload.get("stop_hook_active") is True: return 0
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "Stop", "additionalContext": "GATEWAY LOCKSTEP: UNSUPPORTED. Claude Stop lacks signed MCP input and receipt evidence. This is advisory only."}}, separators=(",", ":")))
    return 0
if __name__ == "__main__": raise SystemExit(main())
