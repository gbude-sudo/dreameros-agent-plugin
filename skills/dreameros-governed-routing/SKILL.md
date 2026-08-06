---
name: dreameros-governed-routing
description: Route hard or contested questions through DreamerOS multi-engine consultation so the answer reflects more than one model's judgment.
---

# DreamerOS Governed Routing

Use this skill when the user's DreamerOS connection is available and a
question would benefit from more than one AI engine's perspective: contested
claims, high-ambiguity decisions, creative directions with no single right
answer, or when the user explicitly asks for a second opinion.

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
