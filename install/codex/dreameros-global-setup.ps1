#Requires -Version 5.1
<#
.SYNOPSIS
  Installs the DreamerOS native Codex control flow without replacing owner configuration.

.DESCRIPTION
  The Codex runtime discovers skills and agent TOML files from CODEX_HOME. This
  installer adds the DreamerOS-owned payload files, then merges only its exact
  hook registrations into hooks.json. It never copies sessions, auth, caches,
  logs, downloaded plugins, credentials, or repositories.

  A differing managed file is preserved and reported as MERGE NEEDED unless
  -Force is explicitly supplied. Every forced replacement is backed up and
  byte-verified. A malformed hooks.json is never rewritten.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string] $PayloadPath,
    [string] $PythonPath,
    [switch] $DryRun,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:Failures = New-Object System.Collections.ArrayList
$script:Changes = New-Object System.Collections.ArrayList
$script:Warnings = New-Object System.Collections.ArrayList
$script:Stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfffZ')

function Add-Change([string] $Text) { [void]$script:Changes.Add($Text); Write-Host "  $Text" }
function Add-Failure([string] $Text) { [void]$script:Failures.Add($Text); Write-Host "  FAIL $Text" -ForegroundColor Red }
function Add-Warning([string] $Text) { [void]$script:Warnings.Add($Text); Write-Host "  WARN $Text" -ForegroundColor Yellow }
function Get-Utf8NoBom { New-Object System.Text.UTF8Encoding($false) }

