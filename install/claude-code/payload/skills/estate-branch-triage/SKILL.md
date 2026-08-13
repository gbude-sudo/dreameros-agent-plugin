---
name: estate-branch-triage
description: Classify every local branch and stash as LANDED, REAL-UNLANDED, or CONFLICTED before merging anything. Use before any branch cleanup, before merging inherited branches, when the operator asks what is unmerged, or when a codex/* queue needs triage. Born 2026-08-13, when a stale local main produced false REAL-UNLANDED verdicts that nearly caused duplicate merges.
---

# estate-branch-triage

The lesson from 2026-08-13, proved twice in one day. A branch that looks
unmerged against local main can be fully landed on origin/main. A stale
local main produced false REAL-UNLANDED verdicts. Those verdicts nearly
caused duplicate merges and false strategy corrections.

The rule: classify against FRESH origin/main, never local main.

## Step zero, always

    git fetch origin main

Then use origin/main as the baseline in every test below. A verdict
computed against local main is not a verdict. Discard it and re-run.

## The three verdicts and their mechanical tests

1. LANDED. The branch content already exists on main.
   - `git cherry origin/main BRANCH` prints all "-" lines. Every commit
     has an equivalent on main.
   - Or `git merge-tree --write-tree origin/main BRANCH` produces a tree
     equal to the origin/main tree. The merge changes nothing.
   Either proof is enough. A LANDED branch is safe to delete after the
   proof is recorded.

2. CONFLICTED. `git merge-tree --write-tree origin/main BRANCH` exits
   with conflict status. The branch cannot merge cleanly. Name it, do not
   merge it blind. It needs a human-grade rebase decision.

3. REAL-UNLANDED. Everything else. Confirm the remainder with:
   - `git diff origin/main...BRANCH --stat` to see what it would add.
   A REAL-UNLANDED branch is work in the queue. Find its intent, then
   ship it or name the exact blocker.

## Stashes

Apply the same discipline. For each stash, `git stash show -p stash@{n}`
and compare against origin/main. A stash whose changes already exist on
main is LANDED noise. Record the proof before dropping anything, and
never drop without operator sign-off, because stash drop is denied by
permission canon.

## Output shape

One line per branch and stash: name, verdict, proof command, and for
REAL-UNLANDED the one-line intent. Merge nothing until the whole table
exists. The table is the safety, because it stops the first merge from
invalidating every later verdict unseen.

After any merge lands, re-fetch and re-classify the remainder. Every
merge to main changes the baseline.
