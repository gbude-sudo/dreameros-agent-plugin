---
name: dreameros-verify
description: Verify a claim against current files, runtime evidence, and DreamerOS before it is acted on or published.
---

<!-- DREAMEROS-BOOT-PRECONDITION v1.1.0 -->
`dreameros_session_package` is the only required boot call. Call it first.
When the package directs it or the assigned task needs read-only enrichment,
use this order: (1) `dreameros_session_handoff_read` for the full record when
present, (2) `dreameros_context` and its SCS as the read-only current-state
channel, (3) scoped `dreameros_recall`, and (4) `dreameros_canon` when needed.

State the exact claim and its definition of done. Read the referent, run the
highest deterministic check available, and call `dreameros_verify` at light
depth unless the Human Conductor authorizes a paid depth. Return the evidence,
counterevidence, limitations, and the smallest truthful verdict.
