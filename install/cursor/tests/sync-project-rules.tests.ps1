$ErrorActionPreference = 'Stop'

# GitHub's windows runner exposes TEMP in 8.3 short form under RUNNER~1.
# Windows PowerShell 5.1 expands that form when it reports children, so a
# fixture path built from the raw value compares unequal to Get-ChildItem
# output. Both engines must also receive identical fixture paths. Ask Win32
# for the long form once and build every fixture path from it.
if (-not ('DreamerOS.Tests.Win32Path' -as [type])) {
    Add-Type -Namespace DreamerOS.Tests -Name Win32Path -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern uint GetLongPathNameW(string shortPath, System.Text.StringBuilder longPath, uint bufferLength);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern uint GetShortPathNameW(string longPath, System.Text.StringBuilder shortPath, uint bufferLength);
'@
}

function Get-LongPath([string]$Path) {
    $buffer = New-Object Text.StringBuilder 32768
    $length = [DreamerOS.Tests.Win32Path]::GetLongPathNameW($Path, $buffer, $buffer.Capacity)
    if ($length -eq 0 -or $length -gt $buffer.Capacity) { throw "GetLongPathNameW failed for $Path" }
    return $buffer.ToString()
}

function Get-ShortPath([string]$Path) {
    $buffer = New-Object Text.StringBuilder 32768
    $length = [DreamerOS.Tests.Win32Path]::GetShortPathNameW($Path, $buffer, $buffer.Capacity)
    if ($length -eq 0 -or $length -gt $buffer.Capacity) { throw "GetShortPathNameW failed for $Path" }
    return $buffer.ToString()
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$SyncScript = Join-Path $RepoRoot 'install\cursor\sync-project-rules.ps1'
$RestoreScript = Join-Path $RepoRoot 'install\cursor\restore-project-rules.ps1'
$BuildScript = Join-Path $RepoRoot 'bootpack\build-boot-pack.ps1'
$Pointer = Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-project-pointer.mdc'
$Legacy = Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-boot-canon.mdc'
$PowerShellExe = (Get-Process -Id $PID).Path
$TempRoot = Join-Path (Get-LongPath $env:TEMP) ('dreameros-pointer-tests-' + [guid]::NewGuid().ToString('N'))
$TestHome = Join-Path $TempRoot 'home'
$Utf8 = New-Object Text.UTF8Encoding($false)
$Cases = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:Cases++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Get-SemanticSha([string]$Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    $bytes = $Utf8.GetBytes($text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLower() }
    finally { $sha.Dispose() }
}

function New-FixtureRepo([string]$Estate, [string]$Name, [string]$Content, [bool]$UseCrLf = $false) {
    $repo = Join-Path $Estate $Name
    $rule = Join-Path $repo '.cursor\rules\dreameros-boot-canon.mdc'
    New-Item -ItemType Directory -Path (Split-Path -Parent $rule) -Force | Out-Null
    $rendered = if ($UseCrLf) { $Content.Replace("`r`n", "`n").Replace("`n", "`r`n") } else { $Content.Replace("`r`n", "`n") }
    [IO.File]::WriteAllText($rule, $rendered, $Utf8)

    & git -C $repo init -b main --quiet
    if ($LASTEXITCODE -ne 0) { throw "git init failed: $repo" }
    & git -C $repo config user.email 'pointer-test@dreameros.invalid'
    & git -C $repo config user.name 'DreamerOS Pointer Test'
    & git -C $repo add .
    & git -C $repo commit -m fixture --quiet
    if ($LASTEXITCODE -ne 0) { throw "fixture commit failed: $repo" }

    $bare = Join-Path $Estate ($Name + '-origin.git')
    & git init --bare $bare --quiet
    & git -C $repo remote add origin $bare
    & git -C $repo push -u origin main --quiet
    if ($LASTEXITCODE -ne 0) { throw "fixture push failed: $repo" }
    return [pscustomobject]@{ Repo = $repo; Rule = $rule; Origin = $bare }
}

function Invoke-Sync(
    [string]$Estate,
    [string[]]$Approved = @(),
    [string]$Confirmation = '',
    [string]$BackupSetId = ''
) {
    $command = "`$env:USERPROFILE='$TestHome'; & '$SyncScript' -EstateRoots '$Estate'"
    if ($Approved.Count -gt 0) {
        $quoted = ($Approved | ForEach-Object { "'$_'" }) -join ','
        $command += " -Apply -ApprovedRepository @($quoted) -ConfirmTrackedWrites '$Confirmation'"
    }
    if ($BackupSetId) { $command += " -BackupSetId '$BackupSetId'" }
    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $priorPreference
    }
    return [pscustomobject]@{ ExitCode = $code; Text = ($output -join "`n") }
}

