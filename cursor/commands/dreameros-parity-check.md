---
name: dreameros-parity-check
description: Prove whether this Cursor session is fully plugged into DreamerOS across components, hooks, MCP, hydration, receipts, Git, and deployment evidence.
---

# Cursor to DreamerOS parity check

<!-- DREAMEROS-BOOT-PRECONDITION v1.0.0 -->
This command proves its own boot. Before any non-boot DreamerOS call, obtain
returned identifiers from `dreameros_session_package`, then
`dreameros_context`, then `dreameros_state`; use those identifiers for the
remaining recall, receipt, and component checks.

Run this as an audit. Do not branch, commit, push, merge, deploy, publish,
change credentials, or approve a paid action.

After a reload, first open Customize and wait until the local DreamerOS plugin
and its eight hooks are discoverable. Then start a true new composer
conversation with the `New Agent` command. On the measured Cursor 3.17.21
Windows install, its shortcut is `Ctrl+Shift+L`. If the shortcut differs, use
the visible `New Agent` command. Do not use the top `+` side-chat button for
this proof. A side chat can retain the parent context and does not prove that a
new boot state was initialized. Require either a fresh `sessionStart=context`
signature or a same-chat `beforeSubmitPrompt=bootstrap` signature. The prompt
fallback covers Cursor lazy-loading the plugin after chat creation and must not
reset an existing boot state.

Record the UTC start time, then verify each row with current evidence:

1. Installed payload: run `bootpack/build-boot-pack.ps1 -VerifyInstalled`, then
   `install/cursor/install.ps1 -VerifyOnly` from the `dreameros-agent-plugin`
   source checkout. Require exact installed Claude and Codex global blocks,
   their boot skills, the Cursor global plugin pointer, shared evidence, the
   Claude SessionStart adapter, the Cursor plugin byte-verification line, and a
   passing native hook case count at or above the locked floor.
2. Project rules: run `install/cursor/sync-project-rules.ps1` without `-Apply`.
   Accept either `VERIFIED GLOBAL_ONLY` for a measured Git estate with no
   per-repository boot rule, or require every discovered
   `.cursor/rules/dreameros-boot-canon.mdc` under the DreamerOS and Codex estate
   roots to be `POINTER_ALIGNED` with the generated fail-closed project
   pointer. `LEGACY_FULL_COPY` means a duplicated canon can override the native
   rule; `UNKNOWN` means the file is customized, truncated, or otherwise unsafe
   to migrate. Either state prevents `FULL`. Never run `-Apply` from this audit.
   `POINTER_ALIGNED DIRTY` is not durable parity and also prevents `FULL`.
3. Cross-vendor project surfaces: run
   `install/cursor/audit-project-boot-surfaces.ps1`. Require every Claude,
   Codex, and Cursor row to be `GLOBAL_ONLY FILE-CLEAN` or
   `POINTER_ALIGNED FILE-CLEAN`. Any full copy, drifted pointer, unknown block,
   dirty pointer, legacy generator, stale or drifted named adapter, duplicated
   embedded/rule excerpt, or registered Claude session-start hook that is not
   `BOOT_HOOK_ALIGNED FILE-CLEAN` prevents `FULL`. The local audit reports
   server-managed Claude hook policy as `UNVERIFIED_LIVE`; `FULL` additionally
   requires an authenticated Claude Code `/hooks` reading proving the central
   SessionStart adapter is effective and not blocked by `allowManagedHooksOnly`
   or `disableAllHooks`. Any critical project, user, or enterprise Cursor hook
   config is a potential higher-priority shadow and prevents `FULL`; the
   cloud-distributed team-hook policy remains `UNVERIFIED_LIVE` until Cursor
   Customize shows the effective hook list.
4. Customize discovery: with the search `dreameros`, require two DreamerOS
   rules, one local plugin, one `dreameros-platform` MCP, the four plugin
   skills, the four native `dreameros-platform-*` subagents, seven commands,
   and eight native plugin hook events. Total Skills, Subagents, and Hooks can
   be higher because Cursor also imports compatible global and Claude assets.
5. Component execution: in the true new Agent chat, require the applied-context
   trace to name both `dreameros-boot-canon` and `dreameros-runtime`; invoke the
   `dreameros-boot` skill. Confirm that
   `dreameros-platform-canon-citer` and
   `dreameros-platform-governance-node` are discovered from the native plugin,
   but do not invoke a subagent before the first result block is visible. The
   plugin roles explicitly inherit the parent Cursor model so same-named
   Claude-compatible project agents cannot redirect the check to a vendor pin.
   Set `subagents=DISCOVERED` in that first block. Discovery without an
   execution trace is not `INVOKED` and prevents `overall=FULL`.
