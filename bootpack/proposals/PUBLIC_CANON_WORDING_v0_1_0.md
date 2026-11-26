# Public canon wording proposal v0.1.0

Status: RATIFIED by the owner, applied to the source in the canon wording
release (source v2.6.4). The generated copies change only when the boot pack
is rebuilt on Windows.

Purpose: the boot canon source is public. Six passages carry detail that a
reader does not need to follow the rule. Each row below names the rule, says
what kind of detail the passage carries, and gives replacement wording that
keeps the rule and drops the detail. This file does not quote the passages.

How to apply after ratification:
1. Edit `bootpack/SOURCE-dreameros-boot-canon.md` only.
2. Run `bootpack/build-boot-pack.ps1` to regenerate every carrier.
3. Run `python scripts/public_surface_gate.py --update-baseline` to lock in
   the lower counts.
4. The rule count floor stays at 44. No rule is added or removed.

| # | Where | What the passage carries now | Replacement wording |
|---|-------|------------------------------|---------------------|
| 1 | Rule on counting sources, the paragraph that begins with the agent counting as one source | A dated owner instruction with an exact quotation | "The agent counts as one source at most. The agent's own command output, reasoning or lane report is never more than one of the two required sources. Two reads of the same system are one source; say so." |
| 2 | Rule 4, the measured count of per-repo instruction files | A dated measurement with exact file counts and byte sizes of one private machine | "Each repository can carry its own instruction file. Working in a repository means carrying the global file plus that file, so changing the global file alone changes only part of what is read." |
| 3 | Rule 13, the two instrument lines | Names of scripts in the owner's private offload folder | "Instruments: a script that walks every public door and checks one signature each, and a script that walks the deepest door while signed in. Extend the walker with a door for every new capability, in the same change that ships it." |
| 4 | Environment variable rule, the defect paragraph | A dated production metric with variable counts and a time of day | "THE DEFECT. Code reads a variable. The variable is unset. The code runs on a default and says nothing, and nobody tells the owner. Measure the count of unset variables from the gateway health report and show it with its time." |
| 5 | Boot check 0, hydrate first | Names of folders and ledger files in the owner's private offload folder | "Read the newest session ledger, then the newest audits index, then the last cloud mirror status line, from the local offload named in the last handoff. Never pick a file by modified time. Compare the handoff with the ledger. A disagreement is written as a correction anchor before any work starts." |
| 5b | Rule 28, two references to the offline folder name | The private offload folder name | "session ledgers and change records" and "session ledgers, audits, change records, mirror" |
| 6 | Definition of done, the closing WHY paragraph | A dated incident and a personal duration | "WHY: an agent once reported work as done because it was merged into main. Main is a branch name. It is not a customer and it is not revenue. That is the cost of speaking the smaller word as the bigger one." |

Held back, with the reason:
- The boot canon states its own source rules (for example the five-condition
  definition of done). They carry no private detail and stay as they are.
- Rows 2, 4 and 5 describe things only the owner's machine or the live gateway
  can measure. The replacement keeps the instruction to measure and drops the
  one-time reading. The reading itself belongs in the private ledger.

Row 7, added at apply time: two mentions of a named verifier vendor in rule 7
now say "the independent verifier pool". Row 5 keeps its required opening
sentence, so the source floor clause list is unchanged. The floor hash and the
version (v2.6.3 to v2.6.4) were updated, and two version pins in
`bootpack/tests/build-installed.tests.ps1` follow the new version.