function Invoke-Restore([string]$Manifest, [string]$Confirmation = '', [bool]$InduceReceiptFailure = $false) {
    $testEnv = if ($InduceReceiptFailure) { "`$env:DREAMEROS_RESTORE_TEST_MODE='1'; `$env:DREAMEROS_RESTORE_TEST_CORRUPT_RECEIPT='1'; " } else { '' }
    $command = "`$env:USERPROFILE='$TestHome'; $testEnv& '$RestoreScript' -Manifest '$Manifest' -ConfirmRestore '$Confirmation'"
    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $priorPreference
    }
    return [pscustomobject]@{ ExitCode = $code; Text = ($output -join "`n") }
}

New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
$pointerText = [IO.File]::ReadAllText($Pointer)
$legacyText = [IO.File]::ReadAllText($Legacy)

# Mixed-state census proves each classifier, including line-ending normalization.
$census = Join-Path $TempRoot 'census'
New-Item -ItemType Directory -Path $census | Out-Null
$aligned = New-FixtureRepo $census 'aligned' $pointerText
$alignedCrLf = New-FixtureRepo $census 'aligned-crlf' $pointerText $true
$dirtyPointer = New-FixtureRepo $census 'dirty-pointer' $pointerText
[IO.File]::WriteAllText($dirtyPointer.Rule, $pointerText.Replace("`r`n", "`n").Replace("`n", "`r`n"), $Utf8)
$legacyRepo = New-FixtureRepo $census 'legacy' $legacyText
$dirtyLegacy = New-FixtureRepo $census 'dirty-legacy' $legacyText
[IO.File]::AppendAllText($dirtyLegacy.Rule, "`nlocal owner edit", $Utf8)
$unknown = New-FixtureRepo $census 'unknown' "---`nalwaysApply: true`n---`ncustom project rule"
$driftedPointer = New-FixtureRepo $census 'drifted-pointer' ($pointerText + "`ncustom drift")

$censusResult = Invoke-Sync $census
Assert-True ($censusResult.ExitCode -ne 0) 'mixed census must fail'
Assert-True ($censusResult.Text -match 'POINTER_ALIGNED FILE-CLEAN') 'aligned pointer state missing'
Assert-True ($censusResult.Text -match 'POINTER_ALIGNED DIRTY') 'dirty pointer state missing'
Assert-True ($censusResult.Text -match 'LEGACY_FULL_COPY FILE-CLEAN') 'legacy state missing'
Assert-True ($censusResult.Text -match 'LEGACY_FULL_COPY DIRTY') 'dirty legacy state missing'
Assert-True ($censusResult.Text -match 'UNKNOWN FILE-CLEAN') 'unknown state missing'
Assert-True ($censusResult.Text -match 'LEGACY_FULL_COPY=2 UNKNOWN=2 DIRTY=2') 'aggregate state counts wrong'
Assert-True ((Get-SemanticSha $aligned.Rule) -eq (Get-SemanticSha $alignedCrLf.Rule)) 'CRLF pointer must normalize'

# GitHub runners hand the sync tool estate roots in 8.3 short form. Ownership
# of each discovered rule must still resolve when the root arrives that way.
$censusShort = Invoke-Sync (Get-ShortPath $census)
Assert-True ($censusShort.Text -match 'POINTER_ALIGNED FILE-CLEAN') "census failed with short-form estate root: $($censusShort.Text)"

# A real Git estate with no project boot rule is intentionally GLOBAL_ONLY.
$globalOnlyEstate = Join-Path $TempRoot 'global-only'
$globalOnlyRepo = Join-Path $globalOnlyEstate 'repo'
New-Item -ItemType Directory -Path $globalOnlyRepo -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $globalOnlyRepo 'README.md'), 'global only fixture', $Utf8)
& git -C $globalOnlyRepo init -b main --quiet
& git -C $globalOnlyRepo config user.email 'pointer-test@dreameros.invalid'
& git -C $globalOnlyRepo config user.name 'DreamerOS Pointer Test'
& git -C $globalOnlyRepo add .
& git -C $globalOnlyRepo commit -m fixture --quiet
$globalOnlyResult = Invoke-Sync $globalOnlyEstate
Assert-True ($globalOnlyResult.ExitCode -eq 0) "GLOBAL_ONLY census failed: $($globalOnlyResult.Text)"
Assert-True ($globalOnlyResult.Text -match 'VERIFIED GLOBAL_ONLY across 1 Git repository') 'GLOBAL_ONLY success signature missing'
$globalOnlyApply = Invoke-Sync $globalOnlyEstate @($globalOnlyRepo) 'APPLY REVIEWED PROJECT RULE WRITES'
Assert-True ($globalOnlyApply.ExitCode -ne 0) 'Apply with no project rule must fail'
Assert-True ($globalOnlyApply.Text -match 'No per-repository Cursor boot rules were discovered for Apply') 'GLOBAL_ONLY Apply refusal missing'

