#!/bin/bash
# Machine-wide SessionStart hook - operator standing orders (boot contract).
# User-scope copy installed 2026-08-04 at the operator's request so EVERY
# Claude Code session on this machine boots with the standing orders, not
# just sessions in repos that carry the repo-scoped copy.
#
# Dedup guard: when the current project ships its own copy of this hook
# (dreameros-app-frontend does, at .claude/hooks/operator-standing-orders.sh),
# this user-scope copy emits nothing so the orders are injected exactly once.
#
# Canonical source of truth: the repo-scoped copy in dreameros-app-frontend
# (versioned, PR-reviewed). When editing the contract, edit the repo copy
# first, then mirror here. Substrate procedural memories carry the same
# orders as a third layer (tags: standing-practice, operator-directive).

set -euo pipefail

if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/.claude/hooks/operator-standing-orders.sh" ]; then
  exit 0
fi

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "## Operator Standing Orders (boot contract, 2026-08-04, machine-wide) - do these without being asked\n\nScope note: orders 1, 2, 6, and 7 involve dreameros_* MCP tools; when the DreamerOS MCP is not connected in this project, apply the discipline orders (3, 4, 5, 8) and skip the tool calls rather than failing.\n\n1. BEFORE/AFTER GATEWAY CHECK-INS (substrate 08503bc9): before acting, dreameros_state load + dreameros_recall the topic (recall query \"session-end continuity-anchor\" reaches the master index in one hop). After acting, dreameros_remember an anchor + update_context. The operator-context header on every dreameros_* return is the canon runtime speaking: honor its verified facts, stop on contradictions.\n\n2. SIDE QUESTS RIDE DREAMEROS, MAIN MODEL STAYS ON MAIN QUEST (substrate 08503bc9): dispatch side-quest work (compilation, grounding research, verification legs, audits) through dreameros_agent / dreameros_verify / dreameros_route so the gateway's own routing - including the Fireworks verifier pool, runtime-live since 2026-07-31 - carries the load. Client-side Agent tool fan-out uses the SMALLEST model that holds integrity (haiku for gathering and remedial tasks); synthesis stays with the main model. Known behavior: dreameros_agent in audit_only mode returns an intent-verified execution PLAN, not a result payload - use dreameros_memory_full for substrate reads.\n\n3. AUTO-MERGE AUTHORITY (substrate 3fa7b5be, operator: \"you can auto commit all prs\"): complete PR merges end to end without waiting. gh pr merge --admin is authorized ONLY when every real check is green and the sole blocker is the three stale branch-protection contexts (canon-parity, metadata cleanliness, Trojan Source). Never bypass a genuinely failing or pending check. PRs always (no direct push to main). Local git clearance is part of done: after merge, return checkouts to main, delete the branch only after proving the squash landed.\n\n4. VOCABULARY (substrate 49c1fcae, operator: \"we dont even say governance\"): the category is INTENT FIDELITY. Customer copy and positioning never say governance or governed. No em dashes anywhere - spaced hyphens only. Commits author DreamerOS <215420744+gbude-sudo@users.noreply.github.com>, no tool attribution.\n\n5. CONSOLIDATION DOCTRINE (substrate a1fc4aa8): duplicate memories and ideas are NEVER deleted - fold the weaker duplicates into the strongest member of the set, cite absorbed UUIDs, keep originals as history.\n\n6. USAGE LOG (standing since 2026-08-03): every session that calls a dreameros_* tool appends its calls to docs/dreameros-usage-log.md in dreameros-app-frontend (what was asked, what it returned, where it fell short).\n\n7. RUNTIME TRUTH (verified 2026-08-04): production gateway health IS reachable from the sandbox - GET https://dreameros-scs-gateway-production.up.railway.app/health returns live version, migration count, and direction-set versions. Use it for runtime verification when the Railway MCP is blind. Still never narrate a code default as a live env value, and never write secret VALUES anywhere.\n\n8. SESSION CLOSE: end with a master-index anchor containing the literal phrase \"session-end continuity-anchor\" plus a UUID index of the session's detail anchors, so the next hydration lands on it in one hop. Three-bucket report on anything substantive: FIXED (PR + citation), NEEDS HC (precise blocker + citation), ALREADY HONEST (citation why)."
  }
}
EOF
