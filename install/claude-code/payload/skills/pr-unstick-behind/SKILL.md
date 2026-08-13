---
name: pr-unstick-behind
description: Detect and clear GitHub auto-merge PRs stuck at mergeStateStatus BEHIND. Use after any merge to main, when an armed PR sits unmerged with green checks, when the operator asks why a PR did not land, or during any multi-PR sprint. Born 2026-08-13, when armed PRs silently fell to BEHIND seven or more times after sibling merges and never merged on their own.
---

# pr-unstick-behind

The lesson from 2026-08-13, seen seven or more times in one day. A PR with
auto-merge armed and checks green still never merges when a sibling merges
first. The sibling moves main. The PR falls to mergeStateStatus BEHIND.
GitHub does not update it for you. It waits forever.

The failure is silent. The PR page looks healthy. The checks are green.
Auto-merge shows armed. Nothing happens.

## Detect

Run:

    gh pr view <n> --repo <owner>/<repo> --json number,mergeStateStatus,autoMergeRequest

Read mergeStateStatus. BEHIND means the branch base is stale and the PR
will not merge without a branch update.

## Fix

Run:

    gh api -X PUT repos/<owner>/<repo>/pulls/<n>/update-branch

This rebuilds the branch on current main and restarts checks. Then re-check
mergeStateStatus. Expect BLOCKED or UNSTABLE while checks run, then CLEAN,
then the armed auto-merge fires.

If the update call returns a merge conflict error, the PR needs a manual
rebase. Name it CONFLICTED and handle it as real work, not a retry.

## The cascade rule

After ANY merge to main, sweep every remaining armed PR for BEHIND. One
merge can knock every sibling to BEHIND at once. The loop:

1. Merge lands on main.
2. List open PRs with auto-merge armed.
3. For each, read mergeStateStatus.
4. For each BEHIND, call update-branch.
5. When the next one merges, go to step 1.

Repeat until zero armed PRs remain open. Do not declare the sprint done
while any armed PR sits at BEHIND.

## Honesty rules

- Never report "auto-merge is armed" as if it means "will merge". Report
  the current mergeStateStatus next to it.
- A PR is landed when the merge commit exists on main, not when armed.
