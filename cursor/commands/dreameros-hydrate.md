---
name: dreameros-hydrate
description: Hydrate the current Cursor task from DreamerOS and the repository before substantive work.
---

<!-- DREAMEROS-BOOT-PRECONDITION v1.0.0 -->
Run the DreamerOS boot sequence now:

1. Call `dreameros_session_package` for the active model family. If the family
   is unavailable, use neutral Markdown via `engine=chatgpt` and set
   `project_context` to identify Cursor and this repository.
2. Call `dreameros_context` and `dreameros_state`.
3. Recall the current topic and `next-session-read-first` continuity.
4. Read root and nested repository instructions, the newest relevant handoff,
   and current Git state.
5. Report `CONNECTED`, `PARTIALLY CONNECTED`, or `BLOCKED`, then continue the
   requested work. Do not stop at the report if safe work is available.
