#!/bin/bash
# Stop GATE. This one REFUSES to let a turn end. It does not narrate.
#
# Built 2026-08-10 after the operator observed, correctly, that the existing
# Stop hooks fired roughly forty times in one session and changed nothing.
# They return additionalContext, which is a note handed to someone who may not
# read it. This returns continue:false, which ends nothing until the state is
# actually resolved.
#
# WHAT IT BLOCKS - only provable, genuinely bad half-states. It does not try to
# police intent or judge whether work was "finished", because a hook cannot know
# that and a gate that guesses is worse than no gate.
#
#   1. Staged-but-uncommitted changes in any DreamerOS repo. Lived today: a
#      stash round-trip silently unstaged two files, a later `git diff --cached`
#      printed empty, and an empty commit was one keystroke away.
#   2. Uncommitted changes inside a .braid-worktrees lane. Those worktrees exist
#      only for in-flight agent work; leaving edits there strands them where no
#      future session will look.
#
# LOOP GUARD, load bearing. A Stop hook that blocks unconditionally makes the
# session unusable, because the model cannot always resolve the condition from
# inside the blocked turn. This records a signature of what it blocked on. If
# the identical state is seen twice, it allows the turn to end and says so
# loudly, so the operator sees an unresolved state rather than an agent trapped
# in a loop. Escalate to the human; never deadlock.

set -uo pipefail

STATE_DIR="$HOME/.claude/.gate-state"
mkdir -p "$STATE_DIR" 2>/dev/null
SESSION_MARK="$STATE_DIR/stop-half-state.last"

REPOS=(
  "__DREAMEROS_REPO_ROOT__/dreameros-scs-gateway"
  "__DREAMEROS_REPO_ROOT__/dreameros-app-frontend"
  "__DREAMEROS_REPO_ROOT__/dreameros-app-site"
  "__DREAMEROS_REPO_ROOT__/dreamerOS"
)
BRAID="__DREAMEROS_REPO_ROOT__/.braid-worktrees"

PROBLEMS=""
SIG=""

# WIP is REPORTED, never blocked. See the note below the loop for why.
WIP=""

for repo in "${REPOS[@]}"; do
  [ -d "$repo/.git" ] || continue
  name="${repo##*/}"
  staged=$(git -C "$repo" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
  if [ "${staged:-0}" -gt 0 ]; then
    PROBLEMS="${PROBLEMS}\\n  ${staged} STAGED but uncommitted file(s) in ${name} on branch $(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    SIG="${SIG}|${name}:staged:${staged}"
  fi

  # Unstaged and untracked work in a PRIMARY checkout.
  #
  # An audit on 2026-08-10 caught this gate returning exit 0 "clean" while
  # three files sat modified in dreameros-app-frontend. It only ever looked at
  # `diff --cached`, and the worktree loop below deliberately skips primary
  # checkouts, so ordinary unstaged work was invisible to it.
  #
  # The fix is NOT to block on it. Those three files are the operator's
  # deliberate in-flight work and blocking would trap every turn. But
  # reporting CLEAN when the tree is not clean buys false confidence, and
  # false confidence is the actual defect - it is how a gate that runs
  # becomes a gate nobody can rely on. So: block on true half-states,
  # SURFACE this, and let the turn end.
  # awk, not `grep -c ... || echo 0`: on a clean repo grep -c prints 0 AND
  # exits 1, so the || fired too and dirty became the two-line string "0\n0",
  # which blew up the -gt test below. Found by the revived open-loop-auditor
  # on 2026-08-10. awk always prints exactly one number and exits 0.
  dirty=$(git -C "$repo" status --porcelain --untracked-files=normal 2>/dev/null | awk '!/^[MADRC] /{n++} END{print n+0}')
  if [ "${dirty:-0}" -gt 0 ]; then
    WIP="${WIP}\\n  ${dirty} uncommitted file(s) in ${name} on branch $(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null) - left alone, not blocked"
  fi
done

# Every linked worktree of every repo, wherever it lives on disk.
#
# This replaced a loop that read only $BRAID. On 2026-08-10 an audit found 29
# uncommitted files sitting in worktrees under C:/tmp - two of them holding the
# entire Codex parity port - and this gate had reported clean for the whole
# session, because it was watching one hardcoded directory that those worktrees
# were not in. A gate that checks the wrong path returns allow and looks alive.
#
# `git worktree list --porcelain` reports the real locations, so a worktree
# cannot hide by being created somewhere new. $BRAID is still covered because
# braid lanes are worktrees too.
SEEN=""
for repo in "${REPOS[@]}"; do
  [ -d "$repo/.git" ] || continue
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    [ "$w" = "$repo" ] && continue          # primary checkout handled above
    case "$SEEN" in *"[$w]"*) continue ;; esac
    SEEN="${SEEN}[$w]"
    n=$(git -C "$w" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "${n:-0}" -gt 0 ]; then
      PROBLEMS="${PROBLEMS}\\n  ${n} uncommitted file(s) in worktree $(basename "$w") on branch $(git -C "$w" rev-parse --abbrev-ref HEAD 2>/dev/null) at ${w}"
      SIG="${SIG}|wt:$(basename "$w"):${n}"
    fi
  done <<< "$(git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')"
done

# No blocking half-state. Clear the guard so a future genuine block still fires.
#
# If ordinary WIP exists, SAY SO on the way out. Silence here is what let this
# gate report clean over three modified files for a whole session.
if [ -z "$PROBLEMS" ]; then
  rm -f "$SESSION_MARK" 2>/dev/null
  if [ -n "$WIP" ]; then
    printf '{"systemMessage":"No half-states to block on. Uncommitted work is present and was deliberately left alone:%s\\n\\nThis is reported, not blocked - it is in-flight work, and blocking on it would trap every turn. Nothing here was staged, stashed, reset or cleaned."}\n' "$WIP"
  fi
  exit 0
fi

# Loop guard: identical state already blocked once. Do not deadlock.
PREV=$(cat "$SESSION_MARK" 2>/dev/null || echo "")
if [ "$PREV" = "$SIG" ]; then
  rm -f "$SESSION_MARK" 2>/dev/null
  printf '{"systemMessage":"GATE ESCALATION: the same half-state was blocked once and is still unresolved, so this turn is being allowed to end rather than deadlocking. UNRESOLVED:%s\\n\\nThis needs the operator. Nothing was lost - the files are exactly where they were - but they are staged or uncommitted and no future session will know to look."}\n' "$PROBLEMS"
  exit 0
fi

printf '%s' "$SIG" > "$SESSION_MARK" 2>/dev/null

REASON="BLOCKED by the no-half-states gate. This turn cannot end while work sits in a half-saved state:${PROBLEMS}\\n\\nResolve, then finish the turn. Either commit the work with a real message, or unstage it deliberately, or say plainly to the operator that it is being left and why. Do NOT clear it with reset, checkout or clean - that destroys the work rather than resolving it, and those are denied anyway.\\n\\nWhy this gate exists: staging was silently lost in a stash round-trip earlier today and an empty commit was one keystroke away; and a braid lane left dirty strands agent work in a directory no future session reads."

printf '{"continue":false,"stopReason":"%s","systemMessage":"Stop gate: unresolved half-state, turn held open."}\n' "$REASON"
