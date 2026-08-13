#!/bin/bash
set -euo pipefail

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "## DreamerOS vendor-neutral execution layer\n\nCombine this layer with all existing project and operator rules. Do not delete, weaken, or silently replace working intent.\n\nExecution order: deterministic local file, Git, test, build, and local service work first; then DreamerOS context and intent-fidelity checks; then the smallest reliable paid model; then larger models or multi-engine verification when complexity or risk requires them.\n\nAt session start, call DreamerOS session/context/state tools when available and report CONNECTED, PARTIALLY CONNECTED, or BLOCKED. If two bounded connection attempts fail, label the session STANDALONE and quarantine output from shared state until DreamerOS reconnects and the Human Conductor approves release.\n\nUse small models for clear mechanical work, balanced coding models for normal implementation, and the strongest available model for architecture, security, ambiguity, and final high-impact review. Explicitly call dreameros_agent or dreameros_route for governed remote offload. Native subagents do not automatically become DreamerOS agents.\n\nBefore and after substantive changes, refresh DreamerOS as needed, fetch and compare Git without discarding work, verify targets, inspect the resulting diff, run proportional checks, scan loose ends, and publish evidence. Preserve every unrelated modified or untracked file.\n\nHuman Conductor approval is required for destructive, irreversible, public, production, key-custody, signing, canon, SCS, deployment, merge, and other trust-bearing actions unless a current explicit HC instruction already grants that exact authority."
  }
}
EOF
