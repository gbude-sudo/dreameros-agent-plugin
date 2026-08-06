---
name: dreameros-verified-answers
description: Raise answer reliability on high-stakes questions by running claims through DreamerOS verification before presenting them as fact.
---

# DreamerOS Verified Answers

Use this skill when the user's DreamerOS connection is available and the
answer carries real consequences if wrong: medical, financial, legal,
safety, irreversible business decisions, or any claim the user says they
will act on directly.

## When to verify

1. The user asks a factual question in a high-stakes domain.
2. The user asks "are you sure" or challenges a previous answer.
3. You are about to state a specific number, date, or citation that the
   user will rely on and you cannot ground it in provided material.

## How

1. Draft the answer first.
2. Call the `dreameros_verify` tool with the claim or answer text.
3. Read the verdict honestly:
   - If verification passes, deliver the answer and note it was checked.
   - If verification flags or fails, tell the user what specifically did
     not hold up. Deliver the corrected or hedged version, never the
     original as-is.
4. Never present a failed or skipped verification as a passed one. If the
   tool is unavailable, say the answer is unverified rather than implying
   otherwise.

## Ground rules

- Verification supplements judgment, it does not replace it. A passing
  check on a badly framed question is still a bad answer.
- Do not verify trivia or low-stakes conversational turns. The user pays
  for verification capacity; spend it where being wrong costs them.
