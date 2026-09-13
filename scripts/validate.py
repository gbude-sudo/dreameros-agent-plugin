"""Offline conformance check for this Agent Plugins v1.0 package.

Checks the parts of the spec that do not need network access: manifest
shape, plugin name rules, MCP config shape, skill discovery layout and
frontmatter, plus two house rules (no long dashes, no embedded secrets).
Exit 0 = pass, 1 = fail, with one line per finding.
"""
from __future__ import annotations

import concurrent.futures
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAILS: list[str] = []
CURSOR_HOOK_CASE_FLOOR = 219

NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9]|[-.](?=[a-z0-9])){0,62}[a-z0-9]$|^[a-z0-9]$")
SECRET_RE = re.compile(
    r"(dros_[A-Za-z0-9]{8,}|sk-[A-Za-z0-9_-]{20,}|Bearer\s+[A-Za-z0-9._-]{20,}"
    r"|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)"
)
CLAUDE_BOOTSTRAP_TOOLS = frozenset(
    {
        "mcp__dreameros__dreameros_session_package",
        "mcp__dreameros__dreameros_session_handoff_read",
        "mcp__dreameros__dreameros_context",
        "mcp__dreameros__dreameros_recall",
        "mcp__dreameros__dreameros_canon",
    }
)
CLAUDE_AGENT_NON_MCP_TOOLS = {
    "canon-citer.md": frozenset(),
    "citation-verifier.md": frozenset({"Read", "Grep", "Glob", "Bash"}),
    "contract-differ.md": frozenset({"Read", "Grep", "Glob", "Bash"}),
    "count-verifier.md": frozenset({"Bash", "Grep", "Read"}),
    "dreameros-operator.md": frozenset({"Bash", "Read", "Glob", "Grep"}),
    "file-locator.md": frozenset({"Glob", "Bash", "Read"}),
    "governance-node.md": frozenset({"Read", "Grep", "Glob", "Bash"}),
    "grep-scout.md": frozenset({"Grep", "Glob", "Read"}),
    "mind-eye-auditor.md": frozenset({"Bash", "Read"}),
    "open-loop-auditor.md": frozenset({"Read", "Grep", "Glob", "Bash"}),
    "plain-language-auditor.md": frozenset({"Read", "Grep", "Glob"}),
    "probe-runner.md": frozenset({"Bash", "Read"}),
    "queue-checker.md": frozenset({"Bash", "Read"}),
    "web-operator.md": frozenset({"Bash", "Read", "Glob", "Grep"}),
    "wolverine.md": frozenset({"Bash", "Read", "Edit", "Grep", "Glob"}),
}
CLAUDE_AGENT_ROLE_MCP_TOOLS = {
    "governance-node.md": frozenset({"mcp__dreameros__dreameros_verify"}),
    "dreameros-operator.md": frozenset(
        {
            "mcp__dreameros__dreameros_manifest",
            "mcp__dreameros__dreameros_memory_full",
            "mcp__dreameros__dreameros_route",
            "mcp__dreameros__dreameros_chat",
            "mcp__dreameros__dreameros_verify",
            "mcp__dreameros__dreameros_govern",
            "mcp__dreameros__dreameros_railway",
            "mcp__dreameros__dreameros_remember",
            "mcp__dreameros__dreameros_get_receipt",
        }
    ),
    "web-operator.md": frozenset(
        {
            "mcp__dreameros__dreameros_remember",
            "mcp__dreameros__dreameros_verify",
            "mcp__dreameros__dreameros_govern",
            "mcp__dreameros__dreameros_get_receipt",
        }
    ),
}
PORTABLE_DREAMEROS_TOOL_RE = re.compile(r"^mcp__dreameros__dreameros_[a-z0-9_]+$")
UUID_MCP_ALIAS_RE = re.compile(r"mcp__[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}__", re.IGNORECASE)
LIVE_MCP_ALIAS_RE = re.compile(r"mcp__DreamerOS_Live__", re.IGNORECASE)


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


def check_boot_source_floor() -> None:
    source = ROOT / "bootpack" / "SOURCE-dreameros-boot-canon.md"
    floor_path = ROOT / "bootpack" / "known-good-source-floor.json"
    try:
        text = source.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
        floor = json.loads(floor_path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail(f"bootpack source floor: unreadable ({exc})")
        return

    match = re.search(r"^# DreamerOS Boot Canon v(\d+\.\d+\.\d+)\s*$", text, re.MULTILINE)
    if not match:
        fail("bootpack source: semantic version heading missing")
        return
    version = tuple(int(part) for part in match.group(1).split("."))
    minimum = tuple(int(part) for part in str(floor.get("minimum_version", "0.0.0")).split("."))
    if version < minimum:
        fail(f"bootpack source: version {match.group(1)} is below floor {floor.get('minimum_version')}")

    source_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()
    if source_hash != floor.get("semantic_sha256"):
        fail("bootpack source: semantic hash differs from reviewed floor")
    for clause in floor.get("required_clauses", []):
        if clause not in text:
            fail(f"bootpack source: required clause missing: {clause}")

    external_value = os.environ.get("DREAMEROS_BOOT_CANON_FLOOR", "").strip()
    external = Path(external_value).expanduser() if external_value else None
    if external is not None and external.is_file() and external.resolve() != source.resolve():
        external_text = external.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
        if hashlib.sha256(external_text.encode("utf-8")).hexdigest() != source_hash:
            fail(f"bootpack source: differs from external current floor {external}")


def check_quote_evidence() -> None:
    source_path = ROOT / "bootpack" / "evidence" / "HC_ATTRIBUTED_QUOTES_v1_0_0.md"
    generated_path = ROOT / "bootpack" / "out" / "evidence" / "HC_ATTRIBUTED_QUOTES_v1_0_0.md"
    floor_path = ROOT / "bootpack" / "known-good-hc-quotes.json"
    boot_source_path = ROOT / "bootpack" / "SOURCE-dreameros-boot-canon.md"
    try:
        text = source_path.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
        floor = json.loads(floor_path.read_text(encoding="utf-8"))
        boot_source = boot_source_path.read_text(encoding="utf-8")
    except Exception as exc:
        fail(f"quote evidence: unreadable ({exc})")
        return

    semantic_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()
    if semantic_hash != floor.get("semantic_sha256"):
        fail("quote evidence: semantic file hash differs from reviewed floor")
    pattern = re.compile(r'HC (?:verbatim|directive|asked)[^:\r\n]*:\s*"[^"]*"', re.DOTALL)
    quotes = sorted({re.sub(r"\s+", " ", match.group(0)).strip() for match in pattern.finditer(text)})
    quote_hashes = {hashlib.sha256(quote.encode("utf-8")).hexdigest() for quote in quotes}
    expected_hashes = set(floor.get("quote_sha256", []))
    expected_count = int(floor.get("unique_quote_count", 0))
    if len(quotes) != expected_count or quote_hashes != expected_hashes:
        fail("quote evidence: unique quote hash set differs from reviewed floor")
    if expected_count != 16:
        fail("quote evidence: reviewed unique quote count must remain 16")
    if generated_path.is_file():
        generated = generated_path.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
        if generated != text:
            fail("quote evidence: generated plugin copy differs from source evidence")
    else:
        fail("quote evidence: generated plugin copy missing")
    for required_path in (
        "bootpack/out/evidence/HC_ATTRIBUTED_QUOTES_v1_0_0.md",
        "~/.agents/evidence/dreameros/HC_ATTRIBUTED_QUOTES_v1_0_0.md",
    ):
        if required_path not in boot_source:
            fail(f"quote evidence: boot source does not name reachable carrier path {required_path}")
    if "CLAUDE.md.backup-2026-08-26-preconsolidation" in boot_source and "~/.claude/backups/" not in boot_source:
        fail("quote evidence: boot source cites the old nonexistent backup path")

    manifest_path = ROOT / "bootpack" / "out" / "manifest" / "dreameros-boot-canon.json"
    try:
        metadata = json.loads(manifest_path.read_text(encoding="utf-8")).get("evidence", {})
    except Exception as exc:
        fail(f"quote evidence: generated manifest unreadable ({exc})")
        return
    if metadata.get("hc_attributed_quotes") != "evidence/HC_ATTRIBUTED_QUOTES_v1_0_0.md":
        fail("quote evidence: generated manifest path mismatch")
    if metadata.get("unique_quote_count") != 16:
        fail("quote evidence: generated manifest count mismatch")


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


def check_model_tiered_offload_mirror() -> None:
    source = ROOT / "skills" / "model-tiered-offload"
    packaged = ROOT / "install" / "claude-code" / "payload" / "skills" / "model-tiered-offload"
    expected = {"SKILL.md", "references/kimi-fireworks-claude.md"}

    for label, root in (("canonical", source), ("Claude package", packaged)):
        if not root.is_dir():
            fail(f"model-tiered-offload {label}: directory missing")
            continue
        inventory = {
            path.relative_to(root).as_posix()
            for path in root.rglob("*")
            if path.is_file()
        }
        if inventory != expected:
            fail(f"model-tiered-offload {label}: file inventory differs from reviewed source map")

    if not source.is_dir() or not packaged.is_dir():
        return
    for relative in sorted(expected):
        try:
            source_text = (source / relative).read_text(encoding="utf-8")
            packaged_text = (packaged / relative).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            fail(f"model-tiered-offload mirror: unreadable {relative} ({exc})")
            continue
        source_canonical = source_text.replace("\r\n", "\n").replace("\r", "\n")
        packaged_canonical = packaged_text.replace("\r\n", "\n").replace("\r", "\n")
        if source_canonical != packaged_canonical:
            fail(f"model-tiered-offload mirror: {relative} content differs from canonical source")

    try:
        entrypoint = (source / "SKILL.md").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"model-tiered-offload canonical entrypoint: unreadable ({exc})")
        return
    if "references/kimi-fireworks-claude.md" not in entrypoint:
        fail("model-tiered-offload canonical entrypoint: provider reference is not discoverable")


