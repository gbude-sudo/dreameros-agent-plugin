from __future__ import annotations

import base64
import hashlib
import io
import json
import tempfile
import unittest
import zipfile
from unittest.mock import patch
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from dreameros_agent.adapters import (
    CLAUDE_MCP_ENTRY,
    CodexAdapter,
    CURSOR_MCP_ENTRY,
    JsonMcpAdapter,
    LOCAL_MCP_URL,
)
from dreameros_agent.heartbeat import ClientHeartbeat, build_heartbeat
from dreameros_agent.autostart import render_autostart
from dreameros_agent.bootpack import install_bootpack
from dreameros_agent.gateway import GatewayClient
from dreameros_agent.managed_files import ManagedFileError, render_owned_block
from dreameros_agent.oauth_client import OAuthDiscovery, authorization_url, registration_payload
from dreameros_agent.pkce import challenge_s256, new_state, new_verifier, state_matches
from dreameros_agent.release_manifest import ManifestVerificationError, verify_manifest
from dreameros_agent.platform_paths import paths_for
from dreameros_agent.proxy import ProxyServer
from dreameros_agent.runtime import _newer_version
from dreameros_agent.state import LocalState
from dreameros_agent.updater import UpdateManager, artifact_key, select_artifact
from dreameros_agent.vault import MacOSKeychainVault, default_vault


