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

function Assert-RealPath([string]$Path, [string]$Root, [string]$Label) {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $candidate = [IO.Path]::GetFullPath($Path)
    Assert-ChildPath -Path $candidate -Parent $rootFull -Label $Label
    while ($candidate -and $candidate.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "$Label crosses a reparse point: $candidate"
            }
        }
        if ([string]::Equals($candidate.TrimEnd('\'), $rootFull, [StringComparison]::OrdinalIgnoreCase)) { break }
        $candidate = [IO.Path]::GetDirectoryName($candidate)
    }
}

function Get-ValidatedCreatedParentDirectories($Entry, [bool]$Existed, [string]$Root, [string]$Relative) {
    $property = $Entry.PSObject.Properties['created_parent_dirs']
    if (-not $property) {
        if (-not $Existed) { throw 'Restore manifest created target is missing created_parent_dirs.' }
        return @()
    }
    $values = @($property.Value | Where-Object { $null -ne $_ })
    if ($Existed -and $values.Count -ne 0) { throw 'Restore manifest existing target cannot claim created parent directories.' }
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $segments = $Relative -split '/'
    for ($index = 1; $index -lt $segments.Count; $index++) {
        [void]$allowed.Add(($segments[0..($index - 1)] -join '/'))
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $result = @()
    foreach ($value in $values) {
        if (-not ($value -is [string])) { throw 'Restore manifest created_parent_dirs contains a non-string value.' }
        $normalized = $value.Replace('\', '/').Trim('/')
        if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized -match '(?:^|/)\.\.(?:/|$)' -or
            -not $allowed.Contains($normalized) -or -not $seen.Add($normalized)) {
            throw "Restore manifest created_parent_dirs is unsafe: $value"
        }
        $bound = [IO.Path]::GetFullPath((Join-Path $Root $normalized.Replace('/', '\')))
        Assert-ChildPath -Path $bound -Parent $Root -Label 'Restore created parent'
        $result += $normalized
    }
    return @($result)
}

function Remove-EmptyCreatedParentDirectories([string]$Root, [string[]]$RelativeDirectories) {
    foreach ($relative in @($RelativeDirectories | Sort-Object Length -Descending)) {
        $directory = [IO.Path]::GetFullPath((Join-Path $Root $relative.Replace('/', '\')))
        Assert-RealPath -Path $directory -Root $Root -Label 'Restore created parent'
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        if ((Get-ChildItem -LiteralPath $directory -Force | Measure-Object).Count -eq 0) {
            [IO.Directory]::Delete($directory, $false)
        }
    }
}

function Remove-CreatedPointerTarget($Item, [string]$PointerHash) {
    Assert-RealPath -Path $Item.Target -Root $Item.Root -Label 'Restore created target'
    if (-not (Test-Path -LiteralPath $Item.Target -PathType Leaf)) {
        throw "Restore created target is missing: $($Item.Target)"
    }
    if ((Get-SemanticSha $Item.Target) -ne $PointerHash) {
        throw "Restore target changed after migration: $($Item.Target)"
    }
    [IO.File]::Delete($Item.Target)
    if (Test-Path -LiteralPath $Item.Target) { throw "Restore created target removal failed: $($Item.Target)" }
    Remove-EmptyCreatedParentDirectories -Root $Item.Root -RelativeDirectories @($Item.CreatedParentDirs)
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
        if ($item.Removed) {
            if (Test-Path -LiteralPath $item.Target -PathType Leaf) {
                throw "Restore created target reappeared during transaction: $($item.Target)"
            }
            continue
        }
        if (-not (Test-Path -LiteralPath $item.Target -PathType Leaf)) {
            throw "Restore target is missing: $($item.Target)"
        }
        $hash = Get-SemanticSha $item.Target
        if ($hash -eq $PointerHash) {
            $expectedDirty += $item.Relative
        } elseif (-not $item.Existed -or $hash -ne $item.OriginalHash) {
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
    foreach ($field in @('target_path', 'git_root', 'git_relative', 'backup_relative')) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.$field)) { throw "Restore manifest entry is missing $field" }
    }
    if (-not $entry.PSObject.Properties['original_sha256']) { throw 'Restore manifest entry is missing original_sha256' }
    if (-not $entry.PSObject.Properties['existed'] -or $entry.existed -isnot [bool]) {
        throw 'Restore manifest entry is missing a boolean existed flag.'
    }
    $existed = [bool]$entry.existed
    $originalHash = [string]$entry.original_sha256
    if ($existed -and ($originalHash -notmatch '^[0-9a-f]{64}$')) {
        throw 'Restore manifest existing target has an invalid original_sha256.'
    }
    if (-not $existed -and -not [string]::IsNullOrEmpty($originalHash)) {
        throw 'Restore manifest newly created target must have an empty original_sha256.'
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
    Assert-RealPath -Path $target -Root $root -Label 'Restore target'
    if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) { throw "Restore Git root is not a repository: $root" }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Restore target is missing: $target" }
    $createdParentDirs = @(Get-ValidatedCreatedParentDirectories -Entry $entry -Existed $existed -Root $root -Relative $relative)
    $backup = Join-Path $backupSet ([string]$entry.backup_relative).Replace('/', '\')
    Assert-ChildPath -Path $backup -Parent $backupSet -Label 'Restore backup'
    if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) { throw "Restore backup is missing: $backup" }
    $backupItem = Get-Item -LiteralPath $backup -Force
    if ($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Restore backup cannot be a reparse point: $backup" }
    if ($existed -and (Get-SemanticSha $backup) -ne $originalHash) { throw "Restore backup hash mismatch: $backup" }
    if (-not $existed -and $backupItem.Length -ne 0) { throw "Restore new-target backup must be empty: $backup" }
    if ((Get-SemanticSha $target) -ne [string]$data.pointer_sha256) { throw "Restore target changed after migration: $target" }
    $work += [pscustomobject]@{
        Root = $root
        Target = $target
        Relative = $relative
        Backup = $backup
        OriginalHash = $originalHash
        Existed = $existed
        CreatedParentDirs = $createdParentDirs
        Removed = $false
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
        if (-not (Test-Path -LiteralPath $item.Work.Target -PathType Leaf)) {
            throw "Restore target changed immediately before write: $($item.Work.Target)"
        }
        if ((Get-SemanticSha $item.Work.Target) -ne [string]$data.pointer_sha256) {
            throw "Restore target changed immediately before write: $($item.Work.Target)"
        }
        [void]$changed.Add($item)
        if (-not $item.Work.Existed) {
            Remove-CreatedPointerTarget -Item $item.Work -PointerHash ([string]$data.pointer_sha256)
            $item.Work.Removed = $true
            continue
        }
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
        $targetExists = Test-Path -LiteralPath $item.Work.Target -PathType Leaf
        if ($targetExists -and (Get-SemanticSha $item.Work.Target) -eq [string]$data.pointer_sha256) {
            $item.Work.Removed = $false
            continue
        }
        if ($targetExists -and -not $item.Work.Existed) {
            $errors += "concurrent change prevented created-target rollback: $($item.Work.Target)"
            continue
        }
        if ($targetExists -and $item.Work.Existed -and (Get-SemanticSha $item.Work.Target) -ne $item.Work.OriginalHash) {
            $errors += "concurrent change prevented existing-target rollback: $($item.Work.Target)"
            continue
        }
        if (-not $targetExists -and $item.Work.Existed) {
            $errors += "concurrent deletion prevented existing-target rollback: $($item.Work.Target)"
            continue
        }
        try {
            Assert-RealPath -Path $item.Work.Target -Root $item.Work.Root -Label 'Restore rollback target'
            New-Item -ItemType Directory -Path (Split-Path -Parent $item.Work.Target) -Force | Out-Null
            Copy-Item -LiteralPath $item.Staging -Destination $item.Work.Target -Force
            if ((Get-SemanticSha $item.Work.Target) -ne [string]$data.pointer_sha256) {
                $errors += "staging rollback hash failed: $($item.Work.Target)"
            } else {
                $item.Work.Removed = $false
            }
        } catch {
            $errors += "staging rollback failed: $($item.Work.Target): $($_.Exception.Message)"
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
