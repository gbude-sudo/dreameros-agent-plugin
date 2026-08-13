---
name: verified-sprint
description: The full verify-then-ship loop for DreamerOS work - verify the defect live before writing code, fix it, prove the fix can fail, ship through local-main-first git flow, verify at the destination, and save to all three locations. Use when the operator says sprint, don't stop until done, deep dive, finish everything, or when any multi-item completion push starts. Also the home of the verification trap table - consult it before reporting ANY absence, count, or "already done / not done" verdict.
---

# verified-sprint

The distilled method from the 2026-08-10/11 marathon session: 12+ PRs shipped,
five false findings caught before they caused damage, zero destructive
mistakes. The loop below is what worked. The trap table is what failed and got
caught.

## The loop, per item

1. RECALL FIRST. `dreameros_recall` the topic before deriving anything.
   Twice in one session the answer already existed in ratified canon and the
   operator had to say "I don't just say things for my health." The substrate
   is checked BEFORE the work, not only written after.
2. VERIFY THE DEFECT LIVE. Probe production before writing code. A defect you
   cannot reproduce is a defect you cannot claim to fix. Probe WITH A CONTROL:
   "new text present" is weak; "old text absent AND new text present" is proof.
3. FIX ON A BRANCH CUT FROM origin/main, never from a stale local branch.
   Check what main already has FIRST - see trap 1.
4. PROVE THE TEST CAN FAIL. A regression guard that has never failed is a
   guess. Simulate the broken state and watch the test go red before trusting
   its green. Same rule for hooks and gates: force a DENY. Silence never
   distinguishes "approved" from "never ran".
5. SHIP: commit -> merge into LOCAL main -> push the BRANCH -> PR ->
   auto-merge (squash). BOTH halves: after the remote squash lands, local main
   diverges by a duplicate merge commit - reconcile it or it accumulates.
   If a PR sits at mergeStateStatus BEHIND, run `gh pr update-branch` -
   auto-merge NEVER fires on a BEHIND branch and it will sit green forever.
6. VERIFY AT THE DESTINATION. A push that prints "new branch" is narration.
   `git ls-remote --heads <url> <branch>` and read back the SHA. A merged PR
   is not deployed: compare the runtime's boot_sha to origin/main.
7. CLASSIFY HONESTLY: FIXED only when a customer can use it in live runtime.
   SHIPPED when merged and deployed. PARTIAL otherwise. NOT ELIGIBLE for
   internal tooling. Never let the effort spent inflate the label.
8. SAVE TO THREE LOCATIONS as you go, not only at close:
   - DreamerOS substrate (`dreameros_remember`, split anchors over 9800 bytes)
   - Git (the flow above)
   - Google Drive under a clearly labeled file
   A checkpoint anchor mid-sprint protects against drops and disconnects.

## The trap table - consult before reporting any absence or count

Every false finding of the marathon session had the same shape: a verification
method that did not match the claim. Before reporting an absence, state which
command would prove PRESENCE, and run that.

| # | Trap | What lies | The truth test |
|---|------|-----------|----------------|
| 1 | Squash-merge | `git rev-list --count` AND `git cherry` both mark landed work as unmerged (squash changes the patch-id) | Read CURRENT origin/main for the defect or capability itself: `git show origin/main:<path>`, `git cat-file -e origin/main:<newfile>` |
| 2 | Count-vs-content | A branch 0 commits ahead can differ from main by 200+ files (stash parents); a branch N ahead can be content-identical | Compare TREES: `git rev-parse <ref>^{tree}` both sides, or diff the trees |
| 3 | Label-vs-content | A branch named rescue/stash-keep can hold ZERO commits main lacks - a label is not a rescue | `git rev-list --count main..<branch>` AND a tree diff, together |
| 4 | Push narration | Push output says "new branch"; the ref may not be there or may be stale | `git ls-remote --heads <url> <branch>`, read the SHA |
| 5 | Three-dot diff | `git diff origin/main...branch` shows changes since the MERGE BASE; its minus lines are the old base, NOT current main | Two-dot against current main, or read main directly |
| 6 | CRLF hash split | Raw md5 splits byte-identical files into "versions" (54 lines = 54 CR bytes); repo reports clean while raw hash disagrees | Normalize line endings before hashing: `tr -d '\r' \| md5sum` |
| 7 | Bounded audit | An audit's "zero artifacts" scoped to one directory reads as a global zero | Read the audit's own BOUNDS section before relaying any zero |
| 8 | 405-shadow | 405 on a path you believe exists means a parameterised sibling captured the literal segment and only the METHOD failed | Check route registration order; a literal route must precede /{param} |
| 9 | Flag-vs-runtime | An env var being SET is not the running deploy using it | Query the RUNNING deploy (env-check endpoint, boot_sha) not the var list |
| 10 | File-vs-registration | An agent .md existing is not the agent being dispatchable; a config entry existing is not the config being parsed (one bad TOML enum silences the whole file) | Attempt the dispatch; run the CLI list command; force the failure |
| 11 | Docs-only cite rule | file:line citations in a docs-only PR BODY fail the hallucinated-facts gate (reviewer cannot verify them from the diff) | Citations live in the committed document; the PR body describes without line numbers |
| 12 | Non-terminal state | A BUILDING deploy manifest or a pending check is not evidence of the outcome | Wait for the terminal state before reporting |
| 13 | Checker repo-scope | A verifier resolving your PR numbers or file paths against the WRONG repo reports real work as nonexistent, and impossible line numbers when the file it opened is a different file of the same name | Name the full owner/repo beside every PR number and state which checkout and which REF the line numbers come from (`git show <ref>:<path>`, never the working tree) |
| 14 | Anchor written while work moves | An armed auto-merge PR can land BETWEEN drafting an anchor and storing it, so an accurate-when-written OPEN becomes a false claim on arrival | Re-read live state immediately before the substrate write, not at the start of the paragraph |
| 15 | SKIPPED is not FAILED | Railway reports `status: SKIPPED, skippedReason: No changes to watched files` for a docs-only merge; it looks like a broken deploy and is correct behavior | Read `skippedReason`; check whether the merge touched anything in the service `watchPatterns` before treating a skip as a defect |
| 16 | 404-vs-401 registration proof | A route you cannot authenticate against still proves it exists: 401 means registered and reached the auth layer, 404 means absent | Probe the route AND a deliberately nonexistent control path in the same sweep; compare the two codes |

## Escalation discipline

- Anything requiring credentials, spend, registry publish, pricing, or
  ratification goes to HC with the exact decision named. Never handle secret
  VALUES; names and SET/MISSING only.
- Before escalating an env flag, run the railway env-check from the linked
  repo directory. Five escalations up to 80 days old were answerable in
  under a minute.
- A gate firing on your own work is the gate working. Conform, do not bypass.
  If a gate denies a whole Bash call, your earlier commands in that call
  never ran - re-issue them separately.

## Fan-out audits (the deep-dive shape)

For "find everything not done": dispatch parallel read-only agents, one per
surface (gateway+runtime, frontend+site, session open-loops), each with
explicit claims to verify WITH CONTROLS and explicit bounds to report. Then
cross-correlate in the main thread and independently re-verify anything
surprising before acting - subagent reports carry the same traps as any
other pointer. Rank the merged list by (age x customer impact).
