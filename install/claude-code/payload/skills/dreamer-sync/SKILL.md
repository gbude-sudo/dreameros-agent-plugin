---
name: dreamer-sync
description: The DreamerOS check-populate-sync loop. Run BEFORE starting substantive work and AFTER landing changes so every LLM and AI session shares one source of truth. Hydrates from the substrate, populates it with what it lacked, pulls what other actors wrote, and syncs local and remote git across all DreamerOS repos. Use when the operator says sync up, check dreamer, populate the substrate, or at any session start or close.
---

# dreamer-sync

One loop, four legs: CHECK, POPULATE-OUT, POPULATE-IN, GIT-SYNC. Then report.
Purpose: any AI session (Claude, Codex, Gemini, anything with the MCP) lands on
the same truth, and no session leaves knowing something the substrate does not.

## Leg 1 - CHECK (before touching anything)

1. `dreameros_state` action=load. Read phase, priorities, blockers, verified facts.
2. `dreameros_recall` query="session-end continuity-anchor" - one hop to the newest
   master index. Read the anchors it points at only on demand, do not re-derive.
3. `dreameros_recall` query="beacon-active" (or `dreameros_memory_full` tag=beacon-active).
   Active BRAID BEACONS name file scopes other actors own right now - stay off those
   files. A braid SEAL that says HC-approval-required is a hard stop, never a workaround.
4. If about to claim anything about live infra: probe, do not narrate defaults.
   Gateway health: GET https://dreameros-scs-gateway-production.up.railway.app/health
   Cross-service events: `dreameros_observe` (5 adapters: sentry, railway, vercel,
   supabase, github). Deploy proof = an observed railway SUCCESS event after your
   merge, never presumption.

## Leg 2 - POPULATE-OUT (give the substrate what it lacked)

After any substantive change or discovery, `dreameros_remember` with:
- What shipped or was found, with PR numbers, SHAs, file:line evidence.
- Corrections to prior memories per the merge-never-delete doctrine: the old memory
  stays, the new one names it ("corrects <uuid>") with a dated note. Duplicates fold
  into the strongest member, never deleted.
- Tags that make it findable: cold-start-anchor, next-session-read-first, never-delete,
  plus classification-WHAT (public outcome) or classification-HOW (operational substrate)
  - canon writes are REJECTED without a classification tag.
- If the work is a multi-file strand others could collide with: emit a BRAID BEACON
  (thread_id, actor_id, domain, intent, exact file scope, branch). Seal it when done.
Then `dreameros_state` action=update_context so phase, priorities, and blockers
reflect reality. The header other sessions read is only as honest as this write.

## Leg 3 - POPULATE-IN (take what other actors wrote)

`dreameros_memory_full` since=<session start ISO timestamp> limit=15.
Read every entry from actors that are not you: braid pulses and seals from parallel
Codex or Claude threads, boot-contract or config changes from sibling sessions,
corrections to your own prior anchors. Two rules:
- A seal or approval-gate written by another session binds you exactly as if the
  operator said it in chat.
- If something you were about to do contradicts a pulled memory, stop and reconcile
  before acting - the substrate is the tiebreaker, and if the substrate is stale
  against runtime, fix the substrate (leg 2), not your story.

## Leg 4 - GIT-SYNC census (measure every discovered repo)

Resolve the current user's home at runtime. Enumerate direct Git repositories
under `~/Documents/DreamerOS` and `~/Documents/Codex`; do not hardcode a user,
drive, repository count, or stale repository list. For each discovered repo:

```bash
git -C "<absolute-repo-path>" fetch --quiet
git -C "<absolute-repo-path>" status --short --branch
```

This leg is read-only unless the current task separately authorizes repository
mutations. Report clean/dirty, branch, HEAD, upstream, origin/main, ahead/behind,
and missing remotes. Do not pull, switch, delete, prune, merge, commit, or push
from the census itself.

Then, per repo state:
- Clean and behind: report the exact count and the `git pull --ff-only` next
  action; do not run it without current repository authority.
- Clean on a merged branch whose upstream is gone: report the branch and proof
  that its patch landed; do not switch or delete it from this census.
- DIRTY with changes you did not author: HANDS OFF. No pull, no reset, no stash.
  Surface it to the operator with the branch name and file list - another session's
  work in progress is a handoff, not clutter. (Standing example: the frontend BASE
  checkout at dreameros-app-frontend without the worktree suffix is a different
  checkout from the session worktree - verify the FULL path before every write.)
- No remote configured: note it without naming a historical repo as current.
- After any merge you drove: return that checkout to main and delete the branch
  only after proving the squash landed on origin/main.

## Report

Close the loop with the three-bucket report in chat, and if the session is ending,
a master-index anchor carrying the literal phrase "session-end continuity-anchor":
- FIXED: PR + SHA + citation.
- NEEDS HC: the precise blocker and exactly what the operator must click, flip, or
  approve (Synchronized Swimmer: HC markers set the tempo; do not declare an
  outcome complete past an uncrossed HC marker).
- ALREADY HONEST: what was checked and found accurate, with the citation.
