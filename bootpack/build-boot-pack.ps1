# build-boot-pack.ps1
# Generates every vendor boot format from ONE source, then checksums them.
#
# WHY THIS EXISTS
#   The estate had three divergent skill sets with no overlap and no promotion
#   pipeline, so the installer shipped a stale subset by construction. A rule
#   written once and copied by hand drifts. This makes copying mechanical and
#   makes drift detectable.
#
#   MOATS_AND_METHOD_2026-08-15 names "build the skill promotion pipeline
#   before publishing anything" as the first step of Moat 3. This is that step.
#
# USAGE
#   .\build-boot-pack.ps1            build every output and write checksums
#   .\build-boot-pack.ps1 -Verify    fail if any output drifted from source
#   .\build-boot-pack.ps1 -Install   place the blocks into the five real files

[CmdletBinding()]
param(
    [switch]$Verify,
    [switch]$VerifyInstalled,
    [switch]$Install
)

$ErrorActionPreference = 'Stop'
$Root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Source = Join-Path $Root 'SOURCE-dreameros-boot-canon.md'
$QuoteEvidenceSource = Join-Path $Root 'evidence\HC_ATTRIBUTED_QUOTES_v1_0_0.md'
$Out    = Join-Path $Root 'out'

if (-not (Test-Path $Source)) { throw "source missing: $Source" }
if (-not (Test-Path $QuoteEvidenceSource)) { throw "quote evidence missing: $QuoteEvidenceSource" }
$Payload = Get-Content $Source -Raw
$QuoteEvidencePayload = Get-Content $QuoteEvidenceSource -Raw
$VersionMatch = [regex]::Match($Payload, '(?m)^# DreamerOS Boot Canon v([0-9]+\.[0-9]+\.[0-9]+)\s*$')
if (-not $VersionMatch.Success) { throw 'boot canon source has no semantic version heading.' }
$VersionNumber = $VersionMatch.Groups[1].Value
$Version = 'v' + $VersionNumber
$Marker  = 'DREAMEROS-BOOT-CANON'
$VerifyGenerated = $Verify -or $VerifyInstalled

function New-Dir([string]$p) { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
function Write-Utf8([string]$Path, [string]$Text) {
    New-Dir (Split-Path -Parent $Path)
    $Text = $Text -replace "`r`n", "`n"
    $Text = $Text -replace "`r", "`n"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}
function Get-Sha([string]$Path) {
    # Git may materialize the same text blob as LF or CRLF. Drift detection
    # compares semantic text bytes so a Windows checkout does not disagree
    # with CI about an otherwise identical generated artifact.
    $text = [System.IO.File]::ReadAllText($Path)
    $text = $text.Replace(([string][char]13 + [char]10), [string][char]10)
    $text = $text.Replace([string][char]13, [string][char]10)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLower()
    } finally {
        $sha.Dispose()
    }
}
function Get-TextSha([string]$Text) {
    $Text = $Text.Replace(([string][char]13 + [char]10), [string][char]10)
    $Text = $Text.Replace([string][char]13, [string][char]10)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLower()
    } finally {
        $sha.Dispose()
    }
}

# This is the check outside the generator/checksum loop. A generated set can
# be perfectly self-consistent while its source is stale. The reviewed floor
# pins the current source version, semantic hash, and structural canaries. On
# this desktop the separate DreamerOS checkout is also compared when present.
$SourceFloorFile = Join-Path $Root 'known-good-source-floor.json'
if (-not (Test-Path -LiteralPath $SourceFloorFile)) {
    throw "known-good source floor missing: $SourceFloorFile"
}
$SourceFloor = Get-Content -Raw -LiteralPath $SourceFloorFile | ConvertFrom-Json
if ([version]$VersionNumber -lt [version]$SourceFloor.minimum_version) {
    throw "boot canon source version $VersionNumber is below floor $($SourceFloor.minimum_version)."
}
$SourceSemanticSha = Get-Sha $Source
if ($SourceSemanticSha -ne [string]$SourceFloor.semantic_sha256) {
    throw "boot canon source hash differs from the reviewed floor. Reconcile the source, then update the floor separately under review."
}
foreach ($clause in @($SourceFloor.required_clauses)) {
    if (-not $Payload.Contains([string]$clause)) {
        throw "boot canon source is missing required clause: $clause"
    }
}

$ExternalFloorCandidates = @()
if ($env:DREAMEROS_BOOT_CANON_FLOOR) {
    $ExternalFloorCandidates += $env:DREAMEROS_BOOT_CANON_FLOOR
}
foreach ($candidate in ($ExternalFloorCandidates | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $candidate)) { continue }
    $external = (Resolve-Path -LiteralPath $candidate).Path
    if ($external -eq (Resolve-Path -LiteralPath $Source).Path) { continue }
    if ((Get-Sha $external) -ne $SourceSemanticSha) {
        throw "boot canon source differs from external current floor: $external"
    }
}

# --- ASCII and dash guard on the source itself -------------------------------
$bad = @()
foreach ($c in $Payload.ToCharArray()) {
    $o = [int]$c
    if ($o -eq 0x2014 -or $o -eq 0x2013) { $bad += 'dash' }
    if ($o -gt 127) { $bad += ("non-ascii U+{0:X4}" -f $o) }
}
if ($bad.Count -gt 0) {
    Write-Host ("SOURCE FAILS THE CANON GUARD: {0} violations" -f $bad.Count) -ForegroundColor Red
    $bad | Group-Object | ForEach-Object { Write-Host ("  {0} x{1}" -f $_.Name, $_.Count) -ForegroundColor Red }
    throw 'fix the source before generating. A generator that emits a canon violation is worse than no generator.'
}