def check_life_of_intent_skill_mirrors() -> None:
    source = ROOT / "skills" / "dreameros-life-of-intent" / "SKILL.md"
    mirrors = (
        ROOT / "install" / "claude-code" / "payload" / "skills" / "dreameros-life-of-intent" / "SKILL.md",
        ROOT / "install" / "codex" / "payload" / "skills" / "dreameros-life-of-intent" / "SKILL.md",
    )
    try:
        source_bytes = source.read_bytes()
    except OSError as exc:
        fail(f"dreameros-life-of-intent canonical skill: unreadable ({exc})")
        return
    for mirror in mirrors:
        try:
            if mirror.read_bytes() != source_bytes:
                fail(f"dreameros-life-of-intent mirror: byte drift in {mirror.relative_to(ROOT)}")
        except OSError as exc:
            fail(f"dreameros-life-of-intent mirror: unreadable {mirror.relative_to(ROOT)} ({exc})")

    expected_vocabulary = "`CONFIGURED`, `INVOKED`, `UNSUPPORTED`, `OFFLINE`, and `TERMINAL`"
    for path in (ROOT / "README.md", source, *mirrors):
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            fail(f"Gateway Lockstep vocabulary: unreadable {path.relative_to(ROOT)} ({exc})")
            continue
        if expected_vocabulary not in text or "`RECEIPTED`" in text:
            fail(f"Gateway Lockstep vocabulary: emitted-status set drifted in {path.relative_to(ROOT)}")


def _frontmatter(path: Path) -> str | None:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"{path.relative_to(ROOT)}: unreadable ({exc})")
        return None
    match = re.match(r"^---\n(.*?)\n---\n", text, re.DOTALL)
    if not match:
        fail(f"{path.relative_to(ROOT)}: missing YAML frontmatter block")
        return None
    return match.group(1)


def check_claude_payload_agents() -> None:
    """Statically validate every installed Claude agent before a loader sees it."""
    attributes_path = ROOT / ".gitattributes"
    try:
        attributes = attributes_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"Claude payload SessionStart hook: .gitattributes unreadable ({exc})")
        attributes = ""
    if not re.search(r"(?m)^install/claude-code/payload/hooks/\*\.sh\s+text\s+eol=lf\s*$", attributes):
        fail("Claude payload SessionStart hook: installed Bash payload is not pinned to LF")

    agents_dir = ROOT / "install" / "claude-code" / "payload" / "agents"
    if not agents_dir.is_dir():
        fail("Claude payload agents: directory missing")
        return

    paths = sorted(agents_dir.glob("*.md"))
    expected_names = set(CLAUDE_AGENT_NON_MCP_TOOLS)
    actual_names = {path.name for path in paths}
    if actual_names != expected_names:
        fail("Claude payload agents: filename inventory differs from the reviewed role map")

    unconditional = "`dreameros_session_package` is the only unconditional boot call. Call it first."
    conditional = "When the package directs it or the assigned task needs read-only enrichment,"
    enrichment = (
        "1. Call `dreameros_session_handoff_read` for the full record when present.",
        "2. Call `dreameros_context`. Use its SCS as the read-only current-state channel.",
        "3. Call scoped `dreameros_recall`.",
        "4. Call `dreameros_canon` when the task needs it.",
    )

    for path in paths:
        relative = path.relative_to(ROOT)
        frontmatter = _frontmatter(path)
        if frontmatter is None:
            continue
        try:
            text = path.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
        except (OSError, UnicodeDecodeError) as exc:
            fail(f"{relative}: unreadable ({exc})")
            continue

        fields = set(re.findall(r"(?m)^([A-Za-z][A-Za-z0-9_-]*):", frontmatter))
        allowed_fields = {"name", "description", "tools", "model", "isolation"}
        unexpected = fields - allowed_fields
        if unexpected:
            fail(f"{relative}: unsupported frontmatter field(s): {', '.join(sorted(unexpected))}")

        name_match = re.search(r"(?m)^name:\s*([^\s]+)\s*$", frontmatter)
        if name_match is None or name_match.group(1) != path.stem:
            fail(f"{relative}: frontmatter name does not match filename")
        if not re.search(r"(?m)^description:\s*\S", frontmatter):
            fail(f"{relative}: frontmatter description missing")

        tools_match = re.search(r"(?m)^tools:\s*\[([^\]\r\n]*)\]\s*$", frontmatter)
        if tools_match is None:
            fail(f"{relative}: tools must be one inline list")
            continue
        tools = [item.strip() for item in tools_match.group(1).split(",") if item.strip()]
        if not tools or len(tools) != len(set(tools)):
            fail(f"{relative}: tools list is empty or contains duplicates")
            continue

        mcp_tools = {tool for tool in tools if tool.startswith("mcp__")}
        non_mcp_tools = set(tools) - mcp_tools
        expected_mcp = CLAUDE_BOOTSTRAP_TOOLS | CLAUDE_AGENT_ROLE_MCP_TOOLS.get(path.name, frozenset())
        if mcp_tools != expected_mcp:
            fail(f"{relative}: MCP tool set differs from the reviewed portable role map")
        if non_mcp_tools != CLAUDE_AGENT_NON_MCP_TOOLS.get(path.name, frozenset()):
            fail(f"{relative}: non-MCP tool set differs from the reviewed role map")
        for tool in mcp_tools:
            if not PORTABLE_DREAMEROS_TOOL_RE.fullmatch(tool):
                fail(f"{relative}: nonportable DreamerOS MCP tool id: {tool}")

        if UUID_MCP_ALIAS_RE.search(text):
            fail(f"{relative}: UUID-shaped MCP alias is forbidden")
        if LIVE_MCP_ALIAS_RE.search(text):
            fail(f"{relative}: DreamerOS_Live MCP alias is forbidden")
        if "dreameros_state" in text:
            fail(f"{relative}: mixed state tool must not appear in a generic agent")
        if "PARTIALLY CONNECTED" in text:
            fail(f"{relative}: absent mixed state tool must not degrade connectivity")
        if text.count("DREAMEROS-READ-ONLY-BOOTSTRAP v1.1.0") != 1:
            fail(f"{relative}: bootstrap marker missing or duplicated")
        if text.count(unconditional) != 1:
            fail(f"{relative}: unconditional package contract missing or duplicated")
        if text.count(conditional) != 1:
            fail(f"{relative}: conditional enrichment contract missing or duplicated")
        ordered = (unconditional, conditional, *enrichment)
        positions = [text.find(item) for item in ordered]
        if any(position < 0 for position in positions) or positions != sorted(positions):
            fail(f"{relative}: unconditional package and conditional enrichment order drifted")

    settings_path = ROOT / "install" / "claude-code" / "payload" / "settings.fragment.json"
    generated_hook = ROOT / "bootpack" / "out" / "claude" / "dreameros-session-start.sh"
    payload_hook = ROOT / "install" / "claude-code" / "payload" / "hooks" / "dreameros-session-start.sh"
    try:
        settings = json.loads(settings_path.read_text(encoding="utf-8"))
        session_groups = settings.get("hooks", {}).get("SessionStart", [])
        session_commands = [hook.get("command", "") for group in session_groups for hook in group.get("hooks", [])]
    except Exception as exc:
        fail(f"Claude payload SessionStart registration: unreadable ({exc})")
        return
    bootstrap_commands = [command for command in session_commands if "dreameros-session-start.sh" in command]
    competing = [command for command in session_commands if re.search(r"(?i)(operator-standing-orders|dreameros-agent-stack-session-start|dreameros_state|dreameros_recall)", command)]
    if len(bootstrap_commands) != 1 or competing:
        fail("Claude payload SessionStart registration: requires one generated bootstrap and no competing hydration hook")
    stop_groups = settings.get("hooks", {}).get("Stop", [])
    stop_commands = [hook.get("command", "") for group in stop_groups for hook in group.get("hooks", [])]
    direct_switch = [command for command in stop_commands if re.search(r"__DREAMEROS_PYTHON_COMMAND__\s+.*model-switch-ack\.py", command)]
    shell_switch = [command for command in stop_commands if "model-switch-ack.sh" in command]
    if len(direct_switch) != 1 or shell_switch:
        fail("Claude payload Stop registration: requires one direct Python model-switch hook and no shell wrapper")
    all_commands = [
        hook.get("command", "")
        for groups in settings.get("hooks", {}).values()
        for group in groups
        for hook in group.get("hooks", [])
        if hook.get("type") == "command"
    ]
    bash_hooks = [command for command in all_commands if re.search(r"(?i)\.sh(?:[\"']|\s|$)", command)]
    if len(bash_hooks) != 10 or any(
        not command.startswith("__DREAMEROS_BASH_COMMAND__ ") for command in bash_hooks
    ):
        fail("Claude payload Bash registration: every managed shell hook must use the portable launcher token")
    if any(re.match(r"(?i)^bash(?:\.exe)?\s", command) for command in bash_hooks):
        fail("Claude payload Bash registration: bare launcher bypasses installer rendering")
    try:
        if payload_hook.read_bytes() != generated_hook.read_bytes():
            fail("Claude payload SessionStart hook: generated payload copy differs from bootpack output")
    except OSError as exc:
        fail(f"Claude payload SessionStart hook: unreadable ({exc})")

    installer_path = ROOT / "install" / "claude-code" / "dreameros-global-setup.ps1"
    try:
        installer_text = installer_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"Claude installer managed merge: unreadable ({exc})")
        installer_text = ""
    managed_merge_guards = (
        r"Merge-ManagedAgentFile\s+-Source\s+\$f\.FullName",
        r"Remove-DuplicateLifecycleHooksAcrossGroups",
        r"foreach\s*\(\$evt\s+in\s+@\('SessionStart',\s*'Stop'\)\)",
        r"retiredAutoInstall",
        r"model-switch-ack\\\.sh",
        r"if\s*\(-not\s+\$hookHash\.Contains\('command'\)\)",
        r"\$sourceBlockLf",
        r"\$currentHeaders\.Count\s+-ne\s+\$currentBlocks\.Count",
        r"Backup-LockedBytes\s+-Path\s+\$Destination",
        r"\$destinationStream\.SetLength\(0\)",
        r"function\s+Resolve-BashLauncher",
        r"function\s+Test-BashExecutable",
        r"function\s+Render-FragmentBashCommands",
        r"function\s+Get-ManagedBashRegistrationKey",
        r"function\s+Update-ClaudeHomeBashHookLaunchers",
        r"Get-ManagedBashRegistrationKey\s+-EventName\s+\$eventName",
        r"CommandPrefix\s*=\s*'bash'",
    )
    for pattern in managed_merge_guards:
        if not re.search(pattern, installer_text):
            fail("Claude installer managed merge: lifecycle or agent merge guard missing")


