#Requires -Version 5.1
<#
.SYNOPSIS
  Verifies or explicitly stages and installs the model-tiered-offload skill.

.DESCRIPTION
  With no switches, this script is read-only and compares the canonical source,
  Claude package mirror, and the installed Agents, Codex, and Claude carriers.
  -StagePayload copies the source tree into the package mirror. -Install copies
  a verified package into all three local carriers. Neither mode deletes files.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$AgentsHome = (Join-Path $env:USERPROFILE '.agents'),
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude'),
    [switch]$StagePayload,
    [switch]$Install
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$SkillName = 'model-tiered-offload'
$Source = Join-Path $RepoRoot "skills\$SkillName"
$Payload = Join-Path $RepoRoot "install\claude-code\payload\skills\$SkillName"
$Targets = [ordered]@{
    package = $Payload
    agents = Join-Path $AgentsHome "skills\$SkillName"
    codex = Join-Path $CodexHome "skills\$SkillName"
    claude = Join-Path $ClaudeHome "skills\$SkillName"
}
$Failures = New-Object System.Collections.Generic.List[string]
$Stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')

function Get-TreeMap([string]$Root) {
    $map = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $map }
    foreach ($file in (Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
        $map[$relative] = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    }
    return $map
}

function Compare-Tree([string]$Label, [string]$ExpectedRoot, [string]$ActualRoot) {
    if (-not (Test-Path -LiteralPath $ActualRoot -PathType Container)) {
        $Failures.Add("$Label missing: $ActualRoot")
        return
    }
    $expected = Get-TreeMap $ExpectedRoot
    $actual = Get-TreeMap $ActualRoot
    $expectedNames = @($expected.Keys)
    $actualNames = @($actual.Keys)
    $missing = @($expectedNames | Where-Object { -not $actual.Contains($_) })
    $extra = @($actualNames | Where-Object { -not $expected.Contains($_) })
    $changed = @($expectedNames | Where-Object { $actual.Contains($_) -and $actual[$_] -cne $expected[$_] })
    if ($missing.Count -or $extra.Count -or $changed.Count) {
        $Failures.Add("$Label drift: missing=$($missing -join ',') extra=$($extra -join ',') changed=$($changed -join ',')")
        return
    }
    Write-Output "PASS $Label files=$($expected.Count)"
}

function Copy-Tree([string]$Label, [string]$From, [string]$To, [bool]$BackUp) {
    if (-not (Test-Path -LiteralPath $From -PathType Container)) { throw "$Label source missing: $From" }
    foreach ($file in (Get-ChildItem -LiteralPath $From -Recurse -File | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($From.Length).TrimStart([char[]]@('\', '/'))
        $destination = Join-Path $To $relative
        $destinationDirectory = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationDirectory)) {
            if ($PSCmdlet.ShouldProcess($destinationDirectory, 'Create directory')) {
                New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
            }
        }
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash
            $destinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash
            if ($sourceHash -ceq $destinationHash) { continue }
            if ($BackUp) {
                $backupRoot = $To + '.backup-' + $Stamp
                $backup = Join-Path $backupRoot $relative
                $backupDirectory = Split-Path -Parent $backup
                if ($PSCmdlet.ShouldProcess($backup, 'Back up existing carrier file')) {
                    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
                    Copy-Item -LiteralPath $destination -Destination $backup
                }
            }
        }
        if ($PSCmdlet.ShouldProcess($destination, "Copy $Label file")) {
            Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        }
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $Source 'SKILL.md') -PathType Leaf)) {
    throw "canonical skill missing: $Source"
}

if ($StagePayload) {
    Copy-Tree -Label 'package' -From $Source -To $Payload -BackUp $false
}

if ($Install) {
    Compare-Tree -Label 'package pre-install' -ExpectedRoot $Source -ActualRoot $Payload
    if ($Failures.Count) { throw 'Refusing local install because the package mirror differs from source.' }
    foreach ($label in @('agents', 'codex', 'claude')) {
        Copy-Tree -Label $label -From $Payload -To $Targets[$label] -BackUp $true
    }
}

foreach ($label in $Targets.Keys) {
    Compare-Tree -Label $label -ExpectedRoot $Source -ActualRoot $Targets[$label]
}

if ($Failures.Count) {
    foreach ($failure in $Failures) { Write-Output "FAIL $failure" }
    exit 1
}

Write-Output 'PASS model-tiered-offload all carriers match canonical source'
