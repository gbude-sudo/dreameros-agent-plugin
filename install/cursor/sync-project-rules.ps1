# Read-only by default. Classifies the existing tracked Cursor project rule at
# its stable path as POINTER_ALIGNED, LEGACY_FULL_COPY, or UNKNOWN. Apply mode
# keeps that path, replaces only a recognized clean legacy generator output,
# requires a reviewed current-main repository allowlist, and is transactional.
[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$ConfirmTrackedWrites,
    [string[]]$ApprovedRepository,
    [string[]]$EstateRoots,
    [string]$BackupSetId
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$PointerSource = Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-project-pointer.mdc'
$Builder = Join-Path $RepoRoot 'bootpack\build-boot-pack.ps1'
$BackupRoot = Join-Path $env:USERPROFILE '.cursor\dreameros\project-rule-backups'

if (-not $EstateRoots -or $EstateRoots.Count -eq 0) {
    $EstateRoots = @(
        (Join-Path $env:USERPROFILE 'Documents\DreamerOS'),
        (Join-Path $env:USERPROFILE 'Documents\Codex')
    )
}

if ($Apply -and $ConfirmTrackedWrites -cne 'APPLY REVIEWED PROJECT RULE WRITES') {
    throw 'Tracked project-rule writes require -ConfirmTrackedWrites "APPLY REVIEWED PROJECT RULE WRITES" after per-repo instruction and ownership review.'
}
if ($Apply -and (-not $ApprovedRepository -or $ApprovedRepository.Count -eq 0)) {
    throw 'Apply requires one or more exact -ApprovedRepository paths. Blanket estate migration is forbidden.'
}
if ($BackupSetId -and -not $Apply) {
    throw '-BackupSetId is valid only with -Apply.'
}
if ($BackupSetId -and $BackupSetId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') {
    throw 'BackupSetId must contain 1-64 ASCII letters, digits, underscores, or hyphens and must start with a letter or digit.'
}

function Get-SemanticSha([string]$Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLower()
    } finally {
        $sha.Dispose()
    }
}

function Get-StringSha([string]$Text) {
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLower()
    } finally {
        $sha.Dispose()
    }
}

function Assert-ChildPath([string]$Path, [string]$Parent, [string]$Label) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escaped its estate root: $full"
    }
}

function Get-CanonicalPath([string]$Path) {
    # Windows PowerShell 5.1 reports the children of an 8.3 short-form
    # directory (C:\Users\RUNNER~1 on GitHub runners) in long form, while
    # Resolve-Path, Join-Path and raw environment values keep the form they
    # were given. Read the longest existing prefix back from the provider so
    # every path this script compares uses the form the provider reports.
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $missing = @()
    $existing = $full
    while (-not (Test-Path -LiteralPath $existing)) {
        $parent = [IO.Path]::GetDirectoryName($existing)
        if ([string]::IsNullOrEmpty($parent)) { return $full }
        $missing = @([IO.Path]::GetFileName($existing)) + $missing
        $existing = $parent
    }
    $canonical = (Get-Item -LiteralPath $existing -Force).FullName.TrimEnd('\')
    foreach ($segment in $missing) { $canonical = Join-Path $canonical $segment }
    return $canonical
}

function Find-GitRoot([string]$Path) {
    $current = Get-Item -LiteralPath (Split-Path -Parent $Path)
    while ($current) {
        if (Test-Path -LiteralPath (Join-Path $current.FullName '.git')) {
            return $current.FullName
        }
        $current = $current.Parent
    }
    return $null
}

function Get-JsonStringValues($Value) {
    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        Write-Output $Value
        return
    }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { Get-JsonStringValues $Value[$key] }
        return
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) { Get-JsonStringValues $property.Value }
        return
    }
    if ($Value -is [Collections.IEnumerable]) {
        foreach ($item in $Value) { Get-JsonStringValues $item }
    }
}

