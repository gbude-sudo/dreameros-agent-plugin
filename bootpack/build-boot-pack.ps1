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
function Get-Utf8NoBomBytes([string]$Text) {
    $Text = $Text.Replace(([string][char]13 + [char]10), [string][char]10)
    $Text = $Text.Replace([string][char]13, [string][char]10)
    return (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
}
function Test-ExactBytes([byte[]]$Left, [byte[]]$Right) {
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}
function Get-RawShaBytes([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "").ToLower()
    } finally {
        $sha.Dispose()
    }
}
function Get-RawFileSha([string]$Path) {
    return Get-RawShaBytes ([System.IO.File]::ReadAllBytes($Path))
}
function Read-LockedFileBytes([System.IO.FileStream]$Stream) {
    $Stream.Position = 0
    [byte[]]$bytes = New-Object byte[] ([int]$Stream.Length)
    $offset = 0
    while ($offset -lt $bytes.Length) {
        $read = $Stream.Read($bytes, $offset, $bytes.Length - $offset)
        if ($read -eq 0) { break }
        $offset += $read
    }
    if ($offset -ne $bytes.Length) {
        throw "short read from locked destination: expected $($bytes.Length) bytes, read $offset."
    }
    return ,$bytes
}
function New-TimestampedBackupPath([string]$Destination) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfffZ')
    return $Destination + '.bak-' + $stamp + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
}
function Install-CollisionSafeFile([string]$Source, [string]$Destination, [string]$Label) {
    [byte[]]$sourceBytes = [System.IO.File]::ReadAllBytes($Source)
    $sourceHash = Get-RawShaBytes $sourceBytes
    New-Dir (Split-Path -Parent $Destination)

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        $createStream = $null
        try {
            $createStream = [System.IO.File]::Open(
                $Destination,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None)
            $createStream.Write($sourceBytes, 0, $sourceBytes.Length)
            $createStream.Flush($true)
        } catch {
            Write-Host ("  MERGE NEEDED {0}  ({1}) - destination appeared or could not be created exclusively." -f $Destination, $Label) -ForegroundColor Yellow
            throw "MERGE NEEDED: collision-safe install stopped before creating $Destination."
        } finally {
            if ($null -ne $createStream) { $createStream.Dispose() }
        }
        if ((Get-RawFileSha $Destination) -cne $sourceHash) {
            throw "destination verification failed after exclusive create: $Destination"
        }
        Write-Host ("  HEALED  {0}  ({1})" -f $Destination, $Label) -ForegroundColor Green
        return
    }

    $destinationStream = $null
    $state = ''
    $backupPath = ''
    try {
        $destinationStream = [System.IO.File]::Open(
            $Destination,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None)
        [byte[]]$currentBytes = Read-LockedFileBytes $destinationStream
        $expectedCurrentHash = Get-RawShaBytes $currentBytes
        if ($expectedCurrentHash -ceq $sourceHash) {
            $state = 'ALIGNED'
        } else {
            $backupPath = New-TimestampedBackupPath $Destination
            $backupStream = $null
            try {
                $backupStream = [System.IO.File]::Open(
                    $backupPath,
                    [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::None)
                $backupStream.Write($currentBytes, 0, $currentBytes.Length)
                $backupStream.Flush($true)
            } finally {
                if ($null -ne $backupStream) { $backupStream.Dispose() }
            }

            # Re-read the locked destination immediately before mutation. The
            # expected hash is the exact byte state captured for the backup.
            [byte[]]$immediateBytes = Read-LockedFileBytes $destinationStream
            $immediateHash = Get-RawShaBytes $immediateBytes
            if ($immediateHash -cne $expectedCurrentHash) {
                throw "destination changed after backup and before write."
            }
            $destinationStream.Position = 0
            $destinationStream.SetLength(0)
            $destinationStream.Write($sourceBytes, 0, $sourceBytes.Length)
            $destinationStream.Flush($true)
            $state = 'HEALED'
        }
    } catch {
        Write-Host ("  MERGE NEEDED {0}  ({1}) - collision-safe transaction stopped: {2}" -f $Destination, $Label, $_.Exception.Message) -ForegroundColor Yellow
        throw "MERGE NEEDED: $Label destination was preserved for owner review."
    } finally {
        if ($null -ne $destinationStream) { $destinationStream.Dispose() }
    }

    if ($state -eq 'ALIGNED') {
        Write-Host ("  ALIGNED {0}  ({1})" -f $Destination, $Label) -ForegroundColor DarkGreen
        return
    }
    if ((Get-RawFileSha $Destination) -cne $sourceHash) {
        throw "destination verification failed after collision-safe update: $Destination"
    }
    Write-Host ("  HEALED  {0}  ({1})  backup {2}" -f $Destination, $Label, (Split-Path $backupPath -Leaf)) -ForegroundColor Green
}
function Install-NewTextFileOrPreserve([string]$Destination, [string]$Text, [string]$RequiredMarker, [string]$Label) {
    [byte[]]$newBytes = Get-Utf8NoBomBytes $Text
    $newHash = Get-RawShaBytes $newBytes
    New-Dir (Split-Path -Parent $Destination)

    # CreateNew is the transaction boundary. If another owner creates the file
    # first, this call cannot truncate it and the preserve path below reads it.
    $createStream = $null
    $createdNew = $false
    $writeComplete = $false
    try {
        $createStream = [System.IO.File]::Open(
            $Destination,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None)
        $createdNew = $true
        $createStream.Write($newBytes, 0, $newBytes.Length)
        $createStream.Flush($true)
        $writeComplete = $true
    } catch {
        if ($createdNew) {
            Write-Host ("  MERGE NEEDED {0}  ({1}) - exclusive creation did not complete." -f $Destination, $Label) -ForegroundColor Yellow
            throw "MERGE NEEDED: $Label creation stopped without overwriting an existing owner file."
        }
    } finally {
        if ($null -ne $createStream) { $createStream.Dispose() }
    }

    if ($writeComplete) {
        if ((Get-RawFileSha $Destination) -cne $newHash) {
            throw "destination verification failed after exclusive create: $Destination"
        }
        Write-Host ("  HEALED  {0}  ({1})" -f $Destination, $Label) -ForegroundColor Green
        return
    }

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        Write-Host ("  MERGE NEEDED {0}  ({1}) - exclusive creation failed and no readable owner file exists." -f $Destination, $Label) -ForegroundColor Yellow
        throw "MERGE NEEDED: $Label destination could not be created or preserved."
    }

    $existingStream = $null
    try {
        $existingStream = [System.IO.File]::Open(
            $Destination,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::None)
        [byte[]]$existingBytes = Read-LockedFileBytes $existingStream
    } catch {
        Write-Host ("  MERGE NEEDED {0}  ({1}) - existing owner file could not be read under an exclusive lock." -f $Destination, $Label) -ForegroundColor Yellow
        throw "MERGE NEEDED: $Label owner file was preserved for review."
    } finally {
        if ($null -ne $existingStream) { $existingStream.Dispose() }
    }

    $existingText = (New-Object System.Text.UTF8Encoding($false)).GetString($existingBytes)
    if ($existingText.Contains($RequiredMarker)) {
        Write-Host ("  ALIGNED {0}  ({1})" -f $Destination, $Label) -ForegroundColor DarkGreen
        return
    }
    Write-Host ("  MERGE NEEDED {0} - it exists and does not register the engine-switch hook. Add the Stop entry from install\codex\payload\hooks.json by hand rather than overwriting another lane's hooks." -f $Destination) -ForegroundColor Yellow
}
function ConvertTo-JsonString([string]$Text) {
    $escaped = New-Object System.Text.StringBuilder
    [void]$escaped.Append('"')
    foreach ($character in $Text.ToCharArray()) {
        switch ([int]$character) {
            8 { [void]$escaped.Append('\b'); break }
            9 { [void]$escaped.Append('\t'); break }
            10 { [void]$escaped.Append('\n'); break }
            12 { [void]$escaped.Append('\f'); break }
            13 { [void]$escaped.Append('\r'); break }
            34 { [void]$escaped.Append('\"'); break }
            92 { [void]$escaped.Append('\\'); break }
            default {
                if ([int]$character -lt 32) {
                    [void]$escaped.Append(('\u{0:X4}' -f [int]$character))
                } else {
                    [void]$escaped.Append($character)
                }
            }
        }
    }
    [void]$escaped.Append('"')
    return $escaped.ToString()
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
$PayloadTargets = @()

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

function Get-ClaudeSessionStartRegistration([string]$SettingsPath) {
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        return [pscustomobject]@{ ParseOk = $false; BootstrapCount = 0; CompetingCount = 0 }
    }
    try { $settings = Get-Content -Raw -LiteralPath $SettingsPath | ConvertFrom-Json } catch {
        return [pscustomobject]@{ ParseOk = $false; BootstrapCount = 0; CompetingCount = 0 }
    }
    $commands = @()
    foreach ($group in @($settings.hooks.SessionStart)) {
        foreach ($hook in @($group.hooks)) {
            if ($hook.command) { $commands += [string]$hook.command }
        }
    }
    $bootstrap = @($commands | Where-Object { $_ -match '(?i)dreameros-session-start\.sh' })
    $competing = @($commands | Where-Object { $_ -match '(?i)(?:operator-standing-orders|dreameros-agent-stack-session-start|dreameros_state|dreameros_recall)' })
    return [pscustomobject]@{ ParseOk = $true; BootstrapCount = $bootstrap.Count; CompetingCount = $competing.Count }
}

