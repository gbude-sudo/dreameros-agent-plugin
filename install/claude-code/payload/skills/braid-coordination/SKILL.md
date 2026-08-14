---
name: braid-coordination
description: Run parallel work strands safely across multiple AI sessions and agents using the DreamerOS Braid Protocol - independence audit, BEACON/PULSE/SEAL substrate messages, and Synchronized Swimmer tempo. Use whenever dispatching two or more agents that edit files, whenever the operator says braid, synchronized swimming, sprint protocol, or parallel lanes, and whenever picking up work in a repo where other sessions (Codex, Claude, cron) may be active - check for live beacons BEFORE touching files.
---

# braid-coordination

Distills three gateway canon docs (DIGITAL_BRAIDING_TECHNIQUE_v1_0_0,
BRAID_PROTOCOL_v1_0_0, SYNCHRONIZED_SWIMMER_TECHNIQUE_v1_0_0) into the executable
loop, as lived on 2026-08-05 when two strands (site copy batch, gateway IFP paper
trail) ran in parallel to completion with zero collisions. The canonical texts live
in the gateway repo under governance/00_CORE/ - read them for doctrine; use this for
execution.

## Before dispatching parallel strands: the independence audit

All three conditions must hold, or collapse to sequential (sequential is cheaper
than merge-conflict recovery):

1. File-scope independence: the strands' planned file sets are disjoint. List the
   exact files per strand before dispatch; "different features" is not the test,
   file paths are.
2. Decision independence: no strand's output is an input to another's decision this
   cycle. If B's approach depends on A's findings, serialize.
3. Artifact separability: each strand ends in one reviewable artifact (usually one
   PR) the operator can evaluate alone.

Document the audit result in the beacon. The historical anti-pattern this prevents:
three sessions editing the same file from parallel chats because they seemed
independent.

## The substrate messages (via dreameros_remember)

- BEACON at dispatch, one per strand. Content: thread_id, actor_id, domain, intent,
  EXACT file scope, branch name, and the independence-audit note versus sibling
  strands. Tag: beacon-active plus a thread tag. Other actors reading the substrate
  stay off those files while the beacon is active.
- PULSE at meaningful mid-strand state changes (pushed but not merged, blocked on
  review, rebased onto new base). Optional for short strands.
- SEAL when the strand completes. Content: what merged (PR, squash SHA, timestamps),
  what was verified (checks, deploy, live probes), what was explicitly NOT covered,
  and the phrase releasing the file scope. Reference the beacon id it seals
  (seals-<uuid> tag). A seal written by another session binds you exactly as if the
  operator said it in chat - never work around one.

Check for live beacons at session start and before any multi-file edit:
dreameros_recall "beacon-active" or memory_full on the tag. An active beacon whose
scope overlaps your plan means renegotiate scope or wait.

## Synchronized Swimmer: tempo

When one actor is mandatory and non-parallelizable - the operator on credentials,
env flips, DNS, ratification, visual approval of marketing artifacts - that actor
is the critical swimmer and sets the formation's pace. Declare every critical
swimmer and their markers in the beacon or the report. Strands may finish at their
artifact boundary, but the OUTCOME is not declared complete until every critical
swimmer crosses their marker. Never announce "production ready" past an uncrossed
operator marker; the all-finish invariant is the honesty line.

## Worktree hygiene for braided agents

Each strand edits in its own isolated git worktree of the target repo, branched
from origin/main after a fetch - never the operator's base checkout, which may hold
another session's uncommitted work. Push the branch; the coordinating session
drives PRs and merges so gate-failure handling stays in one place.
