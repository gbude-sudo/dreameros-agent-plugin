---
name: p37-truth-audit
description: Cross-check every specific product claim on a marketing or docs surface against the shipped runtime, producing LIVE / PARTIAL / MIS-SOLD verdicts with file:line and live-URL evidence, then optionally drive the fix batch. Use whenever the operator asks whether the website matches the product, mentions mis-selling, drift between copy and code, "does this feature actually exist", investor diligence prep, or before publishing any new marketing page. Also use proactively after big feature merges so new copy never ships unchecked.
---

# p37-truth-audit

P37 canon: done means customer-usable, and mis-selling (copy claiming a capability
that has not shipped) is a hard escalation, not a copy nitpick. This skill is the
audit that finds it before a customer or an investor's diligence engineer does.
Proven 2026-08-04/05 across three repos: it found a parked API domain, a key prefix
that never existed, four marketed endpoints with zero code, and deleted components
sold as live Pro+ features.

## Method

1. ENUMERATE specific claims only. A claim is checkable: a named endpoint, a price,
   a tier boundary, a count ("22 rules", "70+ tools"), a capability ("detects action
   items automatically"), a mechanism description ("permissions prevent deletion").
   Vague marketing language ("think better with AI") is out of scope.

2. For each claim, FIND THE RUNTIME REFERENT and verify against it, never against
   another document (documents drift together):
   - Endpoints: grep the gateway route files for the literal path; confirm the
     router is mounted (gateway_routers.py), and note the auth model on the handler.
   - Tier claims: gateway/app/tier_gate.py is the arbiter (min_tier entries,
     TIER_MEMORY_LIMITS, TIER_META prices), never a doc.
   - Frontend features: trace the import chain to a reachable page; a component on
     disk with zero imports is NOT live.
   - External artifacts: npm view / PyPI JSON endpoint for packages, a live GET for
     domains (a parked-domain page counts as MIS-SOLD, not PARTIAL), curl the real
     deployed page for post-deploy verification.
   - Counts: recount from the live registry or enum, never trust a number in prose.

3. VERDICT each claim:
   - LIVE: reachable and working as claimed, at the stated tier.
   - PARTIAL: present but degraded, gated differently, or unusable as documented
     (right endpoint, wrong auth in the sample; feature behind a dark flag).
   - MIS-SOLD: the product does not deliver it to a real customer today.

4. REPORT mis-sold first, evidence-dense: quote the exact copy, cite the exact
   file:line or live URL checked. Include a verified-true section - honesty cuts
   both ways, and the true material is what marketing gets to keep.

## Claim classes that recur (check every one)

- Parked or fictional domains in code samples; wrong API key prefixes.
- Endpoints, SDK methods, or packages that exist only in the copy.
- Components marketed as live that were deleted or never mounted (grep imports).
- Stale counts: principles, tools, recipes, memory limits, domain modules.
- Tier mismatches: free-tier copy claiming pro-gated capability, or the reverse
  (underselling a right users actually have counts too).
- Mechanism misdescriptions (claiming permissions where the real guard is a
  trigger; claiming an advisory gate where the real one is blocking - note when
  the truth is STRONGER than the claim, that is a good-news fix).
- Internal tools presented as customer capabilities.
- The same fact stated differently on two pages of the same site.

## Fix batch discipline (when asked to fix, not just audit)

Work in an isolated git worktree of the target repo, never the operator's checkout.
Intent-fidelity vocabulary in customer copy (verified, checked, receipt - never the
g-word). No em or en dashes; spaced hyphens only; codepoint-scan the diff. One batch
commit, Dreamer AI author identity via GIT env vars. After merge and deploy, curl
the LIVE deployed page and grep for the removed falsehoods returning zero hits -
merged is not done, deployed-and-verified is done. Flag anything out of scope
explicitly so it lands in the next batch instead of evaporating.
