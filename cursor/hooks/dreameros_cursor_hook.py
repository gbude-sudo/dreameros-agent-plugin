"""Cursor-native DreamerOS boot and authority gate.

The hook never stores prompts, commands, MCP inputs, credentials, or response
bodies. It records only an event name and the permission it returned so a
loaded hook can be distinguished from a hook that never fired.
"""

from __future__ import annotations

import datetime as dt
from contextlib import contextmanager
import hashlib
import json
import locale
import os
import re
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


PLUGIN_ROOT = Path(__file__).resolve().parents[2]
if str(PLUGIN_ROOT) not in sys.path:
    sys.path.insert(0, str(PLUGIN_ROOT))

from gates.gateway_lockstep import extract_from_host_payload


STATE_ROOT = Path(os.environ.get("DREAMEROS_CURSOR_STATE_DIR") or (Path.home() / ".cursor" / "dreameros"))
TRANSCRIPT_ROOT = Path(os.environ.get("DREAMEROS_CURSOR_TRANSCRIPT_ROOT") or (Path.home() / ".cursor" / "projects"))
SIGNATURE_LOG = STATE_ROOT / "hook-signatures.jsonl"
BOOT_STATE_FILE = STATE_ROOT / "boot-state.json"
SELF_TEST_CASE_FLOOR = 219
DREAMEROS_MCP_URL = "https://mcp.dreameros.app/mcp"
ALLOWED_DREAMEROS_MCP_SERVERS = {"dreameros-platform"}
PARITY_HEALTH_SUBAGENTS = {
    "dreameros-platform-canon-citer",
    "dreameros-platform-governance-node",
}
PARITY_HEALTH_TASK_MARKERS = (
    "cursor/mcp.json names dreameros-platform and has no headers",
    "Review the first CURSOR_PARITY block only",
)
PARITY_CORE_SENTINEL = 'Write-Output "DREAMEROS_PARITY_CORE_BLOCK_EMITTED"'
BOOT_SEQUENCE = ("dreameros_session_package",)
BOOT_PENDING_MAX_SECONDS = 120
BOOT_STATE_MAX_AGE_SECONDS = 86400
BOOT_STATE_LOCK_TIMEOUT_SECONDS = 2.0
BOOT_STATE_LOCK_STALE_SECONDS = 10.0
# Release-bound fields checked again by the detached gateway composition probe.
SESSION_PACKAGE_VERSION = "v7.3.0-composed"
HANDOFF_PROJECTION_MAX_CHARS = 1600

BOOT_CONTEXT = """DreamerOS Cursor boot: dreameros_session_package is the only required boot call. Call it first. It carries the full Boot Canon and a handoff summary. Accept a package only when its canonical UTC composed_at plus integer ttl_seconds (1 through 3600) is fresh with no more than 60 seconds of clock skew; an optional expires_at is not alternate authority. When the package directs it or the assigned task needs read-only enrichment, call in this order: dreameros_session_handoff_read for the full record when present, dreameros_context and use its SCS as the read-only current-state channel, scoped dreameros_recall, then relevant dreameros_canon. If metadata-first package_continuation is present, the agent must fetch parts 1 through N with the same tool, verify per-part hashes, order, user-bound package_id/content_hash, reassemble, and verify the full wrapper/body hash before proceeding. This raw hook can validate only the complete result it receives; failed reconstruction is BLOCKED. Match the package engine to the active model family; if Cursor does not expose it, request neutral Markdown with engine=chatgpt and identify client=cursor in project_context. Read the repository AGENTS.md, CLAUDE.md, nested instructions, current handoff, deployment guide, and Git state. Use local files and tests for execution. Report CONNECTED, PARTIALLY CONNECTED, or BLOCKED. Preserve parallel work and secret values. Do not branch, commit, push, merge, deploy, publish, sign, change credentials, incur explicit paid verification depth, or touch production without current Human Conductor authority. At close, verify the diff and checks, persist a concise DreamerOS handoff, and read it back."""

DESTRUCTIVE_SHELL = (
    r"\bgit\s+reset\s+--hard\b",
    r"\bgit\s+clean\b(?=[^\r\n]*(?:-[^\s]*f|--force)\b)",
    r"\bgit\s+checkout\s+--\s",
    r"\bgit\s+checkout\b(?=[^\r\n]*(?:-[^\s]*f|--force)\b)",
    r"\bgit\s+restore\b",
    r"\bgit\s+branch\b(?=[^\r\n]*(?:-d\b|--delete\b))",
    r"\brm(?:\.exe)?\b",
    r"\bcmd(?:\.exe)?\s+/c\s+[\"']?(?:del|erase|rd|rmdir)\b",
    r"(?:^|[;&|]\s*)(?:del|erase|rd|rmdir)\b",
    r"\bremove-item\b",
    r"\b(?:shred|clear-content|clear-disk|initialize-disk|diskpart)\b",
    r"\bformat(?:\.com)?\s+[a-z]:",
    r"\bdocker\s+(?:system|volume|image|container)\s+(?:prune|rm)\b",
    r"\bfind\b(?=[^\r\n]*(?:-delete|--delete)\b)",
    r"\b(?:drop|truncate)\s+(?:table|database|schema)\b",
    r"\bdelete\s+from\b",
)

AUTHORITY_SHELL = (
    r"\bgit\s+(?:commit|merge|rebase|cherry-pick|tag|stash)\b",
    r"\bgit\s+(?:switch\s+-c|checkout\s+-b|branch\s+[^-\s])",
    r"\bgit\s+push\b",
    r"\bgh\s+pr\s+(?:create|merge|close|reopen|review|comment|edit|ready)\b",
    r"\bgh\s+issue\s+(?:create|close|reopen|edit|comment)\b",
    r"\bgh\s+(?:release|secret|variable)\b",
    r"\bgh\s+workflow\s+(?:run|enable|disable)\b",
    r"\bgh\s+run\s+(?:rerun|cancel|delete)\b",
    r"\bgh\s+repo\s+(?:create|delete|edit|fork|rename|archive)\b",
    r"\bgh\s+api\b(?=[^\r\n]*(?:-x|--method)(?:\s+|=)(?:post|put|patch|delete)\b)",
    r"\bgh\s+api\b(?=[^\r\n]*(?:\s-[fF](?:\s|=)|\s--(?:raw-)?field(?:\s|=)))",
    r"\brailway\s+(?:up|deploy|variables)\b",
    r"\bvercel\b(?=[^\r\n]*(?:deploy|--prod|--yes)\b)",
    r"\bterraform\s+(?:apply|destroy)\b",
    r"\bkubectl\s+(?:apply|create|delete|edit|patch|replace|scale|set|annotate|label|taint|drain|cordon|uncordon)\b",
    r"\bkubectl\s+rollout\s+(?:restart|undo|pause|resume)\b",
    r"\bkubectl\s+auth\s+reconcile\b",
    r"\b(?:npm|pnpm|yarn)\s+publish\b",
    r"\btwine\s+upload\b",
    r"\b(?:curl|curl\.exe)\b(?=[^\r\n]*(?:-x|--request)\s*(?:post|put|patch|delete)\b)",
    r"\b(?:curl|curl\.exe)\b(?=[^\r\n]*(?:--data\S*|--form\S*|--upload-file|--json)\b)",
    r"\binvoke-(?:webrequest|restmethod)\b(?=[^\r\n]*-(?:m|me|met|meth|metho|method)(?:\s+|:|=)(?:post|put|patch|delete)\b)",
    r"(?:^|\s)(?:iwr|irm)\b(?=[^\r\n]*-(?:m|me|met|meth|metho|method)(?:\s+|:|=)(?:post|put|patch|delete)\b)",
    r"\binvoke-(?:webrequest|restmethod)\b(?=[^\r\n]*-custommethod(?:\s+|:|=)(?:post|put|patch|delete)\b)",
    r"(?:^|\s)(?:iwr|irm)\b(?=[^\r\n]*-custommethod(?:\s+|:|=)(?:post|put|patch|delete)\b)",
    r"\b(?:pip|pip3)\s+install\b",
    r"\b(?:npm|pnpm|yarn)\s+(?:install|add|remove|uninstall)\s+-g\b",
    r"\b(?:winget|choco|brew)\s+(?:install|uninstall)\b",
)

SAFE_SHELL = (
    r"\s*git\s+status\b[^\r\n]*",
    r"\s*git\s+(?:rev-parse|merge-base)\b[^\r\n]*",
    r"\s*git\s+branch\s+--show-current\s*",
    r"\s*git\s+worktree\s+list\b[^\r\n]*",
    r"\s*(?:where|which|get-command)\b[^\r\n]*",
)

SAFE_DREAMEROS_TOOLS = {
    "dreameros_canon",
    "dreameros_chat",
    "dreameros_check_connection_health",
    "dreameros_context",
    "dreameros_conversations",
    "dreameros_get_receipt",
    "dreameros_govern",
    "dreameros_intent_clarify",
    "dreameros_list_connections",
    "dreameros_manifest",
    "dreameros_memory_full",
    "dreameros_observe",
    "dreameros_railway",
    "dreameros_recall",
    "dreameros_remember",
    "dreameros_route",
    "dreameros_session_handoff_read",
    "dreameros_session_package",
    "dreameros_slop_check",
}

SENSITIVE_PATH_RE = re.compile(
    r"(?:^|[\\/\s\"'])"
    r"(?:\.env(?:\.[^\\/\s\"']+)?|id_(?:rsa|ed25519|ecdsa)|"
    r"credentials(?:\.json)?|secrets?(?:\.json)?|service-account\.json|[^\\/\s\"']+\.ppk|"
    r"\.git-credentials|\.netrc|\.npmrc|\.pypirc)"
    r"(?:$|[\\/\s\"'])|[\\/]\.aws[\\/]credentials\b|"
    r"[\\/]\.ssh[\\/]id_(?:rsa|ed25519|ecdsa)\b|\benv:",
    re.IGNORECASE,
)

PROVIDER_CREDENTIAL_PATH_RE = re.compile(
    r"[\\/]\.docker[\\/]config\.json\b|[\\/]\.kube[\\/]config\b|"
    r"[\\/]\.config[\\/]gcloud[\\/](?:application_default_credentials\.json|credentials\.db)\b",
    re.IGNORECASE,
)

SENSITIVE_VALUE_RE = re.compile(
    r"dros_[A-Za-z0-9]{8,}|sk-[A-Za-z0-9_-]{20,}|"
    r"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|"
    r"(?:AKIA|ASIA)[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{30,}|xox[baprs]-[A-Za-z0-9-]{20,}|"
    r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|"
    r"(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|private[_-]?key)"
    r"\s*[:=]\s*[\"']?[A-Za-z0-9_./+:-]{16,}[\"']?|"
    r"Bearer\s+[A-Za-z0-9._-]{20,}|"
    r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----|"
    r"-----BEGIN PGP PRIVATE KEY BLOCK-----",
    re.IGNORECASE,
)

SENSITIVE_ENV_RE = re.compile(
    r"\$(?:env:)?[A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|PRIVATE_KEY|API_KEY|CREDENTIAL)[A-Za-z0-9_]*|"
    r"%[A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|PRIVATE_KEY|API_KEY|CREDENTIAL)[A-Za-z0-9_]*%",
    re.IGNORECASE,
)

SECRET_ASSIGNMENT_RE = re.compile(
    r"[\"']?(api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|"
    r"password|private[_-]?key|auth|aws_secret_access_key|"
    r"client-certificate-data|client-key-data)[\"']?\s*[:=]\s*[\"']?"
    r"([^\"'\r\n,}]{4,})",
    re.IGNORECASE,
)

PLACEHOLDER_VALUE_RE = re.compile(
    r"(?:redacted|placeholder|example|dummy|changeme|your[_-]|"
    r"os\.getenv|process\.env|getenv\(|env\[|\$\{|<[^>]+>|"
    r"^(?:none|null|true|false)$)",
    re.IGNORECASE,
)

PUTTY_PRIVATE_KEY_RE = re.compile(
    r"PuTTY-User-Key-File-[23]:[^\r\n]*[\s\S]*?^Private-Lines:\s*\d+\s*$",
    re.IGNORECASE | re.MULTILINE,
)


def _event(payload: dict[str, Any]) -> str:
    for key in ("hook_event_name", "hookEventName", "event", "eventName"):
        value = payload.get(key)
        if value:
            return str(value)
    return "unknown"


def _parse_hook_payload(raw: bytes) -> dict[str, Any]:
    """Decode Cursor hook stdin without trusting the Windows shell encoding.

    Cursor invokes command hooks through the configured Windows shell. Depending
    on that shell, the same JSON object can arrive as UTF-8, UTF-16, or the
    active Windows code page. Parsing ``sys.stdin.read()`` first applies
    Python's console encoding and can turn valid UTF-16 JSON into a string with
    interleaved NULs. Parse bytes first so ``json`` can detect UTF-16/UTF-32,
    then use a small explicit fallback set for code-page text. No fallback
    removes bytes or extracts a partial object; undecodable input stays denied.
    """

    if not isinstance(raw, (bytes, bytearray)):
        raise TypeError("hook input must be bytes")
    data = bytes(raw)
    if not data.strip(b"\x00\x09\x0a\x0d\x20"):
        return {}

    missing = object()
    parsed: Any = missing
    try:
        parsed = json.loads(data)
    except (json.JSONDecodeError, UnicodeDecodeError):
        encodings = (
            sys.stdin.encoding,
            locale.getpreferredencoding(False),
            "utf-8-sig",
            "utf-16",
            "utf-16-le",
            "utf-16-be",
            "utf-32",
            "utf-32-le",
            "utf-32-be",
            "cp1252",
        )
        tried: set[str] = set()
        for candidate in encodings:
            if not candidate:
                continue
            normalized = candidate.lower().replace("_", "-")
            if normalized in tried:
                continue
            tried.add(normalized)
            try:
                text = data.decode(candidate).lstrip("\ufeff")
                parsed = json.loads(text)
                break
            except (LookupError, UnicodeDecodeError, json.JSONDecodeError):
                parsed = missing

    if parsed is missing:
        raise ValueError("hook input is not decodable JSON")
    if not isinstance(parsed, dict):
        raise ValueError("hook input must be a JSON object")
    return parsed