# Wrong confirmation cannot mutate an otherwise eligible repository.
$wrongConfirmEstate = Join-Path $TempRoot 'wrong-confirm'
New-Item -ItemType Directory -Path $wrongConfirmEstate | Out-Null
$wrongConfirmRepo = New-FixtureRepo $wrongConfirmEstate 'repo' $legacyText
$wrongBefore = Get-SemanticSha $wrongConfirmRepo.Rule
$wrongResult = Invoke-Sync $wrongConfirmEstate @($wrongConfirmRepo.Repo) 'WRONG'
Assert-True ($wrongResult.ExitCode -ne 0) 'wrong confirmation must fail'
Assert-True ((Get-SemanticSha $wrongConfirmRepo.Rule) -eq $wrongBefore) 'wrong confirmation changed target'

# UNKNOWN and locally edited legacy content must never enter Apply.
$unknownApplyEstate = Join-Path $TempRoot 'unknown-apply'
New-Item -ItemType Directory -Path $unknownApplyEstate | Out-Null
$unknownApplyRepo = New-FixtureRepo $unknownApplyEstate 'repo' "---`nalwaysApply: true`n---`ncustom project rule"
$unknownApplyBefore = Get-SemanticSha $unknownApplyRepo.Rule
$unknownApplyResult = Invoke-Sync $unknownApplyEstate @($unknownApplyRepo.Repo) 'APPLY REVIEWED PROJECT RULE WRITES'
Assert-True ($unknownApplyResult.ExitCode -ne 0) 'UNKNOWN Apply must fail'
Assert-True ((Get-SemanticSha $unknownApplyRepo.Rule) -eq $unknownApplyBefore) 'UNKNOWN Apply changed target'

$dirtyApplyEstate = Join-Path $TempRoot 'dirty-apply'
New-Item -ItemType Directory -Path $dirtyApplyEstate | Out-Null
$dirtyApplyRepo = New-FixtureRepo $dirtyApplyEstate 'repo' $legacyText
[IO.File]::AppendAllText($dirtyApplyRepo.Rule, "`nlocal owner edit", $Utf8)
$dirtyApplyBefore = Get-SemanticSha $dirtyApplyRepo.Rule
$dirtyApplyResult = Invoke-Sync $dirtyApplyEstate @($dirtyApplyRepo.Repo) 'APPLY REVIEWED PROJECT RULE WRITES'
Assert-True ($dirtyApplyResult.ExitCode -ne 0) 'dirty legacy Apply must fail'
Assert-True ((Get-SemanticSha $dirtyApplyRepo.Rule) -eq $dirtyApplyBefore) 'dirty legacy Apply changed target'

$unrelatedDirtyEstate = Join-Path $TempRoot 'unrelated-dirty-apply'
New-Item -ItemType Directory -Path $unrelatedDirtyEstate | Out-Null
$unrelatedDirtyRepo = New-FixtureRepo $unrelatedDirtyEstate 'repo' $legacyText
[IO.File]::WriteAllText((Join-Path $unrelatedDirtyRepo.Repo 'unrelated.txt'), 'parallel owner work', $Utf8)
$unrelatedDirtyBefore = Get-SemanticSha $unrelatedDirtyRepo.Rule
$unrelatedDirtyResult = Invoke-Sync $unrelatedDirtyEstate @($unrelatedDirtyRepo.Repo) 'APPLY REVIEWED PROJECT RULE WRITES'
Assert-True ($unrelatedDirtyResult.ExitCode -ne 0) 'unrelated dirty Apply must fail'
Assert-True ($unrelatedDirtyResult.Text -match 'fully clean worktree') 'whole-repository clean gate signature missing'
Assert-True ((Get-SemanticSha $unrelatedDirtyRepo.Rule) -eq $unrelatedDirtyBefore) 'unrelated dirty Apply changed target'

$registryEstate = Join-Path $TempRoot 'registry-gated'
New-Item -ItemType Directory -Path $registryEstate | Out-Null
$registryRepo = New-FixtureRepo $registryEstate 'repo' $legacyText
$registryPath = Join-Path $registryRepo.Repo 'Governance\CANON_REGISTRY.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $registryPath) -Force | Out-Null
[IO.File]::WriteAllText($registryPath, '{"files":[{"path":".cursor/rules/dreameros-boot-canon.mdc"}]}', $Utf8)
& git -C $registryRepo.Repo add Governance/CANON_REGISTRY.json
& git -C $registryRepo.Repo commit -m registry --quiet
& git -C $registryRepo.Repo push origin main --quiet
$registryBefore = Get-SemanticSha $registryRepo.Rule
$registryResult = Invoke-Sync $registryEstate @($registryRepo.Repo) 'APPLY REVIEWED PROJECT RULE WRITES'
Assert-True ($registryResult.ExitCode -ne 0) 'registry-tracked Apply must fail'
Assert-True ($registryResult.Text -match 'will not create registry drift') 'registry companion gate signature missing'
Assert-True ((Get-SemanticSha $registryRepo.Rule) -eq $registryBefore) 'registry gate changed target'

