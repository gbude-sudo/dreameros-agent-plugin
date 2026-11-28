# Changelog

This file lists changes by date, from the Git history of this repository.
The plugin version in `plugin.json` is 0.5.4. The repository has no tagged
release of the plugin yet, so entries are dated, not numbered.

## Unreleased

- Add the member skill `defend-the-dream` under `skills/`. It is a thin entry that calls `dreameros_skill` with `skill: defend-the-dream`. The gateway serves the skill text, so the plugin carries no copy that can drift. The validator now checks its boot precondition block.
- Fix `gate-stop-no-half-states.sh`. The gate used to block, allow the same state once, then erase its memory, so it blocked again on the next reply. One dirty worktree cost one extra model turn on every reply. It now blocks when the set of half-states changes, shows the full notice once, then shows one short line until the set changes. The state names worktrees, not file counts. Nothing is narrowed by folder or owner. Test: `install/claude-code/tests/test_gate_stop_no_half_states.py`.
- The done check is now part of the DreamerOS plugin for Claude Code, not a separate plugin. When the assistant says work is pushed, saved, added or tested, it reads the real git and file state and stops the turn once if the claim does not match. Code moved from `directory/dreameros-guard` to `install/claude-code/plugin`, with its 16 tests. The separate `dreameros-guard` marketplace entry is removed. Plugin version 0.5.4.
- Add `gate_dispatch_names_model.py`, a Claude Code PreToolUse gate for R7a. It denies an Agent or Task call that names no model, except a fork.
- Add `gate_main_thread_offload.py`, a Claude Code PreToolUse gate for R7. It denies the fourth mechanical Bash, Grep or Glob call per user turn in the main thread.
- README: say what this repository is for.
- Boot pack: raise the rule-count floor from 38 to 44, the number the build counts today.
- CI: run on changes to `.claude-plugin`, `directory`, `governance` and `shadow`.
- Add `scripts/public_surface_gate.py` and its baseline. It stops this public repository from showing more internal detail over time.
- Add CODEOWNERS, SECURITY, LICENSE and this changelog.
- Remove literal infrastructure IDs, an owner quote and a hard-coded machine path from three files.

## 2026-11-24

