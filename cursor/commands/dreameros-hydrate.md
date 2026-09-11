---
name: dreameros-hydrate
description: Hydrate the current Cursor task from DreamerOS and the repository before substantive work.
---

<!-- DREAMEROS-BOOT-PRECONDITION v1.1.0 -->
Run the DreamerOS boot sequence now. `dreameros_session_package` is the only
required boot call. Call it first for the active model family. If the family is
unavailable, use neutral Markdown via `engine=chatgpt` and set `project_context`
to identify Cursor and this repository.

When the package directs it or the assigned task needs read-only enrichment,
use this order: (1) `dreameros_session_handoff_read` for the full record when
present, (2) `dreameros_context` and its SCS as the read-only current-state
channel, (3) scoped `dreameros_recall`, and (4) `dreameros_canon` when needed.

1. Read root and nested repository instructions, the newest relevant handoff,
   and current Git state.
2. Report `CONNECTED`, `PARTIALLY CONNECTED`, or `BLOCKED`, then continue the
   requested work. Do not stop at the report if safe work is available.