6. Hook execution: read the hook signature written by this chat's
   `sessionStart=context` or `beforeSubmitPrompt=bootstrap` event and require a
   non-`unavailable` and non-`conflict` `session_fingerprint`. If both exist,
   require the same fingerprint and prove that the prompt fallback did not
   reset existing hydration. Run
   `git status --short --branch` as the safe allow
   control. Use `Write-Output "rm"` as the harmless destructive deny sentinel
   and `Write-Output "git push"` as the harmless authority deny sentinel. The
   strings are evidence inputs only. Require both sentinels to be denied and
   every resulting signature to carry that same
   session fingerprint; a recent signature from another chat does not count.
   Record the generation fingerprint when Cursor supplies one, but never the
   raw session or generation id. If either sentinel executes, or any required
   fingerprint is unavailable or mismatched, mark hooks `BLOCKED`.
7. MCP: require `dreameros-platform` to show connected, not `Authenticate` or
   `needsAuth`. Require the active filesystem/source identity to be the local
   plugin scope `plugin-dreameros-dreameros-platform` (or Cursor's equivalent
   source id for that installed plugin), not a project or user entry with the
   same name. Its nonempty tool list must contain session package, context,
   state, recall, remember, and `dreameros_memory_full` capabilities. If those
   live checks pass but the cross-vendor audit finds a differently named legacy
   project DreamerOS entry with an Authorization header, report
   `CONNECTED_WITH_LEGACY_PROJECT_AUTH`; that state prevents `FULL` but does not
   mislabel the active OAuth plugin as disconnected. A project or user entry
   named `dreameros-platform`, an active source outside the plugin, a missing
   required tool, or an OAuth prompt is `BLOCKED`. A matching URL and tool list
   alone are not OAuth proof.
8. Hydration: call the DreamerOS session package for the active model family,
   then context, state, and a scoped recall, in that order. Record returned
   package/version identifiers without recording credentials or private data.
9. Receipt round trip: only when the invocation includes `receipt=confirm`,
   remember a contextual parity note with a unique nonce in both its text and
   tags. Capture the returned memory id. Run scoped recall to prove the nonce is
   discoverable, then call `dreameros_memory_full` with the exact nonce tag and
   a limit of 10. Require exactly one record. Its UUID must match the captured
   id; its content must equal the submitted note; its memory type must be
   `contextual`; its tags must include every submitted tag; and its creation time
   must be at or after the audit start. Recall text alone is not UUID proof.
   Otherwise report `receipt=HELD`.
10. Repository: read root and nested instructions and report the current repo,
   branch, HEAD, origin/main, upstream, dirty paths, and three-dot changed-file
   list. Do not mutate Git.
11. Deployment: read the repository deployment guide and use only its declared
   read-only destination probe. A source file, merge, or green test is not a
   deployment or customer-runtime signature. If the current task has no
   deployment target, report `UNVERIFIED`; that run cannot return `FULL`.

Return this block plus short evidence citations:

```text
CURSOR_PARITY v1
payload=PROVEN|FAILED
project_rules=GLOBAL_ONLY|POINTER_ALIGNED|LEGACY_FULL_COPY|UNKNOWN|BLOCKED
project_surfaces=ALIGNED|LEGACY_FULL_COPY|POINTER_DRIFT|UNKNOWN|DUPLICATE_EXCERPT|LEGACY_GENERATOR|STALE_ADAPTER|STALE_BOOT_HOOK|BLOCKED
rules=ACTIVE|DISCOVERED|FAILED
skills=INVOKED|DISCOVERED|FAILED
subagents=INVOKED|DISCOVERED|FAILED
commands=INVOKED|DISCOVERED|FAILED
hooks=PROVEN|BLOCKED
mcp=CONNECTED|CONNECTED_WITH_LEGACY_PROJECT_AUTH|BLOCKED
hydration=PROVEN|BLOCKED
receipt=PROVEN|HELD|BLOCKED
git=PROVEN|BLOCKED
deployment=DEPLOYED|REACHABLE|UNVERIFIED|BLOCKED
overall=FULL|PARTIAL|BLOCKED
```

<!-- PARITY-CORE-BLOCK-BARRIER v1.0.0 -->
Emit the complete block as a standalone assistant text message before any
optional prose or Task call. End that assistant message after the block. The
block is mandatory even when a tool, receipt, or deployment probe fails, stops,
times out, or is held. Classify unfinished core rows as `FAILED`, `BLOCKED`, or
`UNVERIFIED` as the row permits. Do not promise a wall-clock deadline because
Cursor plugin loading, operator-approved audits, and remote MCP calls have
variable runtime.

Do not announce, prepare, embed, or launch either parity reviewer until the
standalone core block is visible. The native `subagentStart` hook reads the
parent transcript and denies these exact parity-health tasks unless an earlier
standalone assistant text contains `CURSOR_PARITY v1`, `payload=`,
`subagents=DISCOVERED`, and `overall=`. Putting a proposed block inside a Task
prompt does not satisfy the barrier. An optional reviewer must never suppress
the block.

After the block text, in that same assistant response, run exactly this harmless
shell command: `Write-Output "DREAMEROS_PARITY_CORE_BLOCK_EMITTED"`. Label it
`PARITY PHASE BRIDGE`. Do not include a Task call in that response. The
`beforeShellExecution` hook stores the marker on this parent session and the
shell result re-enters the agent loop, so the next assistant step can perform
the background phase without a second user prompt. A marker from another
session does not count.