function Read-Bytes([string] $Path) { [System.IO.File]::ReadAllBytes($Path) }
function Test-ByteEqual([byte[]] $Left, [byte[]] $Right) {
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($i = 0; $i -lt $Left.Length; $i++) { if ($Left[$i] -ne $Right[$i]) { return $false } }
    return $true
}
function New-BackupPath([string] $Path) {
    $directory = Join-Path $CodexHome ('backups\\dreameros-codex-install-' + $script:Stamp)
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $target = Join-Path $directory (Split-Path -Leaf $Path)
    $suffix = 1
    while (Test-Path -LiteralPath $target) { $target = Join-Path $directory ((Split-Path -Leaf $Path) + '.' + $suffix); $suffix++ }
    return $target
}
function Backup-Exact([string] $Path, [byte[]] $Bytes) {
    $backup = New-BackupPath $Path
    [System.IO.File]::WriteAllBytes($backup, $Bytes)
    if (-not (Test-ByteEqual $Bytes (Read-Bytes $backup))) { throw "backup verification failed: $Path" }
    return $backup
}
function Expand-Tokens([string] $Text) {
    return $Text.Replace('__DREAMEROS_CODEX_HOME__', $CodexHome.Replace('\', '/'))
}
function Write-Exact([string] $Path, [byte[]] $Bytes) {
    if ($DryRun) { Add-Change "DRYRUN would write $Path"; return }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Write DreamerOS managed file')) { return }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
    if (-not (Test-ByteEqual $Bytes (Read-Bytes $Path))) { throw "destination verification failed: $Path" }
}

function Install-ManagedPayloadTree([string] $SourceRoot, [string] $DestinationRoot, [string] $Label) {
    if (-not (Test-Path -LiteralPath $SourceRoot)) { Add-Failure "$Label source missing: $SourceRoot"; return }
    foreach ($source in @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]__pycache__[\\/]|\.pyc$' } | Sort-Object FullName)) {
        $relative = $source.FullName.Substring($SourceRoot.Length).TrimStart([char[]]@([char]92, [char]47))
        $destination = Join-Path $DestinationRoot $relative
        $text = Expand-Tokens ([System.IO.File]::ReadAllText($source.FullName, (Get-Utf8NoBom)))
        $wanted = (Get-Utf8NoBom).GetBytes($text)
        if (-not (Test-Path -LiteralPath $destination)) {
            Write-Exact $destination $wanted
            Add-Change "ADD $Label/$relative"
            continue
        }
        $current = Read-Bytes $destination
        if (Test-ByteEqual $wanted $current) { Add-Change "ALIGNED $Label/$relative"; continue }
        if (-not $Force) {
            Add-Warning "MERGE NEEDED $Label/$relative differs - owner bytes preserved"
            continue
        }
        $backup = Backup-Exact $destination $current
        Write-Exact $destination $wanted
        Add-Change "HEALED $Label/$relative backup=$backup"
    }
}

function ConvertTo-OrderedHash($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) { $result[$key] = ConvertTo-OrderedHash $Value[$key] }
        return $result
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-OrderedHash $property.Value
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($item in $Value) { [void]$items.Add((ConvertTo-OrderedHash $item)) }
        return ,$items
    }
    return $Value
}
function Read-Json([string] $Path) {
    return ConvertTo-OrderedHash (ConvertFrom-Json ([System.IO.File]::ReadAllText($Path, (Get-Utf8NoBom))) -ErrorAction Stop)
}
function Get-HookKey($Hook) {
    $h = ConvertTo-OrderedHash $Hook
    foreach ($field in @('commandWindows','command','prompt')) {
        if ($h.Contains($field)) { return $field + ':' + [string]$h[$field] }
    }
    return 'raw:' + (ConvertTo-Json $h -Depth 100 -Compress)
}
function Merge-HookEvent($Existing, $Incoming) {
    $result = New-Object System.Collections.ArrayList
    foreach ($group in @($Existing)) {
        $converted = ConvertTo-OrderedHash $group
        if ($null -ne $converted) { [void]$result.Add($converted) }
    }
    $added = 0
    foreach ($incomingGroup in @($Incoming)) {
        $incomingHash = ConvertTo-OrderedHash $incomingGroup
        $matcher = if ($incomingHash.Contains('matcher')) { [string]$incomingHash['matcher'] } else { '' }
        $targetIndex = -1
        for ($i = 0; $i -lt $result.Count; $i++) {
            $candidate = ConvertTo-OrderedHash $result[$i]
            if ($null -eq $candidate) { continue }
            $candidateMatcher = if ($candidate.Contains('matcher')) { [string]$candidate['matcher'] } else { '' }
            if ($candidateMatcher -ceq $matcher) { $targetIndex = $i; break }
        }
        if ($targetIndex -lt 0) { [void]$result.Add($incomingHash); $added += @($incomingHash['hooks']).Count; continue }
        $target = ConvertTo-OrderedHash $result[$targetIndex]
        $known = New-Object 'System.Collections.Generic.HashSet[string]'
        $hooks = New-Object System.Collections.ArrayList
        foreach ($hook in @($target['hooks'])) { [void]$known.Add((Get-HookKey $hook)); [void]$hooks.Add((ConvertTo-OrderedHash $hook)) }
        foreach ($hook in @($incomingHash['hooks'])) { if ($known.Add((Get-HookKey $hook))) { [void]$hooks.Add((ConvertTo-OrderedHash $hook)); $added++ } }
        $target['hooks'] = $hooks
        $result[$targetIndex] = $target
    }
    return [pscustomobject]@{ Groups = $result; Added = $added }
}
function Merge-HooksFragment([string] $FragmentPath, [string] $DestinationPath) {
    if (-not (Test-Path -LiteralPath $FragmentPath)) { Add-Failure "hooks fragment missing: $FragmentPath"; return }
    $fragmentText = Expand-Tokens ([System.IO.File]::ReadAllText($FragmentPath, (Get-Utf8NoBom)))
    $fragment = ConvertTo-OrderedHash (ConvertFrom-Json $fragmentText -ErrorAction Stop)
    $existing = [ordered]@{ description = 'DreamerOS user hooks'; hooks = [ordered]@{} }
    if (Test-Path -LiteralPath $DestinationPath) {
        try { $existing = Read-Json $DestinationPath }
        catch { Add-Failure "MERGE NEEDED hooks.json is malformed and was preserved: $($_.Exception.Message)"; return }
    }
    if (-not $existing.Contains('hooks') -or $existing['hooks'] -isnot [System.Collections.IDictionary]) { Add-Failure 'MERGE NEEDED hooks.json has no object hooks key and was preserved'; return }
    $changes = 0
    foreach ($eventName in $fragment['hooks'].Keys) {
        $current = if ($existing['hooks'].Contains($eventName)) { $existing['hooks'][$eventName] } else { @() }
        $merged = Merge-HookEvent $current $fragment['hooks'][$eventName]
        $existing['hooks'][$eventName] = $merged.Groups
        $changes += $merged.Added
    }
    if ($changes -eq 0) { Add-Change 'ALIGNED hooks.json'; return }
    if ($DryRun -or $WhatIfPreference) {
        Add-Change "DRYRUN would merge hooks.json added=$changes"
        return
    }
    $before = if (Test-Path -LiteralPath $DestinationPath) { Read-Bytes $DestinationPath } else { $null }
    if ($null -ne $before) { $backup = Backup-Exact $DestinationPath $before } else { $backup = '' }
    $json = (ConvertTo-Json $existing -Depth 100) + "`n"
    Write-Exact $DestinationPath ((Get-Utf8NoBom).GetBytes($json))
    $verified = Read-Json $DestinationPath
    foreach ($eventName in $fragment['hooks'].Keys) {
        foreach ($group in @($fragment['hooks'][$eventName])) {
            foreach ($hook in @((ConvertTo-OrderedHash $group)['hooks'])) {
                $key = Get-HookKey $hook
                $actual = @($verified['hooks'][$eventName] | ForEach-Object { (ConvertTo-OrderedHash $_)['hooks'] } | ForEach-Object { $_ } | Where-Object { (Get-HookKey $_) -ceq $key })
                if ($actual.Count -ne 1) { throw "hooks.json post-write verification failed for $eventName/$key" }
            }
        }
    }
    Add-Change "MERGED hooks.json added=$changes backup=$backup"
}
function Merge-AgentDefaults([string] $FragmentPath, [string] $DestinationPath) {
    if (-not (Test-Path -LiteralPath $FragmentPath)) { Add-Failure "agent config fragment missing: $FragmentPath"; return }
    $fragment = [System.IO.File]::ReadAllText($FragmentPath, (Get-Utf8NoBom)).Replace("`r`n", "`n")
    $required = [ordered]@{
        'enabled' = 'true'
        'max_concurrent_threads_per_session' = '3'
        'default_subagent_model' = '"gpt-5.6-luna"'
        'default_subagent_reasoning_effort' = '"low"'
    }
    $current = if (Test-Path -LiteralPath $DestinationPath) { [System.IO.File]::ReadAllText($DestinationPath, (Get-Utf8NoBom)) } else { '' }
    $lf = $current.Replace("`r`n", "`n").Replace("`r", "`n")
    $section = [regex]::Match($lf, '(?ms)^\[agents\]\s*\n(?<body>.*?)(?=^\[[^\]]+\]|\z)')
    $missing = New-Object System.Collections.ArrayList
    if ($section.Success) {
        $body = $section.Groups['body'].Value
        foreach ($key in $required.Keys) {
            $entry = [regex]::Match($body, '(?m)^' + [regex]::Escape($key) + '\s*=\s*(?<value>[^#\r\n]+)')
            if (-not $entry.Success) { [void]$missing.Add($key); continue }
            if ($entry.Groups['value'].Value.Trim() -cne $required[$key]) { Add-Warning "MERGE NEEDED config.toml agents.$key differs - owner value preserved" }
        }
        if ($missing.Count -eq 0) { Add-Change 'ALIGNED config.toml agent defaults'; return }
        $insertion = ($missing | ForEach-Object { $_ + ' = ' + $required[$_] }) -join "`n"
        $offset = $section.Groups['body'].Index
        $lf = $lf.Insert($offset, $insertion + "`n")
    }
    else {
        $suffix = if ($lf.Length -gt 0 -and -not $lf.EndsWith("`n")) { "`n`n" } elseif ($lf.Length -gt 0) { "`n" } else { '' }
        $lf += $suffix + $fragment.TrimEnd() + "`n"
    }
    if ($DryRun -or $WhatIfPreference) {
        Add-Change 'DRYRUN would merge config.toml agent defaults'
        return
    }
    $before = if (Test-Path -LiteralPath $DestinationPath) { Read-Bytes $DestinationPath } else { $null }
    if ($null -ne $before) { $backup = Backup-Exact $DestinationPath $before } else { $backup = '' }
    Write-Exact $DestinationPath ((Get-Utf8NoBom).GetBytes($lf))
    & $PythonPath -c "import pathlib,tomllib; tomllib.loads(pathlib.Path(r'$DestinationPath').read_text(encoding='utf-8')); print('config parse ok')"
    if ($LASTEXITCODE -ne 0) { throw 'config.toml post-write parse failed' }
    Add-Change "MERGED config.toml agent defaults backup=$backup"
}