def _cursor_manifest_paths(data: dict, field: str) -> list[Path]:
    raw = data.get(field)
    values = raw if isinstance(raw, list) else [raw]
    resolved: list[Path] = []
    for value in values:
        if not isinstance(value, str) or not value:
            fail(f".cursor-plugin/plugin.json: {field} must be a path or path list")
            continue
        candidate = (ROOT / value).resolve()
        if candidate != ROOT.resolve() and ROOT.resolve() not in candidate.parents:
            fail(f".cursor-plugin/plugin.json: {field} escapes plugin root: {value}")
            continue
        if not candidate.exists():
            fail(f".cursor-plugin/plugin.json: {field} path missing: {value}")
            continue
        resolved.append(candidate)
    return resolved


def check_cursor_project_pointer() -> None:
    cursor_path = ROOT / "bootpack" / "out" / "cursor" / "dreameros-project-pointer.mdc"
    global_path = ROOT / "bootpack" / "out" / "cursor" / "dreameros-global-plugin-pointer.mdc"
    embedded_path = ROOT / "bootpack" / "out" / "project" / "DREAMEROS_BOOT_CANON_POINTER.md.block"
    source_path = ROOT / "bootpack" / "SOURCE-dreameros-boot-canon.md"
    try:
        cursor_text = cursor_path.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
        global_text = global_path.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
        embedded_text = embedded_path.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
        source_text = source_path.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
    except Exception as exc:
        fail(f"project pointer: unreadable ({exc})")
        return

    source_sha256 = hashlib.sha256(source_text.encode("utf-8")).hexdigest()

    if not 500 <= len(cursor_text.encode("utf-8")) <= 4096:
        fail("project pointer: Cursor artifact must remain between 500 and 4096 bytes")
    if any(ord(char) > 127 or (ord(char) < 32 and char not in "\n\r\t") for char in cursor_text):
        fail("project pointer: non-ASCII or control character found")
    frontmatter = re.match(r"^---\n([\s\S]*?)\n---\n\n([\s\S]*)$", cursor_text)
    if not frontmatter:
        fail("project pointer: Cursor artifact has invalid frontmatter")
        return
    if "alwaysApply: true" not in frontmatter.group(1):
        fail("project pointer: alwaysApply must be true")
    body = frontmatter.group(2).strip()
    if body != embedded_text.strip():
        fail("project pointer: Cursor and embedded pointer bodies differ")
    if cursor_text.count("DREAMEROS-PROJECT-BOOT-POINTER v1.1.0") != 1:
        fail("project pointer: stable pointer marker missing or duplicated")
    for required_text in (
        "gbude-sudo/dreameros-agent-plugin:bootpack/SOURCE-dreameros-boot-canon.md",
        "prove either carrier A or carrier B",
        "Cloud carrier: a successful authenticated `dreameros_session_package`",
        "`package_components.boot_canon`",
        "Component and wrapper schema, version, SHA-256,",
        "report CONFLICT",
        "report BLOCKED",
    ):
        if required_text not in cursor_text:
            fail(f"project pointer: required fail-closed text missing: {required_text}")
    for pattern, label in (
        (r"Do not\s+use this pointer as a fallback canon\.", "fail-closed pointer"),
    ):
        if not re.search(pattern, cursor_text):
            fail(f"project pointer: required fail-closed text missing: {label}")
    if source_sha256 in cursor_text or re.search(r"\b[0-9a-fA-F]{64}\b", cursor_text):
        fail("project pointer: release-specific source hash pin is forbidden")
    forbidden = (
        r"(?m)^# DreamerOS Boot Canon v\d",
        r"(?m)^## R1\b",
        r"(?m)^## LAYER\b",
        r"(?m)^# THE DEFINITION OF DONE",
    )
    for pattern in forbidden:
        if re.search(pattern, cursor_text):
            fail(f"project pointer: duplicated full-canon marker matched {pattern}")

    if not 500 <= len(global_text.encode("utf-8")) <= 4096:
        fail("Cursor global plugin pointer: artifact must remain between 500 and 4096 bytes")
    if global_text.count("DREAMEROS-CURSOR-GLOBAL-PLUGIN-POINTER v1.0.0") != 1:
        fail("Cursor global plugin pointer: stable marker missing or duplicated")
    for required_text in ("local `Dreameros` plugin", "dreameros-boot-canon", "dreameros-runtime", "report BLOCKED"):
        if required_text not in global_text:
            fail(f"Cursor global plugin pointer: required fail-closed text missing: {required_text}")
    if re.search(r"\b[0-9a-fA-F]{64}\b", global_text):
        fail("Cursor global plugin pointer: source hash pin would recreate fanout")
    for pattern in forbidden:
        if re.search(pattern, global_text):
            fail(f"Cursor global plugin pointer: duplicated full-canon marker matched {pattern}")

    manifest_path = ROOT / "bootpack" / "out" / "manifest" / "dreameros-boot-canon.json"
    try:
        generated_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail(f"project pointer: generated manifest unreadable ({exc})")
        return
    pointer_meta = generated_manifest.get("project_pointer", {})
    if pointer_meta.get("version") != "v1.1.0":
        fail("project pointer: generated manifest version mismatch")
    if pointer_meta.get("cursor_path") != "cursor/dreameros-project-pointer.mdc":
        fail("project pointer: generated manifest Cursor path mismatch")
    if pointer_meta.get("cursor_global_plugin_pointer") != "cursor/dreameros-global-plugin-pointer.mdc":
        fail("project pointer: generated manifest global Cursor pointer path mismatch")
    if pointer_meta.get("embedded_path") != "project/DREAMEROS_BOOT_CANON_POINTER.md.block":
        fail("project pointer: generated manifest embedded path mismatch")
    cloud_meta = pointer_meta.get("cloud_session_package", {})
    if cloud_meta.get("component") != "package_components.boot_canon":
        fail("project pointer: generated manifest cloud package component mismatch")
    if cloud_meta.get("proof") != "one complete wrapper with matching schema, version, sha256, provenance, full-body hash, canaries, and fresh metadata":
        fail("project pointer: generated manifest cloud package proof mismatch")
    required_canaries = ["R26", "R27", "HC-DEFINITION-OF-DONE"]
    if cloud_meta.get("required_canary_ids") != required_canaries:
        fail("project pointer: generated manifest cloud package required canary ids mismatch")
    if "required_marker_ids" in cloud_meta:
        fail("project pointer: generated manifest retains obsolete cloud package marker ids")
    source_text = (ROOT / "bootpack" / "SOURCE-dreameros-boot-canon.md").read_text(encoding="utf-8")
    for canary in required_canaries:
        if canary not in source_text:
            fail(f"project pointer: required canary no longer exists in source: {canary}")
    oauth_meta = generated_manifest.get("project_oauth_onramp", {})
    if oauth_meta.get("status") != "TEMPLATE_WRITTEN_NOT_REGISTERED":
        fail("project pointer: generated OAuth on-ramp status must remain template-only")


