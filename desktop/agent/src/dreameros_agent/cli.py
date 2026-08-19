"""DreamerOS Desktop Agent command line."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from . import __version__
from .adapters import default_adapters
from .managed_files import ManagedFileError
from .vault import WindowsCredentialVault


def _paths(args) -> tuple[Path, Path, Path]:
    home = Path(args.home or Path.home())
    appdata = Path(args.appdata or os.environ.get("APPDATA", home / "AppData" / "Roaming"))
    backup = Path(args.backup_dir or home / ".dreameros" / "backups")
    return home, appdata, backup


def command_status(args) -> int:
    home, appdata, _ = _paths(args)
    states = [
        {"vendor": adapter.vendor, "detected": adapter.detect()}
        for adapter in default_adapters(home, appdata)
    ]
    print(json.dumps({"agent_version": __version__, "clients": states}, separators=(",", ":")))
    return 0


def command_repair(args) -> int:
    home, appdata, backup = _paths(args)
    results = []
    try:
        for adapter in default_adapters(home, appdata):
            results.append(adapter.repair(backup).__dict__)
    except ManagedFileError as exc:
        print(json.dumps({"status": "refused", "error": str(exc)}, separators=(",", ":")))
        return 2
    print(json.dumps({"status": "ok", "clients": results}, separators=(",", ":")))
    return 0


def command_sign_out(_args) -> int:
    vault = WindowsCredentialVault()
    vault.delete("access_token")
    vault.delete("refresh_token")
    print('{"status":"signed_out"}')
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="dreameros-agent")
    parser.add_argument("--home")
    parser.add_argument("--appdata")
    parser.add_argument("--backup-dir")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status").set_defaults(handler=command_status)
    commands.add_parser("repair").set_defaults(handler=command_repair)
    commands.add_parser("sign-out").set_defaults(handler=command_sign_out)
    args = parser.parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
