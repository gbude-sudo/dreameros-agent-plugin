"""Credential-vault abstraction. Tokens never enter vendor configuration files."""
from __future__ import annotations

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
