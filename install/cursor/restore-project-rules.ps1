# Restores one completed sync-project-rules.ps1 transaction from its durable
# manifest. It refuses committed, moved, concurrently edited, or extra-dirty
# repositories and retains pre-restore staging bytes for audit and rollback.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Manifest,
    [string]$ConfirmRestore
)

$ErrorActionPreference = 'Stop'
$BackupRoot = Join-Path $env:USERPROFILE '.cursor\dreameros\project-rule-backups'
$Utf8 = New-Object Text.UTF8Encoding($false)

function Assert-ChildPath([string]$Path, [string]$Parent, [string]$Label) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escaped its managed parent: $full"
    }
}

function Get-SemanticSha([string]$Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    $bytes = $Utf8.GetBytes($text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-CurrentMain([string]$Root) {
    & git -c "safe.directory=$Root" -C $Root fetch origin --prune
    if ($LASTEXITCODE -ne 0) { throw "Fetch failed for restore repository: $Root" }
    $branch = (& git -c "safe.directory=$Root" -C $Root branch --show-current).Trim()
    $head = (& git -c "safe.directory=$Root" -C $Root rev-parse HEAD).Trim()
    $remote = (& git -c "safe.directory=$Root" -C $Root rev-parse origin/main).Trim()
    if ($branch -ne 'main' -or $head -ne $remote) {
        throw "Restore repository must remain on current origin/main: $Root branch=$branch head=$head origin/main=$remote"
    }
}

function Assert-RestoreReady([object[]]$Items, [string]$PointerHash) {
    $roots = @($Items.Root | Sort-Object -Unique)
    if ($roots.Count -ne 1) { throw 'Restore readiness check requires one repository group.' }
    $root = $roots[0]
    Assert-CurrentMain $root
    $expectedDirty = @()
    foreach ($item in $Items) {
        $hash = Get-SemanticSha $item.Target
        if ($hash -eq $PointerHash) {
            $expectedDirty += $item.Relative
        } elseif ($hash -ne $item.OriginalHash) {
            throw "Restore target changed outside the transaction: $($item.Target)"
        }
    }
    $expectedDirty = @($expectedDirty | Sort-Object -Unique)
    $status = @(& git -c "safe.directory=$root" -C $root status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw "Git status failed for restore repository: $root" }
    $actual = @($status | ForEach-Object {
        if ($_ -notmatch '^..\s+(.+)$') { throw "Unrecognized Git status during restore: $_" }
        $Matches[1].Trim('"').Replace('\', '/')
    } | Sort-Object -Unique)
    if ($actual.Count -ne $expectedDirty.Count -or @($actual | Where-Object { $expectedDirty -notcontains $_ }).Count -gt 0) {
        throw "Restore repository has changes outside the remaining manifest targets: $root status=$($status -join ' | ')"
    }
}

if ($ConfirmRestore -cne 'RESTORE REVIEWED PROJECT RULE WRITES') {
    throw 'Project-rule restore requires -ConfirmRestore "RESTORE REVIEWED PROJECT RULE WRITES".'
}
if (-not [IO.Path]::IsPathRooted($Manifest)) { throw 'Manifest must be an absolute path.' }
if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { throw "Restore manifest does not exist: $Manifest" }
$manifestPath = (Resolve-Path -LiteralPath $Manifest).Path
Assert-ChildPath -Path $manifestPath -Parent $BackupRoot -Label 'Restore manifest'
if ((Split-Path -Leaf $manifestPath) -cne 'restore-manifest.json') {
    throw 'Restore manifest filename must be restore-manifest.json.'
}
$backupSet = Split-Path -Parent $manifestPath

try { $data = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json }
catch { throw "Restore manifest is invalid JSON: $manifestPath" }
if ($data.version -ne 1 -or $data.status -ne 'migrated') {
    throw "Restore manifest must be version 1 with status migrated; found version=$($data.version) status=$($data.status)"
}
$entries = @($data.entries)
if ($entries.Count -eq 0) { throw 'Restore manifest has no entries.' }
if ([string]::IsNullOrWhiteSpace([string]$data.pointer_sha256)) { throw 'Restore manifest has no pointer hash.' }

$work = @()
$seenTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $entries) {
    foreach ($field in @('target_path', 'git_root', 'git_relative', 'original_sha256', 'backup_relative')) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.$field)) { throw "Restore manifest entry is missing $field" }
    }
    $root = [IO.Path]::GetFullPath([string]$entry.git_root).TrimEnd('\')
    $target = [IO.Path]::GetFullPath([string]$entry.target_path)
    $relative = ([string]$entry.git_relative).Replace('\', '/')
    if ([IO.Path]::IsPathRooted($relative) -or $relative.StartsWith('/') -or
        $relative -match '(?:^|/)\.\.(?:/|$)' -or
        $relative -notmatch '(?:^|/)\.cursor/rules/dreameros-boot-canon\.mdc$') {
        throw "Restore manifest git_relative is unsafe or not a managed rule path: $relative"
    }
    $boundTarget = [IO.Path]::GetFullPath((Join-Path $root $relative.Replace('/', '\')))
    if (-not [string]::Equals($boundTarget, $target, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Restore manifest target_path does not match git_root plus git_relative: $target"
    }
    if (-not $seenTargets.Add($target)) { throw "Restore manifest contains a duplicate target: $target" }
    Assert-ChildPath -Path $target -Parent $root -Label 'Restore target'
    if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) { throw "Restore Git root is not a repository: $root" }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Restore target is missing: $target" }
    $backup = Join-Path $backupSet ([string]$entry.backup_relative).Replace('/', '\')
    Assert-ChildPath -Path $backup -Parent $backupSet -Label 'Restore backup'
    if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) { throw "Restore backup is missing: $backup" }
    $backupItem = Get-Item -LiteralPath $backup -Force
    if ($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Restore backup cannot be a reparse point: $backup" }
    if ((Get-SemanticSha $backup) -ne [string]$entry.original_sha256) { throw "Restore backup hash mismatch: $backup" }
    if ((Get-SemanticSha $target) -ne [string]$data.pointer_sha256) { throw "Restore target changed after migration: $target" }
    $work += [pscustomobject]@{
        Root = $root
        Target = $target
        Relative = $relative
        Backup = $backup
        OriginalHash = [string]$entry.original_sha256
    }
}

foreach ($group in ($work | Group-Object Root)) {
    Assert-RestoreReady @($group.Group) ([string]$data.pointer_sha256)
}

$stagingRoot = Join-Path $backupSet ('pre-restore-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
Assert-ChildPath -Path $stagingRoot -Parent $backupSet -Label 'Pre-restore staging'
$staged = @()
foreach ($item in $work) {
    $keyBytes = $Utf8.GetBytes($item.Target.ToLowerInvariant())
    $keySha = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($keySha.ComputeHash($keyBytes))).Replace('-', '').Substring(0, 20).ToLowerInvariant() }
    finally { $keySha.Dispose() }
    $staging = Join-Path $stagingRoot (Join-Path $key 'dreameros-boot-canon.mdc')
    Assert-ChildPath -Path $staging -Parent $stagingRoot -Label 'Pre-restore file'
    New-Item -ItemType Directory -Path (Split-Path -Parent $staging) -Force | Out-Null
    Copy-Item -LiteralPath $item.Target -Destination $staging
    if ((Get-SemanticSha $staging) -ne [string]$data.pointer_sha256) { throw "Pre-restore staging hash failed: $staging" }
    $staged += [pscustomobject]@{ Work = $item; Staging = $staging }
}

$changed = [Collections.Generic.List[object]]::new()
$manifestReplaced = $false
$previousManifest = $null
try {
    foreach ($item in $staged) {
        $rootItems = @($work | Where-Object { $_.Root -eq $item.Work.Root })
        Assert-RestoreReady $rootItems ([string]$data.pointer_sha256)
        if ((Get-SemanticSha $item.Work.Target) -ne [string]$data.pointer_sha256) {
            throw "Restore target changed immediately before write: $($item.Work.Target)"
        }
        [void]$changed.Add($item)
        Copy-Item -LiteralPath $item.Work.Backup -Destination $item.Work.Target -Force
        if ((Get-SemanticSha $item.Work.Target) -ne $item.Work.OriginalHash) {
            throw "Restored target hash failed: $($item.Work.Target)"
        }
    }
    $data.status = 'restored'
    $data | Add-Member -NotePropertyName restored_utc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $data | Add-Member -NotePropertyName pre_restore_staging -NotePropertyValue ($stagingRoot.Substring($backupSet.Length).TrimStart('\').Replace('\', '/')) -Force
    $nextManifest = Join-Path $backupSet ('restore-manifest.next-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '.json')
    $previousManifest = Join-Path $backupSet ('restore-manifest.before-restore-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '.json')
    Assert-ChildPath -Path $nextManifest -Parent $backupSet -Label 'Next restore manifest'
    Assert-ChildPath -Path $previousManifest -Parent $backupSet -Label 'Previous restore manifest'
    [IO.File]::WriteAllText($nextManifest, ($data | ConvertTo-Json -Depth 8), $Utf8)
    $verifiedNext = [IO.File]::ReadAllText($nextManifest) | ConvertFrom-Json
    if ($verifiedNext.status -ne 'restored') { throw 'Next restore manifest did not validate before replacement.' }
    [IO.File]::Replace($nextManifest, $manifestPath, $previousManifest, $true)
    $manifestReplaced = $true
    if ($env:DREAMEROS_RESTORE_TEST_MODE -ceq '1' -and $env:DREAMEROS_RESTORE_TEST_CORRUPT_RECEIPT -ceq '1') {
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $manifestPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Receipt-failure test hook is restricted to the operating-system temp directory.'
        }
        [IO.File]::WriteAllText($manifestPath, '{broken receipt fixture', $Utf8)
    }
    $verifiedReceipt = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ($verifiedReceipt.status -ne 'restored') { throw 'Final restore manifest receipt did not validate.' }
} catch {
    $reason = $_.Exception.Message
    $errors = @()
    for ($index = $changed.Count - 1; $index -ge 0; $index--) {
        $item = $changed[$index]
        if ((Get-SemanticSha $item.Work.Target) -eq [string]$data.pointer_sha256) { continue }
        Copy-Item -LiteralPath $item.Staging -Destination $item.Work.Target -Force
        if ((Get-SemanticSha $item.Work.Target) -ne [string]$data.pointer_sha256) {
            $errors += "staging rollback hash failed: $($item.Work.Target)"
        }
    }
    if ($manifestReplaced) {
        try {
            if (-not (Test-Path -LiteralPath $previousManifest -PathType Leaf)) {
                throw 'previous manifest receipt is missing'
            }
            $failedReceipt = Join-Path $backupSet ('restore-manifest.failed-restored-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '.json')
            Assert-ChildPath -Path $failedReceipt -Parent $backupSet -Label 'Failed restored manifest receipt'
            [IO.File]::Replace($previousManifest, $manifestPath, $failedReceipt, $true)
            $rolledBackReceipt = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
            if ($rolledBackReceipt.status -ne 'migrated') { throw 'rolled-back manifest status is not migrated' }
        } catch {
            $errors += "manifest receipt rollback failed: $($_.Exception.Message)"
        }
    }
    if ($errors.Count -gt 0) { throw "Project-rule restore failed: $reason. Rollback incomplete: $($errors -join '; ')" }
    throw "Project-rule restore failed: $reason. Every changed target was returned to the generated pointer."
}
Write-Output ("RESTORED {0} project Cursor rule(s) from {1}; pre-restore staging retained at {2}" -f $work.Count, $manifestPath, $stagingRoot)