function Test-RegistryTracksProjectRule([string]$Path) {
    try {
        $registry = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    } catch {
        throw "Canon registry is unreadable or invalid JSON: $Path"
    }
    foreach ($value in @(Get-JsonStringValues $registry)) {
        $normalized = ([regex]::Replace($value.Replace('\', '/'), '/+', '/')).ToLowerInvariant()
        if ($normalized.Contains('.cursor/rules/dreameros-boot-canon.mdc')) { return $true }
    }
    return $false
}

function Get-ProjectRuleState([string]$Path, [string]$ExpectedHash) {
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not $item.PSIsContainer -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            return 'UNKNOWN'
        }
        $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    } catch {
        return 'UNKNOWN'
    }
    if ((Get-SemanticSha $Path) -eq $ExpectedHash) { return 'POINTER_ALIGNED' }
    if ($text.Contains('DREAMEROS-PROJECT-BOOT-POINTER')) { return 'UNKNOWN' }
    $legacy =
        $text.Length -ge 5000 -and
        $text -match '(?m)^alwaysApply:\s*true\s*$' -and
        $text -match '(?m)^# DreamerOS Boot Canon v[0-9]+\.[0-9]+\.[0-9]+\s*$' -and
        $text.Contains('SINGLE SOURCE OF TRUTH. Every vendor file is generated from this one.') -and
        $text.Contains('## R1 - ANSWER FROM MEASUREMENT, NEVER FROM MEMORY') -and
        $text.Contains('HC-DEFINITION-OF-DONE')
    if ($legacy) { return 'LEGACY_FULL_COPY' }
    return 'UNKNOWN'
}

function Assert-CurrentMain([string]$Root) {
    & git -c "safe.directory=$Root" -C $Root fetch origin --prune
    if ($LASTEXITCODE -ne 0) { throw "Fetch failed for approved repository: $Root" }
    $branch = (& git -c "safe.directory=$Root" -C $Root branch --show-current).Trim()
    $head = (& git -c "safe.directory=$Root" -C $Root rev-parse HEAD).Trim()
    $remote = (& git -c "safe.directory=$Root" -C $Root rev-parse origin/main).Trim()
    if ($branch -ne 'main' -or $head -ne $remote) {
        throw "Approved repository must be cleanly based on current origin/main: $Root branch=$branch head=$head origin/main=$remote"
    }
}

function Assert-OnlyTransactionChanges([string]$Root, [object[]]$ChangedItems) {
    $expected = @($ChangedItems | Where-Object { $_.Record.GitRoot -eq $Root } |
        ForEach-Object { $_.Record.Relative.Replace('\', '/') } | Sort-Object -Unique)
    $status = @(& git -c "safe.directory=$Root" -C $Root status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw "Whole-repository write-time recheck failed for $Root" }
    $actual = @($status | ForEach-Object {
        if ($_ -notmatch '^..\s+(.+)$') { throw "Unrecognized Git status during transaction: $_" }
        $Matches[1].Trim('"').Replace('\', '/')
    } | Sort-Object -Unique)
    if ($actual.Count -ne $expected.Count -or @($actual | Where-Object { $expected -notcontains $_ }).Count -gt 0) {
        throw "Repository changed outside this transaction before write: $Root status=$($status -join ' | ')"
    }
}

& $Builder -Verify

$resolvedRoots = @()
foreach ($root in $EstateRoots) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    $resolvedRoots += Get-CanonicalPath $root
}
if ($resolvedRoots.Count -eq 0) { throw 'No requested estate roots exist.' }

$gitRepos = @()
foreach ($root in $resolvedRoots) {
    if (Test-Path -LiteralPath (Join-Path $root '.git')) { $gitRepos += $root }
    foreach ($child in (Get-ChildItem -LiteralPath $root -Directory -Force)) {
        if (Test-Path -LiteralPath (Join-Path $child.FullName '.git')) { $gitRepos += $child.FullName }
    }
}
$gitRepos = @($gitRepos | Sort-Object -Unique)
if ($gitRepos.Count -eq 0) { throw 'No Git repositories were discovered at the requested estate roots or their direct children.' }

$targets = @()
foreach ($root in $resolvedRoots) {
    $targets += Get-ChildItem -LiteralPath $root -Filter 'dreameros-boot-canon.mdc' -File -Recurse -Force |
        Where-Object {
            $_.FullName -match '\\.cursor\\rules\\dreameros-boot-canon\.mdc$' -and
            $_.FullName -notmatch '\\(?:\.git|node_modules|\.claude\\worktrees|\.codex\\worktrees)\\'
        }
}
$targets = @($targets | Sort-Object FullName -Unique)
if ($targets.Count -eq 0) {
    if ($Apply) { throw 'No per-repository Cursor boot rules were discovered for Apply.' }
    Write-Output ("VERIFIED GLOBAL_ONLY across {0} Git repository/repositories; no per-repository Cursor boot rule exists." -f $gitRepos.Count)
    exit 0
}

$pointerHash = Get-SemanticSha $PointerSource
$records = @()
foreach ($target in $targets) {
    $estateRoot = $resolvedRoots | Where-Object {
        $target.FullName.StartsWith(($_.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object Length -Descending | Select-Object -First 1
    if (-not $estateRoot) { throw "No estate root owns $($target.FullName)" }
    Assert-ChildPath -Path $target.FullName -Parent $estateRoot -Label 'Project rule target'

    $gitRoot = Find-GitRoot $target.FullName
    if (-not $gitRoot) { throw "Project rule is not inside a Git repository: $($target.FullName)" }
    $relative = $target.FullName.Substring($gitRoot.Length).TrimStart([char[]]@('\', '/'))
    $status = @(& git -c "safe.directory=$gitRoot" -C $gitRoot status --porcelain=v1 -- $relative)
    if ($LASTEXITCODE -ne 0) { throw "Git status failed for $($target.FullName)" }

    $state = Get-ProjectRuleState -Path $target.FullName -ExpectedHash $pointerHash
    $records += [pscustomobject]@{
        EstateRoot = $estateRoot
        GitRoot = $gitRoot
        Relative = $relative
        Path = $target.FullName
        OriginalHash = Get-SemanticSha $target.FullName
        Dirty = $status.Count -gt 0
        Status = ($status -join ' ')
        State = $state
    }
}

foreach ($record in $records) {
    $ownership = if ($record.Dirty) { "DIRTY $($record.Status)" } else { 'FILE-CLEAN' }
    Write-Output ("{0} {1} sha256={2} {3}" -f $record.State, $ownership, $record.OriginalHash, $record.Path)
}

if (-not $Apply) {
    $notAligned = @($records | Where-Object { $_.State -ne 'POINTER_ALIGNED' -or $_.Dirty })
    if ($notAligned.Count -gt 0) {
        $legacyCount = @($notAligned | Where-Object { $_.State -eq 'LEGACY_FULL_COPY' }).Count
        $unknownCount = @($notAligned | Where-Object { $_.State -eq 'UNKNOWN' }).Count
        $dirtyCount = @($notAligned | Where-Object { $_.Dirty }).Count
        throw "$($notAligned.Count) project Cursor pointer(s) are not aligned and file-clean: LEGACY_FULL_COPY=$legacyCount UNKNOWN=$unknownCount DIRTY=$dirtyCount."
    }
    Write-Output ("VERIFIED {0} POINTER_ALIGNED FILE-CLEAN project Cursor rule(s)" -f $records.Count)
    exit 0
}

$approved = @($ApprovedRepository | ForEach-Object {
    if (-not (Test-Path -LiteralPath $_ -PathType Container)) { throw "Approved repository does not exist: $_" }
    Get-CanonicalPath $_
} | Sort-Object -Unique)
$knownGitRoots = @($records.GitRoot | Sort-Object -Unique)
$approvedRecords = @($records | Where-Object { $approved -contains $_.GitRoot })
$unknown = @($approvedRecords | Where-Object { $_.State -eq 'UNKNOWN' })
if ($unknown.Count -gt 0) {
    throw "$($unknown.Count) approved project rule(s) have UNKNOWN content. No project file was changed."
}
foreach ($root in $approved) {
    if ($knownGitRoots -notcontains $root) { throw "Approved repository has no managed project rule: $root" }
    foreach ($registryName in @('Governance\CANON_REGISTRY.json', 'governance\CANON_REGISTRY.json')) {
        $registry = Join-Path $root $registryName
        if ((Test-Path -LiteralPath $registry -PathType Leaf) -and
            (Test-RegistryTracksProjectRule $registry)) {
            throw "Approved repository tracks the project rule in $registryName. Migrate the rule and registry atomically in a reviewed repo change; this synchronizer will not create registry drift."
        }
    }
    Assert-CurrentMain $root
    $repoStatus = @(& git -c "safe.directory=$root" -C $root status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw "Whole-repository status failed for approved repository: $root" }
    if ($repoStatus.Count -gt 0) {
        throw "Approved repository must have a fully clean worktree before migration: $root status=$($repoStatus -join ' | ')"
    }
}

$workRecords = @($approvedRecords | Where-Object { $_.State -eq 'LEGACY_FULL_COPY' })
if ($workRecords.Count -eq 0) { throw 'No approved LEGACY_FULL_COPY project rules require migration.' }

$blocked = @($workRecords | Where-Object { $_.Dirty })
if ($blocked.Count -gt 0) {
    throw "$($blocked.Count) approved legacy project rule(s) have local edits. No project file was changed."
}

$resolvedBackupSetId = if ($BackupSetId) {
    $BackupSetId
} else {
    '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmssfff'), ([guid]::NewGuid().ToString('N').Substring(0, 12))
}
$backupSet = Join-Path $BackupRoot $resolvedBackupSetId
Assert-ChildPath -Path $backupSet -Parent $BackupRoot -Label 'Project rule backup set'
$null = [IO.Directory]::CreateDirectory($BackupRoot)
$backupRootItem = Get-Item -LiteralPath $BackupRoot -Force
if (-not $backupRootItem.PSIsContainer -or
    ($backupRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Project rule backup root must be a real directory, not a file or reparse point: $BackupRoot"
}
try {
    $createdBackupSet = New-Item -ItemType Directory -Path $backupSet -ErrorAction Stop
} catch {
    throw "Backup set already exists or could not be exclusively created: $backupSet. No project file was changed."
}
if (-not $createdBackupSet.PSIsContainer -or
    (Get-ChildItem -LiteralPath $backupSet -Force | Measure-Object).Count -ne 0) {
    throw "Exclusively created backup set is not an empty directory: $backupSet. No project file was changed."
}
$encoding = New-Object Text.UTF8Encoding($false)
$pointerText = [IO.File]::ReadAllText($PointerSource).Replace("`r`n", "`n").Replace("`r", "`n")
$work = @()

foreach ($record in $workRecords) {
    Assert-CurrentMain $record.GitRoot
    $repoStatusNow = @(& git -c "safe.directory=$($record.GitRoot)" -C $record.GitRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw "Whole-repository recheck failed for $($record.GitRoot)" }
    if ($repoStatusNow.Count -gt 0) {
        throw "Repository changed after approval preflight. No project file was written: $($record.GitRoot) status=$($repoStatusNow -join ' | ')"
    }
    $statusNow = @(& git -c "safe.directory=$($record.GitRoot)" -C $record.GitRoot status --porcelain=v1 -- $record.Relative)
    if ($LASTEXITCODE -ne 0) { throw "Git recheck failed for $($record.Path)" }
    $stateNow = Get-ProjectRuleState -Path $record.Path -ExpectedHash $pointerHash
    if ($statusNow.Count -gt 0 -or (Get-SemanticSha $record.Path) -ne $record.OriginalHash -or $stateNow -ne 'LEGACY_FULL_COPY') {
        throw "Project rule changed after preflight. No project file was written: $($record.Path)"
    }

    $pathKey = (Get-StringSha $record.Path.ToLowerInvariant()).Substring(0, 20)
    $backup = Join-Path $backupSet (Join-Path $pathKey 'dreameros-boot-canon.mdc')
    Assert-ChildPath -Path $backup -Parent $backupSet -Label 'Project rule backup'
    New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
    Copy-Item -LiteralPath $record.Path -Destination $backup
    $work += [pscustomobject]@{ Record = $record; Backup = $backup }
}

$manifestPath = Join-Path $backupSet 'restore-manifest.json'
$manifest = [ordered]@{
    version = 1
    status = 'prepared'
    created_utc = [DateTime]::UtcNow.ToString('o')
    completed_utc = $null
    pointer_sha256 = $pointerHash
    entries = @($work | ForEach-Object {
        [ordered]@{
            target_path = $_.Record.Path
            git_root = $_.Record.GitRoot
            git_relative = $_.Record.Relative.Replace('\', '/')
            original_sha256 = $_.Record.OriginalHash
            backup_relative = $_.Backup.Substring($backupSet.Length).TrimStart('\').Replace('\', '/')
        }
    })
}
function Write-RestoreManifest([string]$Status) {
    $manifest['status'] = $Status
    if ($Status -ne 'prepared') { $manifest['completed_utc'] = [DateTime]::UtcNow.ToString('o') }
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), $encoding)
}
Write-RestoreManifest 'prepared'

$changed = [Collections.Generic.List[object]]::new()
try {
    foreach ($item in $work) {
        $record = $item.Record
        Assert-CurrentMain $record.GitRoot
        Assert-OnlyTransactionChanges -Root $record.GitRoot -ChangedItems @($changed)
        $statusNow = @(& git -c "safe.directory=$($record.GitRoot)" -C $record.GitRoot status --porcelain=v1 -- $record.Relative)
        if ($LASTEXITCODE -ne 0) { throw "Git write-time recheck failed for $($record.Path)" }
        $stateNow = Get-ProjectRuleState -Path $record.Path -ExpectedHash $pointerHash
        if ($statusNow.Count -gt 0 -or (Get-SemanticSha $record.Path) -ne $record.OriginalHash -or $stateNow -ne 'LEGACY_FULL_COPY') {
            throw "Project rule changed before write: $($record.Path)"
        }

        [void]$changed.Add($item)
        [IO.File]::WriteAllText($record.Path, $pointerText, $encoding)
        if ((Get-SemanticSha $record.Path) -ne $pointerHash -or
            (Get-ProjectRuleState -Path $record.Path -ExpectedHash $pointerHash) -ne 'POINTER_ALIGNED') {
            throw "Destination verification failed after writing $($record.Path)"
        }
        Write-Output ("POINTER_ALIGNED PROJECT RULE {0} backup={1}" -f $record.Path, $item.Backup)
    }

    foreach ($item in $work) {
        if ((Get-SemanticSha $item.Record.Path) -ne $pointerHash) {
            throw "Final transaction verification failed for $($item.Record.Path)"
        }
    }
    Write-RestoreManifest 'migrated'
} catch {
    $reason = $_.Exception.Message
    $rollbackErrors = @()
    for ($index = $changed.Count - 1; $index -ge 0; $index--) {
        $item = $changed[$index]
        $record = $item.Record
        $currentHash = Get-SemanticSha $record.Path
        if ($currentHash -eq $record.OriginalHash) { continue }
        if ($currentHash -ne $pointerHash) {
            $rollbackErrors += "concurrent change prevented rollback: $($record.Path)"
            continue
        }
        Copy-Item -LiteralPath $item.Backup -Destination $record.Path -Force
        if ((Get-SemanticSha $record.Path) -ne $record.OriginalHash) {
            $rollbackErrors += "backup restore hash failed: $($record.Path)"
        }
    }
    if ($rollbackErrors.Count -gt 0) {
        throw "Project-rule apply failed: $reason. Rollback incomplete: $($rollbackErrors -join '; ')"
    }
    Write-RestoreManifest 'rolled_back'
    throw "Project-rule apply failed: $reason. Every file written by this run was restored."
}

Write-Output ("MIGRATED {0} approved project Cursor rule(s) to POINTER_ALIGNED; backup set {1}; restore manifest {2}" -f $workRecords.Count, $backupSet, $manifestPath)