def check_project_adapters() -> None:
    outputs = {
        "measurement": ROOT / "bootpack" / "out" / "cursor" / "answer-from-measurement.adapter.mdc",
        "status_vocabulary": ROOT / "bootpack" / "out" / "cursor" / "canon-equals-live.adapter.mdc",
        "project_coordination": ROOT / "bootpack" / "out" / "cursor" / "dreameros-cold-start.adapter.mdc",
        "verified_handoff": ROOT / "bootpack" / "out" / "cursor" / "dreameros-first.adapter.mdc",
        "claude_session_start": ROOT / "bootpack" / "out" / "claude" / "dreameros-session-start.sh",
        "historical_generator_pointer": ROOT / "bootpack" / "out" / "project" / "DREAMEROS_CENTRAL_BOOT_GENERATOR_POINTER.ps1.block",
    }
    texts: dict[str, str] = {}
    for name, path in outputs.items():
        try:
            text = path.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
        except Exception as exc:
            fail(f"project adapter {name}: unreadable ({exc})")
            continue
        texts[name] = text
        if not 200 <= len(text.encode("utf-8")) <= 4096:
            fail(f"project adapter {name}: must remain between 200 and 4096 bytes")
        if any(ord(char) > 127 or (ord(char) < 32 and char not in "\n\r\t") for char in text):
            fail(f"project adapter {name}: non-ASCII or control character found")
        if re.search(r"\b[0-9a-fA-F]{64}\b", text):
            fail(f"project adapter {name}: source hash pin would recreate fanout")

    for name in ("measurement", "status_vocabulary"):
        text = texts.get(name, "")
        if text.count("DREAMEROS-CURSOR-ENFORCEMENT-ADAPTER v1.0.0") != 1:
            fail(f"project adapter {name}: stable marker missing or duplicated")
        if "alwaysApply: true" not in text or not re.search(r"report\s+BLOCKED", text):
            fail(f"project adapter {name}: always/fail-closed contract missing")
        for pattern in (r"(?m)^# DreamerOS Boot Canon v", r"(?m)^## R1\b", r"HC-DEFINITION-OF-DONE"):
            if re.search(pattern, text):
                fail(f"project adapter {name}: duplicated canon marker matched {pattern}")

    for name in ("project_coordination", "verified_handoff"):
        text = texts.get(name, "")
        if text.count("DREAMEROS-CURSOR-PROJECT-ADAPTER v1.0.0") != 1:
            fail(f"project adapter {name}: stable marker missing or duplicated")
        if "alwaysApply: true" not in text or "native DreamerOS plugin owns" not in text:
            fail(f"project adapter {name}: native-carrier boundary missing")
        if re.search(r"mcp__[0-9a-f-]{20,}__", text, re.IGNORECASE):
            fail(f"project adapter {name}: hardcoded MCP server id leaked")
        for pattern in (r"(?m)^# DreamerOS Boot Canon v", r"(?m)^## R1\b", r"HC-DEFINITION-OF-DONE"):
            if re.search(pattern, text):
                fail(f"project adapter {name}: duplicated canon marker matched {pattern}")

    hook = texts.get("claude_session_start", "")
    if hook.count("DREAMEROS-CLAUDE-SESSION-START-ADAPTER v1.1.0") != 1:
        fail("Claude session-start adapter: stable marker missing or duplicated")
    adapter_unconditional = "Call dreameros_session_package first for the active Claude engine and current project. It is the only unconditional boot call"
    adapter_conditional = "When the package directs it or the current task needs read-only enrichment, call in this order:"
    adapter_enrichment = (
        "dreameros_session_handoff_read for the full record when present",
        "dreameros_context and use its SCS as the read-only current-state channel",
        "a scoped dreameros_recall for the current topic",
        "relevant dreameros_canon",
    )
    positions = [hook.find(token) for token in (adapter_unconditional, adapter_conditional, *adapter_enrichment)]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        fail("Claude session-start adapter: unconditional package and conditional enrichment order drifted")
    if "dreameros_state" in hook:
        fail("Claude session-start adapter: mixed state tool leaked into generic bootstrap")
    if re.search(r"mcp__[0-9a-f-]{20,}__", hook, re.IGNORECASE):
        fail("Claude session-start adapter: hardcoded MCP server id leaked")
    if "hookEventName\": \"SessionStart" not in hook or "set -euo pipefail" not in hook:
        fail("Claude session-start adapter: executable hook contract missing")

    stub = texts.get("historical_generator_pointer", "")
    if stub.count("DREAMEROS-CENTRAL-BOOT-GENERATOR-POINTER v1.0.0") != 1:
        fail("historical generator pointer: stable marker missing or duplicated")
    if "throw 'This historical boot generator is superseded." not in stub:
        fail("historical generator pointer: fail-closed throw missing")
    if re.search(r"cursor[\\/]dreameros-boot-canon\.mdc", stub, re.IGNORECASE):
        fail("historical generator pointer: legacy Cursor full-copy target leaked")

    manifest_path = ROOT / "bootpack" / "out" / "manifest" / "dreameros-boot-canon.json"
    try:
        meta = json.loads(manifest_path.read_text(encoding="utf-8")).get("project_adapters", {})
    except Exception as exc:
        fail(f"project adapters: generated manifest unreadable ({exc})")
        return
    if meta.get("version") != "v1.1.0":
        fail("project adapters: generated manifest version mismatch")
    expected = {
        "measurement": "cursor/answer-from-measurement.adapter.mdc",
        "status_vocabulary": "cursor/canon-equals-live.adapter.mdc",
        "project_coordination": "cursor/dreameros-cold-start.adapter.mdc",
        "verified_handoff": "cursor/dreameros-first.adapter.mdc",
        "claude_session_start": "claude/dreameros-session-start.sh",
        "historical_generator_pointer": "project/DREAMEROS_CENTRAL_BOOT_GENERATOR_POINTER.ps1.block",
    }
    for key, value in expected.items():
        if meta.get(key) != value:
            fail(f"project adapters: generated manifest path mismatch for {key}")

    oauth_root = ROOT / "bootpack" / "out" / "project-oauth"
    expected_oauth = {
        "claude.mcp.json": ("dreameros", {"type": "streamable-http", "url": "https://mcp.dreameros.app/mcp"}),
        "cursor.mcp.json": ("dreameros-platform", {"url": "https://mcp.dreameros.app/mcp"}),
    }
    for filename, (server_name, expected_server) in expected_oauth.items():
        try:
            payload = json.loads((oauth_root / filename).read_text(encoding="utf-8"))
            server = payload.get("mcpServers", {}).get(server_name, {})
        except Exception as exc:
            fail(f"project OAuth on-ramp: unreadable {filename} ({exc})")
            continue
        if server != expected_server:
            fail(f"project OAuth on-ramp: invalid credential-free {filename}")
    try:
        codex_onramp = (oauth_root / "codex.config.toml").read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"project OAuth on-ramp: unreadable codex.config.toml ({exc})")
    else:
        if "[mcp_servers.dreameros]" not in codex_onramp or 'url = "https://mcp.dreameros.app/mcp"' not in codex_onramp or "[mcp_servers.dreameros.tools.dreameros_session_package]" not in codex_onramp or "output_token_limit = 30000" not in codex_onramp:
            fail("project OAuth on-ramp: invalid credential-free codex.config.toml")
        if re.search(r"(?i)authorization|bearer|api[_-]?key|env", codex_onramp):
            fail("project OAuth on-ramp: Codex template has a credential dependency")


