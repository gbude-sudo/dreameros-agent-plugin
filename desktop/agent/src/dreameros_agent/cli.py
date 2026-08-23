"""DreamerOS Desktop Agent command line."""
from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import time
import webbrowser
from pathlib import Path

import httpx

from . import __version__
from .adapters import default_adapters
from .autostart import install_autostart
from .bootpack import install_bootpack
from .gateway import GatewayClient
from .managed_files import ManagedFileError
from .oauth_client import OAuthClient, OAuthError
from .platform_paths import paths_for
from .runtime import AgentService, adapter_observations, platform_name
from .state import LocalState
from .updater import UpdateManager, invoke_installer
from .trusted_keys import PINNED_RELEASE_KEYS
from .vault import default_vault

ISSUER = "https://mcp.dreameros.app"


def _context(args):
    system = getattr(args, "system", None) or platform.system()
    home = Path(args.home or Path.home())
    env = dict(os.environ)
    if args.appdata:
        env["APPDATA"] = args.appdata
    paths = paths_for(system, home=home, env=env)
    if args.backup_dir:
        paths = type(paths)(paths.home, paths.data_dir, paths.state_file, Path(args.backup_dir), paths.autostart_file)
    appdata = Path(args.appdata or env.get("APPDATA", home / "AppData" / "Roaming")) if system.lower() == "windows" else None
    return system, paths, appdata, LocalState(paths.state_file)


def _json(value: dict) -> None:
    print(json.dumps(value, separators=(",", ":"), sort_keys=True))


def command_status(args) -> int:
    system, paths, appdata, state = _context(args)
    clients = adapter_observations(default_adapters(paths.home, appdata, system=system))
    proxy = False
    try:
        proxy = httpx.get("http://127.0.0.1:18765/health", timeout=0.5).status_code == 200
    except httpx.HTTPError:
        pass
    local = state.load()
    _json({"agent_version": __version__, "installed": paths.autostart_file.exists(), "connected": bool(local.get("installation_id")), "proxy_healthy": proxy, "clients": clients})
    return 0


def command_repair(args) -> int:
    system, paths, appdata, state = _context(args)
    try:
        changed = AgentService(state, default_vault(system), home=paths.home, appdata=appdata, backup_dir=paths.backup_dir).repair()
    except (ManagedFileError, RuntimeError) as exc:
        _json({"status": "refused", "error": str(exc)})
        return 2
    _json({"status": "ok", "changed": changed})
    return 0


def command_connect(args) -> int:
    system, paths, appdata, state = _context(args)
    vault = default_vault(system)
    oauth = OAuthClient(ISSUER, vault)
    try:
        client_id, _tokens = oauth.connect(timeout=args.timeout)
        discovery = oauth.discover()
        adapters = default_adapters(paths.home, appdata, system=system)
        service = AgentService(state, vault, home=paths.home, appdata=appdata, backup_dir=paths.backup_dir)
        service.repair()
        gateway = GatewayClient(vault.read("access_token") or "")
        installation = gateway.register_installation(
            client_id=client_id,
            platform=platform_name(system),
            version=__version__,
            adapters=adapter_observations(adapters),
        )
        installation_id = installation["installation_id"]
        bootpack = {}
        release = gateway.release_metadata()
        if PINNED_RELEASE_KEYS and release.get("status") == "available":
            bootpack = install_bootpack(
                release,
                PINNED_RELEASE_KEYS,
                home=paths.home,
                staging_dir=paths.data_dir / "bootpack",
            )
        elif getattr(sys, "frozen", False):
            raise RuntimeError("The signed DreamerOS boot package is unavailable")
        state.update(
            installation_id=installation_id,
            client_id=client_id,
            version=__version__,
            platform=platform_name(system),
            issuer=discovery.issuer,
            token_endpoint=discovery.token_endpoint,
            boot_contract_version="1.0.0",
            manifest_schema_version="1.0.0",
            **bootpack,
        )
        webbrowser.open(f"https://app.dreameros.app/connect/desktop?installation={installation_id}")
    except (OAuthError, RuntimeError, ManagedFileError, KeyError) as exc:
        _json({"status": "refused", "error": str(exc)})
        return 2
    _json({"status": "connected", "installation_id": installation_id})
    return 0


