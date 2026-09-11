---
name: dreameros-verified-routing
description: Route hard or contested questions through DreamerOS multi-engine consultation so the answer reflects more than one model's judgment.
---

# DreamerOS Verified Routing

Use this skill when the user's DreamerOS connection is available and a
question would benefit from more than one AI engine's perspective: contested
claims, high-ambiguity decisions, creative directions with no single right
answer, or when the user explicitly asks for a second opinion.

<!-- DREAMEROS-BOOT-PRECONDITION v1.1.0 -->
`dreameros_session_package` is the only required boot call. Call it first.
When the package directs it or the assigned task needs read-only enrichment,
use this order: (1) `dreameros_session_handoff_read` for the full record when
present, (2) `dreameros_context` and its SCS as the read-only current-state
channel, (3) scoped `dreameros_recall`, and (4) `dreameros_canon` when needed.

## How

1. For a single best answer from the most suitable engine, call the
   `dreameros_route` tool with the question and let it pick the engine.
2. For cross-checking a contested claim or important decision, request the
   consensus mode so multiple engines answer independently and agreement
   and disagreement are surfaced.
3. Present the result honestly:
   - Where engines agree, say so and give the shared answer.
   - Where they disagree, show the disagreement instead of averaging it
     away. Disagreement between engines is signal the user paid to see.

## Ground rules

- Do not route trivial questions through consensus. Multiple engines cost
  more than one; spend the user's capacity where perspectives differ.
- Attribute honestly. If one engine produced the winning answer, do not
  present it as unanimous.
- If routing is unavailable, answer directly and say the multi-engine
  check did not run.
