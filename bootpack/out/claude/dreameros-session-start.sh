#!/usr/bin/env bash
# DREAMEROS-CLAUDE-SESSION-START-ADAPTER v1.0.0
# Thin runtime adapter. The full boot canon remains in the native global file.
set -euo pipefail

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "DreamerOS session boot is mandatory before substantive work. Use the exact DreamerOS tool names exposed by this session; never hardcode an MCP server id. In order: (1) call dreameros_session_package for the active Claude engine and current project, (2) call dreameros_context, (3) call dreameros_state with action load, and (4) call a scoped dreameros_recall for the current topic. Read relevant canon only when the task requires it. Then read global, repository, and nested instructions; measure Git state; and check active coordination claims. If any required DreamerOS tool is unavailable, report BLOCKED for DreamerOS hydration and continue only safe local work in STANDALONE mode. Never expose or store credentials, token values, private keys, or environment values."
  }
}
JSON