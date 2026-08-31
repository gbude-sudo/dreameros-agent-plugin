# Cursor Native Install

This layer turns the vendor-neutral DreamerOS Agent Plugin into a native Cursor
plugin without copying credentials or replacing existing user configuration.
The source repository keeps its portable root `plugin.json` and `mcp.json` for
other Agent Plugin clients. The Cursor installer deliberately excludes those
two root files so `.cursor-plugin/plugin.json` is the only active manifest in
Cursor. On update, the installer backs up an older dual-manifest install. It
moves both root files into that backup before validation.

The boot pack is the single source for installed boot files. The live MCP
session package supplies current runtime context. The boot builder includes the
full rule in `cursor/rules/` so the native plugin does not depend on separate
user-level rule discovery under `~/.cursor/rules`. The manifest exposes both
`dreameros-boot-canon` and
`dreameros-runtime` from that directory. The user-level file is a thin
fail-closed pointer to the installed plugin directory, not a second full copy.
This plugin provides:

- the generated DreamerOS boot rule and portable boot skill;
- a Cursor runtime rule for repository, authority, and handoff behavior;
- the four portable DreamerOS skills;
- four Cursor-native `dreameros-platform-*` subagents that explicitly inherit
  the selected Cursor model;
- boot, parity-check, Claude-review, status, verification, handoff, and
  release-check commands;
- fail-closed session-start and first-prompt boot hooks, before/after MCP
  boot-order gates, shell authority checks, and secret-file gates;
- the remote DreamerOS MCP URL with Cursor-owned OAuth. The plugin names the
  server `dreameros-platform`. This prevents the legacy project entry from
  shadowing the user plugin.

Install the boot pack from the repository root. Then install the Cursor plugin
from the same root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootpack\build-boot-pack.ps1 -Install
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootpack\build-boot-pack.ps1 -VerifyInstalled
powershell -NoProfile -ExecutionPolicy Bypass -File .\install\cursor\install.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\install\cursor\sync-project-rules.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\install\cursor\audit-project-boot-surfaces.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\install\cursor\plan-project-migration.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\install\cursor\render-project-migration-diffs.ps1 `
  -PlanPath "<absolute sealed plan.json path>" `
  -ExpectedPlanSha256 "<64-hex SHA-256 from an independent receipt>" `
  -RepositoryPath "<exact repository path>"
```

The hook manifest runs `python`. The installer stops if the machine provides
only `python3` or `py`. Cursor must run the executable that the installer tests.

The plugin installer refuses an existing target by default. `-Update` moves the
old DreamerOS plugin target to `~/.cursor/plugins/backups/`. It builds a fresh
exact target and rolls back on failure. The update removes plugin-owned files
that are absent from the new inventory. It does not delete unrelated paths.
Use `-VerifyOnly` to compare the installed inventory and bytes with the source.

Successful installs are recoverable. Uninstall moves the active plugin to the
managed backup directory and verifies its tree digest. It does not delete the
bytes. `-RestoreBackup` accepts one direct managed backup and refuses a
collision. It validates the backup before activation and verifies the digest
after the move. A failed restore returns the plugin to its original backup path:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install\cursor\install.ps1 `
  -Uninstall -ConfirmAction "UNINSTALL DREAMEROS CURSOR PLUGIN"

powershell -NoProfile -ExecutionPolicy Bypass -File .\install\cursor\install.ps1 `
  -RestoreBackup "<absolute managed backup path>" `
  -ConfirmAction "RESTORE DREAMEROS CURSOR PLUGIN BACKUP"
```

An explicitly restored legacy dual-manifest backup remains byte-faithful. The
output labels it as legacy. Run `-Update` afterward to return it to the current
exact native inventory.

