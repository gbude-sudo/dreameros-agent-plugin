#!/usr/bin/env python3
"""SessionStart: fetch the live DreamerOS session package and prove the local
boot canon matches it. Runs itself; the model does not choose to run it.

WHY THIS EXISTS
2026-09-16. HC asked that every Claude Code session boot its canon from
DreamerOS as the live source, not from a stale local copy. Measured that day:
the existing SessionStart hooks (gate_session_boot.py and the repo's
dreameros-session-start.sh) only inject text TELLING the model to call
dreameros_session_package. Nothing made the call. A session after /compact
did not call it at all. R26: one origin, every venue.

WHAT IT DOES
1. Reads DREAMEROS_MCP_TOKEN from the process env, then from the Windows user
   environment (HKCU). The value is sent only in an Authorization header. It
   is never printed, logged, or written.
2. POSTs https://mcp.dreameros.app/api/v1/actions/session-package.
3. Hashes the generated block in ~/.claude/CLAUDE.md (between the BEGIN and
   END DREAMEROS-BOOT-CANON markers, CRLF to LF, trailing whitespace trimmed,
   one final newline). Measured 2026-09-16: that normalization reproduces the
   live sha256 3fa61b2d... exactly.
4. Compares it to package_components.boot_canon.sha256.
5. Tells the session the result as added context, and tells the operator
   through systemMessage:
     HYDRATED   live package fetched, local canon matches.
     CONFLICT   live package fetched, local canon differs. Stop and rebuild.
     BLOCKED    no token, no network, or a bad response. Standalone only.
6. Writes ~/.claude/dreameros-boot-status.json (no secrets) as evidence.

CONTRACT
Always exits 0. On SessionStart the added context and systemMessage are the
channel that reaches the model and the operator. A CONFLICT or BLOCKED result
is stated loudly in both, never swallowed.

Test hooks, no network:
  DREAMEROS_LIVE_CANON_FAKE_SHA=<sha>    use this instead of fetching
  DREAMEROS_LIVE_CANON_CLAUDE_MD=<path>  hash this file instead
"""
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

URL = "https://mcp.dreameros.app/api/v1/actions/session-package"
HOME = os.path.expanduser("~")
CLAUDE_MD = os.environ.get("DREAMEROS_LIVE_CANON_CLAUDE_MD") or os.path.join(HOME, ".claude", "CLAUDE.md")
STATUS_FILE = os.path.join(HOME, ".claude", "dreameros-boot-status.json")
BLOCK = re.compile(
    r"<!-- BEGIN DREAMEROS-BOOT-CANON[^\n]*-->\n(.*?)<!-- END DREAMEROS-BOOT-CANON[^\n]*-->",
    re.S,
)


def _token():
    tok = os.environ.get("DREAMEROS_MCP_TOKEN")
    if tok:
        return tok
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as k:
            return winreg.QueryValueEx(k, "DREAMEROS_MCP_TOKEN")[0]
    except Exception:
        return None


def local_canon_sha(path=CLAUDE_MD):
    try:
        with open(path, encoding="utf-8-sig") as fh:
            text = fh.read().replace("\r\n", "\n")
    except OSError as exc:
        return None, f"cannot read {path}: {exc}"
    m = BLOCK.search(text)
    if not m:
        return None, f"no DREAMEROS-BOOT-CANON block in {path}"
    body = m.group(1).rstrip() + "\n"
    return hashlib.sha256(body.encode("utf-8")).hexdigest(), None


def fetch_package(project):
    fake = os.environ.get("DREAMEROS_LIVE_CANON_FAKE_SHA")
    if fake:
        return {"package_components": {"boot_canon": {"sha256": fake, "version": "test"}},
                "package_id": "test", "ttl_seconds": 0}, None
    tok = _token()
    if not tok:
        return None, "DREAMEROS_MCP_TOKEN is not set"
    req = urllib.request.Request(
        URL,
        data=json.dumps({"engine": "claude", "project_context": project[:200]}).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {tok}",
            "Content-Type": "application/json",
            "User-Agent": "dreameros-claude-code-sessionstart",
        },
    )
    last = None
    for attempt in (1, 2):
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return json.loads(r.read().decode("utf-8", "replace")), None
        except urllib.error.HTTPError as exc:
            last = f"HTTP {exc.code}"
            if exc.code in (401, 403):
                break
        except Exception as exc:
            last = f"{type(exc).__name__}: {exc}"
        if attempt == 1:
            time.sleep(2)
    return None, last


def decide(pkg, err, local_sha, local_err):
    if err:
        return "BLOCKED", f"live package not fetched ({err})"
    try:
        bc = pkg["package_components"]["boot_canon"]
        live_sha = bc["sha256"]
    except Exception:
        return "BLOCKED", "live package has no package_components.boot_canon.sha256"
    if local_err:
        return "CONFLICT", f"live canon {bc.get('version')} {live_sha[:12]}, local canon unreadable: {local_err}"
    if local_sha != live_sha:
        return "CONFLICT", (
            f"live canon {bc.get('version')} sha {live_sha[:12]} differs from local "
            f"~/.claude/CLAUDE.md block sha {local_sha[:12]}"
        )
    return "HYDRATED", (
        f"live canon {bc.get('version')} sha {live_sha[:12]} matches local ~/.claude/CLAUDE.md "
        f"(package {str(pkg.get('package_id'))[:8]})"
    )


MESSAGES = {
    "HYDRATED": (
        "DREAMEROS BOOT (hook-verified, the model did not choose this): HYDRATED. {detail}. "
        "The boot canon you loaded from ~/.claude/CLAUDE.md IS the live DreamerOS canon. "
        "HYDRATED means context only: no request has been checked. Substantive answers "
        "still need dreameros_skill or dreameros_chat for a PIPELINE status."
    ),
    "CONFLICT": (
        "DREAMEROS BOOT CONFLICT (hook-verified): {detail}. The local canon is STALE or edited. "
        "Do not treat ~/.claude/CLAUDE.md rules as current. Tell the operator in your first reply, "
        "call dreameros_session_package and follow its package_text, and rebuild with "
        "bootpack/build-boot-pack.ps1 -Install. No substantive work until resolved."
    ),
    "BLOCKED": (
        "DREAMEROS BOOT BLOCKED (hook-verified): {detail}. The live canon was NOT confirmed. "
        "Report BLOCKED for DreamerOS hydration in your first reply and do only safe local work "
        "in STANDALONE mode until dreameros_session_package succeeds."
    ),
}


def main():
    try:
        raw = sys.stdin.buffer.read().lstrip(b"\xef\xbb\xbf").strip()
        payload = json.loads(raw.decode("utf-8", "replace")) if raw else {}
    except Exception:
        payload = {}
    project = os.path.basename((payload.get("cwd") or os.getcwd()).rstrip("\\/")) or "unknown"

    local_sha, local_err = local_canon_sha()
    pkg, err = fetch_package(project)
    state, detail = decide(pkg, err, local_sha, local_err)

    try:
        with open(STATUS_FILE, "w", encoding="utf-8") as fh:
            json.dump({
                "state": state,
                "detail": detail,
                "checked_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "session_id": payload.get("session_id"),
                "source": payload.get("source"),
                "project": project,
                "local_sha256": local_sha,
                "live_sha256": ((pkg or {}).get("package_components") or {}).get("boot_canon", {}).get("sha256"),
            }, fh, indent=2)
    except OSError:
        pass

    msg = MESSAGES[state].format(detail=detail)
    out = {
        "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": msg},
        "systemMessage": f"DreamerOS boot: {state} - {detail}",
    }
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
