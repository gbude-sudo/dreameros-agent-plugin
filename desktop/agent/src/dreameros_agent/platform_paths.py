"""Cross-platform locations used by the per-user agent."""
from __future__ import annotations

import os
import platform
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class AgentPaths:
    home: Path
    data_dir: Path
    state_file: Path
    backup_dir: Path
    autostart_file: Path


def paths_for(system: str | None = None, *, home: Path | None = None, env: dict[str, str] | None = None) -> AgentPaths:
    env = env or os.environ
    home = home or Path.home()
    family = (system or platform.system()).lower()
    if family == "windows":
        local = Path(env.get("LOCALAPPDATA", home / "AppData" / "Local"))
        roaming = Path(env.get("APPDATA", home / "AppData" / "Roaming"))
        data = local / "DreamerOS" / "Agent"
        auto = roaming / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup" / "DreamerOS Agent.cmd"
    elif family == "darwin":
        data = home / "Library" / "Application Support" / "DreamerOS" / "Agent"
        auto = home / "Library" / "LaunchAgents" / "app.dreameros.agent.plist"
    elif family == "linux":
        data = Path(env.get("XDG_STATE_HOME", home / ".local" / "state")) / "dreameros" / "agent"
        auto = Path(env.get("XDG_CONFIG_HOME", home / ".config")) / "systemd" / "user" / "dreameros-agent.service"
    else:
        raise RuntimeError(f"unsupported desktop platform: {family}")
    return AgentPaths(home, data, data / "state.json", data / "backups", auto)
