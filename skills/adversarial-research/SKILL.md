---
name: adversarial-research
description: "DreamerOS never accepts the first answer. Use this skill for any research, comparison, recommendation, diagnosis, or claim that a decision will rest on: pick a product, a player, a vendor, a fix, a cause, a model, a price, a plan. Trigger on: research, find out, which is best, should I, compare, verify, is it true, what caused, look into, figure out, recommend, decide between, and on any question whose answer can change over time. Skip it only for trivial lookups where one authoritative source settles the matter and nothing is decided on it."
---

# Adversarial Research Protocol

HC canon, 2026-09-16: "we dont accept first answer". Binding on every
DreamerOS venue, engine and vendor, forever. When it applies, run it in full.
The protocol text below is HC's, kept as given.

## Protocol

Act as an adversarial research analyst.

QUESTION
{question}

DECISION THIS RESEARCH MUST SUPPORT
{decision}

FRESHNESS
Current as of: {today / specified date}

Do not search for confirmation of a proposed answer.

Research in rounds:

ROUND 1 - LANDSCAPE
Identify the plausible answers, relevant variables, major evidence categories, and authoritative source classes.

ROUND 2 - PRIMARY EVIDENCE
Investigate the strongest primary/direct sources for each serious candidate.

ROUND 3 - INDEPENDENT CORROBORATION
Find at least two materially independent sources for every claim that could change the decision.

ROUND 4 - COUNTERCASE
Search specifically for:
- evidence against the current leader;
- failure cases;
- contrary expert interpretation;
- version/date/population mismatches;
- hidden disadvantages;
- evidence favoring the strongest alternative.

ROUND 5 - SECOND-ORDER ANALYSIS
Evaluate consequences beyond the immediate answer:
- near term;
- medium term;
- reversibility;
- opportunity cost;
- dependencies;
- downstream effects.

ROUND 6 - SATURATION CHECK
Run one final materially different counterquery.
Stop only when new credible evidence no longer changes the decision or when the remaining uncertainty cannot presently be resolved.

SOURCE RULES
Prefer:
1. direct/primary evidence;
2. official technical or institutional sources;
3. high-quality independent analysis;
4. community evidence only for lived experience or undocumented behavior.

Separate publication date from the date the underlying event/data occurred.
Do not treat multiple sites repeating one source as independent corroboration.

OUTPUT
TLDR winner, if one exists.

Then:
Evidence for winner
Strongest counterargument
Why alternatives lost
Important uncertainty
What would reverse the decision
Sources beside the claims they support

If the evidence does not establish a winner, output:
NO CLEAR WINNER
and identify the smallest missing fact that would decide it.

## How DreamerOS applies it

- A state or fact about the running system counts as research too. The
  "primary source" is a live instrument run now (a command, an API, a
  log), never an older report or memory. An older document cannot
  disprove something that changed after it was written.
- A cheap small model may gather sources. It never picks the winner.
- A check that shares training lineage with the answer is not independent
  corroboration. Say so when it happens.
- A reply that stops at round 2 is not this protocol. Say which rounds
  ran, and why any round was skipped.
