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
$Installer = Join-Path $RepoRoot 'install\cursor\install.ps1'
$GlobalPointer = Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-global-plugin-pointer.mdc'
$ClaudeReviewCommand = Join-Path $RepoRoot 'cursor\commands\dreameros-claude-review.md'
$PowerShellExe = (Get-Process -Id $PID).Path
$TempRoot = Join-Path (Get-LongPath $env:TEMP) ('dreameros-cursor-install-tests-' + [guid]::NewGuid().ToString('N'))
$FakeHome = Join-Path $TempRoot 'home'
$Target = Join-Path $FakeHome '.cursor\plugins\local\dreameros'
$BackupRoot = Join-Path $FakeHome '.cursor\plugins\backups'
$Cases = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:Cases++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Invoke-Installer([string]$Arguments = '', [string]$UserProfile = $FakeHome) {
    $homeEscaped = $UserProfile.Replace("'", "''")
    $installerEscaped = $Installer.Replace("'", "''")
    $command = "`$env:USERPROFILE='$homeEscaped'; & '$installerEscaped' $Arguments"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $priorPreference
    }
    return [pscustomobject]@{ ExitCode = $code; Text = ($output -join "`n") }
}

New-Item -ItemType Directory -Path (Join-Path $FakeHome '.cursor\rules') -Force | Out-Null
Copy-Item -LiteralPath $GlobalPointer -Destination (Join-Path $FakeHome '.cursor\rules\dreameros-boot-canon.mdc')

$initial = Invoke-Installer
Assert-True ($initial.ExitCode -eq 0) "initial install failed: $($initial.Text)"
Assert-True (Test-Path -LiteralPath (Join-Path $Target '.cursor-plugin\plugin.json')) 'initial target missing native manifest'
$claudeReviewText = [IO.File]::ReadAllText($ClaudeReviewCommand)
Assert-True ($claudeReviewText.Contains('auth status --json')) 'Claude review command lacks machine-readable auth status'
Assert-True ($claudeReviewText.Contains('auth login --help')) 'Claude review command does not verify current login help'
Assert-True ($claudeReviewText.Contains('auth login --claudeai')) 'Claude review command lacks the current subscription login command'
Assert-True ($claudeReviewText.Contains('mcp login --help')) 'Claude review command does not verify current MCP login help'
Assert-True ($claudeReviewText.Contains('mcp login dreameros')) 'Claude review command lacks the DreamerOS OAuth login command'
Assert-True ($claudeReviewText.Contains('Never start or automate an')) 'Claude review command does not preserve human-only authentication'
Assert-True ($claudeReviewText.Contains('header-free `dreameros` HTTP server reports `Needs authentication`')) 'Claude review command lacks the header-free OAuth branch'
Assert-True ($claudeReviewText.Contains('authorization_present=true|false')) 'Claude review command lacks a value-free Authorization structural check'
Assert-True ($claudeReviewText.Contains('Never print, copy, or persist a header')) 'Claude review command does not forbid header-value output'
Assert-True ($claudeReviewText.Contains('CONFIRM CLAUDE REVIEW SEND')) 'Claude review command lost the send authorization gate'
$installedClaudeReview = Join-Path $Target 'cursor\commands\dreameros-claude-review.md'
Assert-True ((Get-FileHash -LiteralPath $installedClaudeReview -Algorithm SHA256).Hash -eq
    (Get-FileHash -LiteralPath $ClaudeReviewCommand -Algorithm SHA256).Hash) 'installed Claude review command differs from source'

$verify = Invoke-Installer '-VerifyOnly'
Assert-True ($verify.ExitCode -eq 0 -and $verify.Text -match 'VERIFIED Cursor plugin bytes') 'VerifyOnly failed after initial install'

$collision = Invoke-Installer
Assert-True ($collision.ExitCode -ne 0 -and $collision.Text -match 'Target exists') 'install collision was not refused'

# Seed the legacy dual-manifest shape before Update. Its backup must remain
# restorable even though the active exact target removes these files.
Copy-Item -LiteralPath (Join-Path $RepoRoot 'plugin.json') -Destination (Join-Path $Target 'plugin.json')
Copy-Item -LiteralPath (Join-Path $RepoRoot 'mcp.json') -Destination (Join-Path $Target 'mcp.json')
$update = Invoke-Installer '-Update'
Assert-True ($update.ExitCode -eq 0) "update failed: $($update.Text)"
$legacyBackup = Get-ChildItem -LiteralPath $BackupRoot -Directory -Filter 'dreameros-*' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Assert-True ($null -ne $legacyBackup) 'Update did not create a legacy backup'
Assert-True (Test-Path -LiteralPath (Join-Path $legacyBackup.FullName 'plugin.json')) 'legacy backup lost root plugin.json'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $Target 'plugin.json'))) 'updated active target retained legacy root plugin.json'

$uninstallDenied = Invoke-Installer '-Uninstall -ConfirmAction "WRONG"'
Assert-True ($uninstallDenied.ExitCode -ne 0 -and (Test-Path -LiteralPath $Target)) 'wrong uninstall confirmation changed target'