# --- completeness gate ---------------------------------------------------------
# This runs BEFORE any target is written and BEFORE any checksum is computed.
# Without it: a truncated or empty source still builds cleanly, the checksums
# in CHECKSUMS.txt are computed fresh over that same truncated content, and
# -Verify passes forever after, because -Verify only compares output to the
# checksums this same build wrote. That closed loop cannot catch a bad
# source. This gate is the check outside the loop.
#
# Incident this exists to stop happening again: commit 7a4b699 dropped a
# whole rule (R24) from the merged source, and a human caught it, not the
# pipeline.
$MinPayloadChars = 5000
$PayloadLen = $Payload.Length
if ($PayloadLen -lt $MinPayloadChars) {
    Write-Host "COMPLETENESS GATE FAILED" -ForegroundColor Red
    Write-Host ("  source is {0} chars, the minimum is {1} chars." -f $PayloadLen, $MinPayloadChars) -ForegroundColor Red
    Write-Host ("  source file: {0}" -f $Source) -ForegroundColor Red
    Write-Host "  Refusing to write any output or compute any checksum." -ForegroundColor Red
    throw ("source payload too short: {0} chars, minimum {1}. Fix the source, do not rebuild over it." -f $PayloadLen, $MinPayloadChars)
}

$FloorFile = Join-Path $Root 'known-good-rule-count.txt'
if (-not (Test-Path $FloorFile)) {
    throw "known-good rule-count floor missing: $FloorFile. Create it before building (see bootpack/known-good-rule-count.txt)."
}
$RuleCountFloor = 0
$floorParsed = $false
foreach ($line in (Get-Content $FloorFile)) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    if ([int]::TryParse($t, [ref]$RuleCountFloor)) { $floorParsed = $true }
    break
}
if (-not $floorParsed) {
    throw "known-good-rule-count.txt has no parseable integer floor: $FloorFile"
}

# Count rules once, here, before anything is written. The manifest step
# below reuses this same count so the gate and the reported count can
# never disagree with each other.
$RuleMatches = New-Object System.Collections.Generic.List[object]
foreach ($m in [regex]::Matches($Payload, '(?m)^## (R\d+[a-z]?) - (.+)$')) { $RuleMatches.Add($m) }
foreach ($m in [regex]::Matches($Payload, '(?m)^### (R\d+[a-z]) - (.+)$')) { $RuleMatches.Add($m) }
$RuleCountNow = $RuleMatches.Count

if ($RuleCountNow -lt $RuleCountFloor) {
    Write-Host "COMPLETENESS GATE FAILED" -ForegroundColor Red
    Write-Host ("  current rule count : {0}" -f $RuleCountNow) -ForegroundColor Red
    Write-Host ("  known-good floor   : {0}" -f $RuleCountFloor) -ForegroundColor Red
    Write-Host ("  floor file         : {0}" -f $FloorFile) -ForegroundColor Red
    Write-Host ("  source file        : {0}" -f $Source) -ForegroundColor Red
    Write-Host "  A truncated or empty source builds cleanly by default and passes" -ForegroundColor Red
    Write-Host "  -Verify forever after, because -Verify only compares output to the" -ForegroundColor Red
    Write-Host "  checksums this same build wrote. Refusing to write any output or" -ForegroundColor Red
    Write-Host "  compute any checksum." -ForegroundColor Red
    Write-Host "  If this drop is real and deliberate, update the floor by hand in a" -ForegroundColor Yellow
    Write-Host "  separate, reviewed commit:" -ForegroundColor Yellow
    Write-Host ("    edit {0} and set the floor to {1} (or lower)." -f $FloorFile, $RuleCountNow) -ForegroundColor Yellow
    throw ("rule count dropped below the known-good floor: {0} < {1}. Not writing any output." -f $RuleCountNow, $RuleCountFloor)
}

# --- targets ------------------------------------------------------------------
$Targets = @()

$Targets += @{
    Path = Join-Path $Out 'claude\CLAUDE.md.block'
    Text = @"
<!-- BEGIN $Marker $Version - GENERATED, DO NOT EDIT. Source: SOURCE-dreameros-boot-canon.md -->
$Payload
<!-- END $Marker $Version -->
"@
}

$Targets += @{
    Path = Join-Path $Out 'codex\AGENTS.md.block'
    Text = @"
<!-- BEGIN $Marker $Version - GENERATED, DO NOT EDIT. Source: SOURCE-dreameros-boot-canon.md -->
$Payload
<!-- END $Marker $Version -->
"@
}

$CursorRuleTarget = @{
    Path = Join-Path $Out 'cursor\dreameros-boot-canon.mdc'
    Text = @"
---
description: DreamerOS Boot Canon. Measurement discipline, vocabulary, and the close check. Always applied.
alwaysApply: true
---

$Payload
"@
}
$Targets += $CursorRuleTarget
$CursorPluginRule = Join-Path (Split-Path -Parent $Root) 'cursor\rules\dreameros-boot-canon.mdc'