$registryBackslashEstate = Join-Path $TempRoot 'registry-backslash-gated'
New-Item -ItemType Directory -Path $registryBackslashEstate | Out-Null
$registryBackslashRepo = New-FixtureRepo $registryBackslashEstate 'repo' $legacyText
$registryBackslashPath = Join-Path $registryBackslashRepo.Repo 'Governance\CANON_REGISTRY.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $registryBackslashPath) -Force | Out-Null
[IO.File]::WriteAllText($registryBackslashPath, '{"files":[{"path":".CURSOR\\RULES\\DreamerOS-Boot-Canon.mdc"}]}', $Utf8)
& git -C $registryBackslashRepo.Repo add Governance/CANON_REGISTRY.json
& git -C $registryBackslashRepo.Repo commit -m registry --quiet
& git -C $registryBackslashRepo.Repo push origin main --quiet
$registryBackslashBefore = Get-SemanticSha $registryBackslashRepo.Rule
$registryBackslashResult = Invoke-Sync $registryBackslashEstate @($registryBackslashRepo.Repo) 'APPLY REVIEWED PROJECT RULE WRITES'
Assert-True ($registryBackslashResult.ExitCode -ne 0) 'backslash/case registry Apply must fail'
Assert-True ($registryBackslashResult.Text -match 'will not create registry drift') 'backslash/case registry gate signature missing'
Assert-True ((Get-SemanticSha $registryBackslashRepo.Rule) -eq $registryBackslashBefore) 'backslash/case registry gate changed target'

$registryEscapedEstate = Join-Path $TempRoot 'registry-escaped-slash-gated'
New-Item -ItemType Directory -Path $registryEscapedEstate | Out-Null
$registryEscapedRepo = New-FixtureRepo $registryEscapedEstate 'repo' $legacyText
$registryEscapedPath = Join-Path $registryEscapedRepo.Repo 'Governance\CANON_REGISTRY.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $registryEscapedPath) -Force | Out-Null
[IO.File]::WriteAllText($registryEscapedPath, '{"files":[{"path":".cursor\/rules\/dreameros-boot-canon.mdc"}]}', $Utf8)
& git -C $registryEscapedRepo.Repo add Governance/CANON_REGISTRY.json
& git -C $registryEscapedRepo.Repo commit -m registry --quiet
& git -C $registryEscapedRepo.Repo push origin main --quiet
$registryEscapedBefore = Get-SemanticSha $registryEscapedRepo.Rule
$registryEscapedResult = Invoke-Sync $registryEscapedEstate @($registryEscapedRepo.Repo) 'APPLY REVIEWED PROJECT RULE WRITES'
Assert-True ($registryEscapedResult.ExitCode -ne 0) 'escaped-slash registry Apply must fail'
Assert-True ($registryEscapedResult.Text -match 'will not create registry drift') 'escaped-slash registry gate signature missing'
Assert-True ((Get-SemanticSha $registryEscapedRepo.Rule) -eq $registryEscapedBefore) 'escaped-slash registry gate changed target'

$registryInvalidEstate = Join-Path $TempRoot 'registry-invalid-gated'
New-Item -ItemType Directory -Path $registryInvalidEstate | Out-Null
$registryInvalidRepo = New-FixtureRepo $registryInvalidEstate 'repo' $legacyText
$registryInvalidPath = Join-Path $registryInvalidRepo.Repo 'Governance\CANON_REGISTRY.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $registryInvalidPath) -Force | Out-Null
[IO.File]::WriteAllText($registryInvalidPath, '{"files":[', $Utf8)
& git -C $registryInvalidRepo.Repo add Governance/CANON_REGISTRY.json
& git -C $registryInvalidRepo.Repo commit -m registry --quiet
& git -C $registryInvalidRepo.Repo push origin main --quiet
$registryInvalidBefore = Get-SemanticSha $registryInvalidRepo.Rule
$registryInvalidResult = Invoke-Sync $registryInvalidEstate @($registryInvalidRepo.Repo) 'APPLY REVIEWED PROJECT RULE WRITES'
Assert-True ($registryInvalidResult.ExitCode -ne 0) 'invalid registry Apply must fail'
Assert-True ($registryInvalidResult.Text -match 'unreadable or invalid JSON') 'invalid registry fail-closed signature missing'
Assert-True ((Get-SemanticSha $registryInvalidRepo.Rule) -eq $registryInvalidBefore) 'invalid registry gate changed target'

# Apply is allowed only from current main at the fetched origin/main commit.
$branchEstate = Join-Path $TempRoot 'feature-branch'
New-Item -ItemType Directory -Path $branchEstate | Out-Null
$branchRepo = New-FixtureRepo $branchEstate 'repo' $legacyText
& git -C $branchRepo.Repo switch -c feature --quiet
$branchBefore = Get-SemanticSha $branchRepo.Rule
$branchResult = Invoke-Sync $branchEstate @($branchRepo.Repo) 'APPLY REVIEWED PROJECT RULE WRITES'
Assert-True ($branchResult.ExitCode -ne 0) 'feature branch Apply must fail'
Assert-True ((Get-SemanticSha $branchRepo.Rule) -eq $branchBefore) 'feature branch Apply changed target'

