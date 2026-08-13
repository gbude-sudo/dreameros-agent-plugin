#Requires -Version 5.1
<#
.SYNOPSIS
  Installs the DreamerOS global Claude Code environment onto a Windows machine.

.DESCRIPTION
  This installer places the DreamerOS agent layer, hook gates, and canon file
  into a Claude Code home directory. It merges settings rather than replacing
  them. It backs up every file it changes. It reports what it did.

  Design rules, all load bearing:
    - Idempotent. A second run makes no further change.
    - Merge, never clobber. Existing permissions, hooks, and MCP config stay.
    - Back up before every write, with a timestamp in the file name.
    - No secrets, no tokens, no machine specific paths in the payload.
    - Fail loudly. Every failure appears in the summary and sets the exit code.

.PARAMETER ClaudeHome
  The Claude Code home directory. Default: $env:USERPROFILE\.claude

.PARAMETER RepoRoot
  The directory that holds your DreamerOS repositories. The hook gates read
  this to find repositories to check. Missing repositories are skipped safely.
  Default: $env:USERPROFILE\Documents\DreamerOS

.PARAMETER PayloadPath
  The payload directory. Default: the payload folder next to this script.

.PARAMETER DryRun
  Print every action and change nothing.

.PARAMETER Force
  Overwrite CLAUDE.md when it already exists. Without this switch the
  installer keeps your CLAUDE.md and reports it as skipped.

.PARAMETER SkipCanon
  Do not install CLAUDE.md at all.

.EXAMPLE
  .\dreameros-global-setup.ps1 -DryRun

.EXAMPLE
  .\dreameros-global-setup.ps1

.EXAMPLE
  .\dreameros-global-setup.ps1 -ClaudeHome D:\claude -RepoRoot D:\code\DreamerOS
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ClaudeHome = (Join-Path $env:USERPROFILE '.claude'),
    [string] $RepoRoot = (Join-Path $env:USERPROFILE 'Documents\DreamerOS'),
    [string] $PayloadPath,
    [switch] $DryRun,
    [switch] $Force,
    [switch] $SkipCanon
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Result ledger. Every step records here. The summary reads only from this.
# ---------------------------------------------------------------------------
$script:Installed = New-Object System.Collections.ArrayList
$script:Skipped   = New-Object System.Collections.ArrayList
$script:Failed    = New-Object System.Collections.ArrayList
$script:Warnings  = New-Object System.Collections.ArrayList

$script:Stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')

function Write-Step {
    param([string] $Message)
    Write-Host "  $Message"
}

function Write-Head {
    param([string] $Message)
    Write-Host ""
    Write-Host "== $Message" -ForegroundColor Cyan
}

function Add-Installed { param([string] $Item, [string] $Note = '')
    [void] $script:Installed.Add([pscustomobject]@{ Item = $Item; Note = $Note }) }

function Add-Skipped { param([string] $Item, [string] $Note = '')
    [void] $script:Skipped.Add([pscustomobject]@{ Item = $Item; Note = $Note }) }

function Add-Failed { param([string] $Item, [string] $Note = '')
    [void] $script:Failed.Add([pscustomobject]@{ Item = $Item; Note = $Note }) }

function Add-Warning { param([string] $Text)
    [void] $script:Warnings.Add($Text) }

# ---------------------------------------------------------------------------
# File helpers
# ---------------------------------------------------------------------------

function Get-Utf8NoBom { return New-Object System.Text.UTF8Encoding($false) }

function Read-TextFile {
    param([Parameter(Mandatory)][string] $Path)
    return [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-TextFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Content
    )
    if ($DryRun) { Write-Step "DRYRUN would write $Path"; return }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Write file')) { return }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (Get-Utf8NoBom))
}

function Backup-File {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $backupDir = Join-Path $ClaudeHome ('backups\dreameros-install-' + $script:Stamp)
    $target = Join-Path $backupDir (Split-Path -Leaf $Path)
    # Two files with the same leaf name would collide. Disambiguate.
    $n = 1
    while (Test-Path -LiteralPath $target) {
        $target = Join-Path $backupDir ((Split-Path -Leaf $Path) + ".$n")
        $n++
    }
    if ($DryRun) { Write-Step "DRYRUN would back up $Path to $target"; return $target }
    if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $Path -Destination $target -Force
    Write-Step "backed up to $target"
    return $target
}

