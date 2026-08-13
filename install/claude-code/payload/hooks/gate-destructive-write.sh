#!/bin/bash
# PreToolUse GATE on Write. Refuses a whole-file write that would silently
# delete most of an existing file.
#
# Ported from gateway canon "Destructive Payload Guardrail", codified after
# commit 725eb8c shipped with a correct-looking subject line and a payload that
# erased 1497 lines from gateway/app/orchestrator.py. Railway deploys on push,
# so production ran a broken orchestrator for roughly twenty minutes until an
# emergency restore. The commit message described the surgery. The diff did not.
#
# The canon states the detection rule directly: a Write on an existing file
# whose pre-write line count is much larger than the new content is almost
# certainly destructive. It also names the safer habit - prefer Edit over Write
# when the change is surgical.
#
# This gate does not judge intent. It measures the diff and refuses a shape that
# has already destroyed work once in this codebase.

set -uo pipefail

allow() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'; exit 0; }

CTX=$(cat 2>/dev/null || echo '{}')

read -r FILE NEWLINES <<EOF
$(printf '%s' "$CTX" | python -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('. 0'); raise SystemExit
ti = d.get('tool_input') or d.get('toolInput') or {}
p = ti.get('file_path') or ''
c = ti.get('content')
n = c.count(chr(10)) + 1 if isinstance(c, str) and c else 0
print((p if p else '.'), n)
" 2>/dev/null || echo ". 0")
EOF

[ -n "${FILE:-}" ] && [ "$FILE" != "." ] || allow
[ -f "$FILE" ] || allow   # new file, nothing to destroy

OLDLINES=$(wc -l < "$FILE" 2>/dev/null | tr -d ' ')
[ "${OLDLINES:-0}" -gt 0 ] || allow

LOST=$((OLDLINES - ${NEWLINES:-0}))
[ "$LOST" -gt 0 ] || allow

# Two independent triggers, both taken from the canon's own detection
# signatures. Either one alone is enough to stop and look.
TRIP=""
[ "$LOST" -ge 500 ] && TRIP="it removes ${LOST} lines"
if [ "$OLDLINES" -gt 200 ] && [ "${NEWLINES:-0}" -lt 50 ]; then
  TRIP="the file has ${OLDLINES} lines and the replacement has ${NEWLINES:-0}"
fi
[ -n "$TRIP" ] || allow

PCT=$(( LOST * 100 / OLDLINES ))

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED by the destructive-write gate. This Write targets an existing file and %s - a %s percent reduction, from %s lines to %s.\\n\\nThis is the shape that erased 1497 lines from orchestrator.py and broke production for twenty minutes. The commit subject described a surgical change; the diff did not match it.\\n\\nDo this instead: use Edit for a surgical change. Edit cannot silently drop the rest of the file, which is the whole reason to prefer it.\\n\\nIf you genuinely intend to replace the whole file, read the current content first, account for every section you are dropping, and tell the operator plainly what is being removed and why. A deletion the operator has agreed to is fine. A deletion nobody noticed is the failure this gate exists to stop."}}\n' "$TRIP" "$PCT" "$OLDLINES" "${NEWLINES:-0}"
