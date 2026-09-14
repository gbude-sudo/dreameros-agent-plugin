#!/usr/bin/env python3
"""Surface installed Codex skills whose own trigger phrases match a prompt.

This is a Codex-native port of Claude's skill-match guard. It names literal
matches but never claims that a skill ran. It scans user and project SKILL.md
frontmatter only. It does not scan sessions, caches, credentials, or repos.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tomllib

MAX_SKILLS = 6
MAX_FRONTMATTER_CHARS = 6000
INDEX_SCHEMA = "dreameros-codex-skill-trigger-index-v1"
AGENT_INDEX_SCHEMA = "dreameros-codex-agent-role-index-v1"
QUOTED_TRIGGER = re.compile(r"[\"']([^\"']{4,80})[\"']")
TRIGGER_LIST = re.compile(r"(?:also\s+)?(?:use|trigger|triggers|fires)\s+(?:this\s+)?(?:skill\s+)?(?:when|whenever|on|for)\s+(.+)", re.IGNORECASE)

def _description(frontmatter: str) -> str:
    lines = frontmatter.splitlines()
    for index, line in enumerate(lines):
        match = re.match(r"^description:\s*(.*)$", line)
        if not match:
            continue
        value = match.group(1).strip()
        if value in {">", ">-", ">+", "|", "|-", "|+"}:
            parts: list[str] = []
            for child in lines[index + 1:]:
                if child.startswith((" ", "\t")):
                    parts.append(child.strip())
                    continue
                break
            return " ".join(part for part in parts if part)
        return value.strip("\"'")
    return ""

def _clean_phrase(phrase: str) -> str:
    return phrase.replace('\\"', '"').replace("\\'", "'").strip().strip("\\\"'.,;:()[]{}")

def _acceptable(phrase: str) -> bool:
    cleaned = _clean_phrase(phrase)
    return 4 <= len(cleaned) <= 80 and (" " in cleaned or len(cleaned) >= 10)

def _trigger_phrases(description: str) -> list[str]:
    phrases = list(QUOTED_TRIGGER.findall(description))
    for match in TRIGGER_LIST.finditer(description):
        tail = re.split(r"\.\s+[A-Z]|\.$", match.group(1), maxsplit=1)[0]
        phrases.extend(part.strip() for part in tail.split(","))
    result: list[str] = []
    seen: set[str] = set()
    for phrase in phrases:
        cleaned = _clean_phrase(phrase)
        key = cleaned.casefold()
        if _acceptable(cleaned) and key not in seen:
            seen.add(key)
            result.append(cleaned)
    return result

def _skill_roots(payload: dict) -> list[Path]:
    override = os.environ.get("DREAMEROS_CODEX_SKILL_ROOTS")
    if override:
        return [Path(item) for item in override.split(os.pathsep) if item]
    roots = [Path.home() / ".codex" / "skills", Path.home() / ".agents" / "skills"]
    cwd = payload.get("cwd")
    if cwd:
        workspace = Path(str(cwd))
        roots.extend([workspace / ".codex" / "skills", workspace / ".agents" / "skills"])
    return roots

def _skill_records(roots: list[Path]) -> list[dict]:
    records: list[dict] = []
    seen: set[str] = set()
    for root in roots:
        if not root.is_dir():
            continue
        for directory in sorted(path for path in root.iterdir() if path.is_dir()):
            path = directory / "SKILL.md"
            if directory.name in seen or not path.is_file():
                continue
            seen.add(directory.name)
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            front = text[:MAX_FRONTMATTER_CHARS]
            if front.startswith("---"):
                closing = front.find("\n---", 3)
                if closing >= 0:
                    front = front[:closing + 4]
            description = _description(front)
            records.append({"name": directory.name, "source": str(path.resolve()), "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(), "automatic": "use this skill automatically" in description.casefold(), "triggers": _trigger_phrases(description)})
    return records

def _home_file(env_name: str, suffix: str) -> Path:
    override = os.environ.get(env_name)
    return Path(override) if override else Path.home() / ".codex" / suffix

def _agent_defaults() -> dict:
    try:
        parsed = tomllib.loads(_home_file("DREAMEROS_CODEX_CONFIG", "config.toml").read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError):
        return {}
    return parsed.get("agents") if isinstance(parsed.get("agents"), dict) else {}

def build_agent_index() -> dict:
    root = _home_file("DREAMEROS_CODEX_AGENT_ROOT", "agents")
    defaults = _agent_defaults()
    agents: list[dict] = []
    if root.is_dir():
        for path in sorted(root.glob("*.toml")):
            try:
                raw = path.read_bytes(); parsed = tomllib.loads(raw.decode("utf-8"))
            except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError):
                continue
            name = str(parsed.get("name") or "").strip(); description = str(parsed.get("description") or "").strip(); instructions = str(parsed.get("developer_instructions") or "").strip()
            if name and description and instructions:
                agents.append({"name": name, "source": str(path.resolve()), "sha256": hashlib.sha256(raw).hexdigest(), "description": description, "model": parsed.get("model") or defaults.get("default_subagent_model"), "reasoning_effort": parsed.get("model_reasoning_effort") or defaults.get("default_subagent_reasoning_effort")})
    return {"schema": AGENT_INDEX_SCHEMA, "source_root": str(root.resolve()), "agent_count": len(agents), "global_defaults": {"enabled": defaults.get("enabled", True), "max_concurrent_threads_per_session": defaults.get("max_concurrent_threads_per_session"), "default_subagent_model": defaults.get("default_subagent_model"), "default_subagent_reasoning_effort": defaults.get("default_subagent_reasoning_effort")}, "agents": agents}

def _index_path() -> Path: return _home_file("DREAMEROS_CODEX_SKILL_INDEX", "dreameros/SKILL_TRIGGER_INDEX.json")
def _agent_index_path() -> Path: return _home_file("DREAMEROS_CODEX_AGENT_INDEX", "dreameros/AGENT_ROLE_INDEX.json")
def build_index(payload: dict) -> dict:
    roots = _skill_roots(payload)
    records = _skill_records(roots)
    return {"schema": INDEX_SCHEMA, "source_roots": [str(path.resolve()) for path in roots], "skill_count": len(records), "skills": records}
def _write_json(path: Path, value: dict) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True); temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=True) + "\n", encoding="utf-8"); temporary.replace(path); return path
def write_index(payload: dict) -> Path: return _write_json(_index_path(), build_index(payload))
def write_agent_index() -> Path: return _write_json(_agent_index_path(), build_agent_index())

def startup_result(skill_path: Path, agent_path: Path) -> dict:
    skills = json.loads(skill_path.read_text(encoding="utf-8")); agents = json.loads(agent_path.read_text(encoding="utf-8"))
    return {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "\n".join(["DREAMEROS CODEX STARTUP: use the current Human Conductor request as the root intent.", "Read ~/.codex/dreameros/CONTROL_MANIFEST.json and select its exact read mode before substantive work.", f"Skill routes: {skill_path} ({skills.get('skill_count', 0)} indexed).", f"Agent routes: {agent_path} ({agents.get('agent_count', 0)} indexed).", "Load only matched skills, selected agents, applicable repository instructions, and named task files.", "For substantive DreamerOS work, call dreameros_session_package exactly once, then use conditional handoff, context, recall, and canon only when relevant.", "Measure changing state at its running source. Registration, files, tests, and deployment are not customer completion."])}}

def _indexed_records() -> list[dict]:
    try: parsed = json.loads(_index_path().read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError): return []
    records = parsed.get("skills") if parsed.get("schema") == INDEX_SCHEMA else []
    return records if isinstance(records, list) else []
def evaluate(payload: dict) -> dict | None:
    prompt = str(payload.get("prompt") or "").strip()
    if len(prompt) < 8: return None
    lowered = prompt.casefold(); hits: list[tuple[str, str]] = []
    for record in _indexed_records():
        name = str(record.get("name") or ""); phrases = record.get("triggers")
        if not name or not isinstance(phrases, list): continue
        match = (f"${name}" if f"${name}".casefold() in lowered else None) or ("automatic workflow" if record.get("automatic") else None) or next((phrase for phrase in phrases if phrase.casefold() in lowered), None)
        if match: hits.append((name, match))
        if len(hits) >= MAX_SKILLS: break
    if not hits: return None
    lines = ["DREAMEROS SKILL MATCH: the prompt matched an installed skill trigger or an automatic workflow. Load each applicable SKILL.md before acting, or state why it does not apply:"]
    lines.extend(f'  - {name} (matched "{phrase}")' for name, phrase in hits)
    return {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "\n".join(lines)}}

def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--build-index":
        try:
            skill_path = write_index({"cwd": os.getcwd()}); agent_path = write_agent_index(); print(json.dumps(startup_result(skill_path, agent_path), separators=(",", ":"))); return 0
        except Exception as error:
            print(f"skill index build failed: {error}", file=sys.stderr); return 1
    try:
        payload = json.load(sys.stdin)
        if isinstance(payload, dict):
            result = evaluate(payload)
            if result is not None: print(json.dumps(result, separators=(",", ":")))
    except Exception: return 0
    return 0
if __name__ == "__main__": raise SystemExit(main())