def command_install(args) -> int:
    system, paths, _appdata, _state = _context(args)
    executable = Path(shutil.which("dreameros-agent") or sys.executable)
    install_autostart(paths, system, executable)
    vault = default_vault(system)
    result = command_connect(args) if not vault.read("access_token") else command_repair(args)
    if result == 0 and system.lower() == "windows":
        subprocess.Popen(
            [str(executable), "run"],
            close_fds=True,
            creationflags=subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP,
        )
    return result


def command_run(args) -> int:
    system, paths, appdata, state = _context(args)
    AgentService(state, default_vault(system), home=paths.home, appdata=appdata, backup_dir=paths.backup_dir).run(once=args.once)
    return 0


def command_update(args) -> int:
    system, paths, _appdata, state = _context(args)
    token = default_vault(system).read("access_token")
    if not token:
        raise RuntimeError("DreamerOS sign-in required")
    release = GatewayClient(token).release_metadata()
    keys = PINNED_RELEASE_KEYS
    if args.trusted_keys:
        keys = json.loads(Path(args.trusted_keys).read_text(encoding="utf-8"))["pinned_keys"]
    if not keys:
        raise RuntimeError("No trusted stable release key is installed")
    manager = UpdateManager(state, keys, paths.data_dir / "updates")
    manifest, artifact = manager.fetch_and_stage(release, system=system)
    current = Path(sys.executable) if getattr(sys, "frozen", False) else None
    manager.record_install(manifest, artifact, current)
    invoke_installer(artifact, system=system)
    healthy = False
    for _ in range(30):
        try:
            health = httpx.get("http://127.0.0.1:18765/health", timeout=1)
            healthy = health.status_code == 200 and health.json().get("agent_version") == manifest["agent"]["version"]
        except httpx.HTTPError:
            pass
        if healthy:
            break
        time.sleep(1)
    manager.finish_or_rollback(healthy, current)
    _json({"status": "updated" if healthy else "rolled_back", "release_id": manifest["release_id"]})
    return 0 if healthy else 3


def command_rollback(args) -> int:
    system, paths, _appdata, state = _context(args)
    current = Path(sys.executable) if getattr(sys, "frozen", False) else None
    UpdateManager(state, {}, paths.data_dir / "updates").finish_or_rollback(False, current)
    _json({"status": "rolled_back"})
    return 0


def command_sign_out(args) -> int:
    system, _paths, _appdata, state = _context(args)
    vault = default_vault(system)
    local = state.load()
    token = vault.read("access_token")
    if token and local.get("installation_id"):
        try:
            GatewayClient(token).revoke(local["installation_id"])
        except Exception:
            pass
    for name in ("access_token", "refresh_token", "expires_at"):
        vault.delete(name)
    _json({"status": "signed_out"})
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="dreameros-agent")
    parser.add_argument("--home")
    parser.add_argument("--appdata")
    parser.add_argument("--backup-dir")
    parser.add_argument("--system", choices=("Windows", "Darwin", "Linux"), help=argparse.SUPPRESS)
    commands = parser.add_subparsers(dest="command", required=True)
    for name, handler in (("status", command_status), ("repair", command_repair), ("rollback", command_rollback), ("sign-out", command_sign_out)):
        commands.add_parser(name).set_defaults(handler=handler)
    connect = commands.add_parser("connect")
    connect.add_argument("--timeout", type=float, default=180.0)
    connect.set_defaults(handler=command_connect)
    install = commands.add_parser("install")
    install.add_argument("--timeout", type=float, default=180.0)
    install.set_defaults(handler=command_install)
    run = commands.add_parser("run")
    run.add_argument("--once", action="store_true")
    run.set_defaults(handler=command_run)
    update = commands.add_parser("update")
    update.add_argument("--trusted-keys")
    update.set_defaults(handler=command_update)
    args = parser.parse_args(argv)
    try:
        return args.handler(args)
    except (RuntimeError, ValueError, OSError) as exc:
        _json({"status": "error", "error": str(exc)})
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
