from __future__ import annotations

import unittest

from gates.gateway_lockstep import SCHEMA_VERSION, extract_from_host_payload, verify_record


def valid_record() -> dict[str, object]:
    return {
        "schema_version": SCHEMA_VERSION,
        "intent_envelope_schema": "dreameros-intent-envelope-v1",
        "intent_key": "intent-20260913-a",
        "mcp_invocation": {"tool": "dreameros_skill", "intent_key": "intent-20260913-a"},
        "receipt": {
            "schema_version": "dreameros-receipt-event-v1",
            "id": "receipt-20260913-a",
            "intent_key": "intent-20260913-a",
        },
        "terminal_state": "completed",
    }


class GatewayLockstepTests(unittest.TestCase):
    def test_missing_mcp_invocation_stops_at_configured(self) -> None:
        record = valid_record()
        record["mcp_invocation"] = None
        verdict = verify_record(record)
        self.assertEqual((verdict.status, verdict.ok), ("CONFIGURED", False))

    def test_missing_or_malformed_receipt_stops_at_invoked(self) -> None:
        record = valid_record()
        record["receipt"] = {"id": "bad"}
        verdict = verify_record(record)
        self.assertEqual((verdict.status, verdict.ok), ("INVOKED", False))

    def test_wrong_intent_key_stops_at_invoked(self) -> None:
        record = valid_record()
        record["receipt"] = {
            "schema_version": "dreameros-receipt-event-v1",
            "id": "receipt-20260913-a",
            "intent_key": "another-intent",
        }
        verdict = verify_record(record)
        self.assertEqual((verdict.status, verdict.ok), ("INVOKED", False))

    def test_nonterminal_state_stops_at_receipted(self) -> None:
        record = valid_record()
        record["terminal_state"] = "running"
        verdict = verify_record(record)
        self.assertEqual((verdict.status, verdict.ok), ("RECEIPTED", False))

    def test_valid_record_passes_terminal_completion(self) -> None:
        verdict = verify_record(valid_record())
        self.assertEqual((verdict.status, verdict.ok), ("TERMINAL", True))

    def test_missing_host_evidence_is_unsupported_not_a_pass(self) -> None:
        verdict = extract_from_host_payload({"result_json": {"ok": True}})
        self.assertEqual((verdict.status, verdict.ok), ("UNSUPPORTED", False))


if __name__ == "__main__":
    unittest.main()
