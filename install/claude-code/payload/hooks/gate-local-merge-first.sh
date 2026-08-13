#!/bin/bash
# PreToolUse GATE. This one REFUSES. It does not narrate.
#
# Enforces the HC ordering rule: merge branches into LOCAL main first, then
# sync with cloud. Blocks `git push` of a feature branch whose commits are not
# yet in local main.
#
# Written 2026-08-10 after the assistant recorded that exact rule in CLAUDE.md
# and then violated it on PR #1922 in the same session - branch, push, remote
# merge, then pull main down. The rule existed. Nothing enforced it.
#
# Every other hook on this machine returns additionalContext, which is a
# reminder delivered mechanically. A reminder is still a principle, and the
# operator observed correctly that ~40 firings of the Stop hook changed no
# behavior. This returns permissionDecision deny, which is a different thing.
#
# Deliberately narrow. It blocks ONE mistake it can prove. It does not attempt
# to police intent, and it always explains how to proceed legitimately.

set -uo pipefail

allow() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'; exit 0; }
deny()  { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"; exit 0; }

CTX=$(cat 2>/dev/null || echo '{}')
CMD=$(printf '%s' "$CTX" | python -c "import sys,json;d=json.load(sys.stdin);print(d.get('tool_input',{}).get('command','') or d.get('toolInput',{}).get('command',''))" 2>/dev/null || echo "")

# Only interested in a real push.
#
# Match `push` as a subcommand, NOT the literal string "git push". CLAUDE.md
# tells this thread to prefer `git -C <repo> push` over `cd <repo> && git push`,
# because the -C form is matchable by a permission rule and is safer. The first
# version of this line tested for "git push" only, so the exact form canon asks
# for skipped the gate at line one. The gate returned allow and looked healthy
# for a whole session while every push went around it.
case "$CMD" in
  *git*" push "*|*git*" push") ;;
  *) allow ;;
esac

# Never block the operator explicitly pushing main itself, or a delete.
case "$CMD" in
  *"push"*" main"|*"push"*" main "*|*"--delete"*) allow ;;
esac

# A refspec push (src:dst) is out of scope. Test ONLY the text after the `push`
# keyword. Do NOT test the whole command: on Windows every `git -C C:/...`
# carries a drive-letter colon, which matched here and turned this gate off for
# every push made on this machine. The gate reported allow and looked healthy.
# Found 2026-08-10 after it permitted two codex/* pushes it was built to refuse.
PUSH_ARGS="${CMD#*push}"
case "$PUSH_ARGS" in *":"*) allow ;; esac

# Resolve the repo this push targets. Support `git -C <dir> push`.
REPO=$(printf '%s' "$CMD" | sed -n 's/.*git[[:space:]]\+-C[[:space:]]\+\([^[:space:]]*\).*/\1/p')
REPO="${REPO%\"}"; REPO="${REPO#\"}"

# A hook sees the RAW command text, before the shell expands anything. So
# `git -C "$W" push` arrives here with REPO set to the literal string $W.
# The old code then failed `rev-parse` on that nonsense path and returned
# allow, which meant ANY push written with a shell variable walked straight
# through this gate. Found 2026-08-10: the gate denied a literal-path push
# and permitted the identical push written with a variable.
#
# Unresolvable target is NOT a reason to allow, and it is NOT a reason to go
# looking for a different repo to judge instead.
#
# The first version of this fix fell back to the caller's cwd whenever the -C
# target was unreadable. An audit on 2026-08-10 proved that reopened the same
# hole from the other side: when cwd happened to BE a clean repo, rev-parse
# succeeded, the deny below never ran, and the gate judged the WRONG
# repository - allowing `git -C $W push origin anything` from any clean
# checkout, and in one case denying while naming a branch the command never
# mentioned. A gate that answers a question it was not asked is worse than one
# that abstains, because its answer looks authoritative.
#
# So: if an explicit -C target was given and it is unreadable, DENY. Never
# substitute a different repo for the one named. Only fall back to cwd when
# there was NO -C at all, which is the legitimate `cd repo && git push` shape.
case "$REPO" in
  *'$'*|*'`'*)
    deny "BLOCKED by the local-merge-first gate. This push names its target repository with a shell variable or command substitution, so the gate cannot tell which repository or branch it affects. A hook reads the RAW command text, before the shell expands anything - so \`git -C \$W push\` arrives here as the literal characters \$W.\\n\\nRe-issue the push with a LITERAL path:\\n  git -C __DREAMEROS_REPO_ROOT__/dreameros-app-frontend push origin my-branch\\n\\nThe gate deliberately does NOT guess by checking the current directory instead. Judging a repository the command never named would produce a confident verdict about the wrong thing. This is the same reason CLAUDE.md asks for git -C <repo> over cd <repo> && git ... - a command a gate can read is a command a gate can check."
    ;;
esac

# No explicit -C: the target is wherever the caller is. That IS the right repo.
if [ -z "$REPO" ]; then
  REPO=$(printf '%s' "$CTX" | python -c "import sys,json;d=json.load(sys.stdin);print(d.get('cwd','') or '')" 2>/dev/null || echo "")
  [ -n "$REPO" ] || REPO="$(pwd)"
fi

git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || allow

BR=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)
[ -n "$BR" ] && [ "$BR" != "HEAD" ] && [ "$BR" != "main" ] || allow

# A rescue/* branch exists precisely to get orphaned work off a detached HEAD
# and onto a name. Blocking it would defeat its purpose.
case "$BR" in rescue/*) allow ;; esac

git -C "$REPO" rev-parse --verify main >/dev/null 2>&1 || allow

# The actual test: does local main already contain this branch's commits?
AHEAD=$(git -C "$REPO" rev-list --count main.."$BR" 2>/dev/null || echo 0)
[ "${AHEAD:-0}" -gt 0 ] || allow

deny "BLOCKED by the local-merge-first gate. Branch '$BR' has $AHEAD commit(s) that local main does not contain, so pushing now would make the remote the integration point instead of local main. HC ordering rule: merge into LOCAL main first, then sync with cloud. Do this instead: git -C $REPO checkout main && git -C $REPO merge --no-ff $BR (resolve any conflict HERE, where you have full context), run the repo check suite, then push. If this push is deliberately a work-in-progress backup of unfinished work, say so to the operator and get an explicit go-ahead rather than working around this gate."
