"""Vendor-native DreamerOS configuration adapters."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .managed_files import ManagedFileError, atomic_write, render_owned_block, update_json_entry


LOCAL_MCP_URL = "http://127.0.0.1:18765/mcp"
MCP_URL = LOCAL_MCP_URL
CLAUDE_MCP_ENTRY = {"url": LOCAL_MCP_URL}
CURSOR_MCP_ENTRY = {"url": LOCAL_MCP_URL}
LEGACY_REMOTE_ENTRIES = (
    {"url": "https://mcp.dreameros.app/mcp"},
    {"url": "https://mcp.dreameros.app/mcp/"},
    {"command": "npx", "args": ["-y", "mcp-remote", "https://mcp.dreameros.app/mcp/"]},
)


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
            replace_values=LEGACY_REMOTE_ENTRIES,
        )
        return AdapterResult(self.vendor, True, changed, "configured")


class CodexAdapter:
    MARKER = "DREAMEROS-MCP"
    PAYLOAD = f"""[mcp_servers.dreameros]
enabled = true
url = "{LOCAL_MCP_URL}"
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
            current_url = current.get("url", "").rstrip("/")
            if current_url == LOCAL_MCP_URL.rstrip("/"):
                return AdapterResult(self.vendor, True, False, "configured")
            if current_url == "https://mcp.dreameros.app/mcp":
                start = existing.index("[mcp_servers.dreameros]")
                # The legacy stanza is owned by DreamerOS but unmarked. Replace only
                # its known keys and preserve all other TOML bytes.
                lines = existing.splitlines(keepends=True)
                output, in_block = [], False
                for line in lines:
                    stripped = line.strip()
                    if stripped == "[mcp_servers.dreameros]":
                        in_block = True
                        output.extend((f"# BEGIN {self.MARKER}\n", self.PAYLOAD.rstrip() + "\n", f"# END {self.MARKER}\n"))
                        continue
                    if in_block and stripped.startswith("["):
                        in_block = False
                    if not in_block:
                        output.append(line)
                rendered = "".join(output)
                atomic_write(self.path, rendered.encode("utf-8"), backup_dir)
                return AdapterResult(self.vendor, True, True, "configured")
            raise ManagedFileError("refusing to replace unmanaged Codex DreamerOS entry")
        rendered = render_owned_block(existing, self.PAYLOAD, self.MARKER)
        changed = rendered != existing
        if changed:
            atomic_write(self.path, rendered.encode("utf-8"), backup_dir)
        return AdapterResult(self.vendor, True, changed, "configured")


def default_adapters(home: Path, appdata: Path | None = None, *, system: str | None = None) -> list:
    import platform

    family = (system or platform.system()).lower()
    if family == "windows":
        claude_path = (appdata or home / "AppData" / "Roaming") / "Claude" / "claude_desktop_config.json"
    elif family == "darwin":
        claude_path = home / "Library" / "Application Support" / "Claude" / "claude_desktop_config.json"
    else:
        claude_path = home / ".config" / "Claude" / "claude_desktop_config.json"
    return [
        JsonMcpAdapter(
            "claude",
            claude_path,
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
