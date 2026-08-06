"""Offline conformance check for this Agent Plugins v1.0 package.

Checks the parts of the spec that do not need network access: manifest
shape, plugin name rules, MCP config shape, skill discovery layout and
frontmatter, plus two house rules (no long dashes, no embedded secrets).
Exit 0 = pass, 1 = fail, with one line per finding.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAILS: list[str] = []

NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9]|[-.](?=[a-z0-9])){0,62}[a-z0-9]$|^[a-z0-9]$")
SECRET_RE = re.compile(
    r"(dros_[A-Za-z0-9]{8,}|sk-[A-Za-z0-9_-]{20,}|Bearer\s+[A-Za-z0-9._-]{20,}"
    r"|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)"
)


def fail(msg: str) -> None:
    FAILS.append(msg)


def check_plugin_json() -> None:
    p = ROOT / "plugin.json"
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        fail(f"plugin.json: unreadable or invalid JSON ({e})")
        return
    if data.get("$schema") != "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json":
        fail("plugin.json: $schema is not the 1.0.0 plugin schema URL")
    name = data.get("name", "")
    if not isinstance(name, str) or not NAME_RE.match(name):
        fail(f"plugin.json: name {name!r} violates naming rules")
    if ".." in name or "--" in name:
        fail("plugin.json: name contains consecutive periods or hyphens")


def check_mcp_json() -> None:
    p = ROOT / "mcp.json"
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        fail(f"mcp.json: unreadable or invalid JSON ({e})")
        return
    if data.get("$schema") != "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json":
        fail("mcp.json: $schema is not the 1.0.0 mcp schema URL")
    servers = data.get("mcpServers")
    if not isinstance(servers, dict):
        fail("mcp.json: mcpServers missing or not an object")
        return
    if set(data.keys()) - {"$schema", "mcpServers"}:
        fail("mcp.json: unexpected top-level fields present")
    for sname, server in servers.items():
        stype = server.get("type")
        if stype == "streamable-http":
            url = server.get("url", "")
            if not url.startswith("https://"):
                fail(f"mcp.json[{sname}]: non-HTTPS url for remote server")
            if "@" in url.split("//", 1)[-1].split("/", 1)[0]:
                fail(f"mcp.json[{sname}]: url must not carry user info")
            for hk, hv in (server.get("headers") or {}).items():
                if SECRET_RE.search(f"{hk} {hv}"):
                    fail(f"mcp.json[{sname}]: header looks like a credential")
        elif stype == "stdio":
            if not server.get("command"):
                fail(f"mcp.json[{sname}]: stdio server missing command")
        elif stype == "sse":
            pass
        else:
            fail(f"mcp.json[{sname}]: unknown transport type {stype!r}")


def check_skills() -> None:
    skills_dir = ROOT / "skills"
    if not skills_dir.is_dir():
        fail("skills/: directory missing")
        return
    found = 0
    for sub in sorted(skills_dir.iterdir()):
        if not sub.is_dir():
            continue
        md = sub / "SKILL.md"
        if not md.is_file():
            fail(f"skills/{sub.name}: no SKILL.md (will not be discovered)")
            continue
        found += 1
        text = md.read_text(encoding="utf-8")
        m = re.match(r"^---\n(.*?)\n---\n", text, re.DOTALL)
        if not m:
            fail(f"skills/{sub.name}: SKILL.md missing YAML frontmatter block")
            continue
        fm = m.group(1)
        for field in ("name:", "description:"):
            if field not in fm:
                fail(f"skills/{sub.name}: frontmatter missing {field[:-1]}")
        declared = re.search(r"^name:\s*(\S+)", fm, re.MULTILINE)
        if declared and declared.group(1) != sub.name:
            fail(
                f"skills/{sub.name}: frontmatter name "
                f"{declared.group(1)!r} does not match folder name"
            )
    if found == 0:
        fail("skills/: no discoverable skills")


def check_house_rules() -> None:
    for p in ROOT.rglob("*"):
        if not p.is_file() or ".git" in p.parts:
            continue
        try:
            text = p.read_text(encoding="utf-8")
        except (UnicodeDecodeError, PermissionError):
            continue
        rel = p.relative_to(ROOT)
        em = sum(1 for c in text if ord(c) == 0x2014)
        en = sum(1 for c in text if ord(c) == 0x2013)
        if em or en:
            fail(f"{rel}: contains long dashes (em={em} en={en})")
        if SECRET_RE.search(text) and p.name != "validate.py":
            fail(f"{rel}: contains what looks like a credential")


def main() -> int:
    check_plugin_json()
    check_mcp_json()
    check_skills()
    check_house_rules()
    if FAILS:
        for f in FAILS:
            print(f"FAIL {f}")
        return 1
    print("PASS all conformance checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