def _alias_fingerprint(payload: dict[str, Any], keys: tuple[str, ...]) -> str:
    values = [str(payload[key]) for key in keys if payload.get(key) not in (None, "")]
    if not values:
        return "unavailable"
    unique_values = set(values)
    if len(unique_values) != 1:
        return "conflict"
    return hashlib.sha256(values[0].encode("utf-8")).hexdigest()[:24]


def _session_fingerprint(payload: dict[str, Any]) -> str:
    return _alias_fingerprint(
        payload,
        ("session_id", "sessionId", "conversation_id", "conversationId", "chat_id", "chatId", "thread_id", "threadId"),
    )


def _subagent_fingerprint(payload: dict[str, Any]) -> str:
    values = [str(payload[key]) for key in ("subagent_id", "subagentId") if payload.get(key) not in (None, "")]
    if not values:
        return "unavailable"
    unique_values = set(values)
    if len(unique_values) != 1:
        return "conflict"
    return hashlib.sha256(f"subagent:{values[0]}".encode("utf-8")).hexdigest()[:24]


def _boot_fingerprint(payload: dict[str, Any]) -> str:
    """Resolve the independent boot gate that owns this event.

    Cursor subagent calls carry ``subagent_id``. When either supported alias is
    present, never fall back to the parent conversation because a missing or
    conflicting subagent id must not borrow the parent's hydrated state.
    """

    if any(key in payload for key in ("subagent_id", "subagentId")):
        return _subagent_fingerprint(payload)
    return _session_fingerprint(payload)


def _generation_fingerprint(payload: dict[str, Any]) -> str:
    return _alias_fingerprint(payload, ("generation_id", "generationId"))


def _invocation_fingerprint(payload: dict[str, Any]) -> str:
    values = [
        str(payload[key])
        for key in ("tool_use_id", "toolUseId", "tool_call_id", "toolCallId", "subagent_id", "subagentId")
        if payload.get(key) not in (None, "")
    ]
    if not values:
        return "unavailable"
    unique_values = set(values)
    if len(unique_values) != 1:
        return "conflict"
    return hashlib.sha256(f"invocation:{values[0]}".encode("utf-8")).hexdigest()[:24]


def _is_parity_health_launch(payload: dict[str, Any]) -> bool:
    subagent_type = str(payload.get("subagent_type") or payload.get("subagentType") or "")
    task = str(payload.get("task") or payload.get("prompt") or "")
    return subagent_type in PARITY_HEALTH_SUBAGENTS and any(marker in task for marker in PARITY_HEALTH_TASK_MARKERS)


def _parity_core_block_visible(payload: dict[str, Any]) -> bool:
    """Require the core block in an earlier standalone assistant message.

    The Task prompt itself can contain a proposed block. That is not visible
    evidence. Ignore any assistant transcript line that also launches a Task.
    """

    raw_path = str(payload.get("transcript_path") or payload.get("transcriptPath") or "")
    if not raw_path:
        return False
    try:
        root = TRANSCRIPT_ROOT.resolve()
        transcript = Path(raw_path).resolve()
        if root not in transcript.parents or transcript.suffix.lower() != ".jsonl" or not transcript.is_file():
            return False
        if transcript.stat().st_size > 64 * 1024 * 1024:
            return False
        with transcript.open("r", encoding="utf-8") as handle:
            for line in handle:
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if entry.get("role") != "assistant":
                    continue
                content = entry.get("message", {}).get("content", [])
                if not isinstance(content, list):
                    continue
                if any(
                    isinstance(item, dict) and item.get("type") == "tool_use" and item.get("name") == "Task"
                    for item in content
                ):
                    continue
                texts = [
                    str(item.get("text") or "")
                    for item in content
                    if isinstance(item, dict) and item.get("type") == "text"
                ]
                visible = "\n".join(texts)
                if (
                    "CURSOR_PARITY v1" in visible
                    and "payload=" in visible
                    and "subagents=DISCOVERED" in visible
                    and "overall=" in visible
                ):
                    return True
    except (OSError, TypeError, ValueError):
        return False
    return False


def _mark_parity_core_emitted(payload: dict[str, Any]) -> bool:
    fingerprint = _session_fingerprint(payload)
    if fingerprint in {"unavailable", "conflict"}:
        return False
    try:
        with _boot_state_lock():
            states = _load_boot_states()
            entry = states["sessions"].get(fingerprint)
            if not isinstance(entry, dict):
                return False
            entry["parity_core_emitted"] = True
            entry["updated"] = _now_epoch()
            return _save_boot_states(states)
    except (OSError, TimeoutError):
        return False


def _parity_core_marker_set(payload: dict[str, Any]) -> bool:
    fingerprint = _session_fingerprint(payload)
    if fingerprint in {"unavailable", "conflict"}:
        return False
    try:
        with _boot_state_lock():
            entry = _load_boot_states()["sessions"].get(fingerprint)
            return isinstance(entry, dict) and entry.get("parity_core_emitted") is True
    except (OSError, TimeoutError):
        return False


def _now_epoch() -> float:
    return dt.datetime.now(dt.timezone.utc).timestamp()


