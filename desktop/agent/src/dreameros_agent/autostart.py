"""Per-user autostart rendering for Windows, macOS, and Linux."""
from __future__ import annotations

import html
import shlex
import subprocess
from pathlib import Path

from .managed_files import atomic_write
from .platform_paths import AgentPaths


def render_autostart(system: str, executable: Path) -> str:
    family = system.lower()
    executable = executable.resolve()
    if family == "windows":
        return f'@echo off\r\nstart "" "{executable}" run\r\n'
    if family == "darwin":
        value = html.escape(str(executable))
        return f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>app.dreameros.agent</string>
<key>ProgramArguments</key><array><string>{value}</string><string>run</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
</dict></plist>
'''
    if family == "linux":
        command = shlex.quote(str(executable))
        return f'''[Unit]
Description=DreamerOS Desktop Agent
After=network-online.target

[Service]
Type=simple
ExecStart={command} run
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
'''
    raise RuntimeError(f"unsupported autostart platform: {family}")


def install_autostart(paths: AgentPaths, system: str, executable: Path, *, runner=subprocess.run) -> Path:
    content = render_autostart(system, executable).encode("utf-8")
    atomic_write(paths.autostart_file, content, paths.backup_dir)
    if system.lower() == "linux":
        runner(["systemctl", "--user", "daemon-reload"], check=True, capture_output=True)
        runner(["systemctl", "--user", "enable", "--now", "dreameros-agent.service"], check=True, capture_output=True)
    elif system.lower() == "darwin":
        runner(["launchctl", "bootstrap", f"gui/{__import__('os').getuid()}", str(paths.autostart_file)], check=False, capture_output=True)
    return paths.autostart_file