$behindEstate = Join-Path $TempRoot 'behind-main'
New-Item -ItemType Directory -Path $behindEstate | Out-Null
$behindRepo = New-FixtureRepo $behindEstate 'repo' $legacyText
$advancer = Join-Path $TempRoot 'behind-advancer'
& git clone -b main $behindRepo.Origin $advancer --quiet
if ($LASTEXITCODE -ne 0) { throw 'behind-main advancer clone failed' }
& git -C $advancer config user.email 'pointer-test@dreameros.invalid'
& git -C $advancer config user.name 'DreamerOS Pointer Test'
[IO.File]::WriteAllText((Join-Path $advancer 'advance.txt'), 'remote advance', $Utf8)
& git -C $advancer add advance.txt
& git -C $advancer commit -m advance --quiet
& git -C $advancer push origin main --quiet
if ($LASTEXITCODE -ne 0) { throw 'behind-main advancer push failed' }
$behindBefore = Get-SemanticSha $behindRepo.Rule
$behindResult = Invoke-Sync $behindEstate @($behindRepo.Repo) 'APPLY REVIEWED PROJECT RULE WRITES'
Assert-True ($behindResult.ExitCode -ne 0) 'behind-main Apply must fail'
Assert-True ((Get-SemanticSha $behindRepo.Rule) -eq $behindBefore) 'behind-main Apply changed target'

# An existing backup-set id must fail before any backup or project write.
$collisionEstate = Join-Path $TempRoot 'backup-set-collision'
New-Item -ItemType Directory -Path $collisionEstate | Out-Null
$collisionRepo = New-FixtureRepo $collisionEstate 'repo' $legacyText
$collisionBefore = Get-SemanticSha $collisionRepo.Rule
$collisionId = 'forced-collision'
$collisionSet = Join-Path $TestHome ".cursor\dreameros\project-rule-backups\$collisionId"
$null = [IO.Directory]::CreateDirectory($collisionSet)
$collisionSentinel = Join-Path $collisionSet 'owner-sentinel.txt'
[IO.File]::WriteAllText($collisionSentinel, 'preserve owner bytes', $Utf8)
$collisionResult = Invoke-Sync $collisionEstate @($collisionRepo.Repo) 'APPLY REVIEWED PROJECT RULE WRITES' $collisionId
Assert-True ($collisionResult.ExitCode -ne 0) 'backup-set collision must fail'
Assert-True ($collisionResult.Text -match 'already exists or could not be exclusively created') 'backup-set collision signature missing'
Assert-True ((Get-SemanticSha $collisionRepo.Rule) -eq $collisionBefore) 'backup-set collision changed target'
Assert-True ([IO.File]::ReadAllText($collisionSentinel) -eq 'preserve owner bytes') 'backup-set collision overwrote owner bytes'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $collisionSet 'restore-manifest.json'))) 'backup-set collision created a manifest'

# A reviewed current-main repository migrates in place and preserves the path.
$successEstate = Join-Path $TempRoot 'success'
New-Item -ItemType Directory -Path $successEstate | Out-Null
$successRepo = New-FixtureRepo $successEstate 'repo' $legacyText
$successResult = Invoke-Sync $successEstate @($successRepo.Repo) 'APPLY REVIEWED PROJECT RULE WRITES'
Assert-True ($successResult.ExitCode -eq 0) "approved migration failed: $($successResult.Text)"
Assert-True ((Get-SemanticSha $successRepo.Rule) -eq (Get-SemanticSha $Pointer)) 'migrated pointer hash mismatch'
Assert-True ($successResult.Text -match 'POINTER_ALIGNED PROJECT RULE') 'migration success signature missing'
$manifestMatch = [regex]::Match($successResult.Text, 'restore manifest (?<path>[^\r\n]+)')
Assert-True ($manifestMatch.Success) 'migration did not report a restore manifest'
$successManifest = $manifestMatch.Groups['path'].Value.Trim()
$successManifestOriginal = [IO.File]::ReadAllText($successManifest)
$successManifestData = $successManifestOriginal | ConvertFrom-Json
Assert-True ($successManifestData.status -eq 'migrated') 'restore manifest did not reach migrated state'
Assert-True ($successManifestData.entries.Count -eq 1) 'restore manifest entry count mismatch'

$restoreWrong = Invoke-Restore $successManifest 'WRONG'
Assert-True ($restoreWrong.ExitCode -ne 0) 'wrong restore confirmation must fail'
Assert-True ((Get-SemanticSha $successRepo.Rule) -eq (Get-SemanticSha $Pointer)) 'wrong restore confirmation changed target'