$ProjectPointerVersion = 'v1.1.0'
$SessionPackageRequiredCanaryIds = @('R26', 'R27', 'HC-DEFINITION-OF-DONE')
$ProjectPointerBody = @"
<!-- DREAMEROS-BOOT-CANON: NOT DUPLICATED HERE -->
<!-- DREAMEROS-PROJECT-BOOT-POINTER $ProjectPointerVersion -->
## DreamerOS Boot Canon - proven by a native carrier or session package

The full DreamerOS Boot Canon is generated from
gbude-sudo/dreameros-agent-plugin:bootpack/SOURCE-dreameros-boot-canon.md and delivered
through native carriers and authenticated session packages. This project file
intentionally contains no copy of the canon and cannot import another rule.

Before substantive DreamerOS work, prove either carrier A or carrier B:

A. Native carrier for the active engine:
   1. Claude Code or Desktop: the current generated block is present once in
      ~/.claude/CLAUDE.md.
   2. Codex: the current generated block is present once in ~/.codex/AGENTS.md.
   3. Cursor: Customize shows the local Dreameros plugin, and its
      dreameros-boot-canon rule is set to Always and appears in the active rule
      trace for the fresh Agent chat.

B. Cloud carrier: a successful authenticated ``dreameros_session_package``
   response proves one ``package_components.boot_canon`` component and one
   complete boot-canon wrapper. Component and wrapper schema, version, SHA-256,
   and provenance metadata must match. Recompute the SHA-256 over the complete
   LF-normalized wrapper body and require it to match the component metadata.
   Require the current canary set inside that full body and a canonical UTC
   ``composed_at`` plus integer ``ttl_seconds`` from 1 through 3600, allowing
   no more than 60 seconds of clock skew. An optional ``expires_at`` is not an
   alternate authority. A marker-only, truncated, duplicate, malformed, or
   auth-required package is not proof.

   If the visible package lacks the complete closing wrapper or full hash proof
   but metadata-first ``package_continuation`` is present, fetch same-tool parts
   1 through N. Verify per-part hashes, order, and user-bound ``package_id`` plus
   ``content_hash``. Reassemble, verify the full content hash and boot-canon
   body, then proceed. Failed reconstruction is BLOCKED.

