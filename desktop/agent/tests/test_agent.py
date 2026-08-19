from __future__ import annotations

import base64
import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from dreameros_agent.adapters import CodexAdapter, CURSOR_MCP_ENTRY, JsonMcpAdapter
from dreameros_agent.heartbeat import ClientHeartbeat, build_heartbeat
from dreameros_agent.managed_files import ManagedFileError, render_owned_block
from dreameros_agent.oauth_client import OAuthDiscovery, authorization_url, registration_payload
from dreameros_agent.pkce import challenge_s256, new_state, new_verifier, state_matches
from dreameros_agent.release_manifest import ManifestVerificationError, verify_manifest


class DesktopAgentTests(unittest.TestCase):
    def test_pkce_and_state(self):
        verifier = new_verifier()
        self.assertGreaterEqual(len(verifier), 43)
        self.assertEqual(len(challenge_s256(verifier)), 43)
        state = new_state()
        self.assertTrue(state_matches(state, state))
        self.assertFalse(state_matches(state, state + "x"))

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

    def test_codex_adapter_accepts_matching_unmanaged_entry_without_duplication(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / "config.toml"
            config.write_text(
                '[mcp_servers.dreameros]\nurl = "https://mcp.dreameros.app/mcp"\n',
                encoding="utf-8",
            )
            adapter = CodexAdapter(config, root)
            self.assertFalse(adapter.repair(root / "backups").changed)
            self.assertEqual(config.read_text().count("[mcp_servers.dreameros]"), 1)

    def test_heartbeat_contains_no_local_identity_fields(self):
        payload = build_heartbeat(
            installation_id="test-installation",
            agent_version="0.1.0",
            architecture="x64",
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


if __name__ == "__main__":
    unittest.main()
