from __future__ import annotations

import json
import ast
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
INSTALLER = ROOT / "install" / "codex" / "dreameros-global-setup.ps1"
PAYLOAD = ROOT / "install" / "codex" / "payload"


class GlobalFlowInstallTests(unittest.TestCase):
    def test_every_python_payload_parses(self) -> None:
        for path in sorted((PAYLOAD / "hooks").glob("*.py")):
            with self.subTest(path=path.name):
                ast.parse(path.read_text(encoding="utf-8"))

    def run_installer(self, home: Path, force: bool = False, dry_run: bool = False) -> subprocess.CompletedProcess[str]:
        powershell = shutil.which("powershell")
        self.assertIsNotNone(powershell, "PowerShell is required")
        command = [
            powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(INSTALLER),
            "-CodexHome", str(home), "-PayloadPath", str(PAYLOAD),
        ]
        if force:
            command.append("-Force")
        if dry_run:
            command.append("-DryRun")
        return subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=False)

    def test_installs_native_payload_and_merges_owned_hook_keys(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dreameros-codex-global-flow-") as temp:
            home = Path(temp) / ".codex"
            home.mkdir()
            original_hooks = {
                "description": "owner hooks",
                "owner": {"keep": True},
                "hooks": {"Stop": [{"matcher": "owner", "hooks": [{"type": "command", "command": "owner-stop"}]}]},
            }
            (home / "hooks.json").write_text(json.dumps(original_hooks), encoding="utf-8")
            (home / "config.toml").write_text("[mcp_servers.owner]\nurl = 'https://example.invalid'\n", encoding="utf-8")
            first = self.run_installer(home)
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            self.assertTrue((home / "dreameros" / "CONTROL_MANIFEST.json").is_file())
            self.assertTrue((home / "dreameros" / "adapters" / "gate_gateway_boot_codex.py").is_file())
            self.assertTrue((home / "skills" / "dreameros-control-router" / "SKILL.md").is_file())
            self.assertEqual(len(list((home / "agents").glob("*.toml"))), 17)
            hooks = json.loads((home / "hooks.json").read_text(encoding="utf-8"))
            self.assertEqual(hooks["owner"], {"keep": True})
            self.assertEqual(hooks["hooks"]["Stop"][0]["hooks"][0]["command"], "owner-stop")
            prompt_commands = [hook.get("commandWindows") for group in hooks["hooks"]["UserPromptSubmit"] for hook in group["hooks"]]
            self.assertIn('python "' + str(home).replace("\\", "/") + '/dreameros/adapters/gate_gateway_boot_codex.py"', prompt_commands)
            config = (home / "config.toml").read_text(encoding="utf-8")
            self.assertIn("[mcp_servers.owner]", config)
            self.assertIn("[agents]", config)
            self.assertIn('default_subagent_model = "gpt-5.6-luna"', config)
            before = {path.relative_to(home): path.read_bytes() for path in home.rglob("*") if path.is_file() and "backups" not in path.parts}
            second = self.run_installer(home)
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            after = {path.relative_to(home): path.read_bytes() for path in home.rglob("*") if path.is_file() and "backups" not in path.parts}
            self.assertEqual(before, after)

    def test_different_managed_file_is_preserved_without_force(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dreameros-codex-global-flow-owner-") as temp:
            home = Path(temp) / ".codex"
            destination = home / "dreameros" / "adapters" / "gate_gateway_boot_codex.py"
            destination.parent.mkdir(parents=True)
            destination.write_text("owner edit\n", encoding="utf-8")
            result = self.run_installer(home)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(destination.read_text(encoding="utf-8"), "owner edit\n")
            self.assertIn("MERGE NEEDED adapter/gate_gateway_boot_codex.py", result.stdout)
            forced = self.run_installer(home, force=True)
            self.assertEqual(forced.returncode, 0, forced.stdout + forced.stderr)
            self.assertIn("DREAMEROS GATEWAY BOOT", destination.read_text(encoding="utf-8"))
            backups = list((home / "backups").rglob("gate_gateway_boot_codex.py"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_text(encoding="utf-8"), "owner edit\n")

    def test_dry_run_does_not_create_fresh_target(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dreameros-codex-dry-new-") as temp:
            home = Path(temp) / ".codex"
            result = self.run_installer(home, dry_run=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(home.exists())
            self.assertIn("DRYRUN would merge hooks.json", result.stdout)
            self.assertIn("DRYRUN would merge config.toml", result.stdout)

    def test_dry_run_preserves_existing_targets_without_backup(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dreameros-codex-dry-existing-") as temp:
            home = Path(temp) / ".codex"
            home.mkdir()
            hooks = home / "hooks.json"
            config = home / "config.toml"
            hooks.write_text('{"owner":true,"hooks":{}}\n', encoding="utf-8")
            config.write_text("[owner]\nvalue = true\n", encoding="utf-8")
            before_hooks = hooks.read_bytes()
            before_config = config.read_bytes()
            result = self.run_installer(home, dry_run=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(hooks.read_bytes(), before_hooks)
            self.assertEqual(config.read_bytes(), before_config)
            self.assertFalse((home / "backups").exists())


if __name__ == "__main__":
    unittest.main()