function Expand-Tokens {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)
    $home1 = ($ClaudeHome -replace '\\', '/').TrimEnd('/')
    $root1 = ($RepoRoot -replace '\\', '/').TrimEnd('/')
    $out = $Text.Replace('__DREAMEROS_CLAUDE_HOME__', $home1)
    $out = $out.Replace('__DREAMEROS_REPO_ROOT__', $root1)
    return $out
}

function Install-TemplatedFile {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][string] $Label,
        [switch] $OverwriteWhenDifferent
    )
    try {
        $wanted = Expand-Tokens (Read-TextFile $Source)
        if (Test-Path -LiteralPath $Destination) {
            $current = Read-TextFile $Destination
            if ($current -eq $wanted) {
                Add-Skipped $Label 'already present and identical'
                Write-Step "SKIP  $Label (identical)"
                return
            }
            if (-not $OverwriteWhenDifferent) {
                Add-Skipped $Label 'present with local changes, left alone'
                Write-Step "SKIP  $Label (local changes kept)"
                return
            }
            Backup-File $Destination | Out-Null
            Write-TextFile -Path $Destination -Content $wanted
            Add-Installed $Label 'updated, previous version backed up'
            Write-Step "UPDATE $Label"
            return
        }
        Write-TextFile -Path $Destination -Content $wanted
        Add-Installed $Label 'new'
        Write-Step "ADD   $Label"
    }
    catch {
        Add-Failed $Label $_.Exception.Message
        Write-Host "  FAIL  $Label : $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# JSON helpers. PowerShell 5.1 has no ConvertFrom-Json -AsHashtable, so build
# ordered hashtables by hand. Ordered keeps a merged file readable.
# ---------------------------------------------------------------------------

function ConvertTo-OrderedHash {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) {
            $h[$p.Name] = ConvertTo-OrderedHash $p.Value
        }
        return $h
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-OrderedHash $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $a = New-Object System.Collections.ArrayList
        foreach ($i in $InputObject) { [void] $a.Add((ConvertTo-OrderedHash $i)) }
        return , $a
    }
    return $InputObject
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string] $Path)
    $raw = Read-TextFile $Path
    if ([string]::IsNullOrWhiteSpace($raw)) { return [ordered]@{} }
    return ConvertTo-OrderedHash (ConvertFrom-Json $raw)
}

function Get-CanonicalJson {
    param($Value)
    return (ConvertTo-Json -InputObject $Value -Depth 100 -Compress)
}

function Merge-StringList {
    <#
      Union of two lists, existing order first. Returns the merged list and
      the count of genuinely new entries. This is what makes a second run a
      no-op instead of a file full of duplicates.
    #>
    param($Existing, $Incoming)
    $result = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($null -ne $Existing) {
        foreach ($e in $Existing) {
            $k = [string] $e
            if ($seen.Add($k)) { [void] $result.Add($e) }
        }
    }
    $added = 0
    if ($null -ne $Incoming) {
        foreach ($i in $Incoming) {
            $k = [string] $i
            if ($seen.Add($k)) { [void] $result.Add($i); $added++ }
        }
    }
    return [pscustomobject]@{ List = $result; Added = $added }
}