The project-rule synchronizer defaults to a read-only estate parity check.
Repositories track these files, and some repositories declare the boot canon
global-only. The synchronizer classifies each managed rule as
`POINTER_ALIGNED`, `LEGACY_FULL_COPY`, or `UNKNOWN`. It reports Git ownership
separately. A measured `GLOBAL_ONLY` estate or `POINTER_ALIGNED FILE-CLEAN`
passes. Cursor always applies the generated pointer. The pointer fails closed
unless the audit proves the native full boot rule. It contains no duplicated
canon and cannot import another Cursor rule.

Apply mode is not part of routine bootstrap.
A per-repository instruction and ownership review must approve tracked writes.
The synchronizer then requires an exact `-ApprovedRepository` path. It also
requires `-ConfirmTrackedWrites "APPLY REVIEWED PROJECT RULE WRITES"`. It
fetches and requires current `main`. It requires a fully clean worktree,
including unrelated tracked and untracked paths. It refuses unknown or locally
edited targets. Before the first write, it creates a new backup-set directory
without `-Force`. The default set id combines a millisecond timestamp with a
random suffix. A pre-existing set id fails before any backup or project write.
Each backup subdirectory is keyed by the target path hash, and the manifest
records the original content hash for integrity. The backups are path-addressed,
not content-addressed. It rechecks repository and target ownership before each
write. It rolls back the transaction on failure. `-BackupSetId` exists for a
bounded collision test and must not be reused in routine operation.
If a `Governance/CANON_REGISTRY.json` or `governance/CANON_REGISTRY.json`
tracks the rule, Apply refuses the change. The repository's reviewed migration
must change the rule, hash, and role together.

Every successful Apply writes `restore-manifest.json` beside its path-keyed
backup files. Before commit, restore only from current `main` while the
generated pointer changes are the repository's only dirty paths:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\install\cursor\restore-project-rules.ps1 `
  -Manifest "<absolute restore-manifest.json path>" `
  -ConfirmRestore "RESTORE REVIEWED PROJECT RULE WRITES"
```

The restore keeps pre-restore pointer bytes for rollback, rechecks immediately
before every write, and returns the repository to its original clean content.
It refuses a committed migration, remote drift, unrelated local work, target
or backup drift, a duplicate target, and a reused or malformed manifest. After
a commit or PR, reverse through a reviewed Git change instead of this local
restore path.

The cross-vendor audit is also read-only. It checks each direct Git repository
under the DreamerOS and Codex estate roots across root `CLAUDE.md`, root
`AGENTS.md`, and the Cursor project rule. `GLOBAL_ONLY` and
`POINTER_ALIGNED FILE-CLEAN` are non-conflicting states. `LEGACY_FULL_COPY`,
`POINTER_DRIFT`, `UNKNOWN`, or a dirty aligned pointer require reviewed
per-repository migration. It also reports historical full-copy generators,
separate embedded Definition-of-Done/R1-R3 blocks, and standalone Cursor rule
excerpts. It reports these items so reviewers can see the redundancy. The audit
checks registered project Claude SessionStart hooks against the generated thin
hook. It reports stale order, hardcoded server ids, drift, missing files, and
unregistered hook files separately. The audit merges project and
`.claude/settings.local.json` registrations. It detects disabled hooks and
different-basename hydration scripts. It verifies the user-scope central
Claude hook. It flags Cursor MCP entries that could shadow the OAuth-owned
plugin server. It also inspects project, user, and local enterprise Cursor
`hooks.json` files. Hook configuration for a required native plugin event can
shadow it. Cloud-distributed team hooks remain a live Customize check.
Server-managed Claude hook policy remains a live
`/hooks` verification item because it can arrive from Anthropic, Windows
policy, or system managed settings outside repository scope.

