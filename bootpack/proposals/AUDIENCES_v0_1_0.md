# Who DreamerOS serves, and how deep they go (PROPOSED v0.2.0)

STATUS: PROPOSED. Not canon until the Human Conductor ratifies it. Nothing
here changes the boot canon source or its reviewed floor yet.

Measured 2026-11-20 on main (gateway origin/main, plugin main 7d8b42c,
frontend origin/main). Each "today" line names the file it was read from.

## The idea, in the Human Conductor's terms

DreamerOS began as the Human Conductor's own local system. It is shared so
other people get the same power without the trials it took to build it.

It must be an easy button: it just works, the way an iPhone or Zscaler
just works. And anyone who wants to can go down into the weeds, the way
Android or Palo Alto lets you. Same power, training wheels on by default,
training wheels off when you choose. Money, skill or aptitude never decide
who gets the power. The plan decides what is included. The depth setting
decides how much you see and control.

## 1. HC: the Human Conductor (one person)

What it is: the founder. Builds DreamerOS and uses it every day. Final
authority on canon, keys, spend and other members' plans.

Today: gateway governance/00_CORE/HC_TIER_DEFINITION_v1_0_0.md (ratified
2026-05-07): "HC also USES DreamerOS daily as an operator - the same way a
paying customer would." tier_gate.py: tier "hc", UNLIMITED_TIERS {"hc"}.

THE SAME-TIME RULE. What HC finds, makes or sees reaches members in the same
change, gated only by plan. A capability that exists for HC and not for any
member is a defect with a ship date, not a perk. Only authority stays with
HC: ratifying canon, holding keys, spending, changing another member's plan.
This is boot canon R26 (same power everywhere, the only differentiator is
plan) said from HC's side.

Checking a plan: gateway/app/founder_walk.py lets HC step down into light,
dreamweaver_solo, dreamweaver_duo, pro or elite for 60 to 480 minutes
without changing the account. It refuses free.

## 2. Test accounts (separate from HC)

What it is: member accounts used for in-depth testing, never the founder's
account. They prove what a real member sees.

Today: the nightly member walk signs in with DreamerOS_TestLogin and
DreamerOS_TestPass (gateway/app/member_walk_cron.py:245,254), with a
secondary login MEMBER_WALK_SECONDARY_LOGIN (line 263).

Gap: one test account per plan (free, light, pro, elite) so every plan is
walked, not only one.

## 3. Members, every plan: two depths, same power

Every member is the Human Conductor of their own DreamerOS instance, never
of the system (boot canon R26, ACCOUNT BOUNDARY).

SIMPLE (default, training wheels on):
- It just works on first sign-in. No setup choices before value.
- One answer, one plain line saying what DreamerOS did, one receipt.
- Plain words only. No internal names.
- Safe defaults: checks on, approvals on for anything that sends, spends
  or deletes.

ADVANCED (chosen, training wheels off):
- Every check, every score, every engine choice visible and adjustable.
- The signed receipt in full, the hash chain, the raw record.
- Their own rulebook (direction set), exported to any AI tool.
- Connect from their own machine, server or CI: MCP address, key, one test
  command, one receipt check, member rulebook as AGENTS.md, CLAUDE.md or
  .cursorrules for Linux, macOS and Windows.
- Running locally never unlocks a higher plan.

Today (pieces of this already exist, per surface, not as one setting):
- Sidebar progressive disclosure, calm by default
  (frontend src/components/AppSidebar.tsx:293).
- Receipt four-step disclosure ladder
  (frontend src/components/GovernanceRibbon.tsx:1822).
- Connector drawer progressive disclosure
  (frontend src/components/connect/CapabilityDrawer.tsx:37).
- Rules export: Direction Set Workshop, Pro and above (gateway
  routes_direction_set.py refuses below Pro with 403).

Gaps (agent work, after ratification):
- One Simple/Advanced switch per member that every surface reads, instead
  of each surface deciding alone.
- The paste-into-any-AI file today is the full 1046-line builder rulebook
  (bootpack/out/paste/PASTE-INTO-ANY-LLM.txt). Members need a member pack
  instead: Simple and Advanced versions.
- A self-host guide for Advanced members on any plan.

How to present, in customer words (draft):
- Simple: "It just works. Ask, and you get a checked answer and a receipt."
- Advanced: "Open the hood. Every check, every engine, every record, on your
  machine or ours."
Plan limits come from gateway tier_gate.py at render time, never typed by
hand. No plan is unlimited except hc (UNLIMITED_TIERS).

## 4. Every AI engine

Claude, Codex, Cursor, ChatGPT, Gemini, Grok and others. Each engine is
told who it serves (HC, a test account, or a member at Simple or Advanced
depth) before it reads the rules. An engine serving a member never acts
with HC authority.

## Output plan (after ratification)

From the one boot canon source, the build makes:
- HC pack: today's outputs, for the founder's machines.
- Member pack, Simple: the short member rules and plain words.
- Member pack, Advanced: the member rules plus the under-the-hood detail
  and self-host guide.
