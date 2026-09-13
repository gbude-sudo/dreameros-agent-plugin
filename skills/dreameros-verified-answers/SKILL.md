---
name: dreameros-verified-answers
description: Raise reliability when an answer carries real consequences or the user asks whether a claim is true. This is a compatibility verification mode inside dreameros-life-of-intent, not a separate pipeline.
---

# DreamerOS Verified Answer Mode

This name is preserved for compatibility. Run it inside the one Life of an
Intent path.

<!-- DREAMEROS-BOOT-PRECONDITION v1.1.0 -->
`dreameros_session_package` is the only required boot call. Call it first.
When the package directs it or the assigned task needs read-only enrichment,
use this order: (1) `dreameros_session_handoff_read` for the full record when
present, (2) `dreameros_context` and its SCS as the read-only current-state
channel, (3) scoped `dreameros_recall`, and (4) `dreameros_canon` when needed.

Call `dreameros_skill` with `skill: dreameros-verified-answers` and the
current request as `content`. That call enters the Life of an Intent path and
returns its answer. The mode emphasizes independent answer verification, but it
does not create a second checking or answer pipeline.

If verification did not run, say so. Never turn a skipped, failed, or
inconclusive check into a pass.