The project migration planner does not fetch or write project files. It runs
Git reads with `GIT_OPTIONAL_LOCKS=0`. It runs the cross-vendor audit,
reconciles every parsed category against the audit summary, then emits one plan
per physical Git checkout plus user/global findings. Each plan carries the local
tracking-ref state, Git status counts, registry constraints, generated source
path and hash, exact target path, and the Human Conductor gate. JSON is the
default. The Markdown form includes the same per-action source hash, held or
blocked status, authorization gate, fresh-fetch gate, and notes. Every requested
estate root must exist or the planner stops before auditing. The audit supplies
one machine-readable PASS or FINDINGS marker; a missing or contradictory marker
blocks planning instead of converting an operational error into a finding.
Reparse-point child directories are never traversed; each is reported only by
digest as a blocked human scope-review item. Use
`-Format Markdown` for an operator-readable plan. Use
`-AuditInputPath` only to replay a preserved audit output; every target path
must still stay inside an allowed estate or user scope. The audit inspects MCP
header structure. Neither layer prints, copies, or persists header values. The
planner never applies, commits, pushes, merges, deploys, or changes production.

The migration-diff renderer is also read-only. It accepts only schema version 1
planner JSON plus its SHA-256 from an independent receipt. It rejects duplicate
JSON keys, unknown fields, source-hash drift, reparse traversal, stale Git
snapshots, dirty or blocked repositories, and ambiguous generated-region
boundaries. It also rejects a plan more than five minutes after its UTC
generation time. It revalidates the current target classification before it emits an
in-memory review diff. Only these deterministic project actions can produce
content:

- migrate the clean legacy Cursor boot rule to the generated project pointer;
- replace one verified Claude or Codex generated boot region with the pointer;
- replace the legacy generator with its generated fail-closed stub;
- replace one named Cursor adapter with its generated source; and
- replace one registered stale project Claude hook with the generated thin hook.

JSON is the default review format. It keeps every rendered, held, blocked, and
credential-safe row together. The renderer reports a project MCP Authorization
action only as `PRESENT -> ABSENT`. It never reads or serializes the value.
Every preview remains `HELD`, still requires a fresh fetch and separate Human
Conductor authorization, and is not apply-ready. The renderer creates no backup
and exercises none of the synchronizer's write or restore transaction gates.

Use `-ActionId <16-hex id>` to narrow review to an exact action. The renderer
still returns the complete JSON envelope. It does not provide a standalone
patch mode because that would separate the diff from its authorization, fetch,
preflight, and held-back fields.

Coordinators can use `-PlanFromStandardInput` instead of `-PlanPath`. They must
pass the SHA-256 of the exact UTF-8 JSON bytes through `-ExpectedPlanSha256`.
The reader accepts one UTF-8 transport BOM and excludes it from that content
hash. It rejects UTF-16. This path supports a fresh audit-to-review handoff
without creating or overwriting a plan file.

Run the renderer regression suite in both supported PowerShell engines:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\install\cursor\tests\render-project-migration-diffs.tests.ps1
pwsh -NoProfile -File `
  .\install\cursor\tests\render-project-migration-diffs.tests.ps1
```

The native plugin registers eight hook events. `sessionStart` is the normal
boot-state initializer. Cursor can lazy-load a local plugin after a new chat
already exists, so `beforeSubmitPrompt` creates the same step-zero gate only
when that chat has no state. It never resets existing hydration. The prompt
hook cannot inject context; the two always-applied rules carry the written
boot contract. `afterMCPExecution` is the documented MCP-result event. Cursor
3.17.21 emits `postToolUse` for the same result on Windows. The plugin registers
both result events, filters `postToolUse` to `MCP:.*`, and advances boot state
only after the pending DreamerOS tool returns a successful result. Every hook
has a ten-second fail-closed ceiling. Validation runs an eight-process
state-and-signature burst plus the measured concurrent read/result shape.
The two parity-health Task launches have an additional transcript gate. Cursor
must first emit a complete core `CURSOR_PARITY` block in a standalone assistant
message. A block hidden inside a Task prompt does not count, and the native
`subagentStart` hook denies that out-of-order launch.
The core-block response then runs one harmless
`Write-Output "DREAMEROS_PARITY_CORE_BLOCK_EMITTED"` marker named
`PARITY PHASE BRIDGE`. The shell hook stores that marker on the parent session.
Its result opens the next agent step, so both background reviewers can launch
without asking the operator for a second prompt or waiting for transcript flush.

