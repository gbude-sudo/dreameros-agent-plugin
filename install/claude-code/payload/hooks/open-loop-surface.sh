#!/bin/bash
# Global SessionStart hook. Surfaces work that is easy to forget, so no session
# has to remember to look. This is a GATE, not a reminder: a rule saying "check
# back on open items" was already canon and did not fire, because a thread that
# has forgotten something cannot notice its own forgetting.
#
# Reports three things a new session cannot otherwise see without asking:
#   1. worktrees holding uncommitted work, with file counts and paths
#   2. detached-HEAD worktrees, whose loose edits are the ones actually at risk
#   3. local branches ahead of their remote, i.e. work that never reached GitHub
#
# Read-only. Never edits, stages, commits or prunes anything.

set -uo pipefail

REPOS=(
  "__DREAMEROS_REPO_ROOT__/dreameros-scs-gateway"
  "__DREAMEROS_REPO_ROOT__/dreameros-app-frontend"
  "__DREAMEROS_REPO_ROOT__/dreameros-app-site"
  "__DREAMEROS_REPO_ROOT__/dreamerOS"
  "__DREAMEROS_REPO_ROOT__/dreameros-hc-command-center"
  "__DREAMEROS_REPO_ROOT__/dreameros-light-proxy"
)

DIRTY=""
DETACHED=""
AHEAD=""
TOTAL=0

for repo in "${REPOS[@]}"; do
  [ -d "$repo/.git" ] || continue
  name="${repo##*/}"

  # Every worktree of this repo, including the base checkout.
  # PERFORMANCE, load bearing: this walks ~32 worktrees across the DreamerOS
  # repos and the first version TIMED OUT at 30s (rc=124), which means it
  # emitted nothing at all - a SessionStart hook that exceeds its budget is
  # strictly worse than no hook, because it looks installed and reports clean.
  # Every git call is now individually bounded, and untracked files are
  # excluded from the status walk, which is the expensive part on a repo with
  # large node_modules or build output.
  while read -r w; do
    [ -n "$w" ] && [ -d "$w" ] || continue
    n=$(timeout 3 git -C "$w" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')
    [ "${n:-0}" -gt 0 ] || continue
    TOTAL=$((TOTAL + n))
    br=$(timeout 2 git -C "$w" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ "$br" = "HEAD" ]; then
      DETACHED="${DETACHED}\\n    ${n} files  DETACHED HEAD  ${w}"
    else
      DIRTY="${DIRTY}\\n    ${n} files  ${br}  (${name})"
    fi
  done < <(timeout 5 git -C "$repo" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')

  # Local branches that have NEVER reached the remote.
  #
  # Two plumbing calls for the whole repo, compared in awk. The per-branch
  # rev-list loop was the other half of the timeout, and on this machine that
  # is 170 local branches across three repos.
  #
  # Do NOT use `%(upstream)` for this. An unset upstream is a DIFFERENT
  # question from "never pushed" - a branch can carry a configured upstream
  # that does not exist on the remote, and most here do. Measured 2026-08-10:
  # the upstream test reported 4 for this repo where the real answer was 80,
  # a 20x undercount that would have read as reassuring. Compare the actual
  # ref namespaces instead.
  NEVER=$(
    { timeout 5 git -C "$repo" for-each-ref --format='L %(refname:short)' refs/heads 2>/dev/null
      timeout 5 git -C "$repo" for-each-ref --format='R %(refname:short)' refs/remotes/origin 2>/dev/null
    } | awk '
        $1=="R"{ sub(/^origin\//,"",$2); remote[$2]=1; next }
        $1=="L"{ local[$2]=1 }
        END{ n=0; for (b in local) if (!(b in remote)) n++; print n }'
  )
  [ "${NEVER:-0}" -gt 0 ] && AHEAD="${AHEAD}\\n    ${NEVER} local branches have NEVER reached the remote  (${name})"
done

# Say nothing when there is nothing to say. A hook that fires on every session
# regardless of state trains the reader to ignore it.
if [ -z "$DIRTY" ] && [ -z "$DETACHED" ] && [ -z "$AHEAD" ]; then
  exit 0
fi

MSG="## Open loops on disk at session start\\n"
MSG="${MSG}\\nThis is mechanical output, not a judgement. None of it was touched.\\n"
[ -n "$DETACHED" ] && MSG="${MSG}\\n  AT RISK - detached HEAD, no branch points at this work:${DETACHED}\\n"
[ -n "$DIRTY" ]    && MSG="${MSG}\\n  Uncommitted work in worktrees:${DIRTY}\\n"
[ -n "$AHEAD" ]    && MSG="${MSG}\\n  Local commits the remote has never seen:${AHEAD}\\n"
MSG="${MSG}\\n  Total uncommitted files across all worktrees: ${TOTAL}\\n"
MSG="${MSG}\\nDo NOT clean, prune, stash or commit any of it without asking the operator - it is somebody's in-flight work. "
MSG="${MSG}Surface it if it overlaps what you are about to touch, and check for a live BEACON before editing shared files. "
MSG="${MSG}For a full accounting of what was promised and not delivered, dispatch the open-loop-auditor agent rather than self-assessing."

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$MSG"
