#!/usr/bin/env python3
"""Validate Claude Code settings files before they can silently disable themselves.

WHY THIS EXISTS
2026-09-16. `fallbackModel` was written as a string in ~/.claude/settings.json.
The schema requires an array. Claude Code then skipped the WHOLE user settings
file with no visible error in the Desktop app: every hook, the deny list and
the env block were gone for about two weeks. Only a wrong-typed top-level
value does that. A bad single permission rule drops only itself.

WHAT IT CHECKS
For each settings file (user, project, local, managed) it reports:
  FILE-LEVEL  invalid JSON, or a top-level key whose type does not match the
              schema. Claude Code skips the entire file.
  ENTRY       a permissions.allow / deny / ask entry that does not match the
              schema's rule pattern. Claude Code skips that entry only.

It uses the vendored schema next to this file
(../dreameros/claude-code-settings.schema.json), so it needs no network and no
third-party package. When the `jsonschema` package is installed it also runs a
full validation and reports anything else it finds as ENTRY-level.

MODES
  CLI:          python validate_claude_settings.py [file ...]
                exit 1 when any FILE-LEVEL problem exists, else 0.
  SessionStart: run with --hook. Reads the hook payload on stdin, checks the
                user, project and managed files, and prints a systemMessage
                plus added context. Always exits 0: a broken file must be
                reported loudly, never turned into a blocked session.

ASCII only.
"""
from __future__ import annotations

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA_CANDIDATES = [
    # payload layout: payload/hooks + payload/dreameros/<schema>
    os.path.join(HERE, "..", "dreameros", "claude-code-settings.schema.json"),
    # installed layout: <managed dir>/dreameros/hooks + <managed dir>/dreameros/<schema>
    os.path.join(HERE, "..", "claude-code-settings.schema.json"),
    os.path.join(HERE, "claude-code-settings.schema.json"),
]

JSON_TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "boolean": bool,
    "number": (int, float),
    "integer": int,
    "null": type(None),
}


def load_schema():
    for path in SCHEMA_CANDIDATES:
        try:
            with open(path, encoding="utf-8") as fh:
                return json.load(fh)
        except (OSError, ValueError):
            continue
    return None


def _type_ok(value, type_spec) -> bool:
    types = type_spec if isinstance(type_spec, list) else [type_spec]
    for t in types:
        py = JSON_TYPES.get(t)
        if py is None:
            return True
        if t in ("number", "integer") and isinstance(value, bool):
            continue
        if isinstance(value, py):
            return True
    return False


def _allowed_types(prop: dict):
    """Top-level types a property accepts, or None when the schema does not say."""
    if "type" in prop:
        return prop["type"]
    for key in ("anyOf", "oneOf"):
        if key in prop:
            out = []
            for alt in prop[key]:
                if "type" not in alt:
                    return None
                t = alt["type"]
                out.extend(t if isinstance(t, list) else [t])
            return out
    return None


def _rule_pattern(schema):
    try:
        items = schema["properties"]["permissions"]["properties"]["allow"]["items"]
    except (KeyError, TypeError):
        return None
    pat = items.get("pattern")
    if not pat and "$ref" in items:
        ref = items["$ref"].rsplit("/", 1)[-1]
        pat = (schema.get("definitions") or schema.get("$defs") or {}).get(ref, {}).get("pattern")
    try:
        return re.compile(pat) if pat else None
    except re.error:
        return None


def check_data(data, schema):
    """Return (file_level, entry_level) lists of problem strings."""
    file_level, entry_level = [], []
    if not isinstance(data, dict):
        return ["top level is not a JSON object"], []
    props = (schema or {}).get("properties", {})
    for key, value in data.items():
        prop = props.get(key)
        if prop is None:
            continue
        allowed = _allowed_types(prop)
        if allowed is not None and not _type_ok(value, allowed):
            file_level.append(
                f"{key}: has type {type(value).__name__}, schema requires {allowed}"
            )
    pattern = _rule_pattern(schema or {})
    perms = data.get("permissions")
    if isinstance(perms, dict) and pattern is not None:
        for list_name in ("allow", "deny", "ask"):
            for i, rule in enumerate(perms.get(list_name) or []):
                if isinstance(rule, str) and not pattern.match(rule):
                    entry_level.append(f"permissions.{list_name}[{i}] {rule!r} does not match the rule pattern")
    if not file_level:
        try:
            import jsonschema  # optional
            validator = jsonschema.Draft7Validator(schema)
            for err in validator.iter_errors(data):
                path = list(err.path)
                if path[:1] == ["permissions"] and len(path) == 3:
                    continue
                entry_level.append(f"{'.'.join(map(str, path)) or '(root)'}: {err.message[:120]}")
        except ImportError:
            pass
        except Exception as exc:  # a broken optional check must not hide the result
            entry_level.append(f"jsonschema check could not run: {exc}")
    return file_level, entry_level