The boot builder also emits exact thin replacements for the tracked
`answer-from-measurement.mdc`, `canon-equals-live.mdc`,
`dreameros-cold-start.mdc`, and `dreameros-first.mdc` paths, a Claude
`dreameros-session-start.sh`, and a fail-closed historical-generator stub. The
audit accepts them only by generated semantic hash as `ADAPTER_ALIGNED`,
`BOOT_HOOK_ALIGNED`, or `SUPERSEDED_GENERATOR`. The audit does not trust a
marker alone.

After install, run `Developer: Reload Window` or restart Cursor. In Customize,
verify the local `dreameros-platform` plugin and its Rules, Skills, Subagents,
Commands, and Hooks. Verify the separate `dreameros-platform` MCP entry. Cursor
authentication remains a human step: the plugin contains no bearer token, and
no agent should copy one from another client. Complete the DreamerOS OAuth
prompt in Cursor itself.

## Check parity from Cursor

1. Open Cursor **Customize**. Search `dreameros`. When `dreameros-platform`
   says `Needs authentication`, authenticate that MCP.
2. Use Cursor's `New Agent` command to start a new Agent conversation. On the
   measured Cursor 3.17.21 Windows install, press `Ctrl+Shift+L`. If the shortcut
   differs, use the visible `New Agent` command. Do not use the top `+` side-chat
   button for boot proof. Verify either a fresh `sessionStart=context` signature
   or a same-chat `beforeSubmitPrompt=bootstrap` signature. The latter is the
   measured cold-load fallback. Then invoke `/dreameros-parity-check`. See Cursor's
   [hook reference](https://cursor.com/docs/hooks) and
   [side-chat notes](https://cursor.com/changelog/side-chat).
3. Accept `overall=FULL` only for `GLOBAL_ONLY` or
   `POINTER_ALIGNED FILE-CLEAN` project rules. The same run must prove the
   installed payload, both native rules, skills, subagents, and all seven
   commands. It must prove live hook decisions, the MCP tool list, hydration,
   Git state, and required deployment evidence. Use the repository deployment
   guide to define that evidence. The run must find no adapter that the
   cross-vendor audit reports as stale. It must find no registered project
   Claude SessionStart hook.
4. Invoke `/dreameros-claude-review` to build the independent-review packet and
   preflight Claude Code. It must stop before sending until HC types the exact
   authorization `CONFIRM CLAUDE REVIEW SEND`.

The Claude preflight resolves the newest supported executable even when
`claude` is absent from `PATH`. It never starts authentication itself. When
Claude Code is logged out, it validates current help and gives HC the exact
`auth login --claudeai` command. When the header-free DreamerOS MCP reports
`Needs authentication`, it gives HC the exact `mcp login dreameros` command.
HC completes both browser flows personally. The preflight then requires
`loggedIn=true`, DreamerOS `Connected`, and an effective `/hooks` reading before
the independent review can leave `HELD`.

The first command is the Cursor-side instrument. The second prevents Cursor's
own verdict from serving as its independent check. A Claude review pass proves
the packet and claims it examined; it does not turn an unverified deployment
into a verified one.

The parity MCP row distinguishes the active OAuth plugin from legacy project
configuration. `CONNECTED_WITH_LEGACY_PROJECT_AUTH` means the native plugin and
required tools worked in the measured chat. One or more repository MCP files
still carry a separate DreamerOS Authorization header. That state is not full
parity. It requires reviewed per-repository removal. Do not copy the old header
into the plugin.

Local user hooks and Claude-compatible imports remain separate layers. This
plugin does not delete or overwrite them. The native subagent names do not
overlap the compatible Claude and Codex role names. A project-level vendor
model pin or legacy tool id cannot replace the parity-check role.
