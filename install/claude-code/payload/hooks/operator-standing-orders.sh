#!/bin/bash
# Machine-wide SessionStart hook - operator standing orders (boot contract).
# RETIRED: not registered by the installer, which removes any registration of
# it. Kept as a reference for the optional user-scope form: a SessionStart hook
# that boots every session on this machine with the standing orders.
#
# Dedup guard: when the current project ships its own copy of this hook, this
# user-scope copy emits nothing so the orders are injected exactly once.
#
# Keep one versioned, reviewed source for the orders and mirror it here.

set -euo pipefail

if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/.claude/hooks/operator-standing-orders.sh" ]; then
  exit 0
fi

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "## Standing orders (example set) - do these without being asked\n\nScope note: orders 1 and 5 use DreamerOS tools. When the DreamerOS connection is not available in this project, apply orders 2 to 4 and skip the tool calls instead of failing.\n\n1. CHECK BEFORE AND AFTER. Before acting, recall what DreamerOS already holds on the topic. After acting, save one short record of what changed.\n\n2. READ THE LIVE THING. Answer questions about state from a reading taken now, and name the instrument. Do not answer from memory.\n\n3. PLAIN WORDS. Customer copy says intent fidelity and checked answers. No em dashes. Spaced hyphens only.\n\n4. NO SECRETS. Record names and set or unset status only. Never a value.\n\n5. CLOSE CLEANLY. End a substantive session with a short report in three parts: fixed, needs the owner, already honest."
  }
}
EOF
