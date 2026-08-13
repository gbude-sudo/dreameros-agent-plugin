# self-catch

Find what our own gates caught us doing in the trailing week, and draft the
honest post about it. Born 2026-08-12, first sweep found a direction-set
drift issue open since 2026-06-14 with 106 silent bot comments and nobody
acting on it. The recurring defect class this skill hunts is not the
mistake. It is the mistake nobody read about after the gate caught it.

Use when the operator says: self-catch, weekly integrity post, what did we
catch ourselves doing, or before any content post that claims we hold
ourselves to a standard.

## The rule that makes this different from a status report

State the failure before the fix. Name what it cost before what changed.
No self-congratulation. A post that leads with the fix is marketing. A post
that leads with the failure is the only kind worth a reader's trust.

This skill drafts only. It never publishes. The draft goes to the operator
for review every time, with no exception.

## The sweep, source by source

Workflow and repo names drift. Confirm each path is still real before
citing it; do not assume the name below is current.

**Search every repo, not just the two most familiar ones.** The first
2026-08-12 run of this skill searched only
`gbude-sudo/dreameros-scs-gateway` and `gbude-sudo/dreameros-app-frontend`
plus Sentry, and reported three real, already-merged incidents as
unverified because each had happened in a different repository (a site
repo, a book-project repo, a second frontend PR) that the sweep never
looked at. `gh repo list gbude-sudo` returns the full remote list (17
repos as of that date) - list it fresh every run, do not reuse a
remembered count, and check `gh issue list` / `gh pr list --state merged`
against each one for the trailing week before concluding an item has no
receipt. An incident lands wherever its surface lives, not wherever the
last post's incidents happened to live.

- **Mis-selling / claims-vs-code sentinel.** Look for a scheduled workflow
  under `gbude-sudo/dreameros-scs-gateway/.github/workflows/` that checks
  report vocabulary or marketing claims against shipped code (for example
  `p37-report-vocabulary.yml`). A red run is a finding. `gh run list
  --repo gbude-sudo/dreameros-scs-gateway --workflow=<name> --limit 20`.
  If the exact name in prior notes 404s, search the workflows directory
  for "p37", "vocabulary", or "mis-selling" before concluding it does not
  exist.
- **Canon drift.** Two independent mechanisms, check both:
  1. `canon-drift-detector.yml` (daily, GitHub Actions). `gh run list
     --repo gbude-sudo/dreameros-scs-gateway --workflow=canon-drift-detector.yml`.
     A red run opens or comments on a `canon-drift` labeled issue
     (`gh issue list --label canon-drift-sentry --state all`) - read the
     issue thread, not just the latest run, for how long it has been
     firing and whether anyone has acted.
  2. The weekly filesystem sweep at
     `governance/handoffs/WEEKLY_DRIFT_REPORT_<date>.md` in the same repo -
     compares `LIVING_INDEX.json` canonical entries against files on disk
     and direction-set hashes. Read the newest one for the current
     drifted-file count and severity driver.
- **Sentry self-reported integrity issues.** Org `dreamer-ai-holdings-llc`.
  `search_issues` for PII, leak, exposure, or the affected surface name,
  period 30d then 90d if 30d is empty. Absence of a hit is a real result,
  report it as such - do not assume the incident happened if the tool
  returns nothing.
- **`governance/04_SPRINTS/` documents newer than the last post.** List the
  directory, sort by mtime, read anything dated after the prior self-catch
  draft's date.
- **Substrate anchors tagged `correction`.** `dreameros_recall` for the tag
  if the MCP is reachable this session; otherwise note BLOCKED and move on,
  do not fabricate the anchor content.

## What counts as a finding

A red gate run. A still-open issue the gate filed. A correction anchor. A
sprint doc naming something that broke. Not a green run, not a merged PR by
itself - a merge is SHIPPED, not FIXED (see the FIXED-means-customer-usable
canon). The finding is what the gate caught, not what got built afterward.

## The post shape

1. **What we caught ourselves doing.** One incident, dated, plain language.
2. **What it cost.** Concrete: a number, a duration, a scope. Not "some
   impact" - the actual count or the actual window.
3. **How the gate caught it.** Name the mechanism without governance/audit/
   security words on the customer-facing draft (see positioning rule below).
4. **What changed so it cannot recur.** The fix, dated, with a receipt link
   (PR, commit, issue) a reader could actually open.

Failure first, fix last. Every claim carries a source. No line that reads
as praise for ourselves.

## Positioning rule (binding on the customer-facing draft only)

This is intent fidelity vocabulary, never governance or audit or security
words on the customer surface. Read
`dreameros-app-frontend/src/lib/intent-fidelity-vocabulary.ts` before
writing a single customer-facing sentence - it is the enforced replacement
table (`audit` becomes "the record, what happened, the trail of what ran";
`verified` becomes "checked, confirmed, held up"; and so on) and the same
file is a build gate on the frontend, so a leaked word there would fail CI
even if this draft never touches that repo. Internal notes attached to the
draft (source list, verification status) may use plain engineering words
freely - the vocabulary gate binds only the reader-facing text.

## Honesty rules

Every claim in the draft carries a file path, an issue number, a run URL,
or an explicit UNVERIFIED tag. If a sweep source returns nothing, say so
instead of writing around the gap. If two sweeps disagree with a number
given by the operator or a prior draft, report the number you found and
name the discrepancy rather than silently picking one. This skill never
publishes; a wrong receipt in a draft is a review-catchable error, a wrong
receipt in a published post is not.
