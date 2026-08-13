#!/bin/bash
# PreToolUse GATE for dreameros_remember. Refuses an anchor that the substrate
# will reject, before the call is spent.
#
# Built 2026-08-10 after three anchor writes in one session came back with
# "Memory content exceeds maximum size (10KB). Please shorten and try again."
# Each rejection cost a full round trip and, worse, each one risked the anchor
# never being written at all - which is how a session's findings evaporate.
#
# The substrate ceiling is 10240 bytes of content. This blocks at 9800 to leave
# headroom, and it tells the model to SPLIT into numbered cross-referenced parts
# rather than to cut material. Cutting loses evidence. Splitting does not.

set -uo pipefail

allow() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'; exit 0; }

CTX=$(cat 2>/dev/null || echo '{}')

SIZE=$(printf '%s' "$CTX" | python -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
ti = d.get('tool_input') or d.get('toolInput') or {}
c = ti.get('content')
print(len(c.encode('utf-8')) if isinstance(c, str) else 0)
" 2>/dev/null || echo 0)

[ "${SIZE:-0}" -gt 9800 ] || allow

OVER=$((SIZE - 9800))

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: this anchor is %s bytes. The substrate rejects content over 10240 bytes, and this gate stops at 9800 to leave headroom. You are %s bytes over.\\n\\nSPLIT it, do not cut it. Cutting loses evidence; splitting keeps all of it.\\n\\nWrite it as numbered parts. Give each part its own title ending in PART N of M. In every part, name the anchor ids of its siblings so no part can be read alone and mistaken for the whole. Write the parts in order and record each returned id in the next one.\\n\\nSplit on a real seam - severity, or surface, or one repo per part. Do not split mid-finding, because half a finding reads as a complete one."}}\n' "$SIZE" "$OVER"
