"""Long-running repair, proxy, refresh, and heartbeat lifecycle."""
from __future__ import annotations

import hashlib
import os
import platform
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

from . import __version__
from .adapters import default_adapters
from .bootpack import install_bootpack
from .gateway import GatewayClient, GatewayError
from .oauth_client import OAuthClient
from .proxy import serve_proxy
from .state import LocalState
from .trusted_keys import PINNED_RELEASE_KEYS
from .updater import UpdateManager, invoke_installer
from .vault import TokenVault

ALLOWED_REPAIR_ACTIONS = {
    "SEND_HEARTBEAT", "REPORT_ADAPTER_CENSUS", "REPAIR_ADAPTER",
    "REFRESH_BOOT_CONTRACT", "REFRESH_MANIFEST", "REFRESH_BOOT_PACK",
    "WAIT_FOR_BOOT_PACK_REGISTRY",
}


def platform_name(system: str | None = None) -> str:
    return {"windows": "windows", "darwin": "macos", "linux": "linux"}[(system or platform.system()).lower()]


def adapter_observations(adapters, *, proxy_connected: bool = False) -> list[dict]:
    observations = []
    for adapter in adapters:
        detected = adapter.detect()
        configured = False
        digest = None
        if detected and adapter.path.exists():
            content = adapter.path.read_bytes()
            digest = hashlib.sha256(content).hexdigest()
            text = content.decode("utf-8", errors="ignore")
            configured = "http://127.0.0.1:18765/mcp" in text and "Bearer " not in text
        observations.append({
            "vendor": adapter.vendor,
            "detected": detected,
            "config_state": "aligned" if configured else "missing" if not adapter.path.exists() else "drifted",
            "mcp_state": "connected" if configured and proxy_connected else "configured" if configured else "disconnected",
            "managed_artifact_sha256": digest if configured else None,
        })
    return observations


