---
name: dreameros-continuity
description: Carry context across sessions with DreamerOS memory. Use when work depends on prior decisions, another session, another client, or a durable handoff. This is a compatibility mode inside dreameros-life-of-intent, not a separate pipeline.
---

# DreamerOS Continuity Mode

This name is preserved for compatibility. Run it inside the one Life of an
Intent path.

<!-- DREAMEROS-BOOT-PRECONDITION v1.1.0 -->
`dreameros_session_package` is the only required boot call. Call it first.
When the package directs it or the assigned task needs read-only enrichment,
use this order: (1) `dreameros_session_handoff_read` for the full record when
present, (2) `dreameros_context` and its SCS as the read-only current-state
channel, (3) scoped `dreameros_recall`, and (4) `dreameros_canon` when needed.

Call `dreameros_skill` with `skill: dreameros-continuity` and the current
request as `content`. That call enters the Life of an Intent path and returns
its answer. The mode emphasizes cross-session context and handoff, but it does
not create a second memory or answer pipeline.

If the Gateway or entitlement is unavailable, report the affected step
`BLOCKED`. Never invent recalled context, a handoff, or a receipt.
