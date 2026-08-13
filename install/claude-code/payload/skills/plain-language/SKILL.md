---
name: plain-language
description: Rewrites text into ASD-STE100 Simplified Technical English without losing meaning or evidence. Use when the operator says plain language, simplify this, STE, make this readable, tighten this copy, or before shipping a PR body, canon document, or customer-facing string. Also use to check your own draft before you send it.
---

# plain-language

Rewrite prose into ASD-STE100 Simplified Technical English. Keep every fact. Lose no evidence.

The companion agent `plain-language-auditor` finds violations and reports them. This skill fixes them.

## The rules you apply

1. One word, one meaning. Pick one word per idea. Use it everywhere. Do not vary words for style.
2. Use the plainest word. Start, not commence. Use, not utilize. Before, not prior to. To, not in order to.
3. Instruction sentences: 20 words or fewer.
4. Other sentences: 25 words or fewer.
5. Active voice. Name the actor.
6. One instruction per sentence.
7. No present perfect. Use simple past or present.
8. Turn nominalizations back into verbs. "Perform a verification" becomes "verify".
9. Replace vague quantity with the real number. Not "several failures". Say "32 failures".

## What you must never change

- **Quoted evidence.** A log line, an error string, a test output, or an operator quote keeps its exact original words. Rewriting evidence to read well destroys the thing that made it evidence.
- **Identifiers.** Field names, function names, file paths, branch names, commit SHAs, env var names. `overall_severity` stays `overall_severity`.
- **Numbers and units.** Never round to make a sentence shorter.
- **Hedges that carry real uncertainty.** "This is inferred, not verified" must survive. Plain language removes vagueness, not honesty. If a claim is uncertain, say so in short words.

## Method

1. Read the whole text first. Find the claims it makes.
2. Split every long sentence at its natural joint. Most long sentences hold two claims.
3. Rewrite each part in active voice with a named actor.
4. Replace each non-plain word.
5. Choose one word per repeated idea and apply it everywhere.
6. Re-read. Confirm every original fact survives. A shorter text that lost a fact is a failure, not a success.

## Return

Give the rewritten text. Then give a short list:
- WORD CHOICES LOCKED: which word you kept for each repeated idea
- FACTS AT RISK: anything you nearly lost while shortening, and how you kept it
- LEFT ALONE: quoted evidence and identifiers you did not touch, and why

## The reason this exists

Plain text is checkable. A long sentence can hide a claim that nobody can test. Short active sentences force each claim to stand alone. A reader can then verify the claim or refuse it. Vague writing is how a false claim survives review.
