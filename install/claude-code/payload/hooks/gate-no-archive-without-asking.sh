#!/bin/bash
# PreToolUse GATE. Refuses to archive or end a session without the operator.
#
# This is operator requirement 5, stated at the very start of the work and
# still not built hours later: "doesn't archive without asking - losing remote
# session / PC access."
#
# An audit on 2026-08-10 found ZERO gating for it. No mention of "archive" in
# CLAUDE.md, in any hook, in any agent, or in either settings file. The deny
# list held 17 entries and none touched session management, while
# mcp__ccd_session_mgmt__archive_session sat live and reachable.
#
# WHY THIS IS THE MOST DANGEROUS UNGATED TOOL ON THIS MACHINE:
# The operator works REMOTE. They cannot start a new local session on the PC
# from somewhere else. Archiving the session does not lose a chat - it loses
# their access to the machine until they are physically back at it. That is
# not an inconvenience that a later turn can repair. It ends the engagement.
#
# It is also the one failure the assistant cannot apologise for afterwards,
# because there is no afterwards - the channel used to say sorry is the thing
# that was destroyed.
#
# So this denies unconditionally. There is no "unless it seems fine" branch.
# An operator who wants a session archived can archive it themselves in one
# click, which is cheaper than any recovery from getting this wrong.

set -uo pipefail

allow() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'; exit 0; }

CTX=$(cat 2>/dev/null || echo '{}')

TOOL=$(printf '%s' "$CTX" | python -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(''); raise SystemExit
print(d.get('tool_name') or d.get('toolName') or '')
" 2>/dev/null || echo "")

[ -n "$TOOL" ] || allow

# Match on the ACTION, not on one vendor's tool name. A future connector that
# ships its own archive/delete-session verb must be caught by the same net, or
# this gate protects only the one spelling that existed the day it was written.
case "$TOOL" in
  *archive_session*|*archive-session*|*delete_session*|*delete-session*|\
  *end_session*|*close_session*|*terminate_session*|*session_archive*)
    ;;
  *) allow ;;
esac

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED by the no-archive gate. The tool \\"%s\\" would archive, close, or delete a session, and no assistant may do that on this machine.\\n\\nThe operator works REMOTE and CANNOT start a new local session on this PC from elsewhere. Archiving does not lose a conversation - it loses their ACCESS TO THE MACHINE until they are physically back at it. There is no later turn that repairs it, because the channel needed to fix it is the thing destroyed.\\n\\nThis is operator requirement 5, stated at the start of the work: does not archive without asking, losing remote session and PC access.\\n\\nWhat to do instead: ASK. Say plainly which session you believe should be archived and why, and let the operator do it. It is one click for them and unrecoverable for you. If the operator has already said to archive this exact session in this conversation, tell them this gate refused and ask them to perform it - do NOT look for another route to the same action."}}\n' "$TOOL"