if (-not $PSBoundParameters.ContainsKey('PayloadPath') -or [string]::IsNullOrWhiteSpace($PayloadPath)) { $PayloadPath = Join-Path $PSScriptRoot 'payload' }
if (-not (Test-Path -LiteralPath $PayloadPath)) { throw "payload missing: $PayloadPath" }
if ([string]::IsNullOrWhiteSpace($PythonPath)) { $PythonPath = (Get-Command python -ErrorAction Stop).Source }
& $PythonPath -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)'
if ($LASTEXITCODE -ne 0) { throw 'Python 3.8 or newer is required before installing managed Codex Python hooks.' }

Write-Host 'DreamerOS native Codex global-flow installer'
Install-ManagedPayloadTree (Join-Path $PayloadPath 'dreameros') (Join-Path $CodexHome 'dreameros') 'dreameros'
Install-ManagedPayloadTree (Join-Path $PayloadPath 'hooks') (Join-Path $CodexHome 'dreameros\\adapters') 'adapter'
Install-ManagedPayloadTree (Join-Path $PayloadPath 'skills') (Join-Path $CodexHome 'skills') 'skill'
Install-ManagedPayloadTree (Join-Path $PayloadPath 'agents') (Join-Path $CodexHome 'agents') 'agent'
Merge-AgentDefaults (Join-Path $PayloadPath 'config.fragment.toml') (Join-Path $CodexHome 'config.toml')
Merge-HooksFragment (Join-Path $PayloadPath 'hooks.fragment.json') (Join-Path $CodexHome 'hooks.json')

Write-Host ('CHANGES={0} WARNINGS={1} FAILURES={2}' -f $script:Changes.Count, $script:Warnings.Count, $script:Failures.Count)
if ($script:Failures.Count -gt 0) { exit 1 }
exit 0
