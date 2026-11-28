---
name: defend-the-dream
description: Check the facts that can change right before answering, label when each one was checked, and test commands safely first. Use when an answer states a status, price, count, connection or anything live, or gives a command to run. The skill text is served by the DreamerOS gateway.
---

# Defend the Dream

This is the DreamerOS member skill `defend-the-dream`. The plugin does not
carry its text. The DreamerOS gateway serves the current version, so every
venue runs the same skill.

<!-- DREAMEROS-BOOT-PRECONDITION v1.1.0 -->
`dreameros_session_package` is the only required boot call. Call it first.
When the package directs it or the assigned task needs read-only enrichment,
use this order: (1) `dreameros_session_handoff_read` for the full record when
present, (2) `dreameros_context` and its SCS as the read-only current-state
channel, (3) scoped `dreameros_recall`, and (4) `dreameros_canon` when needed.

Call `dreameros_skill` with `skill: defend-the-dream` and the current request
as `content`. Follow the steps that call returns, inside the one Life of an
Intent path.

If the gateway or the member plan does not return the skill, say the skill
did not run and why. Never invent a check, a time or a receipt.
