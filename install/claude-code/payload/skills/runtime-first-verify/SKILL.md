---
name: runtime-first-verify
description: Probe the live runtime before you list any blocker or ask the operator for an action. Use before reporting a missing env var, a missing credential, a stale deploy, or any blocker inherited from substrate, a prior session, or another agent. Also use when the operator asks "is X still blocked". Born 2026-08-13, when a two-command curl probe proved a blocker was already resolved after it was asked for repeatedly.
---

# runtime-first-verify

The lesson from 2026-08-13. IFAAS_TIER1_KEYS was asked for repeatedly while
a two-command curl probe proved it was already set. The Slack credentials
blocker sat stale in substrate after HC fixed it. Both asks were waste.
The runtime already held the answer.

The rule: a blocker written down is a claim about the past. The runtime is
the present. Probe the present before you repeat the claim.

## When this fires

- Before you list any blocker in a status report.
- Before you ask the operator to set a key, a secret, or a config value.
- Before you act on a blocker recalled from substrate or a prior session.
- When the operator asks whether something is still blocked.

## Probe recipes

1. FAIL-CLOSED ENDPOINT for a secret or env var. Call the endpoint that
   needs the value, with no auth. Read the status code:
   - 503 means the value is unset. The service refuses to start the path.
   - 401 or 403 means the value is set. The service loaded it and now
     rejects your unauthenticated call.
   Two commands, no credentials needed, and the verdict is mechanical.

2. RAILWAY DEPLOY STATE. Query the deployments list. Read meta.commitHash
   on the newest SUCCESS deployment. That is the live SHA. Compare it to
   the SHA the fix landed in. Newer or equal means deployed.

3. TOKEN LIVENESS. Run `gh run list` or an equivalent authenticated read.
   Success proves the token works now. An old failure log proves nothing
   about now.

## The correction duty

A stale blocker is a canon offense. When a probe proves a recorded blocker
is resolved, write the substrate correction immediately, in the same turn.
Name the probe, the result, and the anchor it supersedes. Do not leave the
stale claim standing for the next session to inherit.

## Honesty rules

- Never report a blocker you did not probe this session.
- Name the probe command and the status code next to every blocker claim.
- If you cannot probe, say UNPROBED, not BLOCKED.
