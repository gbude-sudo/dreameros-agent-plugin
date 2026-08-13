#!/bin/bash
# Stop GATE. Verifies CLAIMS against reality before a turn can end.
#
# Built 2026-08-10 after this thread made the same class of error three times
# in one session. Each time the artifact existed and the capability did not:
#
#   1. "The worktrees were rescued as rescue/* branches." The branches existed
#      and pointed at commits already on main. They held ZERO commits. Every
#      file was still uncommitted on disk. A branch label is not a rescue.
#   2. "All branches pushed." One was not. The push log said so; the remote
#      disagreed. `git ls-remote` found it in seconds. Nobody had looked.
#   3. "Nine agents are live." Nine FILES existed. Four were never registered.
#
# The operator caught none of these from the reports, because the reports were
# confident and internally consistent. Only the destination disagreed.
#
# WHAT THIS CHECKS - only things provable with a command, no judgement:
#   A. A branch whose name says rescue/* but which holds no commits main lacks.
#      That is the shape of a rescue that rescued nothing.
#   B. A recently-touched branch with an upstream whose remote SHA does not
#      match local. That is the shape of "I pushed it" when the ref never
#      landed, or landed stale.
#
# It does NOT judge whether work is "finished" - a hook cannot know that, and a
# gate that guesses is worse than no gate.
#
# Bounded: only branches with a commit in the last 12 hours, so this reports on
# the session's own work and not on 165 branches of history. One ls-remote per
# repo, hard timeout, and it FAILS OPEN on any network trouble - a Stop gate
# that hangs on a slow network is worse than one that misses a case.
#
# LOOP GUARD, load bearing, same contract as gate-stop-no-half-states.sh: the
# identical finding twice in a row escalates to the operator instead of
# deadlocking the session. Never trap the model in a state it cannot resolve.

set -uo pipefail

STATE_DIR="$HOME/.claude/.gate-state"
mkdir -p "$STATE_DIR" 2>/dev/null
MARK="$STATE_DIR/stop-claim-verification.last"

REPOS=(
  "__DREAMEROS_REPO_ROOT__/dreameros-scs-gateway"
  "__DREAMEROS_REPO_ROOT__/dreameros-app-frontend"
  "__DREAMEROS_REPO_ROOT__/dreameros-app-site"
  "__DREAMEROS_REPO_ROOT__/dreamerOS"
)

PROBLEMS=""
SIG=""
CUTOFF=$(( $(date +%s) - 43200 ))   # 12 hours

for repo in "${REPOS[@]}"; do
  [ -d "$repo/.git" ] || continue
  name="${repo##*/}"

  # --- A. rescue/* branches that rescued nothing -------------------------
  while IFS='|' read -r br ts; do
    [ -n "$br" ] || continue
    [ "${ts:-0}" -ge "$CUTOFF" ] || continue
    git -C "$repo" rev-parse --verify main >/dev/null 2>&1 || continue
    n=$(git -C "$repo" rev-list --count "main..$br" 2>/dev/null || echo 0)
    if [ "${n:-0}" -eq 0 ]; then
      PROBLEMS="${PROBLEMS}\\n  ${name}: branch '${br}' is named rescue but holds ZERO commits main does not already have. If work was meant to be saved onto it, that work is still uncommitted."
      SIG="${SIG}|empty-rescue:${name}:${br}"
    fi
  done <<< "$(git -C "$repo" for-each-ref --format='%(refname:short)|%(committerdate:unix)' 'refs/heads/rescue/*' 2>/dev/null)"

  # --- B. "I pushed it" versus what the remote actually holds -------------
  RECENT=$(git -C "$repo" for-each-ref --format='%(refname:short)|%(committerdate:unix)|%(upstream:short)|%(objectname)' refs/heads/ 2>/dev/null \
           | awk -F'|' -v c="$CUTOFF" '$2>=c && $3!=""')
  [ -n "$RECENT" ] || continue

  url=$(git -C "$repo" remote get-url origin 2>/dev/null) || continue
  [ -n "$url" ] || continue
  REMOTE=$(timeout 20 git ls-remote --heads "$url" 2>/dev/null) || continue
  [ -n "$REMOTE" ] || continue

  while IFS='|' read -r br ts up sha; do
    [ -n "$br" ] || continue
    rsha=$(printf '%s\n' "$REMOTE" | awk -v b="refs/heads/$br" '$2==b{print $1}')
    if [ -z "$rsha" ]; then
      PROBLEMS="${PROBLEMS}\\n  ${name}: branch '${br}' tracks '${up}' but NO ref of that name exists on the remote. It was not pushed, whatever the push output said."
      SIG="${SIG}|absent:${name}:${br}"
    elif [ "$rsha" != "$sha" ]; then
      PROBLEMS="${PROBLEMS}\\n  ${name}: branch '${br}' is at ${sha:0:8} locally but ${rsha:0:8} on the remote. The remote does not have your latest commit."
      SIG="${SIG}|stale:${name}:${br}"
    fi
  done <<< "$RECENT"
done

if [ -z "$PROBLEMS" ]; then
  rm -f "$MARK" 2>/dev/null
  exit 0
fi

PREV=$(cat "$MARK" 2>/dev/null || echo "")
if [ "$PREV" = "$SIG" ]; then
  rm -f "$MARK" 2>/dev/null
  printf '{"systemMessage":"GATE ESCALATION: the same unverified claim was flagged once and is still unresolved, so this turn is allowed to end rather than deadlocking.\\n\\nUNVERIFIED:%s\\n\\nThis needs the operator. Nothing is lost - but a report may have said this work was saved or pushed when the destination disagrees."}\n' "$PROBLEMS"
  exit 0
fi

printf '%s' "$SIG" > "$MARK" 2>/dev/null

REASON="BLOCKED by the claim-verification gate. Something was reported as saved or pushed, and the destination does not agree:${PROBLEMS}\\n\\nResolve it, then finish the turn. Commit the work onto the branch, or push the branch, or tell the operator plainly that it is being left and why.\\n\\nWhy this gate exists: on 2026-08-10 this thread reported worktrees as rescued when the branches held zero commits, and reported every branch pushed when one had not been. Both reports were confident and both were wrong. Only the destination disagreed, and nobody had asked it. Check the RESULT, at the destination - never the intent of the command you ran."

printf '{"continue":false,"stopReason":"%s","systemMessage":"Stop gate: a save or push claim does not match the destination."}\n' "$REASON"
