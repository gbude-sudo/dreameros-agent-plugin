"""Credential-vault abstraction. Tokens never enter vendor configuration files."""
from __future__ import annotations

import getpass
import platform
import shutil
import subprocess
from typing import Protocol


class TokenVault(Protocol):
    def store(self, name: str, secret: str) -> None: ...
    def read(self, name: str) -> str | None: ...
    def delete(self, name: str) -> None: ...


class WindowsCredentialVault:
    TARGET_PREFIX = "DreamerOS/DesktopAgent/"

    def __init__(self) -> None:
        try:
            import win32cred  # type: ignore
        except ImportError as exc:
            raise RuntimeError("Windows Credential Manager support is unavailable") from exc
        self._api = win32cred

    def store(self, name: str, secret: str) -> None:
        if not secret:
            raise ValueError("refusing to store an empty secret")
        self._api.CredWrite(
            {
                "Type": self._api.CRED_TYPE_GENERIC,
                "TargetName": self.TARGET_PREFIX + name,
                "CredentialBlob": secret,
                "Persist": self._api.CRED_PERSIST_LOCAL_MACHINE,
                "UserName": "DreamerOS",
            },
            0,
        )

    def read(self, name: str) -> str | None:
        try:
            value = self._api.CredRead(
                self.TARGET_PREFIX + name,
                self._api.CRED_TYPE_GENERIC,
                0,
            )
        except Exception:
            return None
        blob = value.get("CredentialBlob")
        return blob.decode("utf-16-le") if isinstance(blob, bytes) else str(blob)

    def delete(self, name: str) -> None:
        try:
            self._api.CredDelete(self.TARGET_PREFIX + name, self._api.CRED_TYPE_GENERIC, 0)
        except Exception:
            return


class MacOSKeychainVault:
    SERVICE_PREFIX = "app.dreameros.desktop-agent."

    def __init__(self, runner=subprocess.run) -> None:
        if not shutil.which("security"):
            raise RuntimeError("macOS Keychain support is unavailable")
        self._run = runner
        self._account = getpass.getuser()

    def store(self, name: str, secret: str) -> None:
        if not secret:
            raise ValueError("refusing to store an empty secret")
        self._run(
            ["security", "add-generic-password", "-U", "-a", self._account, "-s", self.SERVICE_PREFIX + name, "-w"],
            input=secret + "\n",
            text=True,
            check=True,
            capture_output=True,
        )

    def read(self, name: str) -> str | None:
        result = self._run(
            ["security", "find-generic-password", "-a", self._account, "-s", self.SERVICE_PREFIX + name, "-w"],
            check=False,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip() if result.returncode == 0 else None

    def delete(self, name: str) -> None:
        self._run(
            ["security", "delete-generic-password", "-a", self._account, "-s", self.SERVICE_PREFIX + name],
            check=False,
            capture_output=True,
        )


class LinuxSecretServiceVault:
    def __init__(self, runner=subprocess.run) -> None:
        if not shutil.which("secret-tool"):
            raise RuntimeError("Linux Secret Service support is unavailable")
        self._run = runner

    def store(self, name: str, secret: str) -> None:
        if not secret:
            raise ValueError("refusing to store an empty secret")
        self._run(
            ["secret-tool", "store", "--label=DreamerOS Desktop Agent", "service", "dreameros-desktop-agent", "name", name],
            input=secret,
            text=True,
            check=True,
            capture_output=True,
        )

    def read(self, name: str) -> str | None:
        result = self._run(
            ["secret-tool", "lookup", "service", "dreameros-desktop-agent", "name", name],
            text=True,
            check=False,
            capture_output=True,
        )
        return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None

    def delete(self, name: str) -> None:
        self._run(
            ["secret-tool", "clear", "service", "dreameros-desktop-agent", "name", name],
            check=False,
            capture_output=True,
        )


def default_vault(system: str | None = None) -> TokenVault:
    family = (system or platform.system()).lower()
    if family == "windows":
        return WindowsCredentialVault()
    if family == "darwin":
        return MacOSKeychainVault()
    if family == "linux":
        return LinuxSecretServiceVault()
    raise RuntimeError(f"no secure credential vault for platform: {family}")
