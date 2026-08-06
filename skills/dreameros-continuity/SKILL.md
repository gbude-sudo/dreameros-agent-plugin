---
name: dreameros-continuity
description: Carry context across sessions with DreamerOS memory. Recall what is already known before starting work, and save decisions and outcomes so the next session starts warm instead of cold.
---

# DreamerOS Continuity

Use this skill whenever the user's DreamerOS connection is available and the
task involves ongoing work, prior decisions, or anything the user may have
discussed in an earlier session on any AI surface.

## Before starting substantive work

1. Call the `dreameros_recall` tool with a short query describing the topic
   at hand. If the user references past work ("continue the pricing doc",
   "what did we decide about X"), recall FIRST and answer from what comes
   back rather than guessing.
2. If recall returns relevant memories, treat them as the user's real prior
   context. Prefer them over assumptions. If a memory contradicts what the
   user just said, surface the difference and ask which is current.
3. If recall returns nothing relevant, say so plainly and continue. Never
   invent a memory.

## After meaningful outcomes

1. When a decision is made, a task completes, or the user states a durable
   preference, call `dreameros_remember` with a short, self-contained
   summary. Write it so a future session with zero context can act on it.
2. Include concrete identifiers (project names, file names, dates) rather
   than pronouns. Convert relative dates ("tomorrow") to absolute ones.
3. Do not save secrets, passwords, API keys, or payment details to memory.

## Ground rules

- Recall is read, remember is write. Neither replaces asking the user when
  intent is ambiguous.
- Quote memories honestly. If a recalled memory is only partially relevant,
  say what part applies and what part does not.
- The user can see and delete their memories in their DreamerOS vault. Never
  present memory as something hidden from them.