- canon(R19): ratify the surface-boundary clarification as written (#86)
- canon(R19): allow supercharged per HC ruling 2026-11-17 (#84)
- proposal: who DreamerOS serves, and Simple and Advanced depth for every member (#81)
- proposal: correct N2, N4 and N5 with the readings taken after the first version (#83)
- proposal: boot canon newness, six items from the 2026-11-24 readings (#82)

## 2026-11-25

- ci: rebuild carriers in CI after a failure, then fix main (#85)

## 2026-11-20

- bootpack: regenerate outputs after PR 78 (#80)
- R29: remove quote blocks that stop the build, require the exact value HC enters (#78)
- image-critique skill points to DreamerOS Media instead of calling vendors (#79)
- R29 rule 7: every HC ACTION ships with live-checked step-by-step instructions (#77)
- R29: name the HC action for every environment variable (#76)
- PROPOSED: R19 clarification - the boundary is the surface, not the word (unratified) (#74)
- R1m: the agent counts as one source at most (HC standing order 2026-11-20) (#73)

## 2026-11-18

- feat(bootpack): carry full source intake and account boundaries (#72)

## 2026-11-17

- feat(bootpack): R1m takes the reading before the sentence and states its scope (v2.6.2) (#71)

## 2026-11-15

- feat(bootpack): fail the build on a quote-only paragraph in the public source (#70)

## 2026-11-14

- feat(directory): add dreameros-memory, a small plugin for the Claude directory (#68)

## 2026-11-10

- docs(claude): tell users that third-party marketplaces do not auto-update by default (#67)

## 2026-11-09

- fix(privacy): remove the last HC-private quote from the phase-boundary hook (#66)
- chore(privacy): remove HC-private quotes from the public plugin and add a scan (#65)

## 2026-11-07

- fix(claude): drop internal Kimi wording from the public skill, v0.5.3 (#64)
- fix(claude): clean install and update path for Claude Code, v0.5.2 (#63)

## 2026-09-16

- ci: run Cursor installer tests in their own gated job (#62)
- fix: policy lock left files with no access entries (#61)
- fix: lock the managed policy directory to SYSTEM and Administrators (#60)
- feat: Claude Code policy layer (managed settings + settings validator) (#59)
- feat: adversarial research skill (never accept the first answer) (#58)

## 2026-09-14

- feat: install the per-message DreamerOS check with the Claude Code installer (#57)
- fix: dedupe native Claude hook registrations (#56)
- feat: distribute native DreamerOS global flow (#55)

## 2026-09-13

- Add Gateway Lockstep evidence verifier (#54)
- Add the Life of an Intent plugin adapter (#53)
- Add the marketplace catalog so the plugin installs by name (#52)

## 2026-09-12

- Add the Claude Code plugin manifest so the plugin loads with --plugin-dir (#51)

## 2026-09-11

- Carry the estate drift gate so it travels (#50)
- Add source-first model routing skill (#46)
- fix(boot): sync agent plugin discovery skill (#45)
- Add the session intent audit skill, with its extractor (#49)
- Carry the first-principles skill in the plugin so it travels (#48)
- fix(boot): carry R1n into the published boot skill (#47)
- fix(boot): regenerate R1n carriers from merged source (#44)
- Boot canon R1n: open the primary source the operator named
- canon: v2.6.0 offload-in-hydrate, checked against local offload always (#43)
- canon: R28 read every venue in full before and after each change (v2.5.0) (#42)
- fix(claude): render verified Git Bash hook launchers (#40)
- chore: add self-host DreamerOS project carrier (#39)
- fix: dedupe Claude lifecycle hooks safely (#38)
- fix(codex): map client boot to chatgpt engine (#37)
- Ship DreamerOS v7.3 client hydration parity (#36)

## 2026-09-04

- bootpack: -VerifyInstalled covers the registered Cursor plugin rule (#35)
- fix: install boot canon into the Cursor rule Cursor actually loads (#34)
- canon: R7a reworded to the best model for the job, cost in mind, accuracy never traded (#33)
- canon: R7a, the cheapest model that keeps accuracy, power and intent (#32)

## 2026-09-02

- canon v2.4.0 - HC approval: session handoff read at boot and write at close (#28)
- skills: remove two tracked SKILL.md installer backups (#30)
- PRESERVATION: Diamond readiness gate shadow files from an untracked worktree (#27)
- ci: fix 8.3 short-path handling so the Cursor test suites run green on windows-latest (#29)

## 2026-09-01

- docs(diamond): publish ratified decision ledger for review (#23)
- canon: land the live boot canon v2.3.0 source, v1.0.0 to v2.3.0 (#26)

## 2026-08-26

- codex queue - do not merge: add Windows candidate install lifecycle check (#24)
- feat(easy-button): v0 Windows customer installer - probe, provision, register (#22)

## 2026-08-25

- Add completeness gate to the boot canon build (#21)
- Stop-hook family reads the transcript tail, not the whole file
- Add gate_done_proof.py to the durable plugin payload
- R25: name gate_done_proof.py as its runtime hook
- Add R25 boot canon: prove every claim against the Definition of Done
- Add R24 boot canon to plugin boot skill

## 2026-08-24

- canon: merge boot source to one complete R1-R24, collapse the split that kept R24 out of runtime

## 2026-08-23

- feat(desktop): add cross-platform conductor runtime (#20)

## 2026-08-22

- canon: R23, every claim gets checked, R8 gets named instruments (#19)
- Sync boot canon: carry R20-R22 into every vendor format (#18)

## 2026-08-21

- feat(boot): R20 act on the first ask, R21 intent fidelity is a hook (#17)

## 2026-08-20

- feat(boot): R19, write for the scared newbie and the data engineer at once (#16)
- feat(boot): R18, offload by default and never at the cost of accuracy (#15)
- feat(boot): the Codex engine-switch hook installs itself at boot (#14)
- feat(codex): the engine names itself when it changes, on Codex too (#13)
- chore(bootpack): regenerate vendor outputs so they carry R17 (#12)
- feat(boot): the engine names itself when it changes, on every vendor (#11)

## 2026-08-19

- fix(desktop): align heartbeat with gateway contract (#9)
- fix(bootstrap): normalize text hashes across platforms (#8)
- feat(desktop): add secure agent runtime foundation (#7)
- feat(bootstrap): add shared vendor boot pool (#6)

## 2026-08-14

- Promote six portable skills into the installer payload (#5)
- Correct payload counts in the installer README (#4)

## 2026-08-13

- Merge branch 'main' of https://github.com/gbude-sudo/dreameros-agent-plugin
- Merge pull request #3 from gbude-sudo/hooks/register-claim-verification-gate
- Merge hooks/register-claim-verification-gate into main
- Register gate-claim-verification.sh in the Stop hooks
- Merge agents/model-tiered-offload into main
- Add model-tiered offload layer: five micro agents, contract-differ, dispatch skill
- Merge pull request #2 from gbude-sudo/skills/five-lessons-2026-08-13
- skills: add five skills from the 2026-08-13 lessons
- merge: skills, README, and installer defect fixes
- feat(install): add skills, README, and the nine requirement table
- merge: DreamerOS global Claude Code environment installer
- feat(install): DreamerOS global Claude Code environment installer

## 2026-08-06

- feat: DreamerOS Agent Plugin v0.1.0 (Agent Plugins spec 1.0.0)