function Get-RegisteredCursorPluginRuleDest {
    # The global pointer above satisfies the fail-closed pointer contract, but
    # Cursor itself never reads that path for plugin content. It reads the
    # plugin rule at wherever Customize > Plugins > local actually registered
    # this plugin, which plugin.json alone can name. A path guessed here would
    # drift the moment the plugin is reinstalled elsewhere, so this walks
    # every local plugin's own plugin.json under the user's Cursor plugins
    # root and matches it by repository, never by a hardcoded install path.
    $dest = $null
    $localRoot = Join-Path $env:USERPROFILE '.cursor\plugins\local'
    if (Test-Path $localRoot) {
        $pluginManifestFiles = Get-ChildItem -Path $localRoot -Filter 'plugin.json' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\.cursor-plugin[\\/]plugin\.json$' }
        foreach ($pmFile in $pluginManifestFiles) {
            $pluginManifest = $null
            try { $pluginManifest = Get-Content -Raw -LiteralPath $pmFile.FullName | ConvertFrom-Json } catch { continue }
            if ($pluginManifest.repository -and
                ([string]$pluginManifest.repository) -match 'dreameros-agent-plugin(\.git)?/?$' -and
                $pluginManifest.rules) {
                $pluginRoot = Split-Path -Parent (Split-Path -Parent $pmFile.FullName)
                $rulesRel = ([string]$pluginManifest.rules) -replace '^\.[\\/]', '' -replace '/', '\'
                $dest = Join-Path (Join-Path $pluginRoot $rulesRel) 'dreameros-boot-canon.mdc'
                break
            }
        }
    }
    return $dest
}

$ProjectPointerVersion = 'v1.0.0'
$ProjectPointerBody = @"
<!-- DREAMEROS-BOOT-CANON: NOT DUPLICATED HERE -->
<!-- DREAMEROS-PROJECT-BOOT-POINTER $ProjectPointerVersion -->
## DreamerOS Boot Canon - loaded globally, not copied here

The full DreamerOS Boot Canon is generated from
gbude-sudo/dreameros-agent-plugin:bootpack/SOURCE-dreameros-boot-canon.md and delivered
through each engine's machine-wide native surface. This project file
intentionally contains no copy of the canon and cannot import another rule.

Before substantive DreamerOS work, verify the native surface for the active
engine:

1. Claude Code or Desktop: the current generated block is present once in
   ~/.claude/CLAUDE.md.
2. Codex: the current generated block is present once in ~/.codex/AGENTS.md.
3. Cursor: Customize shows the local Dreameros plugin, and its
   dreameros-boot-canon rule is set to Always and appears in the active rule
   trace for the fresh Agent chat.

If the active engine cannot prove its full native boot rule, report BLOCKED
and stop substantive work. Do not treat this pointer as a fallback canon.
Repository instructions add project scope after boot; they do not replace the
Human Conductor or the current generated boot rule.

To change a boot rule, edit the shared source and run
bootpack/build-boot-pack.ps1 -Install. Never paste the full canon into a
repository instruction or project rule. A second copy loads later, drifts, and
can override the current machine-wide rule.
<!-- END DREAMEROS-BOOT-CANON POINTER -->
"@

$Targets += @{
    Path = Join-Path $Out 'project\DREAMEROS_BOOT_CANON_POINTER.md.block'
    Text = $ProjectPointerBody
}

$Targets += @{
    Path = Join-Path $Out 'cursor\dreameros-project-pointer.mdc'
    Text = @"
---
description: DreamerOS project boot pointer. Requires the current native DreamerOS boot rule and contains no duplicated canon.
alwaysApply: true
---

$ProjectPointerBody
"@
}

$Targets += @{
    Path = Join-Path $Out 'cursor\dreameros-global-plugin-pointer.mdc'
    Text = @"
---
description: DreamerOS Cursor global pointer. Requires the native local Dreameros plugin and contains no duplicated canon.
alwaysApply: true
---

<!-- DREAMEROS-CURSOR-GLOBAL-PLUGIN-POINTER v1.0.0 -->
## DreamerOS Boot Canon - carried by the native Cursor plugin

The full DreamerOS Boot Canon exists exactly once for Cursor in the local
``Dreameros`` plugin rule named ``dreameros-boot-canon``. This user-level file is a
fail-closed pointer only; it does not copy or import the canon.

Before substantive DreamerOS work in Cursor, require all of these in the fresh
Agent chat:

1. Customize lists the local ``Dreameros`` plugin.
2. The plugin rule ``dreameros-boot-canon`` appears in the active rule trace.
3. The companion ``dreameros-runtime`` rule appears in the same trace.

If any item is not proven, report BLOCKED and stop substantive work. Do not use
this pointer as a fallback boot contract. Change the full rule only through
gbude-sudo/dreameros-agent-plugin:bootpack/SOURCE-dreameros-boot-canon.md and
the central generator.
"@
}

$Targets += @{
    Path = Join-Path $Out 'cursor\answer-from-measurement.adapter.mdc'
    Text = @"
---
description: DreamerOS state-measurement enforcement adapter. Requires current evidence before dynamic state claims.
alwaysApply: true
---

<!-- DREAMEROS-CURSOR-ENFORCEMENT-ADAPTER v1.0.0 kind=state-measurement -->
This project rule is an enforcement adapter, not a canon copy. The full boot
contract must come from the active native DreamerOS carrier.

Before stating status, count, health, deployment, liveness, cleanliness, or
completion:

1. Take a current reading from the system the claim names and identify the
   instrument.
2. If the reading cannot be taken, report UNKNOWN and name the missing
   instrument.
3. Before trusting an empty search, run the same sweep against a known positive
   control and require it to match.
4. If the full native DreamerOS boot rule cannot be proven active, report
   BLOCKED and stop substantive work.

Change this adapter only through the central DreamerOS agent-plugin generator.
"@
}