class DesktopAgentTests(unittest.TestCase):
    def test_vendor_configs_use_local_proxy_and_never_embed_tokens(self):
        self.assertEqual(LOCAL_MCP_URL, "http://127.0.0.1:18765/mcp")
        rendered = json.dumps(
            {"claude": CLAUDE_MCP_ENTRY, "cursor": CURSOR_MCP_ENTRY},
            sort_keys=True,
        ).lower()
        self.assertIn(LOCAL_MCP_URL, rendered)
        self.assertNotIn("bearer", rendered)
        self.assertNotIn("token", rendered)

    def test_pkce_and_state(self):
        verifier = new_verifier()
        self.assertGreaterEqual(len(verifier), 43)
        self.assertEqual(len(challenge_s256(verifier)), 43)
        state = new_state()
        self.assertTrue(state_matches(state, state))
        self.assertFalse(state_matches(state, state + "x"))
        with self.assertRaises(ValueError):
            challenge_s256("invalid")

    def test_signed_manifest_rejects_tamper(self):
        private = Ed25519PrivateKey.generate()
        public = private.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
        now = datetime.now(timezone.utc)
        payload = {
            "schema_version": "1.0",
            "release_id": "desktop-agent-0.1.0",
            "channel": "stable",
            "published_at": (now - timedelta(minutes=1)).isoformat(),
            "expires_at": (now + timedelta(days=1)).isoformat(),
            "signing_key_id": "test-key",
            "minimum_agent_version": "0.1.0",
            "agent": {},
            "bootpack": {},
        }
        raw = json.dumps(payload, separators=(",", ":")).encode()
        signature = base64.b64encode(private.sign(raw)).decode()
        keys = {"test-key": base64.b64encode(public).decode()}
        self.assertEqual(
            verify_manifest(raw, signature, keys, now=now)["release_id"],
            payload["release_id"],
        )
        with self.assertRaises(ManifestVerificationError):
            verify_manifest(raw + b" ", signature, keys, now=now)

    def test_owned_block_preserves_unrelated_text_and_is_idempotent(self):
        original = "user_setting = true\n"
        first = render_owned_block(original, "managed = true", "DREAMEROS")
        second = render_owned_block(first, "managed = true", "DREAMEROS")
        self.assertEqual(first, second)
        self.assertIn(original.strip(), first)
        with self.assertRaises(ManagedFileError):
            render_owned_block(first + "# BEGIN DREAMEROS\n", "x", "DREAMEROS")

    def test_json_adapter_refuses_malformed_and_preserves_unrelated(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / "mcp.json"
            config.write_text('{"theme":"dark"}', encoding="utf-8")
            adapter = JsonMcpAdapter("cursor", config, root, CURSOR_MCP_ENTRY)
            result = adapter.repair(root / "backups")
            self.assertTrue(result.changed)
            data = json.loads(config.read_text())
            self.assertEqual(data["theme"], "dark")
            self.assertEqual(data["mcpServers"]["dreameros"], CURSOR_MCP_ENTRY)
            self.assertFalse(adapter.repair(root / "backups").changed)
            config.write_text("{broken", encoding="utf-8")
            with self.assertRaises(ManagedFileError):
                adapter.repair(root / "backups")

    def test_json_adapter_refuses_unmanaged_dreameros_entry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / "mcp.json"
            config.write_text(
                '{"mcpServers":{"dreameros":{"url":"https://other.invalid"}}}',
                encoding="utf-8",
            )
            adapter = JsonMcpAdapter("cursor", config, root, CURSOR_MCP_ENTRY)
            with self.assertRaises(ManagedFileError):
                adapter.repair(root / "backups")

    def test_codex_adapter_repairs_owned_block_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / "config.toml"
            config.write_text('model = "local"\n', encoding="utf-8")
            adapter = CodexAdapter(config, root)
            self.assertTrue(adapter.repair(root / "backups").changed)
            text = config.read_text()
            self.assertIn('model = "local"', text)
            self.assertIn("[mcp_servers.dreameros]", text)
            self.assertFalse(adapter.repair(root / "backups").changed)

    def test_codex_adapter_migrates_known_remote_entry_without_duplication(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / "config.toml"
            config.write_text(
                '[mcp_servers.dreameros]\nurl = "https://mcp.dreameros.app/mcp"\n',
                encoding="utf-8",
            )
            adapter = CodexAdapter(config, root)
            self.assertTrue(adapter.repair(root / "backups").changed)
            self.assertEqual(config.read_text().count("[mcp_servers.dreameros]"), 1)
            self.assertIn(LOCAL_MCP_URL, config.read_text())

    def test_heartbeat_contains_no_local_identity_fields(self):
        payload = build_heartbeat(
            installation_id="test-installation",
            agent_version="0.1.0",
            architecture="x64",
            os_family="windows",
            boot_contract_version="1.0.0",
            manifest_schema_version="1.0.0",
            boot_pack_version="1.0.0",
            bootpack_sha256="b" * 64,
            adapters=[
                ClientHeartbeat(
                    vendor=vendor,
                    detected=vendor == "codex",
                    config_state="aligned" if vendor == "codex" else "missing",
                    mcp_state="connected" if vendor == "codex" else "disconnected",
                    managed_artifact_sha256="c" * 64 if vendor == "codex" else None,
                )
                for vendor in ("claude", "codex", "cursor")
            ],
            event="repair",
            repair_result="repaired",
        )
        flat = json.dumps(payload).lower()
        for forbidden in ("username", "hostname", "absolute_path", "token", "secret"):
            self.assertNotIn(forbidden, flat)
        self.assertEqual(
            {item["vendor"] for item in payload["adapters"]},
            {"claude", "codex", "cursor"},
        )

    def test_oauth_contract_uses_pkce_and_exact_loopback(self):
        discovery = OAuthDiscovery(
            "issuer",
            "https://example/auth",
            "https://example/token",
            "https://example/register",
        )
        verifier = new_verifier()
        url = authorization_url(
            discovery,
            client_id="desktop-client",
            redirect_uri="http://127.0.0.1:49152/callback",
            state="state-value",
            verifier=verifier,
        )
        self.assertIn("code_challenge_method=S256", url)
        self.assertIn("127.0.0.1%3A49152", url)
        self.assertEqual(
            registration_payload("http://127.0.0.1:49152/callback")[
                "token_endpoint_auth_method"
            ],
            "none",
        )

    def test_vault_selection_fails_closed_without_platform_backend(self):
        with patch("dreameros_agent.vault.shutil.which", return_value=None):
            with self.assertRaises(RuntimeError):
                default_vault("linux")
        with self.assertRaises(RuntimeError):
            default_vault("plan9")

    def test_macos_vault_does_not_put_secret_in_process_arguments(self):
        seen = {}

        def runner(args, **kwargs):
            seen["args"] = args
            seen["input"] = kwargs.get("input")
            return type("Result", (), {"returncode": 0, "stdout": ""})()

        with patch("dreameros_agent.vault.shutil.which", return_value="/usr/bin/security"):
            vault = MacOSKeychainVault(runner=runner)
            vault.store("access_token", "secret-value")
        self.assertNotIn("secret-value", seen["args"])
        self.assertEqual(seen["input"], "secret-value\n")

    def test_all_platform_path_mappings_and_autostart_renderers(self):
        home = Path("/home/tester")
        windows = paths_for("windows", home=home, env={"APPDATA": "C:/Roaming", "LOCALAPPDATA": "C:/Local"})
        macos = paths_for("darwin", home=home, env={})
        linux = paths_for("linux", home=home, env={})
        self.assertIn("Startup", str(windows.autostart_file))
        self.assertIn("LaunchAgents", str(macos.autostart_file))
        self.assertIn("systemd", str(linux.autostart_file))
        executable = Path("/opt/dreameros/dreameros-agent")
        self.assertIn("start \"\"", render_autostart("windows", executable))
        self.assertIn("RunAtLoad", render_autostart("darwin", executable))
        self.assertIn("WantedBy=default.target", render_autostart("linux", executable))

    def test_gateway_heartbeat_uses_bearer_and_exact_route(self):
        seen = {}

        class FakeClient:
            def request(self, method, url, **kwargs):
                seen.update(method=method, url=url, headers=kwargs["headers"], json=kwargs["json"])
                return httpx.Response(200, json={"state": "CONNECTED"}, request=httpx.Request(method, url))

        payload = {"agent_version": "0.2.0", "adapters": [], "boot_contract_version": "1.0.0", "manifest_schema_version": "1.0.0", "boot_pack_version": "x", "boot_pack_sha256": "0" * 64, "ignored": "x"}
        GatewayClient("secret-value", client=FakeClient()).heartbeat("00000000-0000-0000-0000-000000000000", payload)
        self.assertTrue(seen["url"].endswith("/heartbeat"))
        self.assertEqual(seen["headers"]["Authorization"], "Bearer secret-value")
        self.assertNotIn("ignored", seen["json"])

    def test_proxy_injects_headers_and_does_not_log_secrets(self):
        seen = {}

        class FakeRemote:
            def build_request(self, method, url, headers, content):
                seen.update(method=method, url=url, headers=headers, content=content)
                return httpx.Request(method, url, headers=headers, content=content)

            def send(self, request, stream=False):
                return httpx.Response(200, content=b'{"ok":true}', request=request)

        server = ProxyServer(("127.0.0.1", 0), token_provider=lambda: "vault-token", installation_id="123e4567-e89b-12d3-a456-426614174000", agent_version="0.2.0", client=FakeRemote())
        import threading
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            health = httpx.get(f"http://127.0.0.1:{server.server_port}/health", timeout=2)
            self.assertEqual(health.json()["agent_version"], "0.2.0")
            response = httpx.post(f"http://127.0.0.1:{server.server_port}/mcp", content=b"{}", headers={"Authorization": "Bearer caller-token"}, timeout=2)
            self.assertEqual(response.status_code, 200)
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=2)
        self.assertEqual(seen["headers"]["Authorization"], "Bearer vault-token")
        self.assertEqual(seen["headers"]["X-DreamerOS-Installation"], "123e4567-e89b-12d3-a456-426614174000")
        self.assertNotIn("caller-token", str(seen))

    def test_update_selection_tamper_and_rollback_metadata(self):
        manifest = {"agent": {"artifacts": {"windows-x86_64": {"url": "https://example/agent.exe", "sha256": "a" * 64}}}}
        self.assertEqual(artifact_key("Windows", "AMD64"), "windows-x86_64")
        self.assertEqual(select_artifact(manifest, system="Windows", machine="AMD64")["sha256"], "a" * 64)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state = LocalState(root / "state.json")
            state.save({"version": "0.1.0", "pending_update": {"release_id": "bad"}, "rollback": {"backup": None}})
            manager = UpdateManager(state, {}, root / "updates")
            self.assertFalse(manager.finish_or_rollback(False))
            result = state.load()
            self.assertEqual(result["update_status"], "rolled_back")
            self.assertNotIn("pending_update", result)

    def test_update_version_comparison_fails_closed(self):
        self.assertTrue(_newer_version("0.3.0", "0.2.0"))
        self.assertFalse(_newer_version("0.2.0", "0.2.0"))
        self.assertFalse(_newer_version("latest", "0.2.0"))

    def test_local_state_refuses_tokens(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = LocalState(Path(tmp) / "state.json")
            with self.assertRaises(ValueError):
                state.save({"access_token": "never"})

    def test_signed_bootpack_installs_every_vendor_surface(self):
        private = Ed25519PrivateKey.generate()
        public = private.public_key().public_bytes(
            serialization.Encoding.Raw,
            serialization.PublicFormat.Raw,
        )
        buffer = io.BytesIO()
        block = "<!-- BEGIN DREAMEROS-BOOT-CANON v1 -->\nRULE\n<!-- END DREAMEROS-BOOT-CANON v1 -->\n"
        with zipfile.ZipFile(buffer, "w") as archive:
            archive.writestr("claude/CLAUDE.md.block", block)
            archive.writestr("codex/AGENTS.md.block", block)
            archive.writestr("cursor/dreameros-boot-canon.mdc", "alwaysApply: true\n")
            archive.writestr("skill/dreameros-boot/SKILL.md", "# Boot skill\n")
        archive_bytes = buffer.getvalue()
        now = datetime.now(timezone.utc)
        manifest = {
            "schema_version": "1.0",
            "release_id": "desktop-v0.2.0",
            "channel": "stable",
            "published_at": (now - timedelta(minutes=1)).isoformat(),
            "expires_at": (now + timedelta(days=1)).isoformat(),
            "signing_key_id": "test-key",
            "minimum_agent_version": "0.2.0",
            "agent": {"version": "0.2.0", "artifacts": {}},
            "bootpack": {
                "version": "1.0.0",
                "source_sha256": "a" * 64,
                "archive_url": "https://example/bootpack.zip",
                "archive_sha256": hashlib.sha256(archive_bytes).hexdigest(),
            },
        }
        raw = json.dumps(manifest, separators=(",", ":"), sort_keys=True).encode()
        signature = base64.b64encode(private.sign(raw)).decode()

        class FakeClient:
            def get(self, url):
                if url.endswith("manifest.json"):
                    return httpx.Response(200, content=raw, request=httpx.Request("GET", url))
                if url.endswith("manifest.sig"):
                    return httpx.Response(200, text=signature, request=httpx.Request("GET", url))
                return httpx.Response(200, content=archive_bytes, request=httpx.Request("GET", url))

        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "home"
            result = install_bootpack(
                {
                    "manifest_url": "https://example/manifest.json",
                    "signature_url": "https://example/manifest.sig",
                },
                {"test-key": base64.b64encode(public).decode()},
                home=home,
                staging_dir=Path(tmp) / "stage",
                client=FakeClient(),
            )
            self.assertEqual(result["boot_pack_sha256"], "a" * 64)
            self.assertIn("RULE", (home / ".claude" / "CLAUDE.md").read_text())
            self.assertIn("RULE", (home / ".codex" / "AGENTS.md").read_text())
            self.assertTrue((home / ".cursor" / "rules" / "dreameros-boot-canon.mdc").exists())
            self.assertTrue((home / ".agents" / "skills" / "dreameros-boot" / "SKILL.md").exists())


if __name__ == "__main__":
    unittest.main()
