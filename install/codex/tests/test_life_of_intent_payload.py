from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SKILL = "dreameros-life-of-intent"
SOURCE = ROOT / "skills" / SKILL / "SKILL.md"
CLAUDE_PAYLOAD = ROOT / "install" / "claude-code" / "payload" / "skills" / SKILL / "SKILL.md"
CODEX_PAYLOAD = ROOT / "install" / "codex" / "payload" / "skills" / SKILL / "SKILL.md"
SYNC = ROOT / "scripts" / "sync-model-tiered-offload.ps1"


class TestLifeOfIntentPayload(unittest.TestCase):
    def test_payloads_and_installed_carriers_are_byte_identical(self) -> None:
        source = SOURCE.read_bytes()
        self.assertEqual(CLAUDE_PAYLOAD.read_bytes(), source)
        self.assertEqual(CODEX_PAYLOAD.read_bytes(), source)

        powershell = shutil.which("powershell")
        self.assertIsNotNone(powershell, "Windows PowerShell is required for the installer test")
        with tempfile.TemporaryDirectory(prefix="dreameros-life-of-intent-") as temp:
            home = Path(temp)
            command = [
                powershell,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(SYNC),
                "-RepoRoot",
                str(ROOT),
                "-SkillName",
                SKILL,
                "-AgentsHome",
                str(home / ".agents"),
                "-CodexHome",
                str(home / ".codex"),
                "-ClaudeHome",
                str(home / ".claude"),
                "-Install",
            ]
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for home_name in (".agents", ".codex", ".claude"):
                installed = home / home_name / "skills" / SKILL / "SKILL.md"
                self.assertEqual(installed.read_bytes(), source, installed.as_posix())


if __name__ == "__main__":
    unittest.main()