class AgentService:
    def __init__(self, state: LocalState, vault: TokenVault, *, home: Path, appdata: Path | None, backup_dir: Path):
        self.state, self.vault = state, vault
        self.home = home
        self.adapters = default_adapters(home, appdata)
        self.backup_dir = backup_dir
        self.proxy = None
        self.attestation_lock = threading.Lock()

    def repair(self, target: str | None = None) -> bool:
        changed = False
        for adapter in self.adapters:
            if target and adapter.vendor != target:
                continue
            changed = adapter.repair(self.backup_dir).changed or changed
        return changed

    def run(self, *, once: bool = False) -> None:
        local = self.state.load()
        pending_health_check = self._prepare_pending_update(local)
        local = self.state.load()
        installation = local.get("installation_id")
        if not installation:
            raise RuntimeError("desktop installation is not registered; run connect")
        self.repair()
        self.proxy = serve_proxy(
            lambda: self.vault.read("access_token"),
            installation,
            agent_version=__version__,
            on_mcp_success=lambda: self._verify_after_mcp(installation),
            attestation_lock=self.attestation_lock,
        )
        delay = 5.0
        try:
            while True:
                try:
                    self._refresh_if_needed(local)
                    gateway = GatewayClient(self._required_token())
                    if self._maybe_auto_update(gateway, local):
                        return
                    payload = self._heartbeat_payload(proxy_connected=True)
                    with self.attestation_lock:
                        response = gateway.heartbeat(installation, payload)
                    if pending_health_check:
                        UpdateManager(
                            self.state,
                            PINNED_RELEASE_KEYS,
                            self.state.path.parent / "updates",
                        ).finish_or_rollback(True)
                        pending_health_check = False
                    self._apply_actions(gateway, installation, response.get("repair_actions", []))
                    interval = max(30, min(600, int(response.get("heartbeat_interval_seconds", 300))))
                    delay = 5.0
                    if once:
                        return
                    time.sleep(interval)
                except (GatewayError, OSError, RuntimeError, ValueError):
                    if once:
                        raise
                    time.sleep(delay)
                    delay = min(300.0, delay * 2)
        finally:
            if self.proxy:
                self.proxy.shutdown()
                self.proxy.server_close()

    def _required_token(self) -> str:
        token = self.vault.read("access_token")
        if not token:
            raise RuntimeError("DreamerOS sign-in required")
        return token

    def _prepare_pending_update(self, local: dict) -> bool:
        pending = local.get("pending_update")
        if not isinstance(pending, dict):
            return False
        expected = str(pending.get("expected_version") or "")
        if expected and expected == __version__:
            return True
        UpdateManager(
            self.state,
            PINNED_RELEASE_KEYS,
            self.state.path.parent / "updates",
        ).finish_or_rollback(False)
        return False

    def _refresh_if_needed(self, local: dict) -> None:
        try:
            expires = int(self.vault.read("expires_at") or "0")
        except ValueError:
            expires = 0
        if expires > int(time.time()) + 120:
            return
        OAuthClient(local["issuer"], self.vault).refresh(local["token_endpoint"], local["client_id"])

    def _heartbeat_payload(self, *, proxy_connected: bool) -> dict:
        local = self.state.load()
        return {
            "agent_version": __version__,
            "adapters": adapter_observations(self.adapters, proxy_connected=proxy_connected),
            "boot_contract_version": local.get("boot_contract_version", "1.0.0"),
            "manifest_schema_version": local.get("manifest_schema_version", "1.0.0"),
            "boot_pack_version": local.get("boot_pack_version", "unknown"),
            "boot_pack_sha256": local.get("boot_pack_sha256", "0" * 64),
        }

    def _apply_actions(self, gateway: GatewayClient, installation: str, actions: list) -> None:
        for item in actions:
            if not isinstance(item, dict) or item.get("action") not in ALLOWED_REPAIR_ACTIONS:
                continue
            action = item["action"]
            if action == "REPAIR_ADAPTER" and item.get("adapter") in {"claude", "codex", "cursor"}:
                self.repair(item["adapter"])
            elif action == "REFRESH_BOOT_PACK" and PINNED_RELEASE_KEYS:
                values = install_bootpack(
                    gateway.release_metadata(),
                    PINNED_RELEASE_KEYS,
                    home=self.home,
                    staging_dir=self.state.path.parent / "bootpack",
                )
                self.state.update(**values)

    def _verify_after_mcp(self, installation: str) -> None:
        """Verify only after the Gateway recorded this installation's MCP call."""
        last_error = None
        for _ in range(3):
            try:
                result = GatewayClient(self._required_token()).verify(installation)
                if result.get("state") == "RECEIPTED":
                    return
                last_error = GatewayError(
                    str(result.get("receipt_held_back_reason") or "receipt verification held back")
                )
                time.sleep(0.1)
            except GatewayError as exc:
                last_error = exc
                time.sleep(0.1)
        if last_error is not None:
            raise last_error

    def _maybe_auto_update(self, gateway: GatewayClient, local: dict) -> bool:
        enabled = os.environ.get("DREAMEROS_AGENT_AUTO_UPDATE", "").strip().lower()
        if enabled not in {"1", "true", "yes"}:
            return False
        if not PINNED_RELEASE_KEYS or not getattr(sys, "frozen", False):
            return False
        try:
            last = datetime.fromisoformat(str(local.get("last_update_check_at") or ""))
            if (datetime.now(timezone.utc) - last.astimezone(timezone.utc)).total_seconds() < 43_200:
                return False
        except (TypeError, ValueError):
            pass
        checked_at = datetime.now(timezone.utc).isoformat()
        self.state.update(last_update_check_at=checked_at)
        local["last_update_check_at"] = checked_at
        release = gateway.release_metadata()
        version = str(release.get("version") or "")
        if release.get("status") != "available" or not _newer_version(version, __version__):
            return False
        manager = UpdateManager(self.state, PINNED_RELEASE_KEYS, self.state.path.parent / "updates")
        manifest, artifact = manager.fetch_and_stage(release)
        current = Path(sys.executable)
        manager.record_install(manifest, artifact, current)
        if self.proxy:
            self.proxy.shutdown()
            self.proxy.server_close()
            self.proxy = None
        invoke_installer(artifact)
        return True


def _newer_version(candidate: str, current: str) -> bool:
    try:
        left = tuple(int(part) for part in candidate.split("."))
        right = tuple(int(part) for part in current.split("."))
    except ValueError:
        return False
    return left > right