def check_cursor_plugin() -> None:
    manifest_path = ROOT / ".cursor-plugin" / "plugin.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail(f".cursor-plugin/plugin.json: unreadable or invalid JSON ({exc})")
        return

    name = manifest.get("name", "")
    if not isinstance(name, str) or not NAME_RE.match(name):
        fail(f".cursor-plugin/plugin.json: name {name!r} violates naming rules")

    portable_manifest = json.loads((ROOT / "plugin.json").read_text(encoding="utf-8"))
    if manifest.get("version") != portable_manifest.get("version"):
        fail(".cursor-plugin/plugin.json: version drifted from portable plugin.json")

    required_paths = {
        "rules": "./cursor/rules",
        "skills": "./skills",
        "agents": "./cursor/agents",
        "commands": "./cursor/commands",
        "hooks": "./cursor/hooks/hooks.json",
        "mcpServers": "./cursor/mcp.json",
    }
    for field in required_paths:
        _cursor_manifest_paths(manifest, field)
    for field, expected_path in required_paths.items():
        if manifest.get(field) != expected_path:
            fail(f".cursor-plugin/plugin.json: {field} path must be {expected_path}")

    generated_boot = ROOT / "bootpack" / "out" / "cursor" / "dreameros-boot-canon.mdc"
    plugin_boot = ROOT / "cursor" / "rules" / "dreameros-boot-canon.mdc"
    if generated_boot.read_bytes() != plugin_boot.read_bytes():
        fail("cursor/rules/dreameros-boot-canon.mdc: generated plugin mirror drifted from bootpack output")

    cursor_mcp = ROOT / "cursor" / "mcp.json"
    try:
        mcp = json.loads(cursor_mcp.read_text(encoding="utf-8"))
    except Exception as exc:
        fail(f"cursor/mcp.json: unreadable or invalid JSON ({exc})")
        mcp = {}
    servers = mcp.get("mcpServers") if isinstance(mcp, dict) else None
    if not isinstance(servers, dict) or set(servers) != {"dreameros-platform"}:
        fail("cursor/mcp.json: expected exactly the dreameros-platform server")
    else:
        server = servers["dreameros-platform"]
        if server.get("type") != "streamable-http":
            fail("cursor/mcp.json: DreamerOS transport must be streamable-http")
        if server.get("url") != "https://mcp.dreameros.app/mcp":
            fail("cursor/mcp.json: unexpected DreamerOS MCP URL")
        if server.get("headers"):
            fail("cursor/mcp.json: headers are forbidden; Cursor must own OAuth")

    hook_config = ROOT / "cursor" / "hooks" / "hooks.json"
    try:
        hooks_root = json.loads(hook_config.read_text(encoding="utf-8"))
    except Exception as exc:
        fail(f"cursor/hooks/hooks.json: unreadable or invalid JSON ({exc})")
        hooks_root = {}
    hooks = hooks_root.get("hooks") if isinstance(hooks_root, dict) else None
    required_events = {
        "sessionStart",
        "subagentStart",
        "beforeSubmitPrompt",
        "beforeShellExecution",
        "beforeMCPExecution",
        "afterMCPExecution",
        "postToolUse",
        "beforeReadFile",
    }
    if hooks_root.get("version") != 1 or not isinstance(hooks, dict):
        fail("cursor/hooks/hooks.json: version 1 hooks object required")
    elif set(hooks) != required_events:
        fail("cursor/hooks/hooks.json: required event set does not match")
    else:
        for event in sorted(required_events):
            entries = hooks[event]
            if not isinstance(entries, list) or len(entries) != 1:
                fail(f"cursor/hooks/hooks.json: {event} must have exactly one hook")
                continue
            entry = entries[0]
            if "dreameros_cursor_hook.py" not in str(entry.get("command", "")):
                fail(f"cursor/hooks/hooks.json: {event} does not call the Cursor hook")
            expected_closed = True
            if entry.get("failClosed") is not expected_closed:
                fail(f"cursor/hooks/hooks.json: {event} failClosed is incorrect")
            if not isinstance(entry.get("timeout"), (int, float)) or entry["timeout"] < 10:
                fail(f"cursor/hooks/hooks.json: {event} timeout must absorb a measured Windows cold-start burst")
            if event == "postToolUse" and entry.get("matcher") != "MCP:.*":
                fail("cursor/hooks/hooks.json: postToolUse must not fan out across non-MCP tools")

    component_specs = (
        (ROOT / "cursor" / "rules", {".mdc"}, {"description:", "alwaysApply:"}, 2),
        (ROOT / "cursor" / "agents", {".md"}, {"name:", "description:"}, 4),
        (ROOT / "cursor" / "commands", {".md"}, {"name:", "description:"}, 7),
    )
    for directory, extensions, fields, expected in component_specs:
        files = sorted(p for p in directory.iterdir() if p.is_file() and p.suffix in extensions)
        if len(files) != expected:
            fail(f"{directory.relative_to(ROOT)}: expected {expected} components, found {len(files)}")
        for path in files:
            frontmatter = _frontmatter(path)
            if frontmatter is None:
                continue
            for field in fields:
                if field not in frontmatter:
                    fail(f"{path.relative_to(ROOT)}: frontmatter missing {field[:-1]}")

    expected_cursor_agents = {
        "canon-citer.md": ("dreameros-platform-canon-citer", "true"),
        "dreameros-operator.md": ("dreameros-platform-operator", "false"),
        "governance-node.md": ("dreameros-platform-governance-node", "true"),
        "open-loop-auditor.md": ("dreameros-platform-open-loop-auditor", "true"),
    }
    for filename, (expected_name, expected_readonly) in expected_cursor_agents.items():
        path = ROOT / "cursor" / "agents" / filename
        frontmatter = _frontmatter(path)
        if frontmatter is None:
            continue
        declared_name = re.search(r"^name:\s*(\S+)\s*$", frontmatter, re.MULTILINE)
        declared_model = re.search(r"^model:\s*(\S+)\s*$", frontmatter, re.MULTILINE)
        declared_readonly = re.search(r"^readonly:\s*(\S+)\s*$", frontmatter, re.MULTILINE)
        if not declared_name or declared_name.group(1) != expected_name:
            fail(f"{path.relative_to(ROOT)}: collision-proof native name must be {expected_name}")
        if not declared_model or declared_model.group(1) != "inherit":
            fail(f"{path.relative_to(ROOT)}: model must explicitly inherit the parent Cursor model")
        if not declared_readonly or declared_readonly.group(1).lower() != expected_readonly:
            fail(f"{path.relative_to(ROOT)}: readonly must be {expected_readonly}")

    parity_command = ROOT / "cursor" / "commands" / "dreameros-parity-check.md"
    try:
        parity_text = parity_command.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"cursor parity command: unreadable ({exc})")
        parity_text = ""
    parity_guards = (
        (r"one\s+shell\s+tool\s+call\s+only", "single prelaunch boundary shell call"),
        (r"PARITY\s+SUBAGENT\s+PRELAUNCH\s+BOUNDARY", "named prelaunch boundary"),
        (r"hook-ledger\s+path\s+verified\s+in\s+row\s+6", "verified hook-ledger path"),
        (r"SHA-256\s+of\s+exactly\s+that\s+prefix", "captured prelaunch ledger prefix hash"),
        (r"whole-second\s+UTC\s+precision", "whole-second prelaunch boundary"),
        (r"`boundary_utc`,\s+`byte_length`,\s+and\s+`prefix_sha256`", "exact prelaunch boundary output"),
        (r"ledger\s+is\s+missing,\s+unreadable,\s+or\s+invalid", "prelaunch ledger failure branch"),
        (r"Run\s+exactly\s+this\s+PowerShell\s+command", "exact boundary command"),
        (r"\[Environment\]::GetFolderPath\('UserProfile'\)", "non-secret user-profile resolution"),
        (r"Do\s+not\s+rewrite\s+that\s+command\s+with\s+`\$env:USERPROFILE`", "no credential-path rewrite"),
        (r"Do\s+not\s+co-schedule\s+a\s+Task", "no boundary and Task co-scheduling"),
        (r"Only\s+after\s+that\s+shell\s+result\s+returns", "completed boundary before launches"),
        (r"launch\s+these\s+two\s+independent\s+Task\s+calls\s+in\s+parallel", "parallel background role launches"),
        (r"next\s+parent\s+transcript\s+record", "parent Task request record"),
        (r"exactly\s+two\s+`Task`\s+tool-use\s+objects", "two exact Task request objects"),
        (r"named\s+`subagent_type`", "Task role identity fields"),
        (r"does\s+not\s+preserve\s+an\s+immediate\s+Task-result\s+object", "measured Task-result limitation"),
        (r"do\s+not\s+require,\s+infer,\s+or\s+invent\s+a\s+returned\s+handle\s+or\s+UUID", "no unprovable Task handle gate"),
        (r"Do\s+not\s+delegate\s+parity\s+drafting", "no delegated parity drafting"),
        (r"optional\s+reviewer\s+must\s+never\s+suppress\s+the\s+block\.", "mandatory result block"),
        (r"PARITY-CORE-BLOCK-BARRIER\s+v1\.0\.0", "structural core-block barrier"),
        (r"standalone\s+assistant\s+text\s+message", "standalone core result message"),
        (r"End\s+that\s+assistant\s+message\s+after\s+the\s+block", "core result turn boundary"),
        (r"Putting\s+a\s+proposed\s+block\s+inside\s+a\s+Task\s+prompt\s+does\s+not\s+satisfy", "no hidden Task-prompt block"),
        (r"native\s+`subagentStart`\s+hook\s+reads\s+the\s+parent\s+transcript\s+and\s+denies", "runtime-enforced result barrier"),
        (r"run\s+exactly\s+this\s+harmless\s+shell\s+command", "single harmless phase bridge"),
        (r"Write-Output\s+\"DREAMEROS_PARITY_CORE_BLOCK_EMITTED\"", "runtime core-block marker"),
        (r"`beforeShellExecution`\s+hook\s+stores\s+the\s+marker", "marker persistence hook"),
        (r"Label\s+it\s+`PARITY\s+PHASE\s+BRIDGE`", "named phase bridge"),
        (r"Do\s+not\s+include\s+a\s+Task\s+call\s+in\s+that\s+response", "no same-message reviewer launch"),
        (r"without\s+a\s+second\s+user\s+prompt", "automatic post-block continuation"),
        (r"dreameros_memory_full", "UUID-capable receipt read-back"),
        (r"Require\s+exactly\s+one\s+record", "single-record receipt lookup"),
        (r"UUID\s+must\s+match\s+the\s+captured", "receipt UUID equality"),
        (r"content\s+must\s+equal\s+the\s+submitted", "receipt content equality"),
        (r"memory\s+type\s+must\s+be\s+`contextual`", "receipt memory type"),
        (r"true\s+new\s+Agent", "true new Agent entry point"),
        (r"beforeSubmitPrompt=bootstrap", "cold-load first-prompt boot fallback"),
        (r"must\s+not\s+reset\s+an\s+existing\s+boot\s+state", "cold-load fallback preserves hydration"),
        (r"authority\s+deny\s+sentinel", "fail-closed authority sentinel"),
        (r"If\s+that\s+is\s+the\s+only\s+failed\s+row,\s+set\s+`overall=PARTIAL`", "deterministic subagent downgrade"),
        (r"dreameros-platform-canon-citer", "collision-proof canon-citer invocation"),
        (r"dreameros-platform-governance-node", "collision-proof governance-node invocation"),
        (r"explicitly\s+inherit\s+the\s+parent\s+Cursor\s+model", "native subagent model inheritance"),
        (r"second\s+complete\s+`CURSOR_PARITY\s+v1`\s+block", "mandatory post-health result block"),
        (r"Prose\s+alone\s+is\s+not\s+sufficient", "no prose-only health result"),
        (r"CONNECTED_WITH_LEGACY_PROJECT_AUTH", "connected plugin with legacy project auth classification"),
        (r"Treat\s+`GLOBAL_ONLY`\s+as\s+a\s+`CLOUD_BOOT_GAP`;\s+it\s+prevents\s+`FULL`", "global-only cloud boot gap classification"),
        (r"Do\s+not\s+use\s+foreground\s+Task", "no foreground role calls"),
        (r"Do\s+not\s+wait\s+for,\s+poll,\s+fetch,\s+or\s+read\s+either\s+role's\s+completion", "no role completion wait"),
        (r"one\s+immediate\s+read\s+of\s+the\s+hook\s+signature\s+ledger", "single immediate hook-ledger read"),
        (r"first\s+two\s+complete\s+JSON\s+records[\s\S]*?`subagentStart`\s+entries", "two native role start signatures"),
        (r"current\s+length\s+to\s+be\s+at\s+least\s+`byte_length`", "post-launch ledger length check"),
        (r"Recompute\s+SHA-256\s+over\s+the\s+first\s+`byte_length`\s+bytes", "post-launch ledger prefix check"),
        (r"Read\s+only\s+bytes\s+appended\s+after\s+that\s+prefix", "post-boundary ledger tail"),
        (r"first\s+two\s+complete\s+JSON\s+records\s+in\s+the\s+appended\s+tail", "first two tail records are launches"),
        (r"actual\s+`timestamp`\s+field", "actual hook timestamp field"),
        (r"use\s+the\s+verified\s+byte\s+boundary\s+for\s+ordering", "byte-boundary launch ordering"),
        (r"Do\s+not\s+accept\s+a\s+missing\s+timestamp", "no missing-timestamp fallback"),
        (r"same-session\s+fallback", "no same-session ledger fallback"),
        (r"distinct,\s+non-`unavailable`\s+`subagent_fingerprint`", "distinct native role fingerprints"),
        (r"classifies\s+native\s+role\s+invocation,\s+not\s+the\s+quality\s+or\s+completion", "invocation-only classification"),
        (r"If\s+either\s+Task\s+request\s+is\s+absent\s+or\s+malformed", "rejected-launch branch present"),
        (r"both\s+exact\s+Task\s+request\s+records\s+and\s+both\s+hook\s+signatures", "Task requests plus hook starts gate"),
        (r"UUIDs\s+that\s+arrive\s+in\s+later\s+completion\s+callbacks\s+are\s+optional\s+references,\s+not\s+launch\s+proof", "late UUIDs are not launch proof"),
        (r"Do\s+not\s+retry\s+a\s+failed\s+launch", "no background launch retry"),
        (r"must\s+not\s+delay\s+or\s+rewrite\s+either\s+parity\s+block", "late output isolation"),
    )
    for pattern, label in parity_guards:
        if not re.search(pattern, parity_text, re.IGNORECASE):
            fail(f"cursor parity command: bounded-result guard missing: {label}")
    stale_cloud_parity_contracts = (
        r"Accept\s+either\s+`VERIFIED\s+GLOBAL_ONLY`",
        r"`overall=FULL`\s+requires\s+either\s+a\s+measured\s+`GLOBAL_ONLY`",
    )
    for pattern in stale_cloud_parity_contracts:
        if re.search(pattern, parity_text, re.IGNORECASE):
            fail("cursor parity command: GLOBAL_ONLY cannot satisfy full cloud parity")

    cursor_install_readme = (ROOT / "install" / "cursor" / "README.md").read_text(encoding="utf-8")
    stale_cloud_readme_contracts = (
        r"A\s+measured\s+`GLOBAL_ONLY`\s+estate\s+or\s+`POINTER_ALIGNED\s+FILE-CLEAN`\s+passes",
        r"`GLOBAL_ONLY`\s+and\s+`POINTER_ALIGNED\s+FILE-CLEAN`\s+are\s+non-conflicting\s+states",
        r"Accept\s+`overall=FULL`\s+only\s+for\s+`GLOBAL_ONLY`\s+or",
    )
    for pattern in stale_cloud_readme_contracts:
        if re.search(pattern, cursor_install_readme, re.IGNORECASE):
            fail("install/cursor/README.md: GLOBAL_ONLY cannot satisfy full cloud parity")
    result_position = parity_text.find("CURSOR_PARITY v1")
    health_position = parity_text.find("AFTER-BLOCK BACKGROUND SUBAGENT INVOCATION v1.4.0")
    if result_position < 0 or health_position < 0 or result_position > health_position:
        fail("cursor parity command: result block must precede the subagent health check")
    for required_status in ("subagents=FAILED", "overall=FULL", "subagents/commands"):
        if required_status not in parity_text:
            fail(f"cursor parity command: required classification contract missing: {required_status}")
    if parity_text.count("run_in_background: true") != 2:
        fail("cursor parity command: both native role calls must set run_in_background: true")
    if parity_text.count("PARITY PHASE BRIDGE") != 2:
        fail("cursor parity command: phase bridge must be named once at emission and once at continuation")
    if parity_text.count('Write-Output "DREAMEROS_PARITY_CORE_BLOCK_EMITTED"') != 1:
        fail("cursor parity command: core-block marker command must appear exactly once")
    stale_wait_contracts = (
        r"sequentially,\s+not\s+in\s+parallel",
        r"Give\s+each\s+role\s+at\s+most\s+20\s+seconds",
        r"combined\s+phase\s+under\s+45\s+seconds",
        r"five\s+minutes\s+and\s+45\s+seconds",
        r"first\s+block\s+must\s+be\s+visible\s+within\s+five\s+minutes",
        r"run_in_background:\s*false",
    )
    for pattern in stale_wait_contracts:
        if re.search(pattern, parity_text, re.IGNORECASE):
            fail("cursor parity command: stale blocking or unenforceable role-wait contract found")

    background_guard_labels = {
        "single prelaunch boundary shell call",
        "named prelaunch boundary",
        "verified hook-ledger path",
        "captured prelaunch ledger prefix hash",
        "whole-second prelaunch boundary",
        "exact prelaunch boundary output",
        "prelaunch ledger failure branch",
        "exact boundary command",
        "non-secret user-profile resolution",
        "no credential-path rewrite",
        "no boundary and Task co-scheduling",
        "completed boundary before launches",
        "parallel background role launches",
        "parent Task request record",
        "two exact Task request objects",
        "Task role identity fields",
        "measured Task-result limitation",
        "no unprovable Task handle gate",
        "no foreground role calls",
        "no role completion wait",
        "single immediate hook-ledger read",
        "two native role start signatures",
        "post-launch ledger length check",
        "post-launch ledger prefix check",
        "post-boundary ledger tail",
        "first two tail records are launches",
        "actual hook timestamp field",
        "byte-boundary launch ordering",
        "no missing-timestamp fallback",
        "no same-session ledger fallback",
        "distinct native role fingerprints",
        "invocation-only classification",
        "rejected-launch branch present",
        "Task requests plus hook starts gate",
        "late UUIDs are not launch proof",
        "no background launch retry",
        "late output isolation",
    }

    def background_contract_fails(candidate: str) -> bool:
        if candidate.count("run_in_background: true") != 2:
            return True
        if any(re.search(pattern, candidate, re.IGNORECASE) for pattern in stale_wait_contracts):
            return True
        return any(
            label in background_guard_labels and not re.search(pattern, candidate, re.IGNORECASE)
            for pattern, label in parity_guards
        )

    background_regression_fixtures = {
        "one foreground launch": parity_text.replace(
            "run_in_background: true", "run_in_background: false", 1
        ),
        "sequential launch": parity_text + "\nsequentially, not in parallel\n",
        "completion wait": parity_text.replace(
            "Do not wait for, poll, fetch, or read either role's completion",
            "Wait for either role's completion",
            1,
        ),
        "boundary co-schedule": parity_text.replace(
            "Do not co-schedule a Task with this boundary command",
            "Co-schedule a Task with this boundary command",
            1,
        ),
        "wrong timestamp field": parity_text.replace(
            "actual `timestamp` field",
            "actual `ts` field",
            1,
        ),
        "missing ledger prefix hash": parity_text.replace(
            "SHA-256 of exactly that prefix",
            "a checksum of the ledger",
            1,
        ),
        "fractional boundary": parity_text.replace(
            "whole-second UTC precision",
            "UTC precision",
            1,
        ),
        "credential-bearing profile resolution": parity_text.replace(
            "[Environment]::GetFolderPath('UserProfile')",
            "$env:USERPROFILE",
            1,
        ),
        "invented Task handle": parity_text.replace(
            "do not require, infer, or invent a returned handle or UUID",
            "require a returned handle or UUID",
            1,
        ),
        "unordered tail starts": parity_text.replace(
            "first two complete JSON records in the appended tail",
            "two JSON records in the appended tail",
            1,
        ),
    }
    for label, fixture in background_regression_fixtures.items():
        if not background_contract_fails(fixture):
            fail(f"cursor parity command: background regression guard did not fire for {label}")
    if re.search(r"\$env:USERPROFILE[\s\S]{0,500}ReadAllBytes", parity_text, re.IGNORECASE):
        fail("cursor parity command: credential-bearing profile lookup found in boundary command")
    if re.search(r"stop\s+the\s+remaining\s+lane", parity_text, re.IGNORECASE):
        fail("cursor parity command: one role failure must not cancel the healthy sibling")

    claude_review_command = ROOT / "cursor" / "commands" / "dreameros-claude-review.md"
    try:
        claude_review_text = claude_review_command.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"cursor Claude review command: unreadable ({exc})")
        claude_review_text = ""
    claude_review_guards = (
        (r"latest\s+`/dreameros-parity-check`\s+result", "parity result is the review objective"),
        (r"exact\s+parent\s+Cursor\s+transcript\s+path", "exact parent transcript path"),
        (r"SHA-256,\s+byte\s+length,\s+and\s+line\s+count", "transcript identity fields"),
        (r"both\s+complete\s+`CURSOR_PARITY\s+v1`\s+blocks", "both parity blocks"),
        (r"raw\s+ordered\s+transcript\s+records", "raw transcript ordering records"),
        (r"phase\s+bridge,\s+prelaunch\s+boundary,\s+both\s+Task\s+request\s+records", "required parity transcript records"),
        (r"later\s+UUID\s+completion\s+callbacks\s+separately", "late UUID callbacks separated"),
        (r"do\s+not\s+treat\s+them\s+as\s+pre-emission\s+launch\s+proof", "late UUIDs excluded from launch proof"),
        (r"exact\s+hook-ledger\s+path,\s+`byte_length`,\s+and\s+`prefix_sha256`", "hook-ledger boundary identity"),
        (r"Recompute\s+that\s+prefix\s+hash", "independent prefix verification"),
        (r"raw\s+first\s+two\s+complete\s+appended\s+`subagentStart`\s+JSON\s+records", "raw launch signature rows"),
        (r"parent\s+transcript\s+omits\s+Shell\s+results", "transcript result limitation"),
        (r"read\s+these\s+rows\s+directly\s+from\s+the\s+hook\s+ledger", "direct hook-ledger evidence"),
        (r"For\s+every\s+hash,\s+name\s+the\s+exact\s+file\s+path\s+or\s+transcript\s+byte\s+range", "hash scope"),
        (r"For\s+every\s+diff,\s+name\s+its\s+base,\s+head", "diff endpoints"),
        (r"Separate\s+committed,\s+staged,\s+unstaged,\s+and\s+untracked\s+evidence", "Git state separation"),
        (r"transcript\s+path\s+to\s+the\s+packet's\s+ordered\s+read\s+list", "transcript in ordered reads"),
        (r"Do\s+not\s+name\s+`/dreameros-claude-review`\s+as\s+the\s+Human\s+Conductor\s+objective", "packet command is not the review objective"),
    )
    for pattern, label in claude_review_guards:
        if not re.search(pattern, claude_review_text, re.IGNORECASE):
            fail(f"cursor Claude review command: evidence guard missing: {label}")

    def claude_review_contract_fails(candidate: str) -> bool:
        return any(not re.search(pattern, candidate, re.IGNORECASE) for pattern, _ in claude_review_guards)

    claude_review_regression_fixtures = {
        "raw launch rows removed": claude_review_text.replace(
            "raw first two complete appended `subagentStart` JSON records",
            "summary of the subagent starts",
            1,
        ),
        "direct ledger replaced by summary": claude_review_text.replace(
            "read these rows directly",
            "copy these rows from Cursor's summary",
            1,
        ),
    }
    for label, fixture in claude_review_regression_fixtures.items():
        if not claude_review_contract_fails(fixture):
            fail(f"cursor Claude review command: regression guard did not fire for {label}")

    hook = ROOT / "cursor" / "hooks" / "dreameros_cursor_hook.py"
    try:
        hook_text = hook.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"cursor hook could not be read for continuation validation ({exc})")
        hook_text = ""
    continuation_guards = (
        r"part_text\s*=\s*expected_text\[offset:end\]",
        r"hashlib\.sha256\(part_text\.encode\(\"utf-8\"\)\)\.hexdigest\(\)\s*!=\s*declared_hash",
        r"static continuation part hash corruption rejects",
        r"package continuation part hash corruption rejects",
    )
    for pattern in continuation_guards:
        if not re.search(pattern, hook_text):
            fail("cursor hook: continuation descriptor hashes are not recomputed from exact slices")
    try:
        run = subprocess.run(
            [sys.executable, str(hook), "--self-test"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        result = json.loads(run.stdout)
        if (
            run.returncode != 0
            or result.get("status") != "pass"
            or result.get("cases", 0) < CURSOR_HOOK_CASE_FLOOR
        ):
            fail(f"cursor hook self-test failed: {run.stdout.strip()}")
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
        fail(f"cursor hook self-test could not run ({exc})")

    try:
        with tempfile.TemporaryDirectory(prefix="dreameros-cursor-hook-concurrency-") as state_root:
            environment = os.environ.copy()
            environment["DREAMEROS_CURSOR_STATE_DIR"] = state_root
            payloads = [
                {
                    "hook_event_name": "subagentStart",
                    "conversation_id": "concurrency-parent",
                    "generation_id": f"concurrency-generation-{index}",
                    "subagent_id": f"concurrency-subagent-{index}",
                }
                for index in range(8)
            ]

            def run_hook(payload: dict) -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    [sys.executable, str(hook)],
                    input=json.dumps(payload),
                    capture_output=True,
                    text=True,
                    timeout=9,
                    check=False,
                    env=environment,
                )

            started = time.monotonic()
            with concurrent.futures.ThreadPoolExecutor(max_workers=len(payloads)) as pool:
                runs = list(pool.map(run_hook, payloads))
            elapsed = time.monotonic() - started
            if elapsed >= 10:
                fail(f"cursor hook concurrency: eight-process burst exceeded hook timeout ({elapsed:.2f}s)")
            for index, process in enumerate(runs):
                try:
                    output = json.loads(process.stdout)
                except json.JSONDecodeError:
                    output = {}
                if process.returncode != 0 or output.get("permission") != "allow":
                    fail(f"cursor hook concurrency: process {index} failed: {process.stdout.strip()}")

            state_path = Path(state_root) / "boot-state.json"
            signature_path = Path(state_root) / "hook-signatures.jsonl"
            state = json.loads(state_path.read_text(encoding="utf-8"))
            expected_fingerprints = {
                hashlib.sha256(f"subagent:concurrency-subagent-{index}".encode("utf-8")).hexdigest()[:24]
                for index in range(8)
            }
            actual_fingerprints = set(state.get("sessions", {}))
            if actual_fingerprints != expected_fingerprints:
                fail("cursor hook concurrency: cross-process state update lost or added a subagent")
            signatures = [
                json.loads(line)
                for line in signature_path.read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
            signature_fingerprints = {
                record.get("subagent_fingerprint")
                for record in signatures
                if record.get("event") == "subagentStart" and record.get("permission") == "allow"
            }
            if signature_fingerprints != expected_fingerprints:
                fail("cursor hook concurrency: append-only signature burst lost or added a subagent")
            if (Path(state_root) / "boot-state.json.lock").exists():
                fail("cursor hook concurrency: boot-state lock leaked after the burst")

            mixed_payloads = [
                {
                    "hook_event_name": "beforeReadFile",
                    "conversation_id": f"mixed-read-{index}",
                    "generation_id": f"mixed-read-generation-{index}",
                    "file_path": f"C:\\safe\\mixed-{index}.txt",
                    "content": "safe measured content " * 3200,
                }
                for index in range(4)
            ] + [
                {
                    "hook_event_name": "postToolUse",
                    "conversation_id": f"mixed-post-{index}",
                    "generation_id": f"mixed-post-generation-{index}",
                    "tool_name": "Grep",
                    "tool_output": json.dumps({"success": True}),
                }
                for index in range(4)
            ]
            mixed_started = time.monotonic()
            with concurrent.futures.ThreadPoolExecutor(max_workers=len(mixed_payloads)) as pool:
                mixed_runs = list(pool.map(run_hook, mixed_payloads))
            mixed_elapsed = time.monotonic() - mixed_started
            if mixed_elapsed >= 10:
                fail(f"cursor hook concurrency: read and generic-post burst exceeded hook timeout ({mixed_elapsed:.2f}s)")
            for index, process in enumerate(mixed_runs):
                if process.returncode != 0:
                    fail(f"cursor hook concurrency: mixed process {index} failed: {process.stdout.strip()}")
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError, KeyError) as exc:
        fail(f"cursor hook concurrency test could not run ({exc})")


def check_cursor_component_name_uniqueness() -> None:
    paths = list((ROOT / "skills").glob("*/SKILL.md"))
    paths += list((ROOT / "cursor" / "commands").glob("*.md"))
    paths += list((ROOT / "cursor" / "agents").glob("*.md"))
    owners: dict[str, list[str]] = {}
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            fail(f"component name check: unreadable {path.relative_to(ROOT)} ({exc})")
            continue
        match = re.search(r"^name:\s*(\S+)\s*$", text, re.MULTILINE)
        if not match:
            continue
        owners.setdefault(match.group(1).lower(), []).append(str(path.relative_to(ROOT)))
    for name, component_paths in owners.items():
        if len(component_paths) > 1:
            fail(f"Cursor component name collision {name!r}: {', '.join(component_paths)}")


def check_cursor_portability() -> None:
    roots = (ROOT / ".cursor-plugin", ROOT / "cursor", ROOT / "install" / "cursor")
    paths = [ROOT / "README.md"]
    for directory in roots:
        paths.extend(path for path in directory.rglob("*") if path.is_file())
    absolute_user_path = re.compile(r"(?i)\b[A-Z]:[\\/]Users[\\/][^\\/\s]+")
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if absolute_user_path.search(text):
            fail(f"Cursor portability: hardcoded Windows user path in {path.relative_to(ROOT)}")


def check_customer_copy_vocabulary() -> None:
    forbidden = re.compile(r"(?i)\b(?:governance|governed|governs|govern|DAIM|EDE|IFP)\b")
    for path in (ROOT / "README.md", ROOT / "plugin.json", ROOT / ".cursor-plugin" / "plugin.json"):
        text = path.read_text(encoding="utf-8")
        match = forbidden.search(text)
        if match:
            fail(f"customer copy vocabulary: forbidden term {match.group(0)!r} in {path.relative_to(ROOT)}")


def check_hydration_preconditions() -> None:
    paths = (
        ROOT / "cursor" / "agents" / "canon-citer.md",
        ROOT / "cursor" / "agents" / "dreameros-operator.md",
        ROOT / "cursor" / "commands" / "dreameros-hydrate.md",
        ROOT / "cursor" / "commands" / "dreameros-parity-check.md",
        ROOT / "cursor" / "commands" / "dreameros-verify.md",
        ROOT / "cursor" / "rules" / "dreameros-runtime.mdc",
        ROOT / "skills" / "dreameros-continuity" / "SKILL.md",
        ROOT / "skills" / "dreameros-life-of-intent" / "SKILL.md",
        ROOT / "skills" / "dreameros-verified-answers" / "SKILL.md",
        ROOT / "skills" / "dreameros-verified-routing" / "SKILL.md",
    )
    marker = "DREAMEROS-BOOT-PRECONDITION v1.1.0"
    required_order = (
        "dreameros_session_package",
        "dreameros_session_handoff_read",
        "dreameros_context",
        "dreameros_recall",
        "dreameros_canon",
    )
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
        except (OSError, UnicodeDecodeError) as exc:
            fail(f"hydration precondition: unreadable {path.relative_to(ROOT)} ({exc})")
            continue
        if marker not in text or "DREAMEROS-BOOT-PRECONDITION v1.0.0" in text:
            fail(f"hydration precondition: marker missing in {path.relative_to(ROOT)}")
            continue
        if not re.search(r"`dreameros_session_package`\s+is the only\s+required boot call\.\s+Call it first", text):
            fail(f"hydration precondition: unconditional package contract missing in {path.relative_to(ROOT)}")
        if not re.search(r"When the package directs it or the assigned\s+task needs read-only enrichment,\s+use this order", text):
            fail(f"hydration precondition: conditional enrichment contract missing in {path.relative_to(ROOT)}")
        positions = [text.find(token) for token in required_order]
        if any(position < 0 for position in positions) or positions != sorted(positions):
            fail(f"hydration precondition: v1.1 order missing in {path.relative_to(ROOT)}")
        if path.name != "dreameros-operator.md" and "dreameros_state" in text:
            fail(f"hydration precondition: mixed state tool leaked into generic bootstrap {path.relative_to(ROOT)}")
        if re.search(r"(?i)\brecall\s+FIRST\b|\brecall\s+first\b", text):
            fail(f"hydration precondition: recall-first directive remains in {path.relative_to(ROOT)}")

    hook_path = ROOT / "cursor" / "hooks" / "dreameros_cursor_hook.py"
    try:
        hook = hook_path.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"hydration precondition: unreadable {hook_path.relative_to(ROOT)} ({exc})")
        return
    if 'BOOT_SEQUENCE = ("dreameros_session_package",)' not in hook:
        fail("Cursor hook: session package must be the only mandatory boot gate")
    context_match = re.search(r'BOOT_CONTEXT = """([\s\S]*?)"""', hook)
    if context_match is None:
        fail("Cursor hook: boot context missing")
    else:
        context = context_match.group(1)
        if "dreameros_state" in context:
            fail("Cursor hook: mixed state tool remains in universal boot context")
        positions = [context.find(token) for token in required_order]
        if any(position < 0 for position in positions) or positions != sorted(positions):
            fail("Cursor hook: v1.1 package and conditional enrichment order drifted")
    if '"dreameros_session_handoff_read",' not in hook:
        fail("Cursor hook: handoff read is not classified as a safe optional enrichment call")


