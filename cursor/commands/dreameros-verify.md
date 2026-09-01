---
name: dreameros-verify
description: Verify a claim against current files, runtime evidence, and DreamerOS before it is acted on or published.
---

<!-- DREAMEROS-BOOT-PRECONDITION v1.0.0 -->
Require returned proof for `dreameros_session_package`, then
`dreameros_context`, then `dreameros_state`. If the current chat has no such
proof, perform those calls in that order before verification.

State the exact claim and its definition of done. Read the referent, run the
highest deterministic check available, and call `dreameros_verify` at light
depth unless the Human Conductor authorizes a paid depth. Return the evidence,
counterevidence, limitations, and the smallest truthful verdict.