If both carriers are available, their boot-canon identity metadata must match.
If they differ, report CONFLICT and stop substantive work.

If neither carrier is proven, report BLOCKED and stop substantive work. Do not
use this pointer as a fallback canon.
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
description: DreamerOS project boot pointer. Requires a native carrier or authenticated session package and contains no duplicated canon.
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

$ClaudeSessionStartText = @'
#!/usr/bin/env bash
# DREAMEROS-CLAUDE-SESSION-START-ADAPTER v1.1.0
# Thin runtime adapter. The full boot canon remains in the native global file.
set -euo pipefail

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "DreamerOS session boot is mandatory before substantive work. Use the exact DreamerOS tool names exposed by this session; never hardcode an MCP server id. Call dreameros_session_package first for the active Claude engine and current project. It is the only unconditional boot call and carries the full Boot Canon plus a handoff summary. When the package directs it or the current task needs read-only enrichment, call in this order: (1) dreameros_session_handoff_read for the full record when present, (2) dreameros_context and use its SCS as the read-only current-state channel, (3) a scoped dreameros_recall for the current topic, and (4) relevant dreameros_canon. If package_continuation is metadata-first and the visible package lacks a complete wrapper or full hash proof, fetch parts 1 through N with the same tool, verify part hashes, order, user-bound package_id and content_hash, reassemble, and verify the full boot-canon body before proceeding. Failed reconstruction is BLOCKED. The mixed read/write state tool is not a generic bootstrap call. Then read global, repository, and nested instructions; measure Git state; and check active coordination claims. If any required DreamerOS tool is unavailable, report BLOCKED for DreamerOS hydration and continue only safe local work in STANDALONE mode. Never expose or store credentials, token values, private keys, or environment values."
  }
}
JSON
'@
$Targets += @{
    Path = Join-Path $Out 'claude\dreameros-session-start.sh'
    Text = $ClaudeSessionStartText
}
$PayloadTargets += @{
    Path = Join-Path (Split-Path -Parent $Root) 'install\claude-code\payload\hooks\dreameros-session-start.sh'
    Text = $ClaudeSessionStartText
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
    Path = Join-Path $Out 'project-oauth\claude.mcp.json'
    Text = '{"mcpServers":{"dreameros":{"type":"streamable-http","url":"https://mcp.dreameros.app/mcp"}}}'
}
$Targets += @{
    Path = Join-Path $Out 'project-oauth\cursor.mcp.json'
    Text = '{"mcpServers":{"dreameros-platform":{"url":"https://mcp.dreameros.app/mcp"}}}'
}
$Targets += @{
    Path = Join-Path $Out 'project-oauth\codex.config.toml'
    Text = @'
[mcp_servers.dreameros]
url = "https://mcp.dreameros.app/mcp"

[mcp_servers.dreameros.tools.dreameros_session_package]
output_token_limit = 30000
'@
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

$PortableSourceText = [System.IO.File]::ReadAllText($Source)
$RuntimeStablePrefixText = '{' +
    '"schema_version":' + (ConvertTo-JsonString 'dreameros-session-package-stable-prefix-v1') + ',' +
    '"version":' + (ConvertTo-JsonString $Version) + ',' +
    '"sha256":' + (ConvertTo-JsonString $SourceSemanticSha) + ',' +
    '"source_provenance":{' +
        '"repository":' + (ConvertTo-JsonString 'gbude-sudo/dreameros-agent-plugin') + ',' +
        '"path":' + (ConvertTo-JsonString 'bootpack/SOURCE-dreameros-boot-canon.md') + ',' +
        '"generator":' + (ConvertTo-JsonString 'bootpack/build-boot-pack.ps1') +
    '},' +
    '"portable_text":' + (ConvertTo-JsonString $PortableSourceText) +
'}'
$Targets += @{
    Path = Join-Path $Out 'runtime\dreameros-boot-canon-stable-prefix.json'
    Text = $RuntimeStablePrefixText
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
    purpose = 'Fail-closed project pointer. The full canon remains single-source and is proven by a native carrier or authenticated session package.'
    cursor_path = 'cursor/dreameros-project-pointer.mdc'
    cursor_global_plugin_pointer = 'cursor/dreameros-global-plugin-pointer.mdc'
    embedded_path = 'project/DREAMEROS_BOOT_CANON_POINTER.md.block'
    cloud_session_package = [ordered]@{
        component = 'package_components.boot_canon'
        proof = 'one complete wrapper with matching schema, version, sha256, provenance, full-body hash, canaries, and fresh metadata'
        required_canary_ids = $SessionPackageRequiredCanaryIds
    }
}
$manifest.project_adapters = [ordered]@{
    version = 'v1.1.0'
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
$manifest.runtime_export = [ordered]@{
    schema_version = 'dreameros-session-package-stable-prefix-v1'
    path = 'runtime/dreameros-boot-canon-stable-prefix.json'
    purpose = 'Deterministic gateway session-package stable prefix. Generated from the single boot canon source.'
    source_sha256 = $SourceSemanticSha
}
$manifest.project_oauth_onramp = [ordered]@{
    status = 'TEMPLATE_WRITTEN_NOT_REGISTERED'
    claude = 'project-oauth/claude.mcp.json'
    cursor = 'project-oauth/cursor.mcp.json'
    codex = 'project-oauth/codex.config.toml'
    requirement = 'Client OAuth approval is required before connection proof.'
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
    foreach ($t in $PayloadTargets) { Write-Utf8 -Path $t.Path -Text $t.Text }
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
    foreach ($t in $PayloadTargets) { Write-Host ("  generated payload " + $t.Path) -ForegroundColor DarkGray }
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
        if ($rel -eq 'runtime\dreameros-boot-canon-stable-prefix.json' -and -not (Test-ExactBytes ([IO.File]::ReadAllBytes($t.Path)) (Get-Utf8NoBomBytes $t.Text))) { Write-Host ("  DRIFT  " + $rel + " raw bytes differ from current renderer") -ForegroundColor Red; $fail++ }
        elseif ($now -ne $rendered) { Write-Host ("  DRIFT  " + $rel + " differs from current renderer") -ForegroundColor Red; $fail++ }
        elseif (-not $rec -or $rec -notmatch $now) { Write-Host ("  DRIFT  " + $rel) -ForegroundColor Red; $fail++ }
        else { Write-Host ("  ok     " + $rel) -ForegroundColor Green }
    }
    foreach ($t in $PayloadTargets) {
        $label = 'install\\claude-code\\payload\\hooks\\' + (Split-Path -Leaf $t.Path)
        if (-not (Test-Path $t.Path)) { Write-Host ("  MISSING " + $label) -ForegroundColor Red; $fail++; continue }
        if ((Get-Sha $t.Path) -ne (Get-TextSha $t.Text)) { Write-Host ("  DRIFT  " + $label + " differs from current renderer") -ForegroundColor Red; $fail++ }
        else { Write-Host ("  ok     " + $label) -ForegroundColor Green }
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
    $verifiedCarrierIds = New-Object System.Collections.Generic.List[string]
    $blockPattern = '<!-- BEGIN DREAMEROS-BOOT-CANON v[0-9]+\.[0-9]+\.[0-9]+ - GENERATED, DO NOT EDIT\. Source: SOURCE-dreameros-boot-canon\.md -->[\s\S]*?<!-- END DREAMEROS-BOOT-CANON v[0-9]+\.[0-9]+\.[0-9]+ -->'
    $globalBlocks = @(
        @{ Path = Join-Path $env:USERPROFILE '.claude\CLAUDE.md'; Source = Join-Path $Out 'claude\CLAUDE.md.block'; Label = 'Claude global boot block'; Id = 'claude_global_boot' },
        @{ Path = Join-Path $env:USERPROFILE '.codex\AGENTS.md'; Source = Join-Path $Out 'codex\AGENTS.md.block'; Label = 'Codex global boot block'; Id = 'codex_global_boot' }
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
            [void]$verifiedCarrierIds.Add($item.Id)
        }
    }
    $repoRoot = Split-Path -Parent $Root
    $fileChecks = @(
        @{ Source = Join-Path $Out 'cursor\dreameros-global-plugin-pointer.mdc'; Path = Join-Path $env:USERPROFILE '.cursor\rules\dreameros-boot-canon.mdc'; Label = 'Cursor global plugin pointer'; Id = 'cursor_global_pointer' },
        @{ Source = Join-Path $Out 'skill\dreameros-boot\SKILL.md'; Path = Join-Path $env:USERPROFILE '.claude\skills\dreameros-boot\SKILL.md'; Label = 'Claude boot skill'; Id = 'claude_boot_skill' },
        @{ Source = Join-Path $Out 'skill\dreameros-boot\SKILL.md'; Path = Join-Path $env:USERPROFILE '.codex\skills\dreameros-boot\SKILL.md'; Label = 'Codex boot skill'; Id = 'codex_boot_skill' },
        @{ Source = Join-Path $Out 'skill\dreameros-boot\SKILL.md'; Path = Join-Path $env:USERPROFILE '.agents\skills\dreameros-boot\SKILL.md'; Label = 'Shared boot skill'; Id = 'shared_boot_skill' },
        @{ Source = Join-Path $Out 'skill\dreameros-boot\SKILL.md'; Path = Join-Path $repoRoot 'skills\dreameros-boot\SKILL.md'; Label = 'Agent Plugin boot skill'; Id = 'agent_plugin_boot_skill' },
        @{ Source = Join-Path $Out 'evidence\HC_ATTRIBUTED_QUOTES_v1_0_0.md'; Path = Join-Path $env:USERPROFILE '.agents\evidence\dreameros\HC_ATTRIBUTED_QUOTES_v1_0_0.md'; Label = 'Shared quote evidence'; Id = 'shared_quote_evidence' },
        @{ Source = Join-Path $Out 'claude\dreameros-session-start.sh'; Path = Join-Path $env:USERPROFILE '.claude\hooks\dreameros-session-start.sh'; Label = 'Claude SessionStart adapter'; Id = 'claude_session_start_hook' }
    )
    $registeredCursorRule = Get-RegisteredCursorPluginRuleDest
    if ($registeredCursorRule) {
        $fileChecks += @{ Source = $CursorRuleTarget.Path; Path = $registeredCursorRule; Label = 'Cursor registered plugin rule (the file Cursor actually loads)'; Id = 'cursor_registered_plugin_rule' }
    } else {
        Write-Host '  MISSING Cursor registered plugin rule' -ForegroundColor Red
        $fail++
    }
    foreach ($item in $fileChecks) {
        if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf) -or (Get-Sha $item.Source) -ne (Get-Sha $item.Path)) {
            Write-Host ("  DRIFT   {0} {1}" -f $item.Label, $item.Path) -ForegroundColor Red
            $fail++
        } else {
            Write-Host ("  ok      {0}" -f $item.Label) -ForegroundColor Green
            [void]$verifiedCarrierIds.Add($item.Id)
        }
    }
    $registration = Get-ClaudeSessionStartRegistration (Join-Path $env:USERPROFILE '.claude\settings.json')
    if (-not $registration.ParseOk -or $registration.BootstrapCount -ne 1 -or $registration.CompetingCount -ne 0) {
        Write-Host '  DRIFT   Claude SessionStart registration' -ForegroundColor Red
        $fail++
    } else {
        Write-Host '  ok      Claude SessionStart registration' -ForegroundColor Green
        [void]$verifiedCarrierIds.Add('claude_session_start_registration')
    }
    $requiredCarrierIds = @('claude_global_boot','codex_global_boot','cursor_global_pointer','cursor_registered_plugin_rule','claude_boot_skill','codex_boot_skill','shared_boot_skill','agent_plugin_boot_skill','shared_quote_evidence','claude_session_start_hook','claude_session_start_registration')
    $verifiedSorted = @($verifiedCarrierIds | Sort-Object -Unique)
    $requiredSorted = @($requiredCarrierIds | Sort-Object)
    if (($verifiedSorted -join ',') -cne ($requiredSorted -join ',')) {
        Write-Host '  DRIFT   Installed carrier receipt set is incomplete, extra, or duplicated' -ForegroundColor Red
        $fail++
    }
    if ($fail -gt 0) { throw "$fail installed DreamerOS carrier(s) are missing or drifted." }
    $receipt = [ordered]@{ schema_version = 'dreameros-verify-installed-v1'; ok = $true; boot_canon = [ordered]@{ version = $Version; sha256 = $SourceSemanticSha }; required_carriers = $requiredSorted; verified_carriers = $verifiedSorted }
    Write-Output ('DREAMEROS_VERIFY_INSTALLED_JSON=' + ($receipt | ConvertTo-Json -Compress))
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
    # in a separate installer so that "available at boot" is literal: the
    # SessionStart hook runs this script, so every session checks the source.
    # A differing destination is locked, backed up byte-for-byte, rechecked,
    # and then updated. A lock conflict or drift reports MERGE NEEDED and stops
    # before it can overwrite another owner's in-flight edit.
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
        Install-CollisionSafeFile -Source $codexHookSrc -Destination $codexHookDest -Label 'Codex engine-switch hook'

        $codexJsonDest = Join-Path $codexHome 'hooks.json'
        $rendered = (Get-Content $codexJsonSrc -Raw).Replace(
            '__DREAMEROS_CODEX_HOME__', ($codexHome -replace '\\', '/'))
        Install-NewTextFileOrPreserve -Destination $codexJsonDest -Text $rendered -RequiredMarker 'model-switch-ack-codex' -Label 'Codex hook registration'

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
