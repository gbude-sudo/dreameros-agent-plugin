#!/bin/bash
set -euo pipefail

# Only surface the pre-close checklist if at least one DreamerOS repo has
# uncommitted changes (staged or unstaged). Suppresses the reminder when
# Claude is idle or answering questions with no file edits in flight.

REPOS=(
  "__DREAMEROS_REPO_ROOT__/dreameros-app-frontend"
  "__DREAMEROS_REPO_ROOT__/dreameros-scs-gateway"
  "__DREAMEROS_REPO_ROOT__/dreameros-app-site"
  "__DREAMEROS_REPO_ROOT__/dreamerOS"
  "__DREAMEROS_REPO_ROOT__/dreameros-hc-command-center"
  "__DREAMEROS_REPO_ROOT__/dreameros-light-proxy"
  "__DREAMEROS_REPO_ROOT__/intentfidelityprotocol-site"
  "__DREAMEROS_REPO_ROOT__/thedreamerai-site"
)

HAS_CHANGES=0
for repo in "${REPOS[@]}"; do
  if [ -d "$repo/.git" ]; then
    if ! git -C "$repo" diff --quiet 2>/dev/null || ! git -C "$repo" diff --cached --quiet 2>/dev/null; then
      HAS_CHANGES=1
      break
    fi
  fi
done

if [ "$HAS_CHANGES" -eq 1 ]; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "Stop",
    "additionalContext": "Before ending substantive DreamerOS work: re-read changed files, inspect the final diff, run applicable checks, scan TODO/FIXME/conflict markers/placeholders/secrets/untracked files, recheck Git remote identity, publish an evidence-bounded DreamerOS continuity anchor, and report FIXED, NEEDS HC, and ALREADY HONEST. Never claim commit, push, merge, deployment, production verification, or DreamerOS synchronization without direct evidence."
  }
}
EOF
fi