def check_codex_stop_hook() -> None:
    config_path = ROOT / "install" / "codex" / "payload" / "hooks.json"
    hook_path = ROOT / "install" / "codex" / "payload" / "hooks" / "model-switch-ack-codex.py"
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
        stop_entries = config["hooks"]["Stop"]
        commands = stop_entries[0]["hooks"]
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, KeyError, IndexError, TypeError) as exc:
        fail(f"Codex Stop hook config: unreadable or malformed ({exc})")
        return
    if len(stop_entries) != 1 or len(commands) != 1:
        fail("Codex Stop hook config: expected one DreamerOS Stop command")
        return
    command = commands[0]
    if "additionalContextLimit" in command:
        fail("Codex Stop hook config: additionalContextLimit is not valid for the Stop contract")

    try:
        hook_text = hook_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"Codex Stop hook: unreadable ({exc})")
        return
    required = (
        (r"stop_hook_active", "recursion guard"),
        (r'"decision"\s*:\s*"block"', "blocking decision"),
        (r'"reason"\s*:\s*message', "blocking reason"),
    )
    for pattern, label in required:
        if not re.search(pattern, hook_text):
            fail(f"Codex Stop hook: missing {label}")
    if "hookSpecificOutput" in hook_text or '"additionalContext"' in hook_text:
        fail("Codex Stop hook: obsolete additional-context output remains")

    builder_path = ROOT / "bootpack" / "build-boot-pack.ps1"
    try:
        builder_text = builder_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"Codex Stop hook installer: unreadable ({exc})")
        return
    installer_guards = (
        (r"Install-CollisionSafeFile\s+-Source\s+\$codexHookSrc", "collision-safe install call"),
        (r"FileShare\]::None", "exclusive destination lock"),
        (r"expectedCurrentHash", "captured expected destination hash"),
        (r"immediateHash\s+-cne\s+\$expectedCurrentHash", "immediate pre-write hash check"),
        (r"New-TimestampedBackupPath", "timestamped backup"),
        (r"MERGE NEEDED", "visible collision result"),
        (r"Install-NewTextFileOrPreserve\s+-Destination\s+\$codexJsonDest", "exclusive hooks.json create and preserve call"),
    )
    for pattern, label in installer_guards:
        if not re.search(pattern, builder_text):
            fail(f"Codex Stop hook installer: missing {label}")
    if re.search(r"Copy-Item\s+\$codexHookSrc\s+\$codexHookDest\s+-Force", builder_text):
        fail("Codex Stop hook installer: unconditional overwrite primitive remains")
    if re.search(r"Write-Utf8\s+-Path\s+\$codexJsonDest", builder_text):
        fail("Codex Stop hook installer: hooks.json retains a non-exclusive write path")