<!-- AFTER-BLOCK BACKGROUND SUBAGENT INVOCATION v1.4.0 -->
Only in the assistant step after the `PARITY PHASE BRIDGE` result returns, use
the hook-ledger path verified in row 6. Run one shell tool call only. Label it
`PARITY SUBAGENT PRELAUNCH BOUNDARY`. In that call, capture the ledger byte
length and the SHA-256 of exactly that prefix. Then record `boundary_utc` at
whole-second UTC precision. Return one JSON object with exact keys
`boundary_utc`, `byte_length`, and `prefix_sha256`. If the ledger is missing,
unreadable, or invalid, do not launch either Task. Emit the second block with
`subagents=FAILED`. Do not co-schedule a Task with this boundary command.

Run exactly this PowerShell command. It resolves the user profile without an
environment-variable read, so the DreamerOS hook can classify it as a bounded
read-only command that needs confirmation instead of a credential-path denial:

```powershell
$home = [Environment]::GetFolderPath('UserProfile'); $ledger = Join-Path $home '.cursor\dreameros\hook-signatures.jsonl'; if (-not (Test-Path -LiteralPath $ledger -PathType Leaf)) { throw "ledger missing: $ledger" }; $bytes = [IO.File]::ReadAllBytes($ledger); $sha = [Security.Cryptography.SHA256]::Create(); try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }; [pscustomobject]@{ boundary_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); byte_length = $bytes.Length; prefix_sha256 = $hash } | ConvertTo-Json -Compress
```

Do not rewrite that command with `$env:USERPROFILE`. Generic shell reads through
`$env:` remain credential-bearing and fail closed by design.

Only after that shell result returns, in the next assistant step, launch these
two independent Task calls in parallel:

1. `dreameros-platform-canon-citer`
   - `run_in_background: true`
   - Task: `Run the role's required read-only DreamerOS boot. Cite the claim
     that cursor/mcp.json names dreameros-platform and has no headers. Use no
     writes, web browsing, paid verification, or model routing. Return one
     concise CITED, SPECULATIVE, or UNVERIFIED verdict with the evidence path.`
2. `dreameros-platform-governance-node`
   - `run_in_background: true`
   - Task: `Review the first CURSOR_PARITY block only. Make no changes and call
     no external tools. Return CLEAR, REVISE, or BLOCK with one sentence.`

Do not delegate parity drafting to either subagent. Do not use foreground Task
calls. Do not wait for, poll, fetch, or read either role's completion or verdict
before emitting the second block. This check classifies native role invocation,
not the quality or completion of the background role results.

Require the next parent transcript record to contain exactly two `Task` tool-use
objects. Each must carry its named `subagent_type`, its exact task description,
and a true background flag. This record proves the two launch requests. The
Cursor parent JSONL does not preserve an immediate Task-result object before the
ledger read, so do not require, infer, or invent a returned handle or UUID.

Then perform one immediate read of the hook signature ledger, with no sleep or
retry. Before reading the appended tail, require the current length to be at
least `byte_length`. Recompute SHA-256 over the first `byte_length` bytes and
require it to equal `prefix_sha256`. Read only bytes appended after that prefix.
Require the first two complete JSON records in the appended tail to be
`subagentStart` entries. Both entries must have `permission=allow`, the current
parent `session_fingerprint`, and distinct, non-`unavailable`
`subagent_fingerprint` values. Parse and record each actual `timestamp` field as
metadata, but use the verified byte boundary for ordering. Do not accept a
missing timestamp, an entry from before the captured byte offset, or a
same-session fallback from elsewhere in the ledger. If the ledger prefix,
length, timestamp, or JSON is invalid, classify the check as failed.

If both exact Task request records and both hook signatures are present, record
the two role names and hook fingerprints. Emit a second complete
`CURSOR_PARITY v1` block with `subagents=INVOKED` and a recalculated `overall`.
If either Task request is absent or malformed, or if either matching hook
signature is absent on that one immediate read, emit the second complete block
with `subagents=FAILED`. Do not retry a failed launch, wait for a result, or
cancel a healthy background sibling. Prose alone is not sufficient. UUIDs that
arrive in later completion callbacks are optional references, not launch proof.
If that is the only failed row, set `overall=PARTIAL`. Use `overall=BLOCKED`
only when another required path is blocked. Never erase or replace the first
block. Background role output may arrive later as optional evidence, but it
must not delay or rewrite either parity block.

`overall=FULL` requires either a measured `GLOBAL_ONLY` estate or
`POINTER_ALIGNED FILE-CLEAN` Cursor project rules,
`ALIGNED` cross-vendor project surfaces, `ACTIVE` rules, `INVOKED`
skills/subagents/commands, `PROVEN` hooks, hydration, receipt, and Git, a
`CONNECTED` MCP with no legacy project authorization entries, and the
appropriate destination proof in this run. The
deployment row must be `REACHABLE` and cite
both the deployment id and the destination status/body signature; `DEPLOYED`
alone remains `PARTIAL`. Therefore `receipt=HELD`, `UNVERIFIED`, or no
deployment target cannot return `FULL`. It is not a customer completion claim.
