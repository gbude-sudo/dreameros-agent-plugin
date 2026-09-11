#!/usr/bin/env bash
# DREAMEROS-CLAUDE-SESSION-START-ADAPTER v1.1.0
# Thin runtime adapter. The full boot canon remains in the native global file.
set -euo pipefail

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "DreamerOS session boot is mandatory before substantive work. Use the exact DreamerOS tool names exposed by this session; never hardcode an MCP server id. Call dreameros_session_package first for the active Claude engine and current project. It is the only unconditional boot call and carries the full Boot Canon plus a handoff summary. When the package directs it or the current task needs read-only enrichment, call in this order: (1) dreameros_session_handoff_read for the full record when present, (2) dreameros_context and use its SCS as the read-only current-state channel, (3) a scoped dreameros_recall for the current topic, and (4) relevant dreameros_canon. If package_continuation is metadata-first and the visible package lacks a complete wrapper or full hash proof, fetch parts 1 through N with the same tool, verify part hashes, order, user-bound package_id and content_hash, reassemble, and verify the full boot-canon body before proceeding. Failed reconstruction is BLOCKED. The mixed read/write state tool is not a generic bootstrap call. Then read global, repository, and nested instructions; measure Git state; and check active coordination claims. If any required DreamerOS tool is unavailable, report BLOCKED for DreamerOS hydration and continue only safe local work in STANDALONE mode. Never expose or store credentials, token values, private keys, or environment values."
  }
}
JSON