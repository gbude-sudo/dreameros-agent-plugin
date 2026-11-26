# Boot canon newness proposal, 2026-11-24, v0.1.0

STATUS: PROPOSED. UNRATIFIED. NOT IN FORCE. HC ratifies canon.
This file is not read by the build. It changes no rule. It does not change
bootpack/SOURCE-dreameros-boot-canon.md.

Receipt zero and author session: recorded in DreamerOS.
Base: origin/main 7d8b42c (source v2.6.3, semantic sha256 a33b8115e340d709).

Every reading below has its UTC time and its instrument. A reading older
than five minutes is a recall (R1j). Read it again before you act on it.

## N1. A cloud session cannot run the boot check as written

Reading: on the cloud sandbox at 2026-11-24 19:45Z, `ls ~/.claude/CLAUDE.md`
and `ls ~/.codex/AGENTS.md` both failed (shell). The local record folder
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
CORRECTION 2026-11-24 20:00Z. The first version of this item said the
wrapper markers were not found. That was a limit of my search, which looked
for BEGIN and END words. The wrapper is an XML tag pair: an opening tag named
dreameros_boot_canon with the attributes schema_version, version, sha256,
hash_normalization, canary_ids, source_repository, source_path and generator,
and a closing tag with the same name. The package holds exactly one of each.
The body between them is 52,084 characters. Its LF-normalized sha256 is
a33b8115e340d709, equal to the pinned hash. So the wrapper hash check passes.
Remaining gap: the canon text does not name the tag. The gateway composer
emits it. Proposal: name the tag pair in
carrier B, and add the five checks above, plus a sixth check that hashes the
body between the tags, as the overflow procedure.

## N3. Four sessions started the same goal inside three minutes

Reading: DreamerOS memory (dreameros_recall, 19:40Z) holds beacons or claims
from three other sessions and mine, written 19:38Z to
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
pointer.
UPDATE 2026-11-24 20:15Z. A dreamerOS pull request merged and refreshed the skill
file to v2.6.3. The block in .claude/CLAUDE.md is a generated block with
BEGIN and END markers, so a refresh is what -Install does. a second dreamerOS pull request
refreshes it to v2.6.3 and moves the removed text to
archive/boot-canon-history. Whether to remove the block, and keep carrier A
by install only, stays an HC decision.

## N5. Tracked backup files in a skill folder

Reading: git ls-files at 20:13Z counts 25 tracked files in dreamerOS
.claude/skills/dreameros-boot: SKILL.md and 24 SKILL.md.bak-* files,
908,490 bytes in all. The first version of this item said I read only 20
names. All 25 are read now. Each backup is a stale copy that a search will
find. R27 says stale labels are lies waiting to be searched.
Proposal: delete the 24 backups. Git history holds every blob.
UPDATE 2026-11-24 20:14Z. a third dreamerOS pull request removes the 24 files. Nothing in
the repo references them (grep, control proved).

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
