# reachability-audit

Find value that exists but reaches nobody. Born 2026-08-11/12, when one
session found: six wired signals no customer ever saw, a code-complete proxy
with no deploy, a published spec behind a parked domain, an SDK nobody
announced, a marketing auditor with no caller, four sub-sites with zero
inbound links, and a canon file three agents were told to read that was
never committed. The recurring defect class of this estate is not broken
code. It is unreachable value.

Use when the operator says: reachability audit, what are we sitting on,
find what is built but dark, moat scour, or before any investor or launch
push.

## The four shapes to hunt (rank findings by leverage: value / remaining effort)

1. REAL AND SHIPPED, no surface tells anyone. Highest value, zero build.
2. SPECCED IN DETAIL, never built, where the spec is the hard part.
3. COMPOUNDS silently (corpora, counters, fingerprints, receipts) - a
   competitor starting today cannot catch up by copying code.
4. PROVES a claim others can only assert.

## The sweep, per lane

- ROUTES: every backend route vs every frontend consumer. A route with no
  caller is dark. A 401 on probe proves registered; 404 proves absent;
  always probe a control path too.
- FLAGS: every feature flag defaulting OFF over a REAL implementation.
- REPOS: enumerate from the REMOTE authority (gh repo list), never from
  local clones. The estate is what the remote says, not what is cloned.
- LINKS: every deployed page with zero inbound links from any nav.
- DOCS: governance/proposed and 03_PROPOSALS - built-but-unbuilt verdicts.
- FILES vs GIT: anything an agent was told to read - verify it is COMMITTED
  and pushed, not just present in one working tree.
- MEMORY: a substrate write is complete only when the DESTINATION identity
  reads it back (the retrieval receipt). Cross-surface memory is per
  identity; never assume a write travels.

## Honesty rules

Every claim carries a file path or a probe result. Never assert an absence
you did not test - the expensive error direction is reporting a capability
missing when it exists, which sends someone to rebuild it. Cap output at
the 12 strongest findings; rank by leverage; name what a customer or
investor could be SHOWN once each is surfaced.