$Targets += @{
    Path = Join-Path $Out 'cursor\canon-equals-live.adapter.mdc'
    Text = @"
---
description: DreamerOS status-vocabulary enforcement adapter. Prevents larger completion words from replacing measured evidence.
alwaysApply: true
---

<!-- DREAMEROS-CURSOR-ENFORCEMENT-ADAPTER v1.0.0 kind=status-vocabulary -->
This project rule is an enforcement adapter, not a canon copy. The full boot
contract and its current status vocabulary must come from the active native
DreamerOS carrier.

Before a completion claim:

1. Measure the requested destination, not the command that attempted the work.
2. Use the smallest evidence rung supported by the reading, such as WRITTEN,
   MERGED, DEPLOYED, REACHABLE, PARTIAL, BLOCKED, or UNKNOWN.
3. Do not use a customer-completion word unless every condition in the current
   native boot contract was measured and the Human Conductor verified it.
4. If the full native DreamerOS boot rule cannot be proven active, report
   BLOCKED and stop substantive work.

Change this adapter only through the central DreamerOS agent-plugin generator.
"@
}

$Targets += @{
    Path = Join-Path $Out 'cursor\dreameros-cold-start.adapter.mdc'
    Text = @"
---
description: DreamerOS project coordination adapter. Adds repository scope after the native DreamerOS session boot.
alwaysApply: true
---

<!-- DREAMEROS-CURSOR-PROJECT-ADAPTER v1.0.0 kind=project-coordination -->
The native DreamerOS plugin owns session-package hydration and the current
boot contract. This project adapter does not repeat that sequence or copy
canon.

After the native boot is proven active:

1. Read the repository and nested instruction files that apply to the files in
   scope.
2. Measure the repository path, branch, HEAD, upstream, origin/main, worktree
   status, and active coordination claims before editing.
3. Keep one writer per overlapping file set and preserve unrelated work.
4. Treat branch creation, commit, push, merge, deployment, credentials, and
   production changes as separate approval gates defined by the Human
   Conductor and repository instructions.

If the native DreamerOS boot cannot be proven active, report BLOCKED for
DreamerOS hydration and continue only safe local work in STANDALONE mode.
Change this adapter only through the central DreamerOS agent-plugin generator.
"@
}

$Targets += @{
    Path = Join-Path $Out 'cursor\dreameros-first.adapter.mdc'
    Text = @"
---
description: DreamerOS project handoff adapter. Persists verified outcomes without duplicating session hydration.
alwaysApply: true
---

<!-- DREAMEROS-CURSOR-PROJECT-ADAPTER v1.0.0 kind=verified-handoff -->
The native DreamerOS plugin owns session-package hydration, context, state,
recall, and canon routing. This project adapter adds only the close boundary.

After substantive project work:

1. Re-read changed files, inspect the final diff, and run proportional checks.
2. Distinguish local, merged, deployed, reachable, customer-usable, blocked,
   and unverified evidence. Never promote one rung to another.
3. When DreamerOS memory is connected, store a concise handoff with repository,
   branch, changed files, checks, held-back scope, and the next action.
4. Never store credentials, token values, private keys, or environment values.
5. If a substrate write is required but unavailable, report it as BLOCKED and
   use the repository's dated local handoff path when its instructions require
   one.

Change this adapter only through the central DreamerOS agent-plugin generator.
"@
}

$Targets += @{
    Path = Join-Path $Out 'claude\dreameros-session-start.sh'
    Text = @'
#!/usr/bin/env bash
# DREAMEROS-CLAUDE-SESSION-START-ADAPTER v1.0.0
# Thin runtime adapter. The full boot canon remains in the native global file.
set -euo pipefail

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "DreamerOS session boot is mandatory before substantive work. Use the exact DreamerOS tool names exposed by this session; never hardcode an MCP server id. In order: (1) call dreameros_session_package for the active Claude engine and current project, (2) call dreameros_context, (3) call dreameros_state with action load, and (4) call a scoped dreameros_recall for the current topic. Read relevant canon only when the task requires it. Then read global, repository, and nested instructions; measure Git state; and check active coordination claims. If any required DreamerOS tool is unavailable, report BLOCKED for DreamerOS hydration and continue only safe local work in STANDALONE mode. Never expose or store credentials, token values, private keys, or environment values."
  }
}
JSON
'@
}

$Targets += @{
    Path = Join-Path $Out 'evidence\HC_ATTRIBUTED_QUOTES_v1_0_0.md'
    Text = $QuoteEvidencePayload
}

$Targets += @{
    Path = Join-Path $Out 'project\DREAMEROS_CENTRAL_BOOT_GENERATOR_POINTER.ps1.block'
    Text = @"
# DREAMEROS-CENTRAL-BOOT-GENERATOR-POINTER v1.0.0
# Historical generator path retained as a fail-closed pointer.
# The only active generator is:
# gbude-sudo/dreameros-agent-plugin:bootpack/build-boot-pack.ps1
throw 'This historical boot generator is superseded. Use the central DreamerOS agent-plugin generator. No files were written.'
"@
}

$Targets += @{
    Path = Join-Path $Out 'skill\dreameros-boot\SKILL.md'
    Text = @"
---
name: dreameros-boot
description: Load the DreamerOS Boot Canon. Use at the start of any substantive DreamerOS work, and whenever a claim about status, count, health, deployment, liveness or completion is about to be made. Carries the measurement discipline, the CANON equals RUNTIME vocabulary, the FIXED definition, and the boot and close checks.
---

$Payload
"@
}