function Merge-HookEvent {
    <#
      Merge one hook event, for example PreToolUse.

      An event holds groups. A group has an optional matcher and a hooks list.
      Identity of a group is its matcher. Identity of a single hook inside a
      group is its command string for a command hook, or its prompt text for
      an agent hook. Both are compared after token expansion, so a second run
      recognises what the first run wrote.
    #>
    param($Existing, $Incoming)

    $added = 0
    $result = New-Object System.Collections.ArrayList
    if ($null -ne $Existing) { foreach ($g in $Existing) { [void] $result.Add($g) } }

    function Get-HookKey($h) {
        $hh = ConvertTo-OrderedHash $h
        if ($hh.Contains('command')) { return 'cmd:' + [string] $hh['command'] }
        if ($hh.Contains('prompt')) { return 'agent:' + [string] $hh['prompt'] }
        return 'raw:' + (Get-CanonicalJson $hh)
    }

    function Get-Matcher($g) {
        $gg = ConvertTo-OrderedHash $g
        if ($gg.Contains('matcher')) { return [string] $gg['matcher'] }
        return ''
    }

    foreach ($inGroup in $Incoming) {
        $inMatcher = Get-Matcher $inGroup
        $target = $null
        foreach ($ex in $result) {
            if ((Get-Matcher $ex) -eq $inMatcher) { $target = $ex; break }
        }
        if ($null -eq $target) {
            [void] $result.Add((ConvertTo-OrderedHash $inGroup))
            $inH = ConvertTo-OrderedHash $inGroup
            if ($inH.Contains('hooks')) { $added += @($inH['hooks']).Count }
            continue
        }
        # Group with this matcher exists. Add only hooks it does not carry.
        $targetH = ConvertTo-OrderedHash $target
        $have = New-Object 'System.Collections.Generic.HashSet[string]'
        $mergedHooks = New-Object System.Collections.ArrayList
        if ($targetH.Contains('hooks') -and $null -ne $targetH['hooks']) {
            foreach ($h in @($targetH['hooks'])) {
                [void] $have.Add((Get-HookKey $h))
                [void] $mergedHooks.Add((ConvertTo-OrderedHash $h))
            }
        }
        $inH = ConvertTo-OrderedHash $inGroup
        if ($inH.Contains('hooks') -and $null -ne $inH['hooks']) {
            foreach ($h in @($inH['hooks'])) {
                if ($have.Add((Get-HookKey $h))) {
                    [void] $mergedHooks.Add((ConvertTo-OrderedHash $h))
                    $added++
                }
            }
        }
        $targetH['hooks'] = $mergedHooks
        # Replace the group object in place.
        $idx = $result.IndexOf($target)
        $result[$idx] = $targetH
    }

    return [pscustomobject]@{ List = $result; Added = $added }
}

function Merge-Settings {
    param(
        [Parameter(Mandatory)] $Existing,
        [Parameter(Mandatory)] $Fragment
    )

    $out = $Existing
    $changes = New-Object System.Collections.ArrayList

    if (-not $out.Contains('permissions')) { $out['permissions'] = [ordered]@{} }
    $perm = $out['permissions']
    $fperm = $Fragment['permissions']

    if ($null -ne $fperm) {
        if ($fperm.Contains('defaultMode')) {
            if (-not $perm.Contains('defaultMode')) {
                $perm['defaultMode'] = $fperm['defaultMode']
                [void] $changes.Add("permissions.defaultMode set to $($fperm['defaultMode'])")
            }
            elseif ([string] $perm['defaultMode'] -ne [string] $fperm['defaultMode']) {
                # Never override an explicit operator choice here.
                Add-Warning ("permissions.defaultMode is '" + $perm['defaultMode'] +
                    "' and the DreamerOS default is '" + $fperm['defaultMode'] +
                    "'. Your value was kept.")
            }
        }
        foreach ($listName in @('deny', 'allow')) {
            if (-not $fperm.Contains($listName)) { continue }
            $cur = $null
            if ($perm.Contains($listName)) { $cur = $perm[$listName] }
            $m = Merge-StringList -Existing $cur -Incoming $fperm[$listName]
            $perm[$listName] = $m.List
            if ($m.Added -gt 0) { [void] $changes.Add("permissions.$listName gained $($m.Added) entries") }
        }
    }

    if ($Fragment.Contains('hooks')) {
        if (-not $out.Contains('hooks')) { $out['hooks'] = [ordered]@{} }
        $hooks = $out['hooks']
        foreach ($evt in $Fragment['hooks'].Keys) {
            $cur = $null
            if ($hooks.Contains($evt)) { $cur = $hooks[$evt] }
            $m = Merge-HookEvent -Existing $cur -Incoming @($Fragment['hooks'][$evt])
            $hooks[$evt] = $m.List
            if ($m.Added -gt 0) { [void] $changes.Add("hooks.$evt gained $($m.Added) hooks") }
        }
    }

    # Every other key the operator already had stays untouched. That includes
    # mcpServers, enabledPlugins, env, model, and anything a future Claude
    # Code release adds. The installer never enumerates what it may keep.

    return [pscustomobject]@{ Settings = $out; Changes = $changes }
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "DreamerOS global Claude Code environment installer" -ForegroundColor Green
Write-Host "=================================================="
if ($DryRun) {
    Write-Host "MODE: DRY RUN. Nothing on disk will change." -ForegroundColor Yellow
}
Write-Host "ClaudeHome : $ClaudeHome"
Write-Host "RepoRoot   : $RepoRoot"

if (-not $PSBoundParameters.ContainsKey('PayloadPath') -or [string]::IsNullOrWhiteSpace($PayloadPath)) {
    $PayloadPath = Join-Path $PSScriptRoot 'payload'
}
Write-Host "Payload    : $PayloadPath"

Write-Head 'Preflight'

if (-not (Test-Path -LiteralPath $PayloadPath)) {
    Write-Host "FATAL: payload directory not found at $PayloadPath" -ForegroundColor Red
    Write-Host "Run this script from the folder that contains it, or pass -PayloadPath."
    exit 2
}
Write-Step "payload found"

$bash = Get-Command bash -ErrorAction SilentlyContinue
if ($null -eq $bash) {
    Add-Warning 'bash was not found on PATH. The hook gates are bash scripts and will not run. Install Git for Windows.'
    Write-Step "WARN  bash not on PATH"
}
else {
    Write-Step "bash found at $($bash.Source)"
}

$py = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $py) {
    Add-Warning 'python was not found on PATH. The model phase boundary hook needs it and will stay silent.'
    Write-Step "WARN  python not on PATH"
}
else {
    Write-Step "python found at $($py.Source)"
}