$restoreUnrelated = Join-Path $successRepo.Repo 'parallel-owner.txt'
[IO.File]::WriteAllText($restoreUnrelated, 'parallel owner work', $Utf8)
$restoreDirty = Invoke-Restore $successManifest 'RESTORE REVIEWED PROJECT RULE WRITES'
Assert-True ($restoreDirty.ExitCode -ne 0 -and $restoreDirty.Text -match 'outside the remaining manifest targets') 'restore did not refuse unrelated dirty work'
Assert-True ((Get-SemanticSha $successRepo.Rule) -eq (Get-SemanticSha $Pointer)) 'dirty restore changed target'
Move-Item -LiteralPath $restoreUnrelated -Destination (Join-Path $TempRoot 'preserved-parallel-owner.txt')

[IO.File]::AppendAllText($successRepo.Rule, "`nconcurrent target drift", $Utf8)
$restoreDrift = Invoke-Restore $successManifest 'RESTORE REVIEWED PROJECT RULE WRITES'
Assert-True ($restoreDrift.ExitCode -ne 0 -and $restoreDrift.Text -match 'target changed') 'restore did not refuse target drift'
[IO.File]::WriteAllText($successRepo.Rule, $pointerText, $Utf8)

$successEntry = $successManifestData.entries[0]
$successBackup = Join-Path (Split-Path -Parent $successManifest) ([string]$successEntry.backup_relative).Replace('/', '\')
$successBackupBytes = [IO.File]::ReadAllBytes($successBackup)
[IO.File]::AppendAllText($successBackup, "`ntampered backup", $Utf8)
$restoreTamperedBackup = Invoke-Restore $successManifest 'RESTORE REVIEWED PROJECT RULE WRITES'
Assert-True ($restoreTamperedBackup.ExitCode -ne 0 -and $restoreTamperedBackup.Text -match 'backup hash mismatch') 'restore did not refuse tampered backup'
[IO.File]::WriteAllBytes($successBackup, $successBackupBytes)

$tamperedManifest = $successManifestOriginal | ConvertFrom-Json
$tamperedManifest.entries += $tamperedManifest.entries[0]
[IO.File]::WriteAllText($successManifest, ($tamperedManifest | ConvertTo-Json -Depth 8), $Utf8)
$restoreDuplicateTarget = Invoke-Restore $successManifest 'RESTORE REVIEWED PROJECT RULE WRITES'
Assert-True ($restoreDuplicateTarget.ExitCode -ne 0 -and $restoreDuplicateTarget.Text -match 'duplicate target') 'restore did not refuse duplicate repo target'
[IO.File]::WriteAllText($successManifest, $successManifestOriginal, $Utf8)

$pathTamperedManifest = $successManifestOriginal | ConvertFrom-Json
$pathTamperedManifest.entries[0].target_path = Join-Path $successRepo.Repo 'README.md'
[IO.File]::WriteAllText($successManifest, ($pathTamperedManifest | ConvertTo-Json -Depth 8), $Utf8)
$restorePathTamper = Invoke-Restore $successManifest 'RESTORE REVIEWED PROJECT RULE WRITES'
Assert-True ($restorePathTamper.ExitCode -ne 0 -and $restorePathTamper.Text -match 'target_path does not match') 'restore did not refuse path-binding tamper'
[IO.File]::WriteAllText($successManifest, $successManifestOriginal, $Utf8)

$manifestDir = Split-Path -Parent $successManifest
$concurrentJob = Start-Job -ScriptBlock {
    param($Directory, $Target)
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if (Get-ChildItem -LiteralPath $Directory -Directory -Filter 'pre-restore-*' -ErrorAction SilentlyContinue) {
            try {
                [IO.File]::AppendAllText($Target, "`nconcurrent owner edit")
                return 'mutated'
            } catch [IO.IOException] {
                # The restore may briefly hold the file while staging it. Retry so
                # the fixture tests drift handling instead of failing on file sharing.
            }
        }
        Start-Sleep -Milliseconds 10
    }
    return 'timeout'
} -ArgumentList $manifestDir, $successRepo.Rule
$restoreConcurrent = Invoke-Restore $successManifest 'RESTORE REVIEWED PROJECT RULE WRITES'
$concurrentJobResult = Receive-Job -Job $concurrentJob -Wait
Assert-True ($concurrentJobResult -contains 'mutated') 'concurrent restore fixture did not mutate target'
Assert-True ($restoreConcurrent.ExitCode -ne 0) 'restore overwrote a concurrent target edit'
Assert-True ((Get-SemanticSha $successRepo.Rule) -ne (Get-SemanticSha $Pointer)) 'concurrent target assertion control failed'
[IO.File]::WriteAllText($successRepo.Rule, $pointerText, $Utf8)

$restoreReceiptFailure = Invoke-Restore $successManifest 'RESTORE REVIEWED PROJECT RULE WRITES' $true
Assert-True ($restoreReceiptFailure.ExitCode -ne 0) 'receipt failure did not fail the restore transaction'
Assert-True ((Get-SemanticSha $successRepo.Rule) -eq (Get-SemanticSha $Pointer)) 'receipt failure left restored project bytes active'
$receiptRollbackManifest = [IO.File]::ReadAllText($successManifest) | ConvertFrom-Json
Assert-True ($receiptRollbackManifest.status -eq 'migrated') 'receipt failure did not restore migrated manifest state'