def check_gateway_lockstep() -> None:
    verifier = ROOT / "gates" / "gateway_lockstep.py"
    tests = ROOT / "gates" / "test_gateway_lockstep.py"
    cursor_hook = ROOT / "cursor" / "hooks" / "dreameros_cursor_hook.py"
    claude_settings = ROOT / "install" / "claude-code" / "payload" / "settings.fragment.json"
    claude_installer = ROOT / "install" / "claude-code" / "dreameros-global-setup.ps1"
    cursor_installer = ROOT / "install" / "cursor" / "install.ps1"
    required = (verifier, tests, cursor_hook, claude_settings, claude_installer, cursor_installer)
    if any(not path.is_file() for path in required):
        fail("Gateway Lockstep: required verifier, test, hook, or installer file is missing")
        return
    verifier_text = verifier.read_text(encoding="utf-8")
    required_constants = (
        "MAX_RECORD_BYTES", "INTENT_ENVELOPE_SCHEMA", "RECEIPT_EVENT_SCHEMA",
        "TERMINAL_STATES", "CLIENT_CAPABILITY_MATRIX", "MANAGED_ARTIFACTS",
        "HOOK_EVENT_ADAPTERS",
    )
    if any(constant not in verifier_text for constant in required_constants):
        fail("Gateway Lockstep: verifier lacks bounded terminal contract")
    if "extract_from_host_payload" not in cursor_hook.read_text(encoding="utf-8"):
        fail("Gateway Lockstep: Cursor post-MCP integration is missing")
    if "gateway_lockstep.py" not in claude_settings.read_text(encoding="utf-8"):
        fail("Gateway Lockstep: Claude Stop hook registration is missing")
    if "gates\\gateway_lockstep.py" not in claude_installer.read_text(encoding="utf-8"):
        fail("Gateway Lockstep: Claude installer does not install the shared verifier")
    if "'gates'" not in cursor_installer.read_text(encoding="utf-8"):
        fail("Gateway Lockstep: Cursor installer does not include the shared verifier")


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
    check_boot_source_floor()
    check_quote_evidence()
    check_cursor_project_pointer()
    check_project_adapters()
    check_skills()
    check_model_tiered_offload_mirror()
    check_life_of_intent_skill_mirrors()
    check_claude_payload_agents()
    check_cursor_plugin()
    check_cursor_component_name_uniqueness()
    check_cursor_portability()
    check_customer_copy_vocabulary()
    check_hydration_preconditions()
    check_codex_stop_hook()
    check_gateway_lockstep()
    check_house_rules()
    if FAILS:
        for f in FAILS:
            print(f"FAIL {f}")
        return 1
    print("PASS all conformance checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
