"""Vendor-native DreamerOS configuration adapters."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .managed_files import atomic_write, render_owned_block, update_json_entry


MCP_URL = "https://mcp.dreameros.app/mcp/"
CLAUDE_MCP_ENTRY = {
    "command": "npx",
    "args": ["-y", "mcp-remote", MCP_URL],
}
CURSOR_MCP_ENTRY = {"url": MCP_URL}


@dataclass(frozen=True)
class AdapterResult:
    vendor: str
    detected: bool
    changed: bool
    state: str


class JsonMcpAdapter:
    def __init__(self, vendor: str, path: Path, detect_root: Path, entry: dict):
        self.vendor = vendor
        self.path = path
        self.detect_root = detect_root
        self.entry = entry

    def detect(self) -> bool:
        return self.detect_root.exists() or self.path.exists()

    def repair(self, backup_dir: Path) -> AdapterResult:
        if not self.detect():
            return AdapterResult(self.vendor, False, False, "absent")
        changed = update_json_entry(
            self.path,
            "mcpServers",
            "dreameros",
            self.entry,
            backup_dir,
        )
        return AdapterResult(self.vendor, True, changed, "configured")


class CodexAdapter:
    MARKER = "DREAMEROS-MCP"
    PAYLOAD = """[mcp_servers.dreameros]
enabled = true
url = "https://mcp.dreameros.app/mcp/"
required = false
default_tools_approval_mode = "approve\""""

    def __init__(self, path: Path, detect_root: Path):
        self.vendor = "codex"
        self.path = path
        self.detect_root = detect_root

    def detect(self) -> bool:
        return self.detect_root.exists() or self.path.exists()

    def repair(self, backup_dir: Path) -> AdapterResult:
        if not self.detect():
            return AdapterResult(self.vendor, False, False, "absent")
        existing = self.path.read_text(encoding="utf-8-sig") if self.path.exists() else ""
        if "[mcp_servers.dreameros]" in existing and f"# BEGIN {self.MARKER}" not in existing:
            import tomllib

            try:
                parsed = tomllib.loads(existing)
            except tomllib.TOMLDecodeError as exc:
                raise ManagedFileError("refusing malformed Codex TOML") from exc
            current = parsed.get("mcp_servers", {}).get("dreameros", {})
            if current.get("url", "").rstrip("/") == MCP_URL.rstrip("/"):
                return AdapterResult(self.vendor, True, False, "configured")
            raise ManagedFileError("refusing to replace unmanaged Codex DreamerOS entry")
        rendered = render_owned_block(existing, self.PAYLOAD, self.MARKER)
        changed = rendered != existing
        if changed:
            atomic_write(self.path, rendered.encode("utf-8"), backup_dir)
        return AdapterResult(self.vendor, True, changed, "configured")


def default_adapters(home: Path, appdata: Path) -> list:
    return [
        JsonMcpAdapter(
            "claude",
            appdata / "Claude" / "claude_desktop_config.json",
            home / ".claude",
            CLAUDE_MCP_ENTRY,
        ),
        CodexAdapter(home / ".codex" / "config.toml", home / ".codex"),
        JsonMcpAdapter(
            "cursor",
            home / ".cursor" / "mcp.json",
            home / ".cursor",
            CURSOR_MCP_ENTRY,
        ),
    ]