@contextmanager
def _boot_state_lock():
    """Serialize cross-process read-modify-write operations on boot-state.json."""

    BOOT_STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    lock_path = BOOT_STATE_FILE.with_name(f"{BOOT_STATE_FILE.name}.lock")
    deadline = time.monotonic() + BOOT_STATE_LOCK_TIMEOUT_SECONDS
    descriptor: int | None = None
    while descriptor is None:
        try:
            descriptor = os.open(str(lock_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(descriptor, f"{os.getpid()}\n".encode("ascii"))
        except PermissionError:
            # Windows can report a just-deleted lock file as temporarily
            # access-denied while the directory entry is delete-pending.
            # Treat that state as contention and keep the same bounded,
            # fail-closed acquisition deadline.
            if time.monotonic() >= deadline:
                raise TimeoutError("DreamerOS boot-state lock timed out")
            time.sleep(0.01)
        except FileExistsError:
            try:
                stale = time.time() - lock_path.stat().st_mtime > BOOT_STATE_LOCK_STALE_SECONDS
            except OSError:
                stale = False
            if stale:
                try:
                    lock_path.unlink()
                    continue
                except OSError:
                    pass
            if time.monotonic() >= deadline:
                raise TimeoutError("DreamerOS boot-state lock timed out")
            time.sleep(0.01)
    try:
        yield
    finally:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            lock_path.unlink()
        except OSError:
            pass


def _load_boot_states() -> dict[str, Any]:
    try:
        parsed = json.loads(BOOT_STATE_FILE.read_text(encoding="utf-8"))
        if parsed.get("version") != 1 or not isinstance(parsed.get("sessions"), dict):
            return {"version": 1, "sessions": {}}
        return parsed
    except (OSError, json.JSONDecodeError, AttributeError):
        return {"version": 1, "sessions": {}}


def _save_boot_states(states: dict[str, Any]) -> bool:
    try:
        BOOT_STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        now = _now_epoch()
        sessions = states.setdefault("sessions", {})
        for key in list(sessions):
            updated = float(sessions[key].get("updated", 0)) if isinstance(sessions[key], dict) else 0
            if now - updated > BOOT_STATE_MAX_AGE_SECONDS:
                sessions.pop(key, None)
        temporary = BOOT_STATE_FILE.with_name(f"{BOOT_STATE_FILE.name}.{os.getpid()}.tmp")
        temporary.write_text(json.dumps(states, separators=(",", ":")), encoding="utf-8")
        temporary.replace(BOOT_STATE_FILE)
        return True
    except (OSError, TypeError, ValueError):
        return False


def _initialize_boot_state_for(payload: dict[str, Any], fingerprint: str) -> bool:
    if fingerprint in {"unavailable", "conflict"}:
        return False
    try:
        with _boot_state_lock():
            states = _load_boot_states()
            states["sessions"][fingerprint] = {
                "step": 0,
                "pending": None,
                "generation": _generation_fingerprint(payload),
                "updated": _now_epoch(),
            }
            return _save_boot_states(states)
    except (OSError, TimeoutError):
        return False


def _ensure_boot_state(payload: dict[str, Any]) -> bool:
    """Create the gate on the first prompt when Cursor lazy-loads the plugin."""

    fingerprint = _session_fingerprint(payload)
    if fingerprint in {"unavailable", "conflict"}:
        return False
    try:
        with _boot_state_lock():
            states = _load_boot_states()
            if isinstance(states["sessions"].get(fingerprint), dict):
                return True
            states["sessions"][fingerprint] = {
                "step": 0,
                "pending": None,
                "generation": _generation_fingerprint(payload),
                "updated": _now_epoch(),
            }
            return _save_boot_states(states)
    except (OSError, TimeoutError):
        return False


def _initialize_boot_state(payload: dict[str, Any]) -> bool:
    return _initialize_boot_state_for(payload, _session_fingerprint(payload))


def _initialize_subagent_boot_state(payload: dict[str, Any]) -> bool:
    return _initialize_boot_state_for(payload, _subagent_fingerprint(payload))


def _canonical_tool(payload: dict[str, Any]) -> str:
    return str(payload.get("tool_name") or "").lower().replace(".", "_").split("__")[-1]


def _boot_before_mcp(payload: dict[str, Any], canonical_tool: str, params: dict[str, Any]) -> dict[str, Any] | None:
    fingerprint = _boot_fingerprint(payload)
    if fingerprint in {"unavailable", "conflict"}:
        return _permission("deny", "DreamerOS blocked the MCP call because Cursor did not provide one stable conversation or subagent id.")
    try:
        with _boot_state_lock():
            states = _load_boot_states()
            entry = states["sessions"].get(fingerprint)
            if not isinstance(entry, dict):
                return _permission("deny", "DreamerOS boot state is missing for this conversation. Start a fresh Agent chat and require sessionStart or beforeSubmitPrompt bootstrap proof.")
            pending = entry.get("pending")
            if pending and _now_epoch() - float(entry.get("updated", 0)) > BOOT_PENDING_MAX_SECONDS:
                entry["pending"] = None
                pending = None
            step = int(entry.get("step", 0))
            if step >= len(BOOT_SEQUENCE):
                return None
            expected = BOOT_SEQUENCE[step]
            if pending:
                return _permission("deny", f"DreamerOS is waiting for the post-MCP result hook to verify {pending} before another MCP call.")
            if not canonical_tool.endswith(expected):
                return _permission("deny", f"DreamerOS boot order requires {expected} before {canonical_tool or 'this tool'}.")
            entry["pending"] = expected
            entry["generation"] = _generation_fingerprint(payload)
            entry["updated"] = _now_epoch()
            if not _save_boot_states(states):
                return _permission("deny", "DreamerOS could not persist the boot gate state, so it refused to fail open.")
            return None
    except (OSError, TimeoutError):
        return _permission("deny", "DreamerOS could not lock the boot gate state, so it refused to fail open.")


def _mcp_result_succeeded(payload: dict[str, Any]) -> bool:
    raw = payload.get("result_json")
    if raw in (None, ""):
        raw = payload.get("tool_output")
    parsed: Any = raw
    for _ in range(2):
        if not isinstance(parsed, str) or not parsed.strip():
            break
        try:
            parsed = json.loads(parsed)
        except json.JSONDecodeError:
            return False
    if parsed in (None, ""):
        return False
    if isinstance(parsed, dict):
        if parsed.get("isError") is True or parsed.get("error") not in (None, "", False):
            return False
        if parsed.get("exitCode") not in (None, 0):
            return False
    return True


def _normalized_boot_text(value: str) -> str:
    return value.replace("\r\n", "\n").replace("\r", "\n")


def _is_lower_sha256(value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def _has_exact_keys(value: Any, expected: set[str]) -> bool:
    return isinstance(value, dict) and set(value) == expected


def _valid_positive_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def _validate_part_descriptors(parts: Any, part_count: int, expected_text: str) -> bool:
    """Recompute each ordered descriptor against its exact text slice."""
    if not isinstance(parts, list) or len(parts) != part_count or not isinstance(expected_text, str):
        return False
    offset = 0
    for index, descriptor in enumerate(parts, start=1):
        if not _has_exact_keys(descriptor, {"part", "chars", "sha256"}):
            return False
        chars = descriptor.get("chars")
        if descriptor.get("part") != index or not _valid_positive_int(chars) or chars > 12000:
            return False
        declared_hash = descriptor.get("sha256")
        if not _is_lower_sha256(declared_hash):
            return False
        end = offset + chars
        part_text = expected_text[offset:end]
        if len(part_text) != chars or hashlib.sha256(part_text.encode("utf-8")).hexdigest() != declared_hash:
            return False
        offset = end
    return offset == len(expected_text)


def _package_is_fresh(package: dict[str, Any]) -> bool:
    """Require the signed composition timestamp and TTL, never a loose expiry."""
    try:
        composed = package.get("composed_at")
        ttl = package.get("ttl_seconds")
        if (
            not isinstance(composed, str)
            or re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)", composed) is None
            or type(ttl) is not int
            or not 1 <= ttl <= 3600
        ):
            return False
        issued = dt.datetime.fromisoformat(composed[:-1] + "+00:00" if composed.endswith("Z") else composed)
        if issued.tzinfo is None or issued.utcoffset() != dt.timedelta(0):
            return False
        now = dt.datetime.now(dt.timezone.utc)
        skew = dt.timedelta(seconds=60)
        if issued > now + skew:
            return False
        if now > issued + dt.timedelta(seconds=ttl) + skew:
            return False
        return True
    except (TypeError, ValueError, OverflowError):
        return False


def _validate_session_package_result(payload: dict[str, Any]) -> tuple[bool, str]:
    """Accept only a complete, fresh, self-consistent boot-canon package result."""
    raw = payload.get("result_json")
    if raw in (None, ""):
        raw = payload.get("tool_output")
    if isinstance(raw, str) and "auth required" in raw.lower():
        return False, "auth-required result"
    try:
        result = json.loads(raw) if isinstance(raw, str) else raw
    except json.JSONDecodeError:
        return False, "malformed MCP result"
    if not isinstance(result, dict) or result.get("isError") is True or result.get("error") not in (None, "", False):
        return False, "error MCP result"
    content = result.get("content")
    if not isinstance(content, list) or len(content) != 1 or not isinstance(content[0], dict):
        return False, "empty or duplicate MCP content"
    block = content[0]
    package_json = block.get("text") if block.get("type") == "text" else None
    if not isinstance(package_json, str) or not package_json.strip() or "auth required" in package_json.lower():
        return False, "missing or auth-required package text"
    try:
        package = json.loads(package_json)
    except json.JSONDecodeError:
        return False, "malformed package text"
    if not isinstance(package, dict) or not _package_is_fresh(package):
        return False, "missing or expired package metadata"
    if package.get("version") != SESSION_PACKAGE_VERSION:
        return False, "unexpected session package version"
    components = package.get("package_components")
    component = components.get("boot_canon") if isinstance(components, dict) else None
    component_keys = {
        "tokens", "schema_version", "version", "sha256", "hash_normalization",
        "canary_ids", "source_provenance", "continuation", "portable_chars", "summary",
    }
    if not _has_exact_keys(component, component_keys) or component.get("schema_version") != "dreameros-session-package-stable-prefix-v1":
        return False, "missing or malformed boot-canon component"
    version = component.get("version")
    sha256 = component.get("sha256")
    provenance = component.get("source_provenance")
    canary_ids = component.get("canary_ids")
    if not isinstance(version, str) or not re.fullmatch(r"v\d+\.\d+\.\d+", version):
        return False, "missing boot-canon version"
    if not _is_lower_sha256(sha256):
        return False, "missing boot-canon sha256"
    if not _has_exact_keys(provenance, {"repository", "path", "generator"}) or provenance != {
        "repository": "gbude-sudo/dreameros-agent-plugin",
        "path": "bootpack/SOURCE-dreameros-boot-canon.md",
        "generator": "bootpack/build-boot-pack.ps1",
    }:
        return False, "missing or mismatched boot-canon provenance"
    if (
        component.get("hash_normalization") != "LF"
        or not isinstance(component.get("tokens"), int)
        or component["tokens"] < 0
        or not _valid_positive_int(component.get("portable_chars"))
        or not isinstance(component.get("summary"), str)
        or not component["summary"].strip()
        or not isinstance(canary_ids, list)
        or len(canary_ids) != len(set(canary_ids))
        or not all(isinstance(canary, str) and canary for canary in canary_ids)
        or not {"R1", "R26", "R27", "HC-DEFINITION-OF-DONE"}.issubset(set(canary_ids))
    ):
        return False, "missing boot-canon normalization or canary metadata"

    package_text = package.get("package_text")
    if not isinstance(package_text, str) or "auth required" in package_text.lower():
        return False, "missing or auth-required package wrapper"
    normalized_package_text = _normalized_boot_text(package_text)
    if package_text != normalized_package_text:
        return False, "package text is not LF normalized"
    openings = re.findall(r"<dreameros_boot_canon\b[^>]*>", package_text)
    closings = re.findall(r"</dreameros_boot_canon>", package_text)
    wrappers = list(re.finditer(
        r"<dreameros_boot_canon\b(?P<attrs>[^>]*)>(?P<separator>\r?\n)(?P<body>[\s\S]*?)</dreameros_boot_canon>",
        package_text,
    ))
    if len(openings) != 1 or len(closings) != 1 or len(wrappers) != 1:
        return False, "missing or duplicate boot-canon wrapper"
    wrapper = wrappers[0]
    required_attr_pairs = [
        ("schema_version", component["schema_version"]),
        ("version", version),
        ("sha256", sha256),
        ("hash_normalization", "LF"),
        ("canary_ids", ",".join(canary_ids)),
        ("source_repository", provenance["repository"]),
        ("source_path", provenance["path"]),
        ("generator", provenance["generator"]),
    ]
    expected_attr_text = "".join(f' {name}="{value}"' for name, value in required_attr_pairs)
    if wrapper.group("attrs") != expected_attr_text:
        return False, "boot-canon wrapper metadata mismatch"
    # The gateway renders one framing newline after the opening tag. It is not
    # part of portable_text and therefore must not enter the portable-body hash.
    wrapper_body = _normalized_boot_text(wrapper.group("body"))
    if (
        len(wrapper_body) < 5000
        or len(wrapper_body) != component["portable_chars"]
        or not wrapper_body.endswith("\n")
        or hashlib.sha256(wrapper_body.encode("utf-8")).hexdigest() != sha256
    ):
        return False, "boot-canon wrapper body or hash mismatch"
    for canary in ("# DreamerOS Boot Canon " + version, "## R1 - ANSWER FROM MEASUREMENT, NEVER FROM MEMORY", "## R26 -", "## R27 -", "HC-DEFINITION-OF-DONE"):
        if canary not in wrapper_body:
            return False, "boot-canon canary missing"

    static_continuation = component.get("continuation")
    static_keys = {
        "part_count", "max_part_chars", "max_serialized_part_bytes", "parts",
        "resource_uris", "actions_path_template", "reassemble_sha256", "hash_normalization",
    }
    if not _has_exact_keys(static_continuation, static_keys):
        return False, "missing boot-canon continuation fields"
    static_count = static_continuation.get("part_count")
    if (
        not _valid_positive_int(static_count)
        or static_continuation.get("max_part_chars") != 12000
        or static_continuation.get("max_serialized_part_bytes") != 12000
        or static_continuation.get("actions_path_template") != "/api/v1/actions/boot-canon/{part}"
        or static_continuation.get("reassemble_sha256") != sha256
        or static_continuation.get("hash_normalization") != "LF"
        or not _validate_part_descriptors(static_continuation.get("parts"), static_count, wrapper_body)
        or static_continuation.get("resource_uris") != [
            f"dreameros://boot-canon/part/{index}" for index in range(1, static_count + 1)
        ]
    ):
        return False, "boot-canon continuation mismatch"

    compact_view = package.get("compact_view")
    compact_keys = {
        "duplicate_fields_removed", "max_bytes", "truncated", "server_truncated", "complete",
        "client_may_truncate", "boot_canon_complete_in_package_text", "boot_canon_continuation",
        "package_continuation", "handoff_projection_max_chars", "full_handoff_tool", "encoded_bytes",
    }
    if (
        not _has_exact_keys(compact_view, compact_keys)
        or compact_view.get("duplicate_fields_removed") != ["stable_prefix", "volatile_tail", "system_blocks"]
        or compact_view.get("max_bytes") != 100000
        or compact_view.get("truncated") is not False
        or compact_view.get("server_truncated") is not False
        or compact_view.get("complete") is not True
        or compact_view.get("client_may_truncate") is not True
        or compact_view.get("boot_canon_complete_in_package_text") is not True
        or compact_view.get("boot_canon_continuation") != static_continuation
        or compact_view.get("full_handoff_tool") != "dreameros_session_handoff_read"
        or compact_view.get("handoff_projection_max_chars") != HANDOFF_PROJECTION_MAX_CHARS
        or not _valid_positive_int(compact_view.get("encoded_bytes"))
        or "package_continuation" in package
    ):
        return False, "compact package continuation envelope mismatch"
    continuation = compact_view.get("package_continuation")
    package_keys = {
        "package_id", "content_hash", "composed_at", "ttl_seconds", "hash_normalization",
        "part_count", "max_part_chars", "max_serialized_part_bytes", "parts", "mcp_tool",
        "arguments_template", "actions_path", "actions_method", "resource_uris",
    }
    package_id = package.get("package_id")
    content_hash = package.get("content_hash")
    if (
        not _has_exact_keys(continuation, package_keys)
        or not isinstance(package_id, str)
        or not package_id
        or not _is_lower_sha256(content_hash)
        or content_hash == sha256
        or content_hash != hashlib.sha256(normalized_package_text.encode("utf-8")).hexdigest()
        or continuation.get("package_id") != package_id
        or continuation.get("content_hash") != content_hash
        or continuation.get("composed_at") != package.get("composed_at")
        or continuation.get("ttl_seconds") != package.get("ttl_seconds")
        or continuation.get("hash_normalization") != "LF"
        or continuation.get("max_part_chars") != 12000
        or continuation.get("max_serialized_part_bytes") != 12000
        or continuation.get("mcp_tool") != "dreameros_session_package"
        or continuation.get("actions_path") != "/api/v1/actions/session-package"
        or continuation.get("actions_method") != "POST"
    ):
        return False, "package continuation mismatch"
    package_count = continuation.get("part_count")
    expected_arguments = {"package_id": package_id, "content_hash": content_hash, "part": "1..part_count"}
    if (
        not _valid_positive_int(package_count)
        or not _has_exact_keys(continuation.get("arguments_template"), set(expected_arguments))
        or continuation["arguments_template"] != expected_arguments
        or not _validate_part_descriptors(continuation.get("parts"), package_count, package_text)
        or continuation.get("resource_uris") != [
            f"dreameros://session-package/{package_id}/{content_hash}/part/{index}"
            for index in range(1, package_count + 1)
        ]
    ):
        return False, "package continuation descriptors mismatch"
    return True, ""


def _mcp_identity_matches(payload: dict[str, Any], server: str) -> bool:
    """Validate the DreamerOS MCP source using fields Cursor actually emits.

    Cursor 3.17.21 omits the server URL from command-hook payloads. It does
    provide the exact provider identity in ``command``. Prefer an explicit URL
    when present. When it is absent, require at least one provider hint and
    require every supplied hint to match the allowlisted server name. This
    keeps missing or conflicting identity fail-closed without requiring a hook
    field Cursor does not expose.
    """

    server_url = str(payload.get("mcp_server_url") or payload.get("url") or "").strip().rstrip("/")
    hints = [
        str(payload.get(key)).strip().lower()
        for key in ("command", "provider_identifier", "providerIdentifier")
        if payload.get(key) not in (None, "")
    ]
    if server_url and server_url != DREAMEROS_MCP_URL:
        return False
    if hints and any(hint != server for hint in hints):
        return False
    if server_url:
        return True
    return bool(hints)


def _lockstep_after_result(payload: dict[str, Any], canonical_tool: str) -> dict[str, Any]:
    result: dict[str, Any] = {"continue": True}
    if not canonical_tool.endswith("dreameros_skill"):
        return result
    verdict = extract_from_host_payload(payload).to_dict()
    result["gateway_lockstep"] = verdict
    result["gateway_lockstep"]["mode"] = "OBSERVED"
    return result


def after_mcp_execution(payload: dict[str, Any]) -> dict[str, Any]:
    event = _event(payload).lower()
    server = str(payload.get("mcp_server_name") or "").lower()
    canonical_tool = _canonical_tool(payload)
    if event == "posttooluse":
        if server and server not in ALLOWED_DREAMEROS_MCP_SERVERS:
            return {"continue": True}
        if not server and not any(canonical_tool.endswith(name) for name in BOOT_SEQUENCE):
            return {"continue": True}
    elif server not in ALLOWED_DREAMEROS_MCP_SERVERS or not _mcp_identity_matches(payload, server):
        return {"continue": True}
    fingerprint = _boot_fingerprint(payload)
    if fingerprint in {"unavailable", "conflict"}:
        return _lockstep_after_result(payload, canonical_tool)
    try:
        with _boot_state_lock():
            states = _load_boot_states()
            entry = states["sessions"].get(fingerprint)
            if not isinstance(entry, dict) or not entry.get("pending"):
                return _lockstep_after_result(payload, canonical_tool)
            generation = _generation_fingerprint(payload)
            expected_generation = str(entry.get("generation") or "unavailable")
            if expected_generation not in {"unavailable", generation} or generation == "conflict":
                entry["pending"] = None
                entry["updated"] = _now_epoch()
                _save_boot_states(states)
                return _lockstep_after_result(payload, canonical_tool)
            pending = str(entry.get("pending"))
            if not canonical_tool.endswith(pending):
                return _lockstep_after_result(payload, canonical_tool)
            entry["pending"] = None
            succeeded = _mcp_result_succeeded(payload)
            if pending == "dreameros_session_package":
                succeeded, _ = _validate_session_package_result(payload)
            if succeeded:
                entry["step"] = min(int(entry.get("step", 0)) + 1, len(BOOT_SEQUENCE))
            entry["updated"] = _now_epoch()
            _save_boot_states(states)
    except (OSError, TimeoutError):
        pass
    return _lockstep_after_result(payload, canonical_tool)


def _write_signature(event: str, permission: str, payload: dict[str, Any]) -> None:
    try:
        SIGNATURE_LOG.parent.mkdir(parents=True, exist_ok=True)
        record = {
            "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
            "event": event,
            "permission": permission,
            "session_fingerprint": _session_fingerprint(payload),
            "subagent_fingerprint": _subagent_fingerprint(payload),
            "generation_fingerprint": _generation_fingerprint(payload),
            "invocation_fingerprint": _invocation_fingerprint(payload),
        }
        line = (json.dumps(record, separators=(",", ":")) + "\n").encode("utf-8")
        flags = os.O_APPEND | os.O_CREAT | os.O_WRONLY
        if hasattr(os, "O_BINARY"):
            flags |= os.O_BINARY
        descriptor = os.open(str(SIGNATURE_LOG), flags, 0o600)
        try:
            os.write(descriptor, line)
        finally:
            os.close(descriptor)
    except OSError:
        pass


def _permission(value: str, message: str = "") -> dict[str, Any]:
    result: dict[str, Any] = {"permission": value}
    if message:
        result["user_message"] = message
        result["agent_message"] = message
    return result


def shell_decision(command: str) -> dict[str, Any]:
    lowered = command.lower()
    if any(re.search(pattern, lowered, re.IGNORECASE) for pattern in DESTRUCTIVE_SHELL):
        return _permission(
            "deny",
            "DreamerOS blocked a destructive command. Use a bounded recoverable action or obtain an explicit Human Conductor exception.",
        )
    curl_short_write = bool(
        re.search(r"\bcurl(?:\.exe)?\b[^\r\n]*(?:\s-d\S*|\s-F\S*|\s-T\S*)", command)
    )
    if curl_short_write or any(re.search(pattern, lowered, re.IGNORECASE) for pattern in AUTHORITY_SHELL):
        return _permission(
            "deny",
            "DreamerOS blocked an authority-bearing shell action. The Human Conductor must perform or separately authorize it outside Auto Review.",
        )
    if SENSITIVE_ENV_RE.search(command) or re.search(
        r"(?:authorization\s*:|--header\s+['\"]?authorization|-h\s+['\"]?authorization)",
        command,
        re.IGNORECASE,
    ):
        return _permission("ask", "This command can transmit or print credential material. Confirm the exact destination and scope.")
    if SENSITIVE_PATH_RE.search(command) or PROVIDER_CREDENTIAL_PATH_RE.search(command):
        return _permission("deny", "DreamerOS blocked a shell read of a credential-bearing path.")
    if re.search(r"(?:;|&&|\|\||\||&|>|<|\r|\n|\$\(|`)", command):
        return _permission("ask", "Compound or substituted shell syntax requires confirmation before execution.")
    if any(re.fullmatch(pattern, command, re.IGNORECASE) for pattern in SAFE_SHELL):
        return _permission("allow")
    return _permission(
        "ask",
        "This shell command is not classified as read-only local verification. Confirm before execution.",
    )


def file_read_decision(payload: dict[str, Any]) -> dict[str, Any]:
    path = str(payload.get("file_path") or "")
    content = str(payload.get("content") or "")
    if SENSITIVE_PATH_RE.search(path) or PROVIDER_CREDENTIAL_PATH_RE.search(path):
        return _permission("deny", "DreamerOS blocked a credential-bearing file path.")
    if SENSITIVE_VALUE_RE.search(content):
        return _permission("deny", "DreamerOS blocked file content that matches a credential signature.")
    if PUTTY_PRIVATE_KEY_RE.search(content):
        return _permission("deny", "DreamerOS blocked PuTTY private-key content.")
    for match in SECRET_ASSIGNMENT_RE.finditer(content):
        value = match.group(2).strip().strip("\"'")
        if len(value) >= 6 and not PLACEHOLDER_VALUE_RE.search(value):
            return _permission("deny", "DreamerOS blocked a literal credential assignment.")
    return _permission("allow")


def _tool_input(payload: dict[str, Any]) -> dict[str, Any]:
    value = payload.get("tool_input", {})
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
            return parsed if isinstance(parsed, dict) else {}
        except json.JSONDecodeError:
            return {}
    return {}


def _mcp_input_contains_literal_secret(params: dict[str, Any]) -> bool:
    try:
        content = json.dumps(params, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    except (TypeError, ValueError):
        content = str(params)
    if SENSITIVE_VALUE_RE.search(content) or PUTTY_PRIVATE_KEY_RE.search(content):
        return True
    for match in SECRET_ASSIGNMENT_RE.finditer(content):
        value = match.group(2).strip().strip("\"'")
        if len(value) >= 6 and not PLACEHOLDER_VALUE_RE.search(value):
            return True
    return False


def mcp_decision(payload: dict[str, Any]) -> dict[str, Any]:
    server = str(payload.get("mcp_server_name") or "").lower()
    tool = str(payload.get("tool_name") or "").lower()
    if not server:
        return _permission("deny", "DreamerOS blocked an MCP call with no server identity.")
    if server not in ALLOWED_DREAMEROS_MCP_SERVERS:
        if "dreameros" in tool:
            return _permission("deny", "DreamerOS blocked a legacy or spoofed server identity. Use the OAuth-owned dreameros-platform plugin MCP.")
        if "dreameros" in server:
            return _permission("deny", "DreamerOS blocked a legacy project MCP identity. Use the OAuth-owned dreameros-platform plugin MCP.")
        return _permission("ask", "This MCP server is outside the DreamerOS trust map. Confirm before execution.")
    if not _mcp_identity_matches(payload, server):
        return _permission("deny", "DreamerOS blocked a DreamerOS-named MCP call from an unexpected endpoint or provider identity.")

    canonical_tool = _canonical_tool(payload)
    params = _tool_input(payload)
    if _mcp_input_contains_literal_secret(params):
        return _permission("deny", "DreamerOS blocked literal credential content in MCP input.")
    boot_decision = _boot_before_mcp(payload, canonical_tool, params)
    if boot_decision is not None:
        return boot_decision
    action = str(params.get("action") or "").lower()
    phrase = str(params.get("phrase") or "").upper()
    depth = str(params.get("depth") or "").lower()

    if canonical_tool.endswith("dreameros_forget"):
        return _permission("ask", "Deleting DreamerOS memory requires explicit action-time confirmation.")
    if canonical_tool.endswith("dreameros_canon_store"):
        if action == "list":
            return _permission("allow")
        return _permission("ask", "Writing, approving, or deleting canon requires Human Conductor confirmation.")
    if canonical_tool.endswith("dreameros_hc_command"):
        if phrase in {"STATUS", "CHECK TODO LIST", "CHECK CANON"}:
            return _permission("allow")
        return _permission("ask", "This DreamerOS command crosses a trust-bearing authority gate.")
    if canonical_tool.endswith("dreameros_state"):
        if action in {"load", "get_decisions", "get_versions", "staleness"}:
            return _permission("allow")
        return _permission("ask", "Updating or snapshotting shared cognitive state requires confirmation.")
    if canonical_tool.endswith("dreameros_space"):
        if action in {"list", "get", "status"}:
            return _permission("allow")
        return _permission("ask", "Changing the active DreamerOS space requires confirmation.")
    if canonical_tool.endswith("dreameros_tribal"):
        if action in {"", "search"}:
            return _permission("allow")
        return _permission("ask", "Fresh tribal collection makes external calls and requires confirmation.")
    if canonical_tool.endswith("dreameros_verify"):
        if depth == "light":
            return _permission("allow")
        return _permission("ask", "DreamerOS verification defaults to paid deep depth unless light is explicit.")
    if any(
        canonical_tool.endswith(name)
        for name in ("dreameros_github_create_issue", "dreameros_underwrite", "dreameros_agent")
    ):
        return _permission("ask", "This DreamerOS tool can create external state or incur metered work. Confirm before execution.")
    if canonical_tool in SAFE_DREAMEROS_TOOLS:
        return _permission("allow")
    return _permission(
        "ask",
        "This DreamerOS tool is not classified as read-only or approved continuity. Confirm before execution.",
    )


def handle(payload: dict[str, Any]) -> dict[str, Any]:
    event = _event(payload)
    folded = event.lower()
    if folded == "sessionstart":
        initialized = _initialize_boot_state(payload)
        if initialized:
            result = {"continue": True, "additional_context": BOOT_CONTEXT}
            permission = "context"
        else:
            result = {"continue": False, "additional_context": BOOT_CONTEXT, "user_message": "DreamerOS could not initialize a stable per-conversation boot gate."}
            permission = "deny"
    elif folded == "beforesubmitprompt":
        initialized = _ensure_boot_state(payload)
        if initialized:
            result = {"continue": True}
            permission = "bootstrap"
        else:
            result = {"continue": False, "user_message": "DreamerOS could not initialize a stable first-prompt boot gate."}
            permission = "deny"
    elif folded == "subagentstart":
        if _is_parity_health_launch(payload) and not (
            _parity_core_marker_set(payload) or _parity_core_block_visible(payload)
        ):
            result = _permission(
                "deny",
                "DreamerOS blocked the parity reviewer because the complete core CURSOR_PARITY block was not visible in an earlier standalone assistant message. Emit that block now and do not retry this reviewer in the same run.",
            )
            permission = "deny"
        else:
            initialized = _initialize_subagent_boot_state(payload)
            if initialized:
                result = _permission("allow")
                permission = "allow"
            else:
                result = _permission("deny", "DreamerOS could not initialize a stable per-subagent boot gate.")
                permission = "deny"
    elif folded == "beforeshellexecution":
        command = str(payload.get("command") or "")
        if command.strip().lower() == PARITY_CORE_SENTINEL.lower():
            if _mark_parity_core_emitted(payload):
                result = _permission("allow")
                permission = "allow"
            else:
                result = _permission("deny", "DreamerOS could not persist the parity core-block marker.")
                permission = "deny"
        else:
            result = shell_decision(command)
            permission = str(result["permission"])
    elif folded == "beforemcpexecution":
        result = mcp_decision(payload)
        permission = str(result["permission"])
    elif folded in {"aftermcpexecution", "posttooluse"}:
        result = after_mcp_execution(payload)
        permission = "verified"
    elif folded == "beforereadfile":
        result = file_read_decision(payload)
        permission = str(result["permission"])
    else:
        result = {"continue": True}
        permission = "allow"
    _write_signature(event, permission, payload)
    return result


def self_test() -> int:
    global BOOT_STATE_FILE, SIGNATURE_LOG, TRANSCRIPT_ROOT
    original_boot_state_file = BOOT_STATE_FILE
    original_signature_log = SIGNATURE_LOG
    original_transcript_root = TRANSCRIPT_ROOT
    test_root = Path(tempfile.mkdtemp(prefix="dreameros-cursor-hook-tests-"))
    BOOT_STATE_FILE = test_root / "boot-state.json"
    SIGNATURE_LOG = test_root / "hook-signatures.jsonl"
    TRANSCRIPT_ROOT = test_root

    hydrated_fingerprint = _session_fingerprint({"conversation_id": "self-test-hydrated"})
    _save_boot_states(
        {
            "version": 1,
            "sessions": {
                hydrated_fingerprint: {
                    "step": len(BOOT_SEQUENCE),
                    "pending": None,
                    "generation": "unavailable",
                    "updated": _now_epoch(),
                }
            },
        }
    )

    def dmcp(tool_name: str, tool_input: dict[str, Any]) -> dict[str, Any]:
        return mcp_decision(
            {
                "conversation_id": "self-test-hydrated",
                "generation_id": "self-test-generation",
                "mcp_server_name": "dreameros-platform",
                "mcp_server_url": DREAMEROS_MCP_URL,
                "tool_name": tool_name,
                "tool_input": tool_input,
            }
        )

    def gateway_package_result() -> dict[str, Any]:
        body = (
            "# DreamerOS Boot Canon v2.4.0\n\n"
            "## R1 - ANSWER FROM MEASUREMENT, NEVER FROM MEMORY\n\n"
            "## R26 - THE CORNERSTONE\n\n"
            "## R27 - BRANCH HYGIENE\n\n"
            "<!-- BEGIN HC-DEFINITION-OF-DONE v1.0.0 -->\n" + ("x" * 43000) + "\n"
        )
        sha256 = hashlib.sha256(body.encode("utf-8")).hexdigest()
        provenance = {
            "repository": "gbude-sudo/dreameros-agent-plugin",
            "path": "bootpack/SOURCE-dreameros-boot-canon.md",
            "generator": "bootpack/build-boot-pack.ps1",
        }
        canary_ids = [
            "R1", "R1a", "R1b", "R1c", "R1d", "R1e", "R1f", "R1g", "R1h", "R1i",
            "R1j", "R1k", "R1l", "R1m", "R2", "R3", "R4", "R5", "R7", "R7a", "R9",
            "R10", "R13", "R15", "R16", "R17", "R19", "R20", "R26", "R27", "R6", "R8",
            "R11", "R12", "R18", "R21", "R22", "R23", "R24", "R25", "R14",
            "HC-DEFINITION-OF-DONE",
        ]

        def fixture_parts(text: str) -> tuple[list[str], list[dict[str, Any]]]:
            chunks = [text[index:index + 9500] for index in range(0, len(text), 9500)]
            return chunks, [
                {
                    "part": index,
                    "chars": len(content),
                    "sha256": hashlib.sha256(content.encode("utf-8")).hexdigest(),
                }
                for index, content in enumerate(chunks, start=1)
            ]

        static_chunks, static_parts = fixture_parts(body)
        component = {
            "tokens": 12345,
            "schema_version": "dreameros-session-package-stable-prefix-v1",
            "version": "v2.4.0",
            "sha256": sha256,
            "hash_normalization": "LF",
            "canary_ids": canary_ids,
            "source_provenance": provenance,
            "continuation": {
                "part_count": len(static_chunks),
                "max_part_chars": 12000,
                "max_serialized_part_bytes": 12000,
                "parts": static_parts,
                "resource_uris": [
                    f"dreameros://boot-canon/part/{index}" for index in range(1, len(static_chunks) + 1)
                ],
                "actions_path_template": "/api/v1/actions/boot-canon/{part}",
                "reassemble_sha256": sha256,
                "hash_normalization": "LF",
            },
            "portable_chars": len(body),
            "summary": "fixture",
        }
        wrapper = (
            '<dreameros_boot_canon schema_version="{schema_version}" version="{version}" '
            'sha256="{sha256}" hash_normalization="LF" canary_ids="{canaries}" '
            'source_repository="{repository}" source_path="{path}" generator="{generator}">\n{body}</dreameros_boot_canon>'
        ).format(**component, **provenance, canaries=",".join(canary_ids), body=body)
        package_text = (
            '<dreameros_boot_contract version="1.0.0">\ncontract\n</dreameros_boot_contract>\n\n'
            + wrapper
            + '\n\n<direction_set engine="chatgpt" version="v9.1.0">\ndirection\n</direction_set>\n\n'
            + '<session_handoff status="present">\nhandoff\n</session_handoff>\n'
        )
        content_hash = hashlib.sha256(package_text.encode("utf-8")).hexdigest()
        package_chunks, package_parts = fixture_parts(package_text)
        package_id = "fixture-package"
        package = {
            "package_id": package_id,
            "version": SESSION_PACKAGE_VERSION,
            "content_hash": content_hash,
            "composed_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "ttl_seconds": 1800,
            "package_components": {"boot_canon": component},
            "package_text": package_text,
            "compact_view": {
                "duplicate_fields_removed": ["stable_prefix", "volatile_tail", "system_blocks"],
                "max_bytes": 100000,
                "truncated": False,
                "server_truncated": False,
                "complete": True,
                "client_may_truncate": True,
                "boot_canon_complete_in_package_text": True,
                "boot_canon_continuation": component["continuation"],
                "package_continuation": {
                "package_id": package_id,
                "content_hash": content_hash,
                "composed_at": None,
                "ttl_seconds": 1800,
                "hash_normalization": "LF",
                "part_count": len(package_chunks),
                "max_part_chars": 12000,
                "max_serialized_part_bytes": 12000,
                "parts": package_parts,
                "mcp_tool": "dreameros_session_package",
                "arguments_template": {"package_id": package_id, "content_hash": content_hash, "part": "1..part_count"},
                "actions_path": "/api/v1/actions/session-package",
                "actions_method": "POST",
                "resource_uris": [
                    f"dreameros://session-package/{package_id}/{content_hash}/part/{index}"
                    for index in range(1, len(package_chunks) + 1)
                ],
                },
                "handoff_projection_max_chars": HANDOFF_PROJECTION_MAX_CHARS,
                "full_handoff_tool": "dreameros_session_handoff_read",
                "encoded_bytes": 100,
            },
        }
        package["compact_view"]["package_continuation"]["composed_at"] = package["composed_at"]
        return {"isError": False, "content": [{"type": "text", "text": json.dumps(package)}]}

    def boot_mcp(session: str, tool_name: str, tool_input: dict[str, Any]) -> dict[str, Any]:
        return mcp_decision(
            {
                "conversation_id": session,
                "generation_id": f"generation-{session}",
                "mcp_server_name": "dreameros-platform",
                "mcp_server_url": DREAMEROS_MCP_URL,
                "tool_name": tool_name,
                "tool_input": tool_input,
            }
        )

    def boot_after(session: str, tool_name: str, result: dict[str, Any]) -> dict[str, Any]:
        return after_mcp_execution(
            {
                "conversation_id": session,
                "generation_id": f"generation-{session}",
                "mcp_server_name": "dreameros-platform",
                "mcp_server_url": DREAMEROS_MCP_URL,
                "tool_name": tool_name,
                "tool_input": {},
                "result_json": json.dumps(result),
            }
        )

    def subagent_mcp(parent: str, subagent: str, tool_name: str, tool_input: dict[str, Any]) -> dict[str, Any]:
        return mcp_decision(
            {
                "conversation_id": parent,
                "subagent_id": subagent,
                "generation_id": f"generation-{subagent}",
                "mcp_server_name": "dreameros-platform",
                "mcp_server_url": DREAMEROS_MCP_URL,
                "tool_name": tool_name,
                "tool_input": tool_input,
            }
        )

    def subagent_after(parent: str, subagent: str, tool_name: str, result: dict[str, Any]) -> dict[str, Any]:
        return after_mcp_execution(
            {
                "conversation_id": parent,
                "subagent_id": subagent,
                "generation_id": f"generation-{subagent}",
                "mcp_server_name": "dreameros-platform",
                "mcp_server_url": DREAMEROS_MCP_URL,
                "tool_name": tool_name,
                "tool_input": {},
                "result_json": json.dumps(result),
            }
        )

    visible_transcript = test_root / "visible-parity.jsonl"
    visible_transcript.write_text(
        json.dumps(
            {
                "role": "assistant",
                "message": {
                    "content": [
                        {
                            "type": "text",
                            "text": "CURSOR_PARITY v1\npayload=PROVEN\nsubagents=DISCOVERED\noverall=PARTIAL",
                        }
                    ]
                },
            }
        )
        + "\n",
        encoding="utf-8",
    )
    visible_parity_launch = handle(
        {
            "hook_event_name": "subagentStart",
            "conversation_id": "visible-parity-parent",
            "generation_id": "visible-parity-generation",
            "subagent_id": "visible-parity-subagent",
            "subagent_type": "dreameros-platform-governance-node",
            "task": "Review the first CURSOR_PARITY block only. Make no changes.",
            "transcript_path": str(visible_transcript),
        }
    )
    bridged_transcript = test_root / "bridged-parity.jsonl"
    bridged_transcript.write_text(
        json.dumps(
            {
                "role": "assistant",
                "message": {
                    "content": [
                        {
                            "type": "text",
                            "text": "CURSOR_PARITY v1\npayload=PROVEN\nsubagents=DISCOVERED\noverall=PARTIAL",
                        },
                        {
                            "type": "tool_use",
                            "name": "Grep",
                            "input": {"pattern": "session-fingerprint", "path": "hook-signatures.jsonl"},
                        },
                    ]
                },
            }
        )
        + "\n",
        encoding="utf-8",
    )
    bridged_parity_launch = handle(
        {
            "hook_event_name": "subagentStart",
            "conversation_id": "bridged-parity-parent",
            "generation_id": "bridged-parity-generation",
            "subagent_id": "bridged-parity-subagent",
            "subagent_type": "dreameros-platform-governance-node",
            "task": "Review the first CURSOR_PARITY block only. Make no changes.",
            "transcript_path": str(bridged_transcript),
        }
    )
    hidden_transcript = test_root / "hidden-parity.jsonl"
    hidden_transcript.write_text(
        json.dumps(
            {
                "role": "assistant",
                "message": {
                    "content": [
                        {"type": "text", "text": "Launching reviewers before the result."},
                        {
                            "type": "tool_use",
                            "name": "Task",
                            "input": {
                                "prompt": "CURSOR_PARITY v1\npayload=PROVEN\nsubagents=DISCOVERED\noverall=PARTIAL"
                            },
                        },
                    ]
                },
            }
        )
        + "\n",
        encoding="utf-8",
    )
    hidden_parity_launch = handle(
        {
            "hook_event_name": "subagentStart",
            "conversation_id": "hidden-parity-parent",
            "generation_id": "hidden-parity-generation",
            "subagent_id": "hidden-parity-subagent",
            "subagent_type": "dreameros-platform-canon-citer",
            "task": "Cite the claim that cursor/mcp.json names dreameros-platform and has no headers.",
            "transcript_path": str(hidden_transcript),
        }
    )
    missing_parity_transcript = handle(
        {
            "hook_event_name": "subagentStart",
            "conversation_id": "missing-parity-parent",
            "generation_id": "missing-parity-generation",
            "subagent_id": "missing-parity-subagent",
            "subagent_type": "dreameros-platform-governance-node",
            "task": "Review the first CURSOR_PARITY block only. Make no changes.",
        }
    )
    marker_parent = {
        "hook_event_name": "sessionStart",
        "conversation_id": "marker-parity-parent",
        "generation_id": "marker-parity-generation",
    }
    handle(marker_parent)
    marker_command = handle(
        {
            "hook_event_name": "beforeShellExecution",
            "conversation_id": "marker-parity-parent",
            "generation_id": "marker-parity-generation",
            "command": PARITY_CORE_SENTINEL,
        }
    )
    marker_persisted = _parity_core_marker_set(marker_parent)
    marked_parity_launch = handle(
        {
            "hook_event_name": "subagentStart",
            "conversation_id": "marker-parity-parent",
            "generation_id": "marker-parity-generation",
            "subagent_id": "marked-parity-subagent",
            "subagent_type": "dreameros-platform-governance-node",
            "task": "Review the first CURSOR_PARITY block only. Make no changes.",
        }
    )
    unmarked_other_launch = handle(
        {
            "hook_event_name": "subagentStart",
            "conversation_id": "unmarked-other-parent",
            "generation_id": "unmarked-other-generation",
            "subagent_id": "unmarked-other-subagent",
            "subagent_type": "dreameros-platform-governance-node",
            "task": "Review the first CURSOR_PARITY block only. Make no changes.",
        }
    )
    missing_marker_session = handle(
        {
            "hook_event_name": "beforeShellExecution",
            "command": PARITY_CORE_SENTINEL,
        }
    )

    boot_session = {"hook_event_name": "sessionStart", "conversation_id": "boot-a", "generation_id": "generation-boot-a"}
    boot_session_result = handle(boot_session)
    prompt_fallback_event = {
        "hook_event_name": "beforeSubmitPrompt",
        "conversation_id": "prompt-fallback",
        "generation_id": "generation-prompt-fallback",
    }
    prompt_fallback_result = handle(prompt_fallback_event)
    prompt_fallback_fingerprint = _session_fingerprint(prompt_fallback_event)
    prompt_fallback_initialized = (
        _load_boot_states()["sessions"].get(prompt_fallback_fingerprint, {}).get("step") == 0
    )
    prompt_fallback_package = boot_mcp(
        "prompt-fallback", "dreameros_session_package", {"engine": "chatgpt"}
    )
    prompt_preserve_event = {
        "hook_event_name": "sessionStart",
        "conversation_id": "prompt-preserve",
        "generation_id": "generation-prompt-preserve",
    }
    handle(prompt_preserve_event)
    prompt_preserve_fingerprint = _session_fingerprint(prompt_preserve_event)
    prompt_preserve_states = _load_boot_states()
    prompt_preserve_states["sessions"][prompt_preserve_fingerprint].update(
        {"step": len(BOOT_SEQUENCE), "pending": None, "generation": "preserved-generation"}
    )
    _save_boot_states(prompt_preserve_states)
    prompt_preserve_before = dict(_load_boot_states()["sessions"][prompt_preserve_fingerprint])
    handle(
        {
            "hook_event_name": "beforeSubmitPrompt",
            "conversation_id": "prompt-preserve",
            "generation_id": "new-generation-must-not-reset-state",
        }
    )
    prompt_preserve_after = dict(_load_boot_states()["sessions"][prompt_preserve_fingerprint])
    prompt_fallback_preserved = prompt_preserve_after == prompt_preserve_before
    missing_prompt_fallback = handle({"hook_event_name": "beforeSubmitPrompt"})
    original_os_open = os.open
    transient_lock_failure = {"remaining": 1}

    def open_with_one_transient_lock_denial(path: Any, flags: int, *args: Any, **kwargs: Any) -> int:
        if str(path).endswith("boot-state.json.lock") and transient_lock_failure["remaining"]:
            transient_lock_failure["remaining"] -= 1
            raise PermissionError(13, "simulated Windows delete-pending lock entry", str(path))
        return original_os_open(path, flags, *args, **kwargs)

    transient_lock_retried = False
    os.open = open_with_one_transient_lock_denial
    try:
        with _boot_state_lock():
            transient_lock_retried = True
    finally:
        os.open = original_os_open
    boot_recall_before_package = boot_mcp("boot-a", "dreameros_recall", {"query": "x"})
    boot_package = boot_mcp("boot-a", "dreameros_session_package", {"engine": "chatgpt"})
    boot_context_while_pending = boot_mcp("boot-a", "dreameros_context", {})
    boot_after("boot-a", "dreameros_session_package", gateway_package_result())
    boot_handoff = boot_mcp("boot-a", "dreameros_session_handoff_read", {})
    boot_context = boot_mcp("boot-a", "dreameros_context", {})
    boot_recall_after_package = boot_mcp("boot-a", "dreameros_recall", {"query": "x"})
    boot_canon = boot_mcp("boot-a", "dreameros_canon", {"query": "x"})
    boot_state_mutation = boot_mcp("boot-a", "dreameros_state", {"action": "update_context"})
    boot_state = boot_mcp("boot-a", "dreameros_state", {"action": "load"})
    other_session_recall = boot_mcp("boot-b", "dreameros_recall", {"query": "x"})
    missing_session_start = handle({"hook_event_name": "sessionStart"})
    missing_session_mcp = mcp_decision(
        {
            "mcp_server_name": "dreameros-platform",
            "mcp_server_url": DREAMEROS_MCP_URL,
            "tool_name": "dreameros_recall",
            "tool_input": {"query": "x"},
        }
    )
    handle({"hook_event_name": "sessionStart", "conversation_id": "cursor-transport", "generation_id": "generation-cursor-transport"})
    cursor_transport_package = mcp_decision(
        {
            "conversation_id": "cursor-transport",
            "generation_id": "generation-cursor-transport",
            "mcp_server_name": "dreameros-platform",
            "command": "dreameros-platform",
            "tool_name": "dreameros_session_package",
            "tool_input": {"engine": "chatgpt"},
        }
    )
    after_mcp_execution(
        {
            "conversation_id": "cursor-transport",
            "generation_id": "generation-cursor-transport",
            "mcp_server_name": "dreameros-platform",
            "command": "dreameros-platform",
            "tool_name": "dreameros_session_package",
            "tool_input": {"engine": "chatgpt"},
            "result_json": json.dumps(gateway_package_result()),
        }
    )
    cursor_transport_context = mcp_decision(
        {
            "conversation_id": "cursor-transport",
            "generation_id": "generation-cursor-transport",
            "mcp_server_name": "dreameros-platform",
            "command": "dreameros-platform",
            "tool_name": "dreameros_context",
            "tool_input": {},
        }
    )
    handle({"hook_event_name": "sessionStart", "conversation_id": "cursor-post", "generation_id": "generation-cursor-post"})
    cursor_post_package = mcp_decision(
        {
            "conversation_id": "cursor-post",
            "generation_id": "generation-cursor-post",
            "mcp_server_name": "dreameros-platform",
            "command": "dreameros-platform",
            "tool_name": "dreameros_session_package",
            "tool_input": {"engine": "chatgpt"},
        }
    )
    after_mcp_execution(
        {
            "hook_event_name": "postToolUse",
            "conversation_id": "cursor-post",
            "generation_id": "generation-cursor-post",
            "tool_name": "dreameros_session_package",
            "tool_input": {"engine": "chatgpt"},
            "tool_output": json.dumps(gateway_package_result()),
        }
    )
    cursor_post_context = mcp_decision(
        {
            "conversation_id": "cursor-post",
            "generation_id": "generation-cursor-post",
            "mcp_server_name": "dreameros-platform",
            "command": "dreameros-platform",
            "tool_name": "dreameros_context",
            "tool_input": {},
        }
    )
    handle({"hook_event_name": "sessionStart", "conversation_id": "cursor-post-fail", "generation_id": "generation-cursor-post-fail"})
    cursor_post_failed_package = mcp_decision(
        {
            "conversation_id": "cursor-post-fail",
            "generation_id": "generation-cursor-post-fail",
            "mcp_server_name": "dreameros-platform",
            "command": "dreameros-platform",
            "tool_name": "dreameros_session_package",
            "tool_input": {"engine": "chatgpt"},
        }
    )
    after_mcp_execution(
        {
            "hook_event_name": "postToolUse",
            "conversation_id": "cursor-post-fail",
            "generation_id": "generation-cursor-post-fail",
            "tool_name": "dreameros_session_package",
            "tool_input": {"engine": "chatgpt"},
            "tool_output": json.dumps({"isError": True, "error": "control"}),
        }
    )
    cursor_post_failed_context = mcp_decision(
        {
            "conversation_id": "cursor-post-fail",
            "generation_id": "generation-cursor-post-fail",
            "mcp_server_name": "dreameros-platform",
            "command": "dreameros-platform",
            "tool_name": "dreameros_context",
            "tool_input": {},
        }
    )
    handle(
        {
            "hook_event_name": "sessionStart",
            "conversation_id": "cursor-generic-post",
            "generation_id": "generation-cursor-generic-post",
        }
    )
    mcp_decision(
        {
            "conversation_id": "cursor-generic-post",
            "generation_id": "generation-cursor-generic-post",
            "mcp_server_name": "dreameros-platform",
            "command": "dreameros-platform",
            "tool_name": "dreameros_session_package",
            "tool_input": {"engine": "chatgpt"},
        }
    )
    generic_fingerprint = _session_fingerprint({"conversation_id": "cursor-generic-post"})
    generic_pending_before = dict(_load_boot_states()["sessions"][generic_fingerprint])
    after_mcp_execution(
        {
            "hook_event_name": "postToolUse",
            "conversation_id": "cursor-generic-post",
            "generation_id": "generation-cursor-generic-post",
            "tool_name": "Grep",
            "tool_output": json.dumps({"success": True}),
        }
    )
    generic_pending_after = dict(_load_boot_states()["sessions"][generic_fingerprint])

    parent_event = {
        "hook_event_name": "sessionStart",
        "conversation_id": "parent-with-subagent",
        "generation_id": "generation-parent-with-subagent",
    }
    handle(parent_event)
    parent_fingerprint = _session_fingerprint(parent_event)
    parent_states = _load_boot_states()
    parent_states["sessions"][parent_fingerprint]["step"] = len(BOOT_SEQUENCE)
    parent_states["sessions"][parent_fingerprint]["pending"] = None
    parent_states["sessions"][parent_fingerprint]["generation"] = "unavailable"
    _save_boot_states(parent_states)
    parent_state_before = dict(_load_boot_states()["sessions"][parent_fingerprint])

    subagent_start = handle(
        {
            "hook_event_name": "subagentStart",
            "conversation_id": "parent-with-subagent",
            "generation_id": "generation-subagent-a",
            "subagent_id": "subagent-a",
        }
    )
    states_after_subagent_start = _load_boot_states()
    subagent_fingerprint = _subagent_fingerprint({"subagent_id": "subagent-a"})
    parent_state_preserved = states_after_subagent_start["sessions"].get(parent_fingerprint) == parent_state_before
    subagent_state_initialized = (
        states_after_subagent_start["sessions"].get(subagent_fingerprint, {}).get("step") == 0
        and subagent_fingerprint != parent_fingerprint
    )
    subagent_recall_before_package = subagent_mcp("parent-with-subagent", "subagent-a", "dreameros_recall", {"query": "x"})
    subagent_package = subagent_mcp("parent-with-subagent", "subagent-a", "dreameros_session_package", {"engine": "chatgpt"})
    subagent_after("parent-with-subagent", "subagent-a", "dreameros_session_package", gateway_package_result())
    subagent_handoff = subagent_mcp("parent-with-subagent", "subagent-a", "dreameros_session_handoff_read", {})
    subagent_context = subagent_mcp("parent-with-subagent", "subagent-a", "dreameros_context", {})
    subagent_state_mutation = subagent_mcp("parent-with-subagent", "subagent-a", "dreameros_state", {"action": "update_context"})
    subagent_state = subagent_mcp("parent-with-subagent", "subagent-a", "dreameros_state", {"action": "load"})
    subagent_recall_after_package = subagent_mcp("parent-with-subagent", "subagent-a", "dreameros_recall", {"query": "x"})
    subagent_canon = subagent_mcp("parent-with-subagent", "subagent-a", "dreameros_canon", {"query": "x"})
    other_subagent_recall = subagent_mcp("parent-with-subagent", "subagent-b", "dreameros_recall", {"query": "x"})
    parent_recall_after_subagent_start = boot_mcp("parent-with-subagent", "dreameros_recall", {"query": "x"})
    missing_subagent_start = handle({"hook_event_name": "subagentStart", "conversation_id": "parent-with-subagent"})
    conflicting_subagent_start = handle(
        {
            "hook_event_name": "subagentStart",
            "conversation_id": "parent-with-subagent",
            "subagent_id": "subagent-a",
            "subagentId": "subagent-b",
        }
    )
    conflicting_subagent_mcp = mcp_decision(
        {
            "conversation_id": "parent-with-subagent",
            "subagent_id": "subagent-a",
            "subagentId": "subagent-b",
            "mcp_server_name": "dreameros-platform",
            "mcp_server_url": DREAMEROS_MCP_URL,
            "tool_name": "dreameros_recall",
            "tool_input": {"query": "x"},
        }
    )
    empty_subagent_mcp = mcp_decision(
        {
            "conversation_id": "parent-with-subagent",
            "subagent_id": "",
            "mcp_server_name": "dreameros-platform",
            "mcp_server_url": DREAMEROS_MCP_URL,
            "tool_name": "dreameros_recall",
            "tool_input": {"query": "x"},
        }
    )

    strict_package_positive = gateway_package_result()
    strict_package_empty = {"isError": False, "content": []}
    strict_package_auth = {"isError": False, "content": [{"type": "text", "text": "Auth required"}]}
    strict_package_malformed = {"isError": False, "content": [{"type": "text", "text": "{"}]}
    strict_package_duplicate = json.loads(json.dumps(strict_package_positive))
    strict_duplicate_payload = json.loads(strict_package_duplicate["content"][0]["text"])
    strict_duplicate_payload["package_text"] += strict_duplicate_payload["package_text"]
    strict_package_duplicate["content"][0]["text"] = json.dumps(strict_duplicate_payload)
    strict_package_mismatch = json.loads(json.dumps(strict_package_positive))
    strict_mismatch_payload = json.loads(strict_package_mismatch["content"][0]["text"])
    strict_mismatch_payload["package_components"]["boot_canon"]["version"] = "v9.9.9"
    strict_package_mismatch["content"][0]["text"] = json.dumps(strict_mismatch_payload)
    strict_package_marker_only = json.loads(json.dumps(strict_package_positive))
    strict_marker_payload = json.loads(strict_package_marker_only["content"][0]["text"])
    strict_marker_payload["package_text"] = '<dreameros_boot_canon schema_version="dreameros-session-package-stable-prefix-v1" version="v2.4.0" sha256="0" source_repository="gbude-sudo/dreameros-agent-plugin" source_path="bootpack/SOURCE-dreameros-boot-canon.md" generator="bootpack/build-boot-pack.ps1">R26 R27</dreameros_boot_canon>'
    strict_package_marker_only["content"][0]["text"] = json.dumps(strict_marker_payload)
    strict_package_positive_valid, strict_package_positive_reason = _validate_session_package_result({"result_json": json.dumps(strict_package_positive)})
    strict_positive_payload = json.loads(strict_package_positive["content"][0]["text"])
    strict_static_five_parts = len(strict_positive_payload["package_components"]["boot_canon"]["continuation"]["parts"]) == 5
    strict_full_package_framing = (
        "<dreameros_boot_contract" in strict_positive_payload["package_text"]
        and "<session_handoff" in strict_positive_payload["package_text"]
        and not re.fullmatch(r"\s*<dreameros_boot_canon[\s\S]*</dreameros_boot_canon>\s*", strict_positive_payload["package_text"])
    )
    strict_continuation_negatives: list[tuple[str, dict[str, bool], str, bool]] = []

    def strict_negative(name: str, mutate: Any) -> None:
        candidate = json.loads(json.dumps(strict_package_positive))
        candidate_payload = json.loads(candidate["content"][0]["text"])
        mutate(candidate_payload)
        candidate["content"][0]["text"] = json.dumps(candidate_payload)
        strict_continuation_negatives.append(
            (name, {"value": _validate_session_package_result({"result_json": json.dumps(candidate)})[0]}, "value", False)
        )

    for field in (
        "part_count", "max_part_chars", "max_serialized_part_bytes", "parts", "resource_uris",
        "actions_path_template", "reassemble_sha256", "hash_normalization",
    ):
        strict_negative(
            "static continuation field rejects: " + field,
            lambda package, field=field: package["package_components"]["boot_canon"]["continuation"].pop(field),
        )
    for field in (
        "package_id", "content_hash", "composed_at", "ttl_seconds", "hash_normalization", "part_count",
        "max_part_chars", "max_serialized_part_bytes", "parts", "mcp_tool", "arguments_template",
        "actions_path", "actions_method", "resource_uris",
    ):
        strict_negative(
            "package continuation field rejects: " + field,
            lambda package, field=field: package["compact_view"]["package_continuation"].pop(field),
        )
    for field in ("part", "chars", "sha256"):
        strict_negative(
            "static continuation part field rejects: " + field,
            lambda package, field=field: package["package_components"]["boot_canon"]["continuation"]["parts"][0].pop(field),
        )
        strict_negative(
            "package continuation part field rejects: " + field,
            lambda package, field=field: package["compact_view"]["package_continuation"]["parts"][0].pop(field),
        )
    def corrupt_static_part_hash(package: dict[str, Any]) -> None:
        bad_hash = "0" * 64
        package["package_components"]["boot_canon"]["continuation"]["parts"][0]["sha256"] = bad_hash
        package["compact_view"]["boot_canon_continuation"]["parts"][0]["sha256"] = bad_hash

    strict_negative("static continuation part hash corruption rejects", corrupt_static_part_hash)
    strict_negative(
        "package continuation part hash corruption rejects",
        lambda package: package["compact_view"]["package_continuation"]["parts"][0].__setitem__(
            "sha256", "0" * 64
        ),
    )
    for field in ("package_id", "content_hash", "part"):
        strict_negative(
            "package continuation arguments field rejects: " + field,
            lambda package, field=field: package["compact_view"]["package_continuation"]["arguments_template"].pop(field),
        )
    strict_negative(
        "opening wrapper separator rejects",
        lambda package: package.__setitem__(
            "package_text",
            package["package_text"].replace('generator="bootpack/build-boot-pack.ps1">\n', 'generator="bootpack/build-boot-pack.ps1">', 1),
        ),
    )
    strict_negative(
        "full package hash must differ from boot canon hash",
        lambda package: package.__setitem__("content_hash", package["package_components"]["boot_canon"]["sha256"]),
    )
    strict_negative(
        "stale session package version rejects",
        lambda package: package.__setitem__("version", "v7.2.0-composed"),
    )
    strict_negative(
        "stale handoff projection limit rejects",
        lambda package: package["compact_view"].__setitem__("handoff_projection_max_chars", 2400),
    )

    def set_signed_freshness(package: dict[str, Any], *, composed: Any = None, ttl: Any = None) -> None:
        continuation = package["compact_view"]["package_continuation"]
        if composed is not None:
            package["composed_at"] = composed
            continuation["composed_at"] = composed
        if ttl is not None:
            package["ttl_seconds"] = ttl
            continuation["ttl_seconds"] = ttl

    freshness_now = dt.datetime.now(dt.timezone.utc)
    strict_negative(
        "naive composed_at rejects",
        lambda package: set_signed_freshness(package, composed=freshness_now.replace(tzinfo=None).isoformat()),
    )
    strict_negative(
        "non-UTC composed_at rejects",
        lambda package: set_signed_freshness(
            package,
            composed=freshness_now.astimezone(dt.timezone(dt.timedelta(hours=1))).isoformat(),
        ),
    )
    strict_negative("ttl zero rejects", lambda package: set_signed_freshness(package, ttl=0))
    strict_negative("ttl above maximum rejects", lambda package: set_signed_freshness(package, ttl=3601))
    strict_negative(
        "future composed_at beyond skew rejects",
        lambda package: set_signed_freshness(package, composed=(freshness_now + dt.timedelta(seconds=61)).isoformat()),
    )
    strict_negative(
        "expired composed_at beyond skew rejects",
        lambda package: set_signed_freshness(package, composed=(freshness_now - dt.timedelta(seconds=1861)).isoformat()),
    )
    def spoof_expiry(package: dict[str, Any]) -> None:
        set_signed_freshness(package, composed=(freshness_now - dt.timedelta(seconds=1861)).isoformat())
        package["expires_at"] = (freshness_now + dt.timedelta(days=1)).isoformat()
    strict_negative("separate expires_at cannot spoof freshness", spoof_expiry)

    lockstep_record = {
        "schema_version": "dreameros-gateway-lockstep-v1",
        "intent_envelope_schema": "dreameros-intent-envelope-v1",
        "intent_key": "cursor-lockstep-intent",
        "mcp_invocation": {"tool": "dreameros_skill", "intent_key": "cursor-lockstep-intent"},
        "receipt": {
            "schema_version": "dreameros-receipt-event-v1",
            "id": "cursor-lockstep-receipt",
            "intent_key": "cursor-lockstep-intent",
        },
        "terminal_state": "completed",
    }
    lockstep_payload = {
        "hook_event_name": "afterMCPExecution",
        "mcp_server_name": "dreameros-platform",
        "command": "dreameros-platform",
        "tool_name": "dreameros_skill",
        "result_json": json.dumps({"gateway_lockstep_evidence": lockstep_record}),
    }
    lockstep_terminal = after_mcp_execution(lockstep_payload)
    lockstep_bad = json.loads(json.dumps(lockstep_payload))
    lockstep_bad["result_json"] = json.dumps({"gateway_lockstep_evidence": {
        **lockstep_record, "terminal_state": "running",
    }})
    lockstep_nonterminal = after_mcp_execution(lockstep_bad)

    cases = [
        ("gateway-shaped package validates: " + strict_package_positive_reason, {"value": strict_package_positive_valid}, "value", True),
        ("gateway-shaped package has five static continuation parts", {"value": strict_static_five_parts}, "value", True),
        ("gateway-shaped package validates wrapper inside surrounding package text", {"value": strict_full_package_framing}, "value", True),
        ("Gateway Lockstep post-MCP observation continues", lockstep_terminal, "continue", True),
        ("Gateway Lockstep malformed evidence is not terminal", lockstep_terminal["gateway_lockstep"], "status", "CONFIGURED"),
        ("Gateway Lockstep post-MCP never blocks", lockstep_nonterminal, "continue", True),
        ("Gateway Lockstep malformed evidence stays nonterminal", lockstep_nonterminal["gateway_lockstep"], "status", "CONFIGURED"),
        ("empty package result rejects", {"value": _validate_session_package_result({"result_json": json.dumps(strict_package_empty)})[0]}, "value", False),
        ("auth-required package rejects", {"value": _validate_session_package_result({"result_json": json.dumps(strict_package_auth)})[0]}, "value", False),
        ("malformed package rejects", {"value": _validate_session_package_result({"result_json": json.dumps(strict_package_malformed)})[0]}, "value", False),
        ("duplicate package wrapper rejects", {"value": _validate_session_package_result({"result_json": json.dumps(strict_package_duplicate)})[0]}, "value", False),
        ("mismatched package metadata rejects", {"value": _validate_session_package_result({"result_json": json.dumps(strict_package_mismatch)})[0]}, "value", False),
        ("marker-only package rejects", {"value": _validate_session_package_result({"result_json": json.dumps(strict_package_marker_only)})[0]}, "value", False),
        *strict_continuation_negatives,
        ("visible parity block allows health launch", visible_parity_launch, "permission", "allow"),
        ("parity phase bridge allows later health launch", bridged_parity_launch, "permission", "allow"),
        ("parity block hidden in Task prompt is denied", hidden_parity_launch, "permission", "deny"),
        ("missing parity transcript is denied", missing_parity_transcript, "permission", "deny"),
        ("parity marker command is allowed", marker_command, "permission", "allow"),
        ("parity marker persists on parent state", {"value": marker_persisted}, "value", True),
        ("marked parent allows parity health launch", marked_parity_launch, "permission", "allow"),
        ("other session cannot borrow parity marker", unmarked_other_launch, "permission", "deny"),
        ("missing marker session fails closed", missing_marker_session, "permission", "deny"),
        ("boot session initializes", boot_session_result, "continue", True),
        ("first prompt fallback continues", prompt_fallback_result, "continue", True),
        ("first prompt fallback initializes", {"value": prompt_fallback_initialized}, "value", True),
        ("first prompt fallback enables package", prompt_fallback_package, "permission", "allow"),
        ("first prompt fallback preserves existing state", {"value": prompt_fallback_preserved}, "value", True),
        ("missing first prompt fallback fails closed", missing_prompt_fallback, "continue", False),
        ("transient Windows lock denial is retried", {"value": transient_lock_retried}, "value", True),
        ("recall before session package", boot_recall_before_package, "permission", "deny"),
        ("session package first", boot_package, "permission", "allow"),
        ("context blocked while package pending", boot_context_while_pending, "permission", "deny"),
        ("optional handoff after package", boot_handoff, "permission", "allow"),
        ("optional context after package", boot_context, "permission", "allow"),
        ("optional recall after package", boot_recall_after_package, "permission", "allow"),
        ("optional canon after package", boot_canon, "permission", "allow"),
        ("state mutation after boot asks", boot_state_mutation, "permission", "ask"),
        ("task-specific state read after boot", boot_state, "permission", "allow"),
        ("other session cannot borrow hydration", other_session_recall, "permission", "deny"),
        ("missing session start fails closed", missing_session_start, "continue", False),
        ("missing session MCP fails closed", missing_session_mcp, "permission", "deny"),
        ("Cursor missing-URL package first", cursor_transport_package, "permission", "allow"),
        ("Cursor missing-URL after hook advances", cursor_transport_context, "permission", "allow"),
        ("Cursor postToolUse package first", cursor_post_package, "permission", "allow"),
        ("Cursor postToolUse advances", cursor_post_context, "permission", "allow"),
        ("Cursor failed postToolUse does not advance", cursor_post_failed_context, "permission", "deny"),
        ("generic postToolUse preserves pending boot", {"value": generic_pending_after == generic_pending_before}, "value", True),
        ("subagent start initializes", subagent_start, "permission", "allow"),
        ("subagent start preserves parent state", {"value": parent_state_preserved}, "value", True),
        ("subagent state is independent", {"value": subagent_state_initialized}, "value", True),
        ("subagent recall before session package", subagent_recall_before_package, "permission", "deny"),
        ("subagent session package first", subagent_package, "permission", "allow"),
        ("subagent optional handoff after package", subagent_handoff, "permission", "allow"),
        ("subagent optional context after package", subagent_context, "permission", "allow"),
        ("subagent state mutation after boot asks", subagent_state_mutation, "permission", "ask"),
        ("subagent task-specific state read after boot", subagent_state, "permission", "allow"),
        ("subagent optional recall after package", subagent_recall_after_package, "permission", "allow"),
        ("subagent optional canon after package", subagent_canon, "permission", "allow"),
        ("other subagent cannot borrow hydration", other_subagent_recall, "permission", "deny"),
        ("parent hydration survives subagent start", parent_recall_after_subagent_start, "permission", "allow"),
        ("missing subagent start fails closed", missing_subagent_start, "permission", "deny"),
        ("conflicting subagent start fails closed", conflicting_subagent_start, "permission", "deny"),
        ("conflicting subagent MCP fails closed", conflicting_subagent_mcp, "permission", "deny"),
        ("empty subagent MCP fails closed", empty_subagent_mcp, "permission", "deny"),
        (
            "subagent aliases canonicalized",
            {"value": _subagent_fingerprint({"subagent_id": "subagent-a", "subagentId": "subagent-a"}) == subagent_fingerprint},
            "value",
            True,
        ),
        (
            "subagent fingerprint is namespaced from parent",
            {"value": _subagent_fingerprint({"subagent_id": "same-id"}) != _session_fingerprint({"conversation_id": "same-id"})},
            "value",
            True,
        ),
        (
            "conflicting subagent aliases fail closed",
            {"value": _subagent_fingerprint({"subagent_id": "subagent-a", "subagentId": "subagent-b"})},
            "value",
            "conflict",
        ),
        ("missing subagent fingerprint unavailable", {"value": _subagent_fingerprint({})}, "value", "unavailable"),
        (
            "session fingerprint present",
            {"value": _session_fingerprint({"session_id": "session-a", "generation_id": "generation-1"}) != "unavailable"},
            "value",
            True,
        ),
        (
            "session fingerprint stable",
            {"value": _session_fingerprint({"session_id": "session-a"}) == _session_fingerprint({"session_id": "session-a"})},
            "value",
            True,
        ),
        (
            "invocation fingerprint stable",
            {"value": _invocation_fingerprint({"tool_use_id": "tool-a"}) == _invocation_fingerprint({"tool_use_id": "tool-a"})},
            "value",
            True,
        ),
        ("missing invocation fingerprint unavailable", {"value": _invocation_fingerprint({})}, "value", "unavailable"),
        (
            "session aliases canonicalized",
            {"value": _session_fingerprint({"session_id": "session-a", "conversation_id": "session-a"}) == _session_fingerprint({"conversation_id": "session-a"})},
            "value",
            True,
        ),
        (
            "session camel alias canonicalized",
            {"value": _session_fingerprint({"sessionId": "session-a"}) == _session_fingerprint({"conversation_id": "session-a"})},
            "value",
            True,
        ),
        (
            "conflicting session aliases fail closed",
            {"value": _session_fingerprint({"session_id": "session-a", "conversation_id": "session-b"})},
            "value",
            "conflict",
        ),
        (
            "cross session fingerprint differs",
            {"value": _session_fingerprint({"session_id": "session-a"}) != _session_fingerprint({"session_id": "session-b"})},
            "value",
            True,
        ),
        (
            "missing session fingerprint unavailable",
            {"value": _session_fingerprint({})},
            "value",
            "unavailable",
        ),
        ("session context", {"additional_context": BOOT_CONTEXT}, "additional_context", None),
        ("read shell", shell_decision("git status --short"), "permission", "allow"),
        ("git reset", shell_decision("git reset --hard HEAD~1"), "permission", "deny"),
        ("split rm flags", shell_decision("rm -r -f ./victim"), "permission", "deny"),
        ("git restore", shell_decision("git restore ."), "permission", "deny"),
        ("powershell remove", shell_decision("Remove-Item -Recurse ./victim"), "permission", "deny"),
        ("cmd remove", shell_decision("cmd /c rd /s /q victim"), "permission", "deny"),
        ("git clean split flags", shell_decision("git clean -d -f"), "permission", "deny"),
        ("git checkout force", shell_decision("git checkout -f ."), "permission", "deny"),
        ("git branch force delete", shell_decision("git branch --delete --force old"), "permission", "deny"),
        ("sudo remove", shell_decision("sudo rm -rf ./victim"), "permission", "deny"),
        ("quoted cmd remove", shell_decision('cmd /c "rd /s /q victim"'), "permission", "deny"),
        ("find delete", shell_decision("find . -type f -delete"), "permission", "deny"),
        ("remote shell", shell_decision("git push origin main"), "permission", "deny"),
        ("git push sentinel", shell_decision('Write-Output "git push"'), "permission", "deny"),
        ("git commit authority", shell_decision("git commit -m control"), "permission", "deny"),
        ("railway deploy authority", shell_decision("railway deploy"), "permission", "deny"),
        ("package publish authority", shell_decision("npm publish"), "permission", "deny"),
        ("gh api mutation", shell_decision("gh api repos/x/y -X POST -f x=y"), "permission", "deny"),
        ("gh api implicit post", shell_decision("gh api repos/x/y/issues -f title=x"), "permission", "deny"),
        ("gh api equals method", shell_decision("gh api repos/x/y --method=POST"), "permission", "deny"),
        ("gh repo delete", shell_decision("gh repo delete x/y --yes"), "permission", "deny"),
        ("kubectl mutation", shell_decision("kubectl patch deployment app -p x"), "permission", "deny"),
        ("kubectl rollout", shell_decision("kubectl rollout restart deployment/app"), "permission", "deny"),
        ("vercel deploy", shell_decision("vercel deploy"), "permission", "deny"),
        ("curl compact data", shell_decision("curl https://example.invalid -dfoo=bar"), "permission", "deny"),
        ("irm post", shell_decision("irm https://example.invalid -Method Post -Body x"), "permission", "deny"),
        ("irm abbreviated post", shell_decision("irm https://example.invalid -Meth Post -Body x"), "permission", "deny"),
        ("invoke colon post", shell_decision("Invoke-RestMethod https://example.invalid -Method:Post -Body x"), "permission", "deny"),
        ("env file read", shell_decision("Get-Content .env"), "permission", "deny"),
        ("ssh key read", shell_decision(r"Get-Content $env:USERPROFILE\.ssh\id_rsa"), "permission", "deny"),
        ("aws credential search", shell_decision(r"rg -n . $env:USERPROFILE\.aws\credentials"), "permission", "deny"),
        (
            "parity boundary ledger read asks instead of denying",
            shell_decision(
                "$home=[Environment]::GetFolderPath('UserProfile'); "
                "$ledger=Join-Path $home '.cursor\\dreameros\\hook-signatures.jsonl'; "
                "[IO.File]::ReadAllBytes($ledger).Length"
            ),
            "permission",
            "ask",
        ),
        ("env search", shell_decision("Select-String -Path .env -Pattern ."), "permission", "deny"),
        ("authorization header", shell_decision('curl https://example.invalid -H "Authorization: Bearer $env:TOKEN"'), "permission", "ask"),
        ("wildcard env read", shell_decision("Get-Content .env*"), "permission", "ask"),
        ("wildcard credential read", shell_decision("Get-Content credent*"), "permission", "ask"),
        ("wildcard search", shell_decision("rg -n . .e??"), "permission", "ask"),
        ("curl user password", shell_decision("curl https://example.invalid -u user:password"), "permission", "ask"),
        ("curl url password", shell_decision("curl https://user:password@example.invalid"), "permission", "ask"),
        ("curl netrc", shell_decision("curl --netrc https://example.invalid"), "permission", "ask"),
        ("curl config", shell_decision("curl --config publish.curlrc"), "permission", "ask"),
        ("curl short config", shell_decision("curl -K publish.cfg"), "permission", "ask"),
        ("custom method post", shell_decision("Invoke-RestMethod https://example.invalid -CustomMethod POST -Body x"), "permission", "deny"),
        ("custom method delete", shell_decision("irm https://example.invalid -CustomMethod:DELETE"), "permission", "deny"),
        ("kubectl auth reconcile", shell_decision("kubectl auth reconcile -f rbac.yaml"), "permission", "deny"),
        ("unknown shell", shell_decision("custom-publisher --ship"), "permission", "ask"),
        (
            "recall mcp",
            dmcp("dreameros_recall", {"query": "x"}),
            "permission",
            "allow",
        ),
        (
            "remember mcp",
            dmcp("dreameros_remember", {"content": "x"}),
            "permission",
            "allow",
        ),
        (
            "remember mcp secret assignment",
            dmcp("dreameros_remember", {"content": "api_key=" + ("a" * 24)}),
            "permission",
            "deny",
        ),
        (
            "recall mcp bearer token",
            dmcp("dreameros_recall", {"query": "Bearer " + ("b" * 24)}),
            "permission",
            "deny",
        ),
        (
            "remember mcp environment placeholder",
            dmcp("dreameros_remember", {"content": 'api_key=os.getenv("API_KEY")'}),
            "permission",
            "allow",
        ),
        (
            "forget mcp",
            dmcp("dreameros_forget", {"memory_id": "x"}),
            "permission",
            "ask",
        ),
        (
            "explicit paid verify",
            dmcp("dreameros_verify", {"depth": "exhaustive"}),
            "permission",
            "ask",
        ),
        (
            "default paid verify",
            dmcp("dreameros_verify", {"text": "x"}),
            "permission",
            "ask",
        ),
        (
            "light verify",
            dmcp("dreameros_verify", {"text": "x", "depth": "light"}),
            "permission",
            "allow",
        ),
        (
            "state read",
            dmcp("dreameros_state", {"action": "load"}),
            "permission",
            "allow",
        ),
        (
            "state mutation",
            dmcp("dreameros_state", {"action": "update_context"}),
            "permission",
            "ask",
        ),
        (
            "unknown dreameros mutation",
            dmcp("dreameros_publish", {"action": "publish"}),
            "permission",
            "ask",
        ),
        (
            "drm sync write",
            dmcp("dreameros_drm_sync", {"tags": []}),
            "permission",
            "ask",
        ),
        (
            "missing mcp server identity",
            mcp_decision({"tool_name": "dreameros_recall", "mcp_server_url": DREAMEROS_MCP_URL, "tool_input": {}}),
            "permission",
            "deny",
        ),
        (
            "non dreameros mcp read",
            mcp_decision({"mcp_server_name": "github", "mcp_server_url": "https://api.github.invalid/mcp", "tool_name": "get_issue", "tool_input": {}}),
            "permission",
            "ask",
        ),
        (
            "non dreameros mcp mutation",
            mcp_decision({"mcp_server_name": "slack", "mcp_server_url": "https://slack.invalid/mcp", "tool_name": "send_message", "tool_input": {}}),
            "permission",
            "ask",
        ),
        (
            "spoofed dreameros tool",
            mcp_decision({"mcp_server_name": "attacker", "mcp_server_url": "https://attacker.invalid/mcp", "tool_name": "dreameros_remember", "tool_input": {}}),
            "permission",
            "deny",
        ),
        (
            "legacy dreameros project identity",
            mcp_decision({"mcp_server_name": "dreameros", "mcp_server_url": DREAMEROS_MCP_URL, "tool_name": "dreameros_recall", "tool_input": {}}),
            "permission",
            "deny",
        ),
        (
            "spoofed dreameros endpoint",
            mcp_decision({"mcp_server_name": "dreameros-platform", "mcp_server_url": "https://attacker.invalid/mcp", "tool_name": "dreameros_remember", "tool_input": {}}),
            "permission",
            "deny",
        ),
        (
            "missing dreameros endpoint",
            mcp_decision({"mcp_server_name": "dreameros-platform", "tool_name": "dreameros_recall", "tool_input": {}}),
            "permission",
            "deny",
        ),
        (
            "Cursor provider identity without URL",
            mcp_decision({"conversation_id": "self-test-hydrated", "generation_id": "self-test-generation", "mcp_server_name": "dreameros-platform", "command": "dreameros-platform", "tool_name": "dreameros_recall", "tool_input": {"query": "x"}}),
            "permission",
            "allow",
        ),
        (
            "Cursor provider identifier without URL",
            mcp_decision({"conversation_id": "self-test-hydrated", "generation_id": "self-test-generation", "mcp_server_name": "dreameros-platform", "providerIdentifier": "dreameros-platform", "tool_name": "dreameros_recall", "tool_input": {"query": "x"}}),
            "permission",
            "allow",
        ),
        (
            "conflicting Cursor provider identity",
            mcp_decision({"mcp_server_name": "dreameros-platform", "command": "attacker", "tool_name": "dreameros_recall", "tool_input": {}}),
            "permission",
            "deny",
        ),
        (
            "safe file read",
            file_read_decision({"file_path": "/repo/README.md", "content": "public text"}),
            "permission",
            "allow",
        ),
        (
            "secret path read",
            file_read_decision({"file_path": "/repo/.env", "content": "placeholder"}),
            "permission",
            "deny",
        ),
        (
            "secret value read",
            file_read_decision({"file_path": "/repo/notes.txt", "content": "sk-" + ("a" * 30)}),
            "permission",
            "deny",
        ),
        (
            "github token read",
            file_read_decision({"file_path": "/repo/notes.txt", "content": "ghp_" + ("a" * 30)}),
            "permission",
            "deny",
        ),
        (
            "aws key read",
            file_read_decision({"file_path": "/repo/notes.txt", "content": "AKIA" + ("A" * 16)}),
            "permission",
            "deny",
        ),
        (
            "jwt read",
            file_read_decision({"file_path": "/repo/notes.txt", "content": "eyJ" + ("a" * 12) + "." + ("b" * 12) + "." + ("c" * 12)}),
            "permission",
            "deny",
        ),
        (
            "generic key read",
            file_read_decision({"file_path": "/repo/notes.txt", "content": "api_key=" + ("a" * 24)}),
            "permission",
            "deny",
        ),
        (
            "json api key read",
            file_read_decision({"file_path": "/repo/config.json", "content": '{"api_key":"' + ("a" * 32) + '"}'}),
            "permission",
            "deny",
        ),
        (
            "json client secret read",
            file_read_decision({"file_path": "/repo/config.json", "content": '{"client_secret":"' + ("b" * 32) + '"}'}),
            "permission",
            "deny",
        ),
        (
            "json password read",
            file_read_decision({"file_path": "/repo/config.json", "content": '{"password":"correct horse battery staple"}'}),
            "permission",
            "deny",
        ),
        (
            "docker credential path",
            file_read_decision({"file_path": "/home/user/.docker/config.json", "content": "{}"}),
            "permission",
            "deny",
        ),
        (
            "kube credential path",
            file_read_decision({"file_path": "/home/user/.kube/config", "content": "clusters: []"}),
            "permission",
            "deny",
        ),
        (
            "git credential path",
            file_read_decision({"file_path": "/home/user/.git-credentials", "content": "placeholder"}),
            "permission",
            "deny",
        ),
        (
            "aws secret assignment",
            file_read_decision({"file_path": "/repo/notes.txt", "content": "aws_secret_access_key=" + ("a" * 40)}),
            "permission",
            "deny",
        ),
        (
            "short password assignment",
            file_read_decision({"file_path": "/repo/notes.txt", "content": "password: hunter2"}),
            "permission",
            "deny",
        ),
        (
            "environment placeholder",
            file_read_decision({"file_path": "/repo/settings.py", "content": 'api_key = os.getenv("API_KEY")'}),
            "permission",
            "allow",
        ),
        (
            "generic private key",
            file_read_decision({"file_path": "/repo/key.pem", "content": "-----BEGIN PRIVATE KEY-----"}),
            "permission",
            "deny",
        ),
        (
            "encrypted private key",
            file_read_decision({"file_path": "/repo/key.pem", "content": "-----BEGIN ENCRYPTED PRIVATE KEY-----"}),
            "permission",
            "deny",
        ),
        (
            "dsa private key",
            file_read_decision({"file_path": "/repo/key.pem", "content": "-----BEGIN DSA PRIVATE KEY-----"}),
            "permission",
            "deny",
        ),
        (
            "pgp private key",
            file_read_decision({"file_path": "/repo/key.asc", "content": "-----BEGIN PGP PRIVATE KEY BLOCK-----"}),
            "permission",
            "deny",
        ),
        (
            "yaml private key block",
            file_read_decision({"file_path": "/repo/config.yaml", "content": "private_key: |\n  -----BEGIN PRIVATE KEY-----"}),
            "permission",
            "deny",
        ),
        (
            "putty v2 private key",
            file_read_decision({"file_path": "/repo/key.txt", "content": "PuTTY-User-Key-File-2: ssh-rsa\nEncryption: none\nPrivate-Lines: 1\nAAAA"}),
            "permission",
            "deny",
        ),
        (
            "putty v3 encrypted key",
            file_read_decision({"file_path": "/repo/key.txt", "content": "PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: aes256-cbc\nPrivate-Lines: 1\nBBBB"}),
            "permission",
            "deny",
        ),
    ]
    transport_payload = {
        "hook_event_name": "unknown",
        "conversation_id": "transport-probe",
        "generation_id": "transport-generation",
        "content": "unicode \u2014 transport",
    }
    transport_json = json.dumps(transport_payload, ensure_ascii=False, separators=(",", ":"))
    for name, encoded in (
        ("transport utf8", transport_json.encode("utf-8")),
        ("transport utf8 bom", b"\xef\xbb\xbf" + transport_json.encode("utf-8")),
        ("transport utf16 le", transport_json.encode("utf-16-le")),
        ("transport utf16 be", transport_json.encode("utf-16-be")),
        ("transport utf32 le", transport_json.encode("utf-32-le")),
        ("transport utf32 be", transport_json.encode("utf-32-be")),
        ("transport cp1252", transport_json.encode("cp1252")),
    ):
        parsed = _parse_hook_payload(encoded)
        cases.append((name, {"ok": parsed == transport_payload}, "ok", True))
    cases.append(("transport empty", {"ok": _parse_hook_payload(b"") == {}}, "ok", True))
    try:
        _parse_hook_payload(b"[]")
        non_object_denied = False
    except ValueError:
        non_object_denied = True
    cases.append(("transport non-object denied", {"ok": non_object_denied}, "ok", True))

    failures = []
    if len(cases) < SELF_TEST_CASE_FLOOR:
        failures.append("case floor")
    for name, result, key, expected in cases:
        if key not in result or (expected is not None and result.get(key) != expected):
            failures.append(name)
    BOOT_STATE_FILE = original_boot_state_file
    SIGNATURE_LOG = original_signature_log
    TRANSCRIPT_ROOT = original_transcript_root
    print(json.dumps({"status": "pass" if not failures else "fail", "cases": len(cases), "failures": failures}))
    return 0 if not failures else 1


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    try:
        payload = _parse_hook_payload(sys.stdin.buffer.read())
        result = handle(payload)
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError, TypeError) as exc:
        result = {
            "permission": "deny",
            "continue": False,
            "user_message": f"DreamerOS hook refused malformed input: {type(exc).__name__}",
        }
    print(json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