$Targets += @{
    Path = Join-Path $Out 'paste\PASTE-INTO-ANY-LLM.txt'
    Text = @"
You are operating under the DreamerOS Boot Canon $Version. Follow it for the
whole of this conversation. It overrides your defaults where they conflict.
If you cannot follow a rule, say which one and why, rather than ignoring it.

$Payload

Acknowledge by naming, in one line each: the instrument you will use for a
state question, and the word you will use when something is merged but not
reachable. Then wait for the task.
"@
}

$manifest = [ordered]@{
    name        = 'dreameros-boot-canon'
    version     = $Version
    generated   = 'see CHECKSUMS.txt'
    source_file = 'SOURCE-dreameros-boot-canon.md'
    purpose     = 'Vendor-neutral boot canon. One source, generated into every engine format.'
    applies_to  = @('claude-code','claude-desktop','codex','cursor','chatgpt','gemini','grok','perplexity','byollm','mcp-client','agent-sdk')
    rules       = @()
}
foreach ($m in $RuleMatches) {
    $manifest.rules += [ordered]@{ id = $m.Groups[1].Value; title = $m.Groups[2].Value.Trim() }
}
$manifest.rule_count = $manifest.rules.Count
$manifest.project_pointer = [ordered]@{
    version = $ProjectPointerVersion
    purpose = 'Fail-closed project pointer. The full canon remains machine-wide and single-source.'
    cursor_path = 'cursor/dreameros-project-pointer.mdc'
    cursor_global_plugin_pointer = 'cursor/dreameros-global-plugin-pointer.mdc'
    embedded_path = 'project/DREAMEROS_BOOT_CANON_POINTER.md.block'
}
$manifest.project_adapters = [ordered]@{
    version = 'v1.0.0'
    measurement = 'cursor/answer-from-measurement.adapter.mdc'
    status_vocabulary = 'cursor/canon-equals-live.adapter.mdc'
    project_coordination = 'cursor/dreameros-cold-start.adapter.mdc'
    verified_handoff = 'cursor/dreameros-first.adapter.mdc'
    claude_session_start = 'claude/dreameros-session-start.sh'
    historical_generator_pointer = 'project/DREAMEROS_CENTRAL_BOOT_GENERATOR_POINTER.ps1.block'
}
$manifest.evidence = [ordered]@{
    hc_attributed_quotes = 'evidence/HC_ATTRIBUTED_QUOTES_v1_0_0.md'
    unique_quote_count = 16
    purpose = 'Portable evidence only. Not a second rule surface.'
}
$Targets += @{
    Path = Join-Path $Out 'manifest\dreameros-boot-canon.json'
    Text = ($manifest | ConvertTo-Json -Depth 6 -Compress)
}

# --- build --------------------------------------------------------------------
# R1c: a guard that cannot fire is worse than no guard. -Verify must NOT
# rebuild first, or it would overwrite the very drift it exists to catch.
$ckPath = Join-Path $Out 'CHECKSUMS.txt'

