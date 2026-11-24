# Boot canon newness proposal, 2026-11-24, v0.1.0

STATUS: PROPOSED. UNRATIFIED. NOT IN FORCE. HC ratifies canon.
This file is not read by the build. It changes no rule. It does not change
bootpack/SOURCE-dreameros-boot-canon.md.

Receipt zero: 08b70e68. Author session: 017THZwRpiF6Sv1VWVHuLaqr.
Base: origin/main 7d8b42c (source v2.6.3, semantic sha256 a33b8115e340d709).

Every reading below has its UTC time and its instrument. A reading older
than five minutes is a recall (R1j). Read it again before you act on it.

## N1. A cloud session cannot run the boot check as written

Reading: on the cloud sandbox at 2026-11-24 19:45Z, `ls ~/.claude/CLAUDE.md`
and `ls ~/.codex/AGENTS.md` both failed (shell). The Offline_Repo folder
that BOOT CHECK step 0 names was not on the box.
Cause: BOOT CHECK step 0, R13 and R15 name paths and PowerShell tools that
exist only on HC's Windows machine.
Proposal: add one line to BOOT CHECK step 0. In a cloud venue, say that
carrier A is absent, prove carrier B, and use the cloud instruments in the
dreameros-live-state skill appendix (gateway repo, .claude/skills). R26
already says a venue gap is a defect. The line makes the gap a named state,
not a silent skip.

## N2. How to prove carrier B when the package overflows the tool limit

Reading: the session package was 76,547 characters at 19:39:05Z
(dreameros_session_package, harness saved it to a file).
The harness could not show it inline.
Proof that worked, with five checks, all passed at 19:45Z:
1. sha256 of package_text equals the package content_hash (d9bb6d7b).
2. package_components.boot_canon.version reads v2.6.3.
3. The component sha256 equals the reassemble_sha256 (a33b8115).
4. The source file sha256 equals that value, and the full source text sits
   inside package_text.
5. composed_at plus ttl_seconds (1800) has not run out.
Gap: I did not find the wrapper begin and end markers by regex, so I did
not hash the wrapper body on its own. The canon names a wrapper but gives no
marker text. Proposal: name the exact marker strings in carrier B, and add
these five checks as the overflow procedure.

## N3. Four sessions started the same goal inside three minutes

Reading: DreamerOS memory (dreameros_recall, 19:40Z) holds beacons or claims
from sessions 01BV1zz2, 34fd731d, 1aef3edb and mine, written 19:38Z to
19:40Z, all for the same HC goal. One session disclosed that it wrote to a
PR branch before it read the other claims.
Cause: BOOT CHECK step 5 asks for a claim only before editing a shared
file. A census starts as a read, then turns into writes.
Proposal: before any goal that can write to a shared repo, recall
beacon-active first. If a claim for the same goal exists, take one named
lane or yield. Write your own claim before your first write.

## N4. The skill copy in dreamerOS fell three versions behind, unseen

Reading: dreamerOS .claude/skills/dreameros-boot/SKILL.md was v2.6.0 at
19:45Z. The source was v2.6.3. Nothing failed. The repo file
.claude/CLAUDE.md also holds a full v2.6.0 copy of the canon at line 265,
against the rule that says never paste the full canon into a repository
instruction.
Proposal: a parity check in the dreamerOS repo. It compares the skill file
sha256 to the CHECKSUMS.txt entry in this plugin, and fails when they
differ. Remove the pasted canon copy from .claude/CLAUDE.md, and keep the
pointer. PR 287 in dreamerOS refreshes the skill file now.

## N5. Tracked backup files in a skill folder

Reading: git ls-files at 19:46Z counts 25 tracked files in dreamerOS
.claude/skills/dreameros-boot. I read the first 20 names: SKILL.md and 19
SKILL.md.bak-* files. I did not read the last 5 names. Each backup is a
stale copy that a search will find. R27 says stale labels are lies waiting to be searched.
Proposal: add each backup to the recoverable-originals folder, or delete it
after HC confirms git history holds it.

## N6. One line that shows the boot state in the first reply

Idea, not a reading. The first reply of a session would carry one line:
`Boot: v2.6.3 a33b8115, carrier B, composed 19:39Z, ttl 1800`.
HC then sees which canon a session runs on without asking. A session that
cannot print the line has not proven a carrier. This adds a check that a
Stop hook can run, and it is cheap to build.

## What this proposal does not do

- It does not change a rule, a hash or a generated file.
- It does not ratify the R19 clarification that the source already labels
  as unratified.
- It names no secret and quotes no operator words.
