---
name: check-for-filler
description: Scan text or code the member provides for placeholder passages, filler wording and unfinished-code patterns. Use when the member asks for a filler check, a placeholder scan, or a check for unfinished code.
---

Scan only text the member gave you for this purpose.

1. Call the DreamerOS connector's `dreameros_slop_check` tool with the text. Use
   language "text" for prose, or the code language for code. Use mode "advisory"
   unless the member asks for "block".
2. List the findings with their severity and place in the text. If the result says
   there are more pages, call the tool again with the same text and the
   `next_offset` it gave.
3. State plainly that this scan finds patterns. It does not check whether the text
   is true.
4. Offer to fix the findings. Do not rewrite the member's text unless they ask.
