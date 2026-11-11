---
name: save-handoff
description: Save a short handoff to the member's DreamerOS account. Use when the member asks to save where they stopped, leave notes for a later session, or write a handoff. Do not use it on your own initiative.
---

Save a handoff only when the member asks for it.

1. Draft a short handoff from what the member told you in this conversation:
   - summary: what happened, in plain words.
   - next_actions: what to do next, in order (optional).
   - open_questions: what is still unresolved (optional).
2. Show the member the exact text you plan to save. Leave out passwords, keys and
   other secrets, even if they appeared in the conversation.
3. Save only after the member says yes. Use the DreamerOS connector's
   `dreameros_session_handoff_write` tool with those fields.
4. Tell the member that the handoff is saved, and how to read it later: ask
   "what did I leave for later?".

If the member says no or wants changes, edit the text and show it again. If the tool
returns an error, tell the member what it said. Do not retry with different text
without asking.