$restoreSuccess = Invoke-Restore $successManifest 'RESTORE REVIEWED PROJECT RULE WRITES'
Assert-True ($restoreSuccess.ExitCode -eq 0) "valid project-rule restore failed: $($restoreSuccess.Text)"
Assert-True ((Get-SemanticSha $successRepo.Rule) -eq $successEntry.original_sha256) 'restored project rule hash mismatch'
$restoredManifestData = [IO.File]::ReadAllText($successManifest) | ConvertFrom-Json
Assert-True ($restoredManifestData.status -eq 'restored') 'restore manifest did not reach restored state'
Assert-True (@(& git -C $successRepo.Repo status --porcelain=v1).Count -eq 0) 'successful restore did not return repository clean'

$committedRestoreEstate = Join-Path $TempRoot 'committed-restore'
New-Item -ItemType Directory -Path $committedRestoreEstate | Out-Null
$committedRestoreRepo = New-FixtureRepo $committedRestoreEstate 'repo' $legacyText
$committedApply = Invoke-Sync $committedRestoreEstate @($committedRestoreRepo.Repo) 'APPLY REVIEWED PROJECT RULE WRITES'
Assert-True ($committedApply.ExitCode -eq 0) 'committed-restore fixture migration failed'
$committedManifestMatch = [regex]::Match($committedApply.Text, 'restore manifest (?<path>[^\r\n]+)')
& git -C $committedRestoreRepo.Repo add .cursor/rules/dreameros-boot-canon.mdc
& git -C $committedRestoreRepo.Repo commit -m pointer --quiet
$committedRestore = Invoke-Restore $committedManifestMatch.Groups['path'].Value.Trim() 'RESTORE REVIEWED PROJECT RULE WRITES'
Assert-True ($committedRestore.ExitCode -ne 0 -and $committedRestore.Text -match 'current origin/main') 'restore did not refuse committed migration'
Assert-True ((Get-SemanticSha $committedRestoreRepo.Rule) -eq (Get-SemanticSha $Pointer)) 'committed restore changed target'

$multiTargetEstate = Join-Path $TempRoot 'multi-target-restore'
New-Item -ItemType Directory -Path $multiTargetEstate | Out-Null
$multiTargetRepo = New-FixtureRepo $multiTargetEstate 'repo' $legacyText
$nestedRule = Join-Path $multiTargetRepo.Repo 'nested\.cursor\rules\dreameros-boot-canon.mdc'
New-Item -ItemType Directory -Path (Split-Path -Parent $nestedRule) -Force | Out-Null
[IO.File]::WriteAllText($nestedRule, $legacyText, $Utf8)
& git -C $multiTargetRepo.Repo add nested/.cursor/rules/dreameros-boot-canon.mdc
& git -C $multiTargetRepo.Repo commit -m nested-rule --quiet
& git -C $multiTargetRepo.Repo push origin main --quiet
$multiApply = Invoke-Sync $multiTargetEstate @($multiTargetRepo.Repo) 'APPLY REVIEWED PROJECT RULE WRITES'
Assert-True ($multiApply.ExitCode -eq 0) "multi-target migration failed: $($multiApply.Text)"
Assert-True ((Get-SemanticSha $multiTargetRepo.Rule) -eq (Get-SemanticSha $Pointer)) 'root multi-target rule did not migrate'
Assert-True ((Get-SemanticSha $nestedRule) -eq (Get-SemanticSha $Pointer)) 'nested multi-target rule did not migrate'
$multiManifestMatch = [regex]::Match($multiApply.Text, 'restore manifest (?<path>[^\r\n]+)')
$multiManifest = $multiManifestMatch.Groups['path'].Value.Trim()
$multiManifestData = [IO.File]::ReadAllText($multiManifest) | ConvertFrom-Json
Assert-True ($multiManifestData.entries.Count -eq 2) 'multi-target restore manifest entry count mismatch'
$nestedLock = [IO.File]::Open($nestedRule, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    $multiRestoreFailure = Invoke-Restore $multiManifest 'RESTORE REVIEWED PROJECT RULE WRITES'
} finally {
    $nestedLock.Dispose()
}
Assert-True ($multiRestoreFailure.ExitCode -ne 0) 'multi-target restore failure did not fail the transaction'
Assert-True ((Get-SemanticSha $multiTargetRepo.Rule) -eq (Get-SemanticSha $Pointer)) 'multi-target rollback left root rule restored'
Assert-True ((Get-SemanticSha $nestedRule) -eq (Get-SemanticSha $Pointer)) 'multi-target rollback changed second rule'
$multiRestore = Invoke-Restore $multiManifest 'RESTORE REVIEWED PROJECT RULE WRITES'
Assert-True ($multiRestore.ExitCode -eq 0) "multi-target restore failed: $($multiRestore.Text)"
Assert-True ((Get-SemanticSha $multiTargetRepo.Rule) -eq (Get-SemanticSha $Legacy)) 'root multi-target rule did not restore'
Assert-True ((Get-SemanticSha $nestedRule) -eq (Get-SemanticSha $Legacy)) 'nested multi-target rule did not restore'
Assert-True (@(& git -C $multiTargetRepo.Repo status --porcelain=v1).Count -eq 0) 'multi-target restore did not return repository clean'

