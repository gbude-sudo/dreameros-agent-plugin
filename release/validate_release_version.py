"""Fail closed unless every release surface names one strict version."""
from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path


STRICT_SEMVER = re.compile(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)")


def validate_release_version(version: str, root: Path) -> None:
    if not STRICT_SEMVER.fullmatch(version):
        raise ValueError("release version must be strict SemVer")
    package = tomllib.loads(
        (root / "desktop/agent/pyproject.toml").read_text(encoding="utf-8")
    )["project"]["version"]
    runtime_match = re.search(
        r'__version__ = "([^"]+)"',
        (root / "desktop/agent/src/dreameros_agent/__init__.py").read_text(encoding="utf-8"),
    )
    installer_match = re.search(
        r'#define AppVersion "([^"]+)"',
        (root / "release/windows/installer.iss").read_text(encoding="utf-8"),
    )
    if runtime_match is None or installer_match is None:
        raise ValueError("release version source is unreadable")
    values = {package, runtime_match.group(1), installer_match.group(1)}
    if values != {version}:
        raise ValueError(
            f"version mismatch: input={version} package={package} "
            f"runtime={runtime_match.group(1)} installer={installer_match.group(1)}"
        )


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate_release_version.py VERSION")
    try:
        validate_release_version(sys.argv[1], Path(__file__).resolve().parents[1])
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(f"RELEASE_VERSION_OK={sys.argv[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