$uninstall = Invoke-Installer '-Uninstall -ConfirmAction "UNINSTALL DREAMEROS CURSOR PLUGIN"'
Assert-True ($uninstall.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $Target)) "recoverable uninstall failed: $($uninstall.Text)"
$uninstalledBackup = Get-ChildItem -LiteralPath $BackupRoot -Directory -Filter 'uninstalled-dreameros-*' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Assert-True ($null -ne $uninstalledBackup) 'recoverable uninstall backup missing'

$restoreDeniedArgs = '-RestoreBackup "' + $uninstalledBackup.FullName + '" -ConfirmAction "WRONG"'
$restoreDenied = Invoke-Installer $restoreDeniedArgs
Assert-True ($restoreDenied.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $Target)) 'wrong restore confirmation activated target'

# Corrupt backup validation happens before activation and must preserve both
# the empty target and the selected backup.
$corruptBackup = Join-Path $BackupRoot 'corrupt-dreameros-fixture'
Copy-Item -LiteralPath $uninstalledBackup.FullName -Destination $corruptBackup -Recurse
[IO.File]::WriteAllText((Join-Path $corruptBackup '.cursor-plugin\plugin.json'), '{broken json')
$corruptArgs = '-RestoreBackup "' + $corruptBackup + '" -ConfirmAction "RESTORE DREAMEROS CURSOR PLUGIN BACKUP"'
$corrupt = Invoke-Installer $corruptArgs
Assert-True ($corrupt.ExitCode -ne 0) 'corrupt backup restore unexpectedly passed'
Assert-True (-not (Test-Path -LiteralPath $Target)) 'corrupt backup became active'
Assert-True (Test-Path -LiteralPath $corruptBackup) 'corrupt backup was consumed on failed restore'

$restoreArgs = '-RestoreBackup "' + $uninstalledBackup.FullName + '" -ConfirmAction "RESTORE DREAMEROS CURSOR PLUGIN BACKUP"'
$restore = Invoke-Installer $restoreArgs
Assert-True ($restore.ExitCode -eq 0 -and (Test-Path -LiteralPath $Target)) "valid restore failed: $($restore.Text)"
Assert-True (-not (Test-Path -LiteralPath $uninstalledBackup.FullName)) 'successful restore left consumed backup path'

$collisionRestoreArgs = '-RestoreBackup "' + $legacyBackup.FullName + '" -ConfirmAction "RESTORE DREAMEROS CURSOR PLUGIN BACKUP"'
$collisionRestore = Invoke-Installer $collisionRestoreArgs
Assert-True ($collisionRestore.ExitCode -ne 0 -and $collisionRestore.Text -match 'Restore target already exists') 'restore collision was not refused'
Assert-True (Test-Path -LiteralPath $legacyBackup.FullName) 'restore collision consumed legacy backup'

$uninstallCurrent = Invoke-Installer '-Uninstall -ConfirmAction "UNINSTALL DREAMEROS CURSOR PLUGIN"'
Assert-True ($uninstallCurrent.ExitCode -eq 0) 'could not stage current target before legacy restore'
$currentBackup = Get-ChildItem -LiteralPath $BackupRoot -Directory -Filter 'uninstalled-dreameros-*' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$legacyRestoreArgs = '-RestoreBackup "' + $legacyBackup.FullName + '" -ConfirmAction "RESTORE DREAMEROS CURSOR PLUGIN BACKUP"'
$legacyRestore = Invoke-Installer $legacyRestoreArgs
Assert-True ($legacyRestore.ExitCode -eq 0 -and $legacyRestore.Text -match 'RESTORED LEGACY DUAL-MANIFEST') "legacy backup restore failed: $($legacyRestore.Text)"
Assert-True (Test-Path -LiteralPath (Join-Path $Target 'plugin.json')) 'legacy restore lost root plugin.json'
Assert-True (Test-Path -LiteralPath (Join-Path $Target 'mcp.json')) 'legacy restore lost root mcp.json'

$uninstallLegacy = Invoke-Installer '-Uninstall -ConfirmAction "UNINSTALL DREAMEROS CURSOR PLUGIN"'
Assert-True ($uninstallLegacy.ExitCode -eq 0) 'could not remove restored legacy target'
$restoreCurrentArgs = '-RestoreBackup "' + $currentBackup.FullName + '" -ConfirmAction "RESTORE DREAMEROS CURSOR PLUGIN BACKUP"'
$restoreCurrent = Invoke-Installer $restoreCurrentArgs
Assert-True ($restoreCurrent.ExitCode -eq 0) "could not return to current exact target: $($restoreCurrent.Text)"

$finalVerify = Invoke-Installer '-VerifyOnly'
Assert-True ($finalVerify.ExitCode -eq 0) "final VerifyOnly failed: $($finalVerify.Text)"

# GitHub runners hand the installer USERPROFILE in 8.3 short form. Its own path
# comparisons must still hold when the root arrives in that form.
$shortHome = Get-ShortPath $FakeHome
$shortHomeVerify = Invoke-Installer '-VerifyOnly' $shortHome
Assert-True ($shortHomeVerify.ExitCode -eq 0 -and $shortHomeVerify.Text -match 'VERIFIED Cursor plugin bytes') "VerifyOnly failed with short-form USERPROFILE $shortHome : $($shortHomeVerify.Text)"

Write-Output (@{
    status = 'pass'
    assertions = $Cases
    fixture_root = $TempRoot
} | ConvertTo-Json -Compress)
