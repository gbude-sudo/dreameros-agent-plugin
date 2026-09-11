from __future__ import annotations

import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
HOOK_PATH = ROOT / "install" / "codex" / "payload" / "hooks" / "model-switch-ack-codex.py"
HOOKS_PATH = ROOT / "install" / "codex" / "payload" / "hooks.json"


def load_hook_module():
    spec = importlib.util.spec_from_file_location("dreameros_codex_stop_hook", HOOK_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("Could not load the Codex Stop hook")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CodexStopHookTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="dreameros-codex-stop-hook-")
        self.root = Path(self.temp.name)
        self.module = load_hook_module()
        self.module._STATE_DIR = self.root / ".codex" / "hooks" / ".model-switch-ack-state"
        self.module._SESSIONS_DIR = self.root / ".codex" / "sessions"
        self.module._SESSIONS_DIR.mkdir(parents=True)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write_rollout(self, session_id: str, *models: str) -> None:
        path = self.module._SESSIONS_DIR / f"rollout-2026-09-11-{session_id}.jsonl"
        records = [json.dumps({"type": "turn_context", "payload": {"model": model}}) for model in models]
        path.write_text("\n".join(records) + "\n", encoding="utf-8")

    def run_hook(self, payload: object) -> tuple[int, str]:
        output = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(json.dumps(payload))), redirect_stdout(output):
            result = self.module.main()
        return result, output.getvalue().strip()

    def test_stop_registration_matches_current_contract(self) -> None:
        root = json.loads(HOOKS_PATH.read_text(encoding="utf-8"))
        stop_entries = root["hooks"]["Stop"]
        self.assertEqual(len(stop_entries), 1)
        commands = stop_entries[0]["hooks"]
        self.assertEqual(len(commands), 1)
        self.assertNotIn("additionalContextLimit", commands[0])

    def test_switch_blocks_stop_with_reason(self) -> None:
        session_id = "11111111-1111-1111-1111-111111111111"
        self.write_rollout(session_id, "gpt-model-a", "gpt-model-b")
        result, output = self.run_hook({"session_id": session_id, "model": "gpt-model-b"})
        self.assertEqual(result, 0)
        parsed = json.loads(output)
        self.assertEqual(set(parsed), {"decision", "reason"})
        self.assertEqual(parsed["decision"], "block")
        self.assertIn("Switched to gpt-model-b - continuing from here.", parsed["reason"])

    def test_active_stop_hook_guard_prevents_recursion(self) -> None:
        session_id = "22222222-2222-2222-2222-222222222222"
        self.write_rollout(session_id, "gpt-model-a", "gpt-model-b")
        result, output = self.run_hook(
            {"session_id": session_id, "model": "gpt-model-b", "stop_hook_active": True}
        )
        self.assertEqual(result, 0)
        self.assertEqual(output, "")
        self.assertFalse(self.module._STATE_DIR.exists())

    def test_same_switch_boundary_blocks_only_once(self) -> None:
        session_id = "33333333-3333-3333-3333-333333333333"
        self.write_rollout(session_id, "gpt-model-a", "gpt-model-b")
        payload = {"session_id": session_id, "model": "gpt-model-b"}
        _, first = self.run_hook(payload)
        _, second = self.run_hook(payload)
        self.assertEqual(json.loads(first)["decision"], "block")
        self.assertEqual(second, "")

    def test_no_switch_and_malformed_input_are_silent(self) -> None:
        session_id = "44444444-4444-4444-4444-444444444444"
        self.write_rollout(session_id, "gpt-model-a")
        _, no_switch = self.run_hook({"session_id": session_id, "model": "gpt-model-a"})
        self.assertEqual(no_switch, "")
        output = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO("not-json")), redirect_stdout(output):
            self.assertEqual(self.module.main(), 0)
        self.assertEqual(output.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
