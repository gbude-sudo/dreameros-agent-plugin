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
    [switch]$Install
)

$ErrorActionPreference = 'Stop'
$Root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Source = Join-Path $Root 'SOURCE-dreameros-boot-canon.md'
$Out    = Join-Path $Root 'out'

if (-not (Test-Path $Source)) { throw "source missing: $Source" }
$Payload = Get-Content $Source -Raw
$Version = 'v1.0.0'
$Marker  = 'DREAMEROS-BOOT-CANON'

function New-Dir([string]$p) { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
function Write-Utf8([string]$Path, [string]$Text) {
    New-Dir (Split-Path -Parent $Path)
    $Text = $Text -replace "`r`n", "`n"
    $Text = $Text -replace "`r", "`n"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}
function Get-Sha([string]$Path) { (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower() }

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

$Targets += @{
    Path = Join-Path $Out 'cursor\dreameros-boot-canon.mdc'
    Text = @"
---
description: DreamerOS Boot Canon. Measurement discipline, vocabulary, and the close check. Always applied.
alwaysApply: true
---

$Payload
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
foreach ($m in [regex]::Matches($Payload, '(?m)^## (R\d+[a-z]?) - (.+)$')) {
    $manifest.rules += [ordered]@{ id = $m.Groups[1].Value; title = $m.Groups[2].Value.Trim() }
}
foreach ($m in [regex]::Matches($Payload, '(?m)^### (R\d+[a-z]) - (.+)$')) {
    $manifest.rules += [ordered]@{ id = $m.Groups[1].Value; title = $m.Groups[2].Value.Trim() }
}
$manifest.rule_count = $manifest.rules.Count
$Targets += @{
    Path = Join-Path $Out 'manifest\dreameros-boot-canon.json'
    Text = ($manifest | ConvertTo-Json -Depth 6)
}

# --- build --------------------------------------------------------------------
# R1c: a guard that cannot fire is worse than no guard. -Verify must NOT
# rebuild first, or it would overwrite the very drift it exists to catch.
$ckPath = Join-Path $Out 'CHECKSUMS.txt'

if (-not $Verify) {
    New-Dir $Out
    foreach ($t in $Targets) { Write-Utf8 -Path $t.Path -Text $t.Text }

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
if ($Verify) {
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
        $rec = $stored | Where-Object { $_ -match ([regex]::Escape($rel) + '$') }
        if (-not $rec -or $rec -notmatch $now) { Write-Host ("  DRIFT  " + $rel) -ForegroundColor Red; $fail++ }
        else { Write-Host ("  ok     " + $rel) -ForegroundColor Green }
    }
    if ($fail -gt 0) { throw "$fail generated file(s) drifted from source. Rebuild, do not hand-edit." }
    Write-Host "  no drift" -ForegroundColor Green
}

# --- install ------------------------------------------------------------------
if ($Install) {
    Write-Host "`n=== INSTALL into each vendor's native global surface ===" -ForegroundColor Cyan
    $begin  = "<!-- BEGIN $Marker"
    $end    = "<!-- END $Marker $Version -->"

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
        if ($cur -match [regex]::Escape($begin)) {
            $pattern = [regex]::Escape($begin) + '[\s\S]*?' + [regex]::Escape($end)
            $new = [regex]::Replace($cur, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block.TrimEnd() })
        } else {
            $new = $cur.TrimEnd() + "`r`n`r`n" + $block
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
    $fileInstalls = @(
        @{
            source = Join-Path $Out 'cursor\dreameros-boot-canon.mdc'
            dest = Join-Path $env:USERPROFILE '.cursor\rules\dreameros-boot-canon.mdc'
            engine = 'Cursor global rules'
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
    )

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

    Write-Host "`n  Per-repo files remain reviewed Git artifacts." -ForegroundColor Yellow
    Write-Host "  Global Claude, Codex, Cursor, shared skills, and Agent Plugin" -ForegroundColor Yellow
    Write-Host "  discovery are installed automatically from this one source." -ForegroundColor Yellow

    Write-Host "`n  VERIFY AT THE DESTINATION, per R6. Read it back:" -ForegroundColor Cyan
    foreach ($i in $installs) {
        if (Test-Path $i.f) {
            $n = ([regex]::Matches((Get-Content $i.f -Raw), [regex]::Escape($begin))).Count
            Write-Host ("    {0} contains {1} boot-canon block(s)" -f (Split-Path $i.f -Leaf), $n)
        }
    }
    foreach ($i in $fileInstalls) {
        $same = (Get-Sha $i.source) -eq (Get-Sha $i.dest)
        Write-Host ("    {0} byte-match={1}" -f $i.engine, $same)
        if (-not $same) { throw "destination verification failed: $($i.dest)" }
    }
}