# Estate-wide census findings outside the exact approved repository cannot
# block that repository's reviewed, current-main, clean migration.
$isolationEstate = Join-Path $TempRoot 'approved-isolation'
New-Item -ItemType Directory -Path $isolationEstate | Out-Null
$isolationApproved = New-FixtureRepo $isolationEstate 'approved' $legacyText
$isolationUnknown = New-FixtureRepo $isolationEstate 'unapproved-unknown' 'custom pointer-like text'
$isolationUnknownBefore = Get-SemanticSha $isolationUnknown.Rule
$isolationResult = Invoke-Sync $isolationEstate @($isolationApproved.Repo) 'APPLY REVIEWED PROJECT RULE WRITES'
Assert-True ($isolationResult.ExitCode -eq 0) "unapproved UNKNOWN blocked exact approved repo: $($isolationResult.Text)"
Assert-True ($isolationResult.Text -match 'UNKNOWN FILE-CLEAN') 'unapproved UNKNOWN was not reported in census'
Assert-True ((Get-SemanticSha $isolationApproved.Rule) -eq (Get-SemanticSha $Pointer)) 'approved isolated repo did not migrate'
Assert-True ((Get-SemanticSha $isolationUnknown.Rule) -eq $isolationUnknownBefore) 'unapproved UNKNOWN repo changed'

# Force a second-repository write failure and require rollback of the first.
$rollbackEstate = Join-Path $TempRoot 'rollback'
New-Item -ItemType Directory -Path $rollbackEstate | Out-Null
$rollbackOne = New-FixtureRepo $rollbackEstate 'repo-one' $legacyText
$rollbackTwo = New-FixtureRepo $rollbackEstate 'repo-two' $legacyText
$rollbackOneBefore = Get-SemanticSha $rollbackOne.Rule
$rollbackTwoBefore = Get-SemanticSha $rollbackTwo.Rule
(Get-Item -LiteralPath $rollbackTwo.Rule).IsReadOnly = $true
try {
    $rollbackResult = Invoke-Sync $rollbackEstate @($rollbackOne.Repo, $rollbackTwo.Repo) 'APPLY REVIEWED PROJECT RULE WRITES'
} finally {
    (Get-Item -LiteralPath $rollbackTwo.Rule).IsReadOnly = $false
}
Assert-True ($rollbackResult.ExitCode -ne 0) 'forced second-repo failure must fail'
Assert-True ($rollbackResult.Text -match 'Every file written by this run was restored') 'rollback signature missing'
Assert-True ((Get-SemanticSha $rollbackOne.Rule) -eq $rollbackOneBefore) 'first repo was not restored'
Assert-True ((Get-SemanticSha $rollbackTwo.Rule) -eq $rollbackTwoBefore) 'second repo changed on failed write'

# A renderer-only change must make -Verify fail even when old checksums match.
$bootFixture = Join-Path $TempRoot 'boot-renderer'
Copy-Item -LiteralPath (Join-Path $RepoRoot 'bootpack') -Destination $bootFixture -Recurse
$fixtureBuilder = Join-Path $bootFixture 'build-boot-pack.ps1'
$fixtureScript = [IO.File]::ReadAllText($fixtureBuilder)
$fixtureScript = $fixtureScript.Replace(
    'The full DreamerOS Boot Canon is generated from',
    'The current DreamerOS Boot Canon is generated from')
[IO.File]::WriteAllText($fixtureBuilder, $fixtureScript, $Utf8)
$priorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $rendererOutput = @(& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $fixtureBuilder -Verify 2>&1)
    $rendererExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $priorPreference
}
Assert-True ($rendererExit -ne 0) 'stale rendered pointer must fail Verify'
Assert-True (($rendererOutput -join "`n") -match 'differs from current renderer') 'renderer drift signature missing'

$syncSource = [IO.File]::ReadAllText($SyncScript)
$currentMainCalls = [regex]::Matches($syncSource, '(?m)^\s*Assert-CurrentMain\s+\$').Count
Assert-True ($currentMainCalls -eq 3) 'current-main gate must run at preflight, pre-backup, and pre-write'

Write-Output (@{
    status = 'pass'
    assertions = $Cases
    fixture_root = $TempRoot
} | ConvertTo-Json -Compress)

# The last child process above may be a deliberate failure run that exits
# non-zero. GitHub's powershell step wrapper ends with "exit $LASTEXITCODE",
# so without this line a passing test reports failure. Every assertion
# throws on failure, so reaching here means pass.
exit 0