def check_file(path, schema):
    try:
        with open(path, encoding="utf-8-sig") as fh:
            raw = fh.read()
    except FileNotFoundError:
        return None
    except OSError as exc:
        return [f"cannot read: {exc}"], []
    try:
        data = json.loads(raw)
    except ValueError as exc:
        return [f"invalid JSON: {exc}"], []
    return check_data(data, schema)


def settings_paths(cwd):
    home = os.path.expanduser("~")
    paths = [
        ("user", os.path.join(home, ".claude", "settings.json")),
        ("user-local", os.path.join(home, ".claude", "settings.local.json")),
    ]
    if cwd:
        paths += [
            ("project", os.path.join(cwd, ".claude", "settings.json")),
            ("project-local", os.path.join(cwd, ".claude", "settings.local.json")),
        ]
    if os.name == "nt":
        paths.append(("managed", r"C:\Program Files\ClaudeCode\managed-settings.json"))
    elif sys.platform == "darwin":
        paths.append(("managed", "/Library/Application Support/ClaudeCode/managed-settings.json"))
    else:
        paths.append(("managed", "/etc/claude-code/managed-settings.json"))
    return paths


def run_hook():
    try:
        raw = sys.stdin.buffer.read().lstrip(b"\xef\xbb\xbf").strip()
        payload = json.loads(raw.decode("utf-8", "replace")) if raw else {}
    except Exception:
        payload = {}
    schema = load_schema()
    if schema is None:
        msg = "Settings check could not run: the bundled schema file is missing."
        print(json.dumps({"systemMessage": msg}))
        return 0
    broken, faults = [], []
    for label, path in settings_paths(payload.get("cwd") or os.getcwd()):
        res = check_file(path, schema)
        if res is None:
            continue
        fl, el = res
        broken += [f"{label} ({path}): {p}" for p in fl]
        faults += [f"{label}: {p}" for p in el]
    if not broken and not faults:
        return 0
    lines = []
    if broken:
        lines.append("SETTINGS FILE SKIPPED BY CLAUDE CODE. These files have a file-level error, "
                     "so every hook, permission and env value in them is OFF right now:")
        lines += ["  " + b for b in broken]
    if faults:
        lines.append(f"{len(faults)} single entries are ignored (the rest of the file still loads):")
        lines += ["  " + f for f in faults[:10]]
    text = "\n".join(lines)
    out = {
        "systemMessage": ("Settings check: FILE SKIPPED - " if broken else "Settings check: ") + text.splitlines()[0],
        "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text},
    }
    print(json.dumps(out))
    return 0


def run_cli(paths):
    schema = load_schema()
    if schema is None:
        print("schema file missing; cannot validate", file=sys.stderr)
        return 2
    if not paths:
        paths = [p for _, p in settings_paths(os.getcwd())]
    bad = False
    for path in paths:
        res = check_file(path, schema)
        if res is None:
            continue
        fl, el = res
        status = "FILE SKIPPED" if fl else ("ENTRY FAULTS" if el else "OK")
        print(f"{status}: {path}")
        for p in fl:
            print(f"  file-level: {p}")
        for p in el:
            print(f"  entry: {p}")
        bad = bad or bool(fl)
    return 1 if bad else 0


if __name__ == "__main__":
    if "--hook" in sys.argv[1:]:
        sys.exit(run_hook())
    sys.exit(run_cli([a for a in sys.argv[1:] if not a.startswith("--")]))
