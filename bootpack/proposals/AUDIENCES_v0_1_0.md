# Who DreamerOS serves: five audiences (PROPOSED v0.1.0)

STATUS: PROPOSED. Not canon until the Human Conductor ratifies it. Nothing
here changes the boot canon source or its reviewed floor yet.

Measured 2026-11-20 on main (gateway origin/main, plugin main 7d8b42c,
frontend origin/main). Each "today" line names the file it was read from.

## Why this exists

The boot canon (bootpack/SOURCE-dreameros-boot-canon.md) is written for one
reader: the person building DreamerOS. It has 0 lines that say "pro",
"elite" or "light", and no section that names an audience. The paste file
for other AI tools (bootpack/out/paste/PASTE-INTO-ANY-LLM.txt, 1046 lines)
is that same builder rulebook, so a customer who pastes it gets internal
rules about branch cleanup and HC actions.

One source stays the rule. This file names the readers so each output can
carry the part that fits its reader.

## 1. HC Architect (the founder building DreamerOS)

What it is: the person who designs, builds and ratifies DreamerOS itself.
Final authority on canon, infrastructure, spend and keys.

Today: gateway governance/00_CORE/HC_TIER_DEFINITION_v1_0_0.md (ratified
2026-05-07) defines the hc tier: founder, architect, governance authority,
the only override power. tier_gate.py TIER_HIERARCHY ends with "hc";
UNLIMITED_TIERS is {"hc"}.

Rules that bind here: the whole current boot canon (R1 to R29). Examples:
R5 "if we claim it, we must do it" (build the claim true, never reword it),
R27 branch hygiene, R29 name the exact value for every HC action.

How to present: never to customers. Internal only.

## 2. HC User (the founder using and testing the product)

What it is: the same person, using DreamerOS daily like a customer, with no
limits, and able to step down into any paid plan to judge what that plan
really delivers.

Today: gateway/app/founder_walk.py. A founder starts a walk as light,
dreamweaver_solo, dreamweaver_duo, pro or elite for 60 minutes by default,
480 at most. Every gateway door answers as that plan; the users table does
not change; hc-only tools refuse during the walk. Routes:
gateway/app/routes_founder_walk.py (POST, GET, DELETE).

Gaps (agent work, after ratification):
- A walk as Free is refused by design (founder_walk.py WALKABLE_TIERS).
  Testing the Free plan needs either Free added to the walk list or a
  separate test member.
- The app has no button to start or end a walk (frontend src: 0 hits for
  walk_as or founder_walk). Today it needs an API call.
- Every receipt and answer during a walk should say "walking as Pro" so a
  test result is never mistaken for an hc result.

How to present: internal only.

## 3. Members: Free, Pro, Elite (and DreamWeaver Solo, Duo)

What it is: paying or free customers. Each member is the Human Conductor
of their own DreamerOS instance (boot canon R26, ACCOUNT BOUNDARY), never
of the system.

Today: one plugin install works on every plan; the gateway checks the plan
on each call and the receipt shows what ran (plugin README.md, lines
193-197). The rules export (Direction Set Workshop, app Profile > Settings
> "Take what we know about you anywhere") is Pro and above: gateway
routes_direction_set.py refuses below Pro with 403.

What a member's AI should carry (the member canon, a subset):
- R1 answer from measurement, R1m show the instrument beside the claim.
- R19 plain words for the scared newbie and the engineer at once.
- R20 act on the first ask.
- R26 the gateway in between, same power on every device, limited only
  by plan.
- Their own direction set (fingerprint, voice, personal canon) on top.
NOT carried: R27 branch hygiene, R29 HC actions, R7a model pinning, any
rule about the founder's repos, keys or Railway.

How to present, one line per plan, in customer words:
- Free: "Your AI, checked. Answers come with a receipt." (Free mints
  up to 25 new receipts a day: gateway receipt_quota.py.)
- Pro: "Take your rules into any AI you use, with checks on the way in
  and the way out."
- Elite: "The highest plan: the most engines and checks DreamerOS
  offers, and your own rulebook in every AI you use." (Draft wording.
  Elite is not unlimited: tier_gate.py UNLIMITED_TIERS is {"hc"} only.
  Which engines Elite gets must be read from TIER_ENGINES before this
  line ships.)
(Exact plan limits come from gateway tier_gate.py at render time, never
typed by hand.)

## 4. Advanced users, any plan (own machines, own servers)

What it is: members who want to see under the hood: run agents locally,
on their own servers or in their own CI, and call DreamerOS from there.

Today: the MCP door https://mcp.dreameros.app/mcp authenticates each user
(plugin README.md "Authentication"). The install folder is Windows
PowerShell setup aimed at the founder (install/claude-code/README.md).

What they need (agent work, after ratification):
- A plain "connect from your own machine or server" guide: MCP URL, key,
  one curl that proves the connection, one receipt check.
- The member canon as a file they can drop into their own agent config
  (AGENTS.md, CLAUDE.md, .cursorrules) on Linux, macOS and Windows.
- Their plan still decides what runs; running locally never unlocks a
  higher plan.

How to present: "Run it your way. Your machine, your server, the same
checks and receipts."

## 5. Every AI engine

What it is: Claude, Codex, Cursor, ChatGPT, Gemini, Grok and others that
read the rules at the start of a session.

Rule: each engine is told which audience it serves before it reads the
rules. An engine serving a member never acts as the HC Architect.

## Output plan (after ratification)

From the one source, the build makes two families:
- Architect pack (today's outputs, unchanged): founder's own machines.
- Member pack: member canon + plan line + their direction set; this
  replaces the current PASTE-INTO-ANY-LLM.txt for customers.
