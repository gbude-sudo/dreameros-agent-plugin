---
name: dreameros-verified-routing
description: Choose the best eligible model or request a second opinion for a hard, ambiguous, or contested task. This is a compatibility routing mode inside dreameros-life-of-intent, not a separate pipeline.
---

# DreamerOS Verified Routing Mode

This name is preserved for compatibility. Run it inside the one Life of an
Intent path.

<!-- DREAMEROS-BOOT-PRECONDITION v1.1.0 -->
`dreameros_session_package` is the only required boot call. Call it first.
When the package directs it or the assigned task needs read-only enrichment,
use this order: (1) `dreameros_session_handoff_read` for the full record when
present, (2) `dreameros_context` and its SCS as the read-only current-state
channel, (3) scoped `dreameros_recall`, and (4) `dreameros_canon` when needed.

Call `dreameros_skill` with `skill: dreameros-verified-routing` and the
current request as `content`. That call enters the Life of an Intent path and
returns its answer. The mode emphasizes best-fit routing and second opinion,
but it does not create a second model-selection or answer pipeline.

Report the engine and any disagreement only when the Gateway response proves
them. Never present one answer as consensus.