if (-not (Test-Path -LiteralPath $RepoRoot)) {
    Add-Warning "RepoRoot $RepoRoot does not exist yet. Hooks skip repositories they cannot find, so this is safe."
    Write-Step "WARN  RepoRoot missing (safe)"
}

foreach ($d in @($ClaudeHome, (Join-Path $ClaudeHome 'agents'), (Join-Path $ClaudeHome 'hooks'))) {
    if (Test-Path -LiteralPath $d) { continue }
    if ($DryRun) { Write-Step "DRYRUN would create $d"; continue }
    if ($PSCmdlet.ShouldProcess($d, 'Create directory')) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Step "created $d"
    }
}

# ---------------------------------------------------------------------------
# Agents
# ---------------------------------------------------------------------------

Write-Head 'Agents'
$agentSrc = Join-Path $PayloadPath 'agents'
if (Test-Path -LiteralPath $agentSrc) {
    foreach ($f in (Get-ChildItem -LiteralPath $agentSrc -Filter '*.md' -File)) {
        Install-TemplatedFile -Source $f.FullName `
            -Destination (Join-Path $ClaudeHome ('agents\' + $f.Name)) `
            -Label ('agent ' + $f.BaseName) `
            -OverwriteWhenDifferent:$Force
    }
}
else {
    Add-Failed 'agents' "payload folder missing at $agentSrc"
}

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------

Write-Head 'Hooks'
$hookSrc = Join-Path $PayloadPath 'hooks'
if (Test-Path -LiteralPath $hookSrc) {
    foreach ($f in (Get-ChildItem -LiteralPath $hookSrc -File | Where-Object { $_.Extension -in @('.sh', '.py') })) {
        Install-TemplatedFile -Source $f.FullName `
            -Destination (Join-Path $ClaudeHome ('hooks\' + $f.Name)) `
            -Label ('hook ' + $f.Name) `
            -OverwriteWhenDifferent:$Force
    }
}
else {
    Add-Failed 'hooks' "payload folder missing at $hookSrc"
}

# ---------------------------------------------------------------------------
# Skills
# ---------------------------------------------------------------------------

Write-Head 'Skills'
$skillSrc = Join-Path $PayloadPath 'skills'
if (Test-Path -LiteralPath $skillSrc) {
    foreach ($d in (Get-ChildItem -LiteralPath $skillSrc -Directory)) {
        $sf = Join-Path $d.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $sf)) { continue }
        Install-TemplatedFile -Source $sf `
            -Destination (Join-Path (Join-Path (Join-Path $ClaudeHome 'skills') $d.Name) 'SKILL.md') `
            -Label ('skill ' + $d.Name) `
            -OverwriteWhenDifferent:$Force
    }
}
else {
    Add-Skipped 'skills' 'no skills folder in payload'
}

# ---------------------------------------------------------------------------
# Canon file
# ---------------------------------------------------------------------------

Write-Head 'Canon (CLAUDE.md)'
if ($SkipCanon) {
    Add-Skipped 'CLAUDE.md' 'skipped by -SkipCanon'
    Write-Step 'SKIP  CLAUDE.md (-SkipCanon)'
}
else {
    $canonSrc = Join-Path $PayloadPath 'CLAUDE.md'
    if (Test-Path -LiteralPath $canonSrc) {
        # Canon is the one file most likely to hold the operator's own words.
        # It is never overwritten without -Force.
        Install-TemplatedFile -Source $canonSrc `
            -Destination (Join-Path $ClaudeHome 'CLAUDE.md') `
            -Label 'CLAUDE.md' `
            -OverwriteWhenDifferent:$Force
    }
    else {
        Add-Failed 'CLAUDE.md' "payload file missing at $canonSrc"
    }
}

# ---------------------------------------------------------------------------
# settings.json merge. The single most important safety property in this file.
# ---------------------------------------------------------------------------

Write-Head 'settings.json merge'
$settingsPath = Join-Path $ClaudeHome 'settings.json'
$fragPath = Join-Path $PayloadPath 'settings.fragment.json'

try {
    if (-not (Test-Path -LiteralPath $fragPath)) {
        throw "settings fragment missing at $fragPath"
    }

    $fragRaw = Expand-Tokens (Read-TextFile $fragPath)
    $fragment = ConvertTo-OrderedHash (ConvertFrom-Json $fragRaw)

    $existing = [ordered]@{}
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $existing = Read-JsonFile $settingsPath
            Write-Step "read existing settings.json"
        }
        catch {
            # A settings file that does not parse must stop the merge. Writing
            # over it would destroy configuration this installer cannot read.
            throw ("existing settings.json does not parse as JSON, so the merge was refused. " +
                "Fix or move the file, then run again. Parser said: " + $_.Exception.Message)
        }
    }
    else {
        Write-Step "no existing settings.json, a new one will be created"
    }

    $before = Get-CanonicalJson $existing
    $merged = Merge-Settings -Existing $existing -Fragment $fragment
    $after = Get-CanonicalJson $merged.Settings

    if ($before -eq $after) {
        Add-Skipped 'settings.json' 'already carries every DreamerOS entry'
        Write-Step 'SKIP  settings.json (no change needed)'
    }
    else {
        foreach ($c in $merged.Changes) { Write-Step "change: $c" }
        Backup-File $settingsPath | Out-Null
        $json = ConvertTo-Json -InputObject $merged.Settings -Depth 100
        Write-TextFile -Path $settingsPath -Content ($json + "`n")
        $note = ($merged.Changes -join '; ')
        if ([string]::IsNullOrWhiteSpace($note)) { $note = 'merged' }
        Add-Installed 'settings.json' $note
        Write-Step 'MERGE settings.json'
    }
}
catch {
    Add-Failed 'settings.json' $_.Exception.Message
    Write-Host "  FAIL  settings.json : $($_.Exception.Message)" -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host "SUMMARY" -ForegroundColor Green
Write-Host "=================================================="
if ($DryRun) { Write-Host "DRY RUN. Nothing on disk changed." -ForegroundColor Yellow }

Write-Host ""
Write-Host ("INSTALLED ({0})" -f $script:Installed.Count) -ForegroundColor Green
if ($script:Installed.Count -eq 0) { Write-Host "  none" }
foreach ($i in $script:Installed) { Write-Host ("  {0}  [{1}]" -f $i.Item, $i.Note) }

Write-Host ""
Write-Host ("SKIPPED, already present ({0})" -f $script:Skipped.Count) -ForegroundColor Yellow
if ($script:Skipped.Count -eq 0) { Write-Host "  none" }
foreach ($i in $script:Skipped) { Write-Host ("  {0}  [{1}]" -f $i.Item, $i.Note) }

Write-Host ""
Write-Host ("FAILED ({0})" -f $script:Failed.Count) -ForegroundColor Red
if ($script:Failed.Count -eq 0) { Write-Host "  none" }
foreach ($i in $script:Failed) { Write-Host ("  {0}  [{1}]" -f $i.Item, $i.Note) }

if ($script:Warnings.Count -gt 0) {
    Write-Host ""
    Write-Host ("WARNINGS ({0})" -f $script:Warnings.Count) -ForegroundColor Yellow
    foreach ($w in $script:Warnings) { Write-Host "  $w" }
}

Write-Host ""
if (-not $DryRun -and $script:Failed.Count -eq 0) {
    Write-Host "Backups, when anything changed, are under:" -ForegroundColor Cyan
    Write-Host ("  " + (Join-Path $ClaudeHome ('backups\dreameros-install-' + $script:Stamp)))
    Write-Host ""
    Write-Host "Next step: set DREAMEROS_MCP_TOKEN in your user environment, then"
    Write-Host "start a new Claude Code session. This installer never handles tokens."
}

if ($script:Failed.Count -gt 0) {
    Write-Host "Install finished with failures. Exit code 1." -ForegroundColor Red
    exit 1
}
Write-Host "Install finished. Exit code 0." -ForegroundColor Green
exit 0