if (-not $VerifyGenerated) {
    New-Dir $Out
    foreach ($t in $Targets) { Write-Utf8 -Path $t.Path -Text $t.Text }
    Write-Utf8 -Path $CursorPluginRule -Text $CursorRuleTarget.Text

    $lines  = @()
    $lines += "DreamerOS Boot Pack $Version"
    $lines += ("source sha256 " + (Get-Sha $Source) + "  SOURCE-dreameros-boot-canon.md")
    $lines += "generated outputs:"
    foreach ($t in $Targets) {
        $rel = $t.Path.Substring($Out.Length).TrimStart('\')
        $lines += ("  " + (Get-Sha $t.Path) + "  " + $rel)
    }
    Write-Utf8 -Path $ckPath -Text (($lines -join "`r`n") + "`r`n")

    Write-Host ("BUILT {0} vendor formats from 1 source. Rules carried: {1}" -f $Targets.Count, $manifest.rule_count) -ForegroundColor Green
    foreach ($t in $Targets) { Write-Host ("  " + $t.Path.Substring($Out.Length).TrimStart('\')) -ForegroundColor DarkGray }
}

# --- verify -------------------------------------------------------------------
if ($VerifyGenerated) {
    Write-Host "=== DIVERGENCE CHECK (read-only, no rebuild) ===" -ForegroundColor Cyan
    if (-not (Test-Path $ckPath)) { throw "no CHECKSUMS.txt. Run without -Verify first." }
    $stored = Get-Content $ckPath
    $srcNow = Get-Sha $Source
    if (($stored | Where-Object { $_ -match '^source sha256' }) -notmatch $srcNow) {
        Write-Host "  DRIFT  SOURCE changed since last build. Rebuild is required." -ForegroundColor Red
        throw 'source drifted from the last generated set.'
    }
    $fail = 0
    foreach ($t in $Targets) {
        $rel = $t.Path.Substring($Out.Length).TrimStart('\')
        if (-not (Test-Path $t.Path)) { Write-Host ("  MISSING " + $rel) -ForegroundColor Red; $fail++; continue }
        $now = Get-Sha $t.Path
        $rendered = Get-TextSha $t.Text
        $rec = $stored | Where-Object { $_ -match ([regex]::Escape($rel) + '$') }
        if ($now -ne $rendered) { Write-Host ("  DRIFT  " + $rel + " differs from current renderer") -ForegroundColor Red; $fail++ }
        elseif (-not $rec -or $rec -notmatch $now) { Write-Host ("  DRIFT  " + $rel) -ForegroundColor Red; $fail++ }
        else { Write-Host ("  ok     " + $rel) -ForegroundColor Green }
    }
    if (-not (Test-Path $CursorPluginRule)) {
        Write-Host "  MISSING cursor\rules\dreameros-boot-canon.mdc" -ForegroundColor Red
        $fail++
    } elseif ((Get-Sha $CursorPluginRule) -ne (Get-Sha $CursorRuleTarget.Path)) {
        Write-Host "  DRIFT  cursor\rules\dreameros-boot-canon.mdc" -ForegroundColor Red
        $fail++
    } else {
        Write-Host "  ok     cursor\rules\dreameros-boot-canon.mdc (plugin mirror)" -ForegroundColor Green
    }
    if ($fail -gt 0) { throw "$fail generated file(s) drifted from source. Rebuild, do not hand-edit." }
    Write-Host "  no drift" -ForegroundColor Green
}

if ($VerifyInstalled) {
    Write-Host "`n=== INSTALLED DESTINATION CHECK (read-only) ===" -ForegroundColor Cyan
    $fail = 0
    $blockPattern = '<!-- BEGIN DREAMEROS-BOOT-CANON v[0-9]+\.[0-9]+\.[0-9]+ - GENERATED, DO NOT EDIT\. Source: SOURCE-dreameros-boot-canon\.md -->[\s\S]*?<!-- END DREAMEROS-BOOT-CANON v[0-9]+\.[0-9]+\.[0-9]+ -->'
    $globalBlocks = @(
        @{ Path = Join-Path $env:USERPROFILE '.claude\CLAUDE.md'; Source = Join-Path $Out 'claude\CLAUDE.md.block'; Label = 'Claude global boot block' },
        @{ Path = Join-Path $env:USERPROFILE '.codex\AGENTS.md'; Source = Join-Path $Out 'codex\AGENTS.md.block'; Label = 'Codex global boot block' }
    )
    foreach ($item in $globalBlocks) {
        if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf)) {
            Write-Host ("  MISSING {0} {1}" -f $item.Label, $item.Path) -ForegroundColor Red
            $fail++
            continue
        }
        $installedText = [IO.File]::ReadAllText($item.Path)
        $matches = [regex]::Matches($installedText, $blockPattern)
        $expectedText = [IO.File]::ReadAllText($item.Source)
        if ($matches.Count -ne 1 -or (Get-TextSha $matches[0].Value) -ne (Get-TextSha $expectedText)) {
            Write-Host ("  DRIFT   {0} {1}" -f $item.Label, $item.Path) -ForegroundColor Red
            $fail++
        } else {
            Write-Host ("  ok      {0}" -f $item.Label) -ForegroundColor Green
        }
    }
    $repoRoot = Split-Path -Parent $Root
    $fileChecks = @(
        @{ Source = Join-Path $Out 'cursor\dreameros-global-plugin-pointer.mdc'; Path = Join-Path $env:USERPROFILE '.cursor\rules\dreameros-boot-canon.mdc'; Label = 'Cursor global plugin pointer' },
        @{ Source = Join-Path $Out 'skill\dreameros-boot\SKILL.md'; Path = Join-Path $env:USERPROFILE '.claude\skills\dreameros-boot\SKILL.md'; Label = 'Claude boot skill' },
        @{ Source = Join-Path $Out 'skill\dreameros-boot\SKILL.md'; Path = Join-Path $env:USERPROFILE '.codex\skills\dreameros-boot\SKILL.md'; Label = 'Codex boot skill' },
        @{ Source = Join-Path $Out 'skill\dreameros-boot\SKILL.md'; Path = Join-Path $env:USERPROFILE '.agents\skills\dreameros-boot\SKILL.md'; Label = 'Shared boot skill' },
        @{ Source = Join-Path $Out 'skill\dreameros-boot\SKILL.md'; Path = Join-Path $repoRoot 'skills\dreameros-boot\SKILL.md'; Label = 'Agent Plugin boot skill' },
        @{ Source = Join-Path $Out 'evidence\HC_ATTRIBUTED_QUOTES_v1_0_0.md'; Path = Join-Path $env:USERPROFILE '.agents\evidence\dreameros\HC_ATTRIBUTED_QUOTES_v1_0_0.md'; Label = 'Shared quote evidence' },
        @{ Source = Join-Path $Out 'claude\dreameros-session-start.sh'; Path = Join-Path $env:USERPROFILE '.claude\hooks\dreameros-session-start.sh'; Label = 'Claude SessionStart adapter' }
    )
    $registeredCursorRule = Get-RegisteredCursorPluginRuleDest
    if ($registeredCursorRule) {
        $fileChecks += @{ Source = $CursorRuleTarget.Path; Path = $registeredCursorRule; Label = 'Cursor registered plugin rule (the file Cursor actually loads)' }
    } else {
        Write-Host '  SKIP    no local Cursor plugin registration names dreameros-agent-plugin; registered plugin rule not checked' -ForegroundColor Yellow
    }
    foreach ($item in $fileChecks) {
        if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf) -or (Get-Sha $item.Source) -ne (Get-Sha $item.Path)) {
            Write-Host ("  DRIFT   {0} {1}" -f $item.Label, $item.Path) -ForegroundColor Red
            $fail++
        } else {
            Write-Host ("  ok      {0}" -f $item.Label) -ForegroundColor Green
        }
    }
    if ($fail -gt 0) { throw "$fail installed DreamerOS carrier(s) are missing or drifted." }
    Write-Host "  VERIFIED installed Claude, Codex, Cursor pointer, Cursor registered plugin rule, skills, evidence, and Claude hook" -ForegroundColor Green
}

# --- install ------------------------------------------------------------------
if ($Install) {
    Write-Host "`n=== INSTALL into each vendor's native global surface ===" -ForegroundColor Cyan
    $begin = "<!-- BEGIN $Marker"
    $blockPattern = [regex]::Escape($begin) + '[\s\S]*?' +
        [regex]::Escape("<!-- END $Marker") + '\s+v[0-9]+\.[0-9]+\.[0-9]+\s+-->'

    $installs = @(
        @{
            f = Join-Path $env:USERPROFILE '.claude\CLAUDE.md'
            block = Join-Path $Out 'claude\CLAUDE.md.block'
            engine = 'Claude Code + Desktop'
        }
        @{
            f = Join-Path $env:USERPROFILE '.codex\AGENTS.md'
            block = Join-Path $Out 'codex\AGENTS.md.block'
            engine = 'Codex Desktop + CLI + IDE'
        }
    )

    foreach ($i in $installs) {
        if (-not (Test-Path $i.f)) { Write-Host ("  SKIP   {0} does not exist ({1})" -f $i.f, $i.engine) -ForegroundColor Yellow; continue }
        $block = Get-Content $i.block -Raw
        $cur = Get-Content $i.f -Raw
        $beginCount = ([regex]::Matches($cur, [regex]::Escape($begin))).Count
        if ($beginCount -gt 1) {
            throw "multiple DreamerOS boot blocks found in $($i.f); refusing an ambiguous replacement."
        }
        if ($beginCount -eq 1) {
            $existingBlocks = [regex]::Matches($cur, $blockPattern)
            if ($existingBlocks.Count -ne 1) {
                throw "DreamerOS boot block in $($i.f) has an unrecognized or unbalanced version wrapper."
            }
            $new = [regex]::Replace($cur, $blockPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block.TrimEnd() })
        } else {
            $new = $cur.TrimEnd() + "`r`n`r`n" + $block
        }
        $newBlocks = [regex]::Matches($new, $blockPattern)
        if ($newBlocks.Count -ne 1 -or $newBlocks[0].Value -notmatch [regex]::Escape("# DreamerOS Boot Canon $Version")) {
            throw "generated $Version block was not present exactly once after rendering $($i.f)."
        }
        if ($new -eq $cur) {
            Write-Host ("  ALIGNED {0}  ({1})" -f $i.f, $i.engine) -ForegroundColor DarkGreen
            continue
        }
        $bak = $i.f + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item $i.f $bak
        Set-Content -Path $i.f -Value $new -Encoding utf8
        Write-Host ("  HEALED  {0}  ({1})  backup {2}" -f $i.f, $i.engine, (Split-Path $bak -Leaf)) -ForegroundColor Green
    }

    $repoRoot = Split-Path -Parent $Root

    $CursorPluginsLocalRoot = Join-Path $env:USERPROFILE '.cursor\plugins\local'
    $RegisteredCursorPluginRuleDest = Get-RegisteredCursorPluginRuleDest


    $fileInstalls = @(
        @{
            source = Join-Path $Out 'cursor\dreameros-global-plugin-pointer.mdc'
            dest = Join-Path $env:USERPROFILE '.cursor\rules\dreameros-boot-canon.mdc'
            engine = 'Cursor global plugin pointer'
        }
        @{
            source = Join-Path $Out 'skill\dreameros-boot\SKILL.md'
            dest = Join-Path $env:USERPROFILE '.claude\skills\dreameros-boot\SKILL.md'
            engine = 'Claude skill discovery'
        }
        @{
            source = Join-Path $Out 'skill\dreameros-boot\SKILL.md'
            dest = Join-Path $env:USERPROFILE '.codex\skills\dreameros-boot\SKILL.md'
            engine = 'Codex skill discovery'
        }
        @{
            source = Join-Path $Out 'skill\dreameros-boot\SKILL.md'
            dest = Join-Path $env:USERPROFILE '.agents\skills\dreameros-boot\SKILL.md'
            engine = 'Shared agent skill discovery'
        }
        @{
            source = Join-Path $Out 'skill\dreameros-boot\SKILL.md'
            dest = Join-Path $repoRoot 'skills\dreameros-boot\SKILL.md'
            engine = 'Agent Plugin clients'
        }
        @{
            source = Join-Path $Out 'evidence\HC_ATTRIBUTED_QUOTES_v1_0_0.md'
            dest = Join-Path $env:USERPROFILE '.agents\evidence\dreameros\HC_ATTRIBUTED_QUOTES_v1_0_0.md'
            engine = 'Shared DreamerOS quote evidence'
        }
        @{
            source = Join-Path $Out 'claude\dreameros-session-start.sh'
            dest = Join-Path $env:USERPROFILE '.claude\hooks\dreameros-session-start.sh'
            engine = 'Claude DreamerOS SessionStart adapter'
        }
    )

    if ($RegisteredCursorPluginRuleDest) {
        $fileInstalls += @{
            source = $CursorRuleTarget.Path
            dest = $RegisteredCursorPluginRuleDest
            engine = 'Cursor registered plugin rule (the file Cursor actually loads)'
        }
    } else {
        Write-Host ("  SKIP   no local Cursor plugin registration under {0} names dreameros-agent-plugin; registered plugin rule not installed." -f $CursorPluginsLocalRoot) -ForegroundColor Yellow
    }

    foreach ($i in $fileInstalls) {
        New-Dir (Split-Path -Parent $i.dest)
        $new = Get-Content $i.source -Raw
        $byteAligned = (Test-Path $i.dest) -and ((Get-Sha $i.source) -eq (Get-Sha $i.dest))
        if ($byteAligned) {
            Write-Host ("  ALIGNED {0}  ({1})" -f $i.dest, $i.engine) -ForegroundColor DarkGreen
            continue
        }
        if (Test-Path $i.dest) {
            $bak = $i.dest + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item $i.dest $bak
        }
        Write-Utf8 -Path $i.dest -Text $new
        Write-Host ("  HEALED  {0}  ({1})" -f $i.dest, $i.engine) -ForegroundColor Green
    }

    # R17 RUNTIME HALF, Codex. The boot canon above is PROSE - it reaches
    # whoever reads the file. The hook below EXECUTES, which is the half
    # that actually fires when the operator changes engine mid-session.
    #
    # It installs at the user level, not per repository, because an engine
    # switch is not a per-repository event. It is placed here rather than
    # in a separate installer so that "available at boot" is literally
    # true: the SessionStart hook runs this script, so every session
    # re-places the hook if something removed it.
    #
    # An existing user hooks.json is NEVER overwritten. Codex allows only
    # one file there and it may already carry another lane's hooks, so a
    # blind write would silently delete them. When one exists this reports
    # MERGE NEEDED and moves on, which is a visible gap rather than a
    # silent loss.
    $codexHookSrc = Join-Path $repoRoot 'install\codex\payload\hooks\model-switch-ack-codex.py'
    $codexJsonSrc = Join-Path $repoRoot 'install\codex\payload\hooks.json'
    $codexHome    = Join-Path $env:USERPROFILE '.codex'
    if ((Test-Path $codexHookSrc) -and (Test-Path $codexJsonSrc)) {
        $codexHookDest = Join-Path $codexHome 'hooks\model-switch-ack-codex.py'
        New-Dir (Split-Path -Parent $codexHookDest)
        if ((Test-Path $codexHookDest) -and ((Get-Sha $codexHookSrc) -eq (Get-Sha $codexHookDest))) {
            Write-Host ("  ALIGNED {0}  (Codex engine-switch hook)" -f $codexHookDest) -ForegroundColor DarkGreen
        } else {
            Copy-Item $codexHookSrc $codexHookDest -Force
            Write-Host ("  HEALED  {0}  (Codex engine-switch hook)" -f $codexHookDest) -ForegroundColor Green
        }

        $codexJsonDest = Join-Path $codexHome 'hooks.json'
        $rendered = (Get-Content $codexJsonSrc -Raw).Replace(
            '__DREAMEROS_CODEX_HOME__', ($codexHome -replace '\\', '/'))
        if (-not (Test-Path $codexJsonDest)) {
            Write-Utf8 -Path $codexJsonDest -Text $rendered
            Write-Host ("  HEALED  {0}  (Codex hook registration)" -f $codexJsonDest) -ForegroundColor Green
        } elseif ((Get-Content $codexJsonDest -Raw) -match 'model-switch-ack-codex') {
            Write-Host ("  ALIGNED {0}  (Codex hook registration)" -f $codexJsonDest) -ForegroundColor DarkGreen
        } else {
            Write-Host ("  MERGE NEEDED {0} - it exists and does not register the engine-switch hook. Add the Stop entry from install\codex\payload\hooks.json by hand rather than overwriting another lane's hooks." -f $codexJsonDest) -ForegroundColor Yellow
        }

        Write-Host "  NOTE: Codex records hook trust as a hash in config.toml. A newly" -ForegroundColor Yellow
        Write-Host "  placed hook stays untrusted until Codex records it, so confirm it" -ForegroundColor Yellow
        Write-Host "  fires before treating this as covered. A hook that exits 0 is not" -ForegroundColor Yellow
        Write-Host "  a hook that ran." -ForegroundColor Yellow
    }

    Write-Host "`n  Per-repo files remain reviewed Git artifacts." -ForegroundColor Yellow
    Write-Host "  Global Claude, Codex, Cursor, shared skills, and Agent Plugin" -ForegroundColor Yellow
    Write-Host "  discovery are installed automatically from this one source." -ForegroundColor Yellow

    Write-Host "`n  VERIFY AT THE DESTINATION, per R6. Read it back:" -ForegroundColor Cyan
    foreach ($i in $installs) {
        if (Test-Path $i.f) {
            $destinationText = Get-Content $i.f -Raw
            $destinationBlocks = [regex]::Matches($destinationText, $blockPattern)
            if ($destinationBlocks.Count -ne 1) {
                throw "destination block count failed for $($i.f): $($destinationBlocks.Count)"
            }
            $actualBlock = $destinationBlocks[0].Value.Replace("`r`n", "`n").TrimEnd()
            $expectedBlock = (Get-Content $i.block -Raw).Replace("`r`n", "`n").TrimEnd()
            $same = $actualBlock -ceq $expectedBlock
            Write-Host ("    {0} block-match={1} version={2}" -f (Split-Path $i.f -Leaf), $same, $Version)
            if (-not $same) { throw "destination block bytes failed for $($i.f)" }
        }
    }
    foreach ($i in $fileInstalls) {
        $same = (Get-Sha $i.source) -eq (Get-Sha $i.dest)
        Write-Host ("    {0} byte-match={1}" -f $i.engine, $same)
        if (-not $same) { throw "destination verification failed: $($i.dest)" }
    }
}
