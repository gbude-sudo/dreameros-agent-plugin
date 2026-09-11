param([switch]$ForceFailure)

$ErrorActionPreference = 'Stop'

$BootRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$RepoRoot = Split-Path -Parent $BootRoot
$PowerShellExe = (Get-Process -Id $PID).Path
$TempRoot = Join-Path $env:TEMP ('dreameros-codex-hook-install-tests-' + [guid]::NewGuid().ToString('N'))
$FixtureRepo = Join-Path $TempRoot 'repo'
$FakeHome = Join-Path $TempRoot 'home'
$Cases = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:Cases++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

if ($ForceFailure) {
    Assert-True $false 'forced assertion negative control'
}

function Get-RawSha([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-', '').ToLower()
    }
    finally {
        $sha.Dispose()
    }
}

function Test-ExactBytes([byte[]]$Left, [byte[]]$Right) {
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Invoke-Install {
    $homeEscaped = $FakeHome.Replace("'", "''")
    $builderEscaped = $Builder.Replace("'", "''")
    $command = "`$env:USERPROFILE='$homeEscaped'; & '$builderEscaped' -Install"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $priorPreference
    }
    return [pscustomobject]@{ ExitCode = $code; Text = ($output -join "`n") }
}

New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
Copy-Item -LiteralPath $RepoRoot -Destination $FixtureRepo -Recurse
$Builder = Join-Path $FixtureRepo 'bootpack\build-boot-pack.ps1'
$HookSource = Join-Path $FixtureRepo 'install\codex\payload\hooks\model-switch-ack-codex.py'
$HookDestination = Join-Path $FakeHome '.codex\hooks\model-switch-ack-codex.py'
$HooksDestination = Join-Path $FakeHome '.codex\hooks.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $HookDestination) -Force | Out-Null

# An aligned destination stays byte-identical and creates no backup.
Copy-Item -LiteralPath $HookSource -Destination $HookDestination
$aligned = Invoke-Install
Assert-True ($aligned.ExitCode -eq 0) "aligned install failed: $($aligned.Text)"
Assert-True ($aligned.Text -match 'ALIGNED .*Codex engine-switch hook') 'aligned result missing'
Assert-True ((Get-RawSha $HookDestination) -ceq (Get-RawSha $HookSource)) 'aligned destination changed'
Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $HookDestination) -Filter 'model-switch-ack-codex.py.bak-*' -File).Count -eq 0) 'aligned install created a backup'

# A differing file is updated only after its exact owner bytes are backed up.
$ownerBytes = (New-Object Text.UTF8Encoding($false)).GetBytes("# owner edit before install`n")
[IO.File]::WriteAllBytes($HookDestination, $ownerBytes)
$update = Invoke-Install
Assert-True ($update.ExitCode -eq 0) "differing install failed: $($update.Text)"
Assert-True ($update.Text -match 'HEALED .*Codex engine-switch hook.*backup') 'updated result or backup receipt missing'
Assert-True ((Get-RawSha $HookDestination) -ceq (Get-RawSha $HookSource)) 'differing destination was not updated'
$backups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $HookDestination) -Filter 'model-switch-ack-codex.py.bak-*' -File)
Assert-True ($backups.Count -eq 1) 'differing install did not create exactly one backup'
Assert-True (Test-ExactBytes ([IO.File]::ReadAllBytes($backups[0].FullName)) $ownerBytes) 'backup did not preserve exact owner bytes'

# An active writer holds an exclusive file handle. Install must report MERGE
# NEEDED, return nonzero, and leave the owner's destination bytes untouched.
$concurrentBytes = (New-Object Text.UTF8Encoding($false)).GetBytes("# concurrent owner edit`n")
[IO.File]::WriteAllBytes($HookDestination, $concurrentBytes)
$backupsBeforeCollision = @(Get-ChildItem -LiteralPath (Split-Path -Parent $HookDestination) -Filter 'model-switch-ack-codex.py.bak-*' -File).Count
$readyPath = Join-Path $TempRoot 'lock-ready'
$releasePath = Join-Path $TempRoot 'lock-release'
$destinationEscaped = $HookDestination.Replace("'", "''")
$readyEscaped = $readyPath.Replace("'", "''")
$releaseEscaped = $releasePath.Replace("'", "''")
$helperCommand = @"
`$stream = [IO.File]::Open('$destinationEscaped', [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    [IO.File]::WriteAllText('$readyEscaped', 'ready')
    while (-not (Test-Path -LiteralPath '$releaseEscaped')) { Start-Sleep -Milliseconds 20 }
}
finally {
    `$stream.Dispose()
}
"@
$helperEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helperCommand))
$helper = Start-Process -FilePath $PowerShellExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $helperEncoded) -WindowStyle Hidden -PassThru
try {
    for ($attempt = 0; $attempt -lt 400 -and -not (Test-Path -LiteralPath $readyPath); $attempt++) {
        Start-Sleep -Milliseconds 25
    }
    Assert-True (Test-Path -LiteralPath $readyPath) 'exclusive-lock helper did not become ready'
    $collision = Invoke-Install
    Assert-True ($collision.ExitCode -ne 0) 'locked destination did not fail closed'
    Assert-True ($collision.Text -match 'MERGE NEEDED .*model-switch-ack-codex\.py') 'locked destination did not report MERGE NEEDED'
}
finally {
    [IO.File]::WriteAllText($releasePath, 'release')
    [void]$helper.WaitForExit(5000)
    if (-not $helper.HasExited) { Stop-Process -Id $helper.Id -Force }
    $helper.Dispose()
}
Assert-True (Test-ExactBytes ([IO.File]::ReadAllBytes($HookDestination)) $concurrentBytes) 'collision overwrote concurrent owner bytes'
$backupsAfterCollision = @(Get-ChildItem -LiteralPath (Split-Path -Parent $HookDestination) -Filter 'model-switch-ack-codex.py.bak-*' -File).Count
Assert-True ($backupsAfterCollision -eq $backupsBeforeCollision) 'locked collision created an unreceipted backup'

# Registration creation must use CreateNew, not a Test-Path then overwrite
# sequence. An existing owner file remains exact and reports MERGE NEEDED.
$builderText = [IO.File]::ReadAllText($Builder)
Assert-True ($builderText -match 'Install-NewTextFileOrPreserve\s+-Destination\s+\$codexJsonDest') 'hooks.json does not use exclusive create and preserve flow'
Assert-True ($builderText -notmatch 'Write-Utf8\s+-Path\s+\$codexJsonDest') 'hooks.json retains the non-exclusive write path'
Copy-Item -LiteralPath $HookSource -Destination $HookDestination -Force
$ownerHooksBytes = (New-Object Text.UTF8Encoding($false)).GetBytes('{"hooks":{"OwnerOnly":[]}}')
[IO.File]::WriteAllBytes($HooksDestination, $ownerHooksBytes)
$preservedRegistration = Invoke-Install
Assert-True ($preservedRegistration.ExitCode -eq 0) "owner registration preservation failed: $($preservedRegistration.Text)"
Assert-True ($preservedRegistration.Text -match 'MERGE NEEDED .*hooks\.json') 'owner hooks.json did not report MERGE NEEDED'
Assert-True (Test-ExactBytes ([IO.File]::ReadAllBytes($HooksDestination)) $ownerHooksBytes) 'owner hooks.json bytes were overwritten'

# A writer that holds hooks.json also forces a nonzero MERGE NEEDED result.
$jsonReadyPath = Join-Path $TempRoot 'json-lock-ready'
$jsonReleasePath = Join-Path $TempRoot 'json-lock-release'
$jsonDestinationEscaped = $HooksDestination.Replace("'", "''")
$jsonReadyEscaped = $jsonReadyPath.Replace("'", "''")
$jsonReleaseEscaped = $jsonReleasePath.Replace("'", "''")
$jsonHelperCommand = @"
`$stream = [IO.File]::Open('$jsonDestinationEscaped', [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    [IO.File]::WriteAllText('$jsonReadyEscaped', 'ready')
    while (-not (Test-Path -LiteralPath '$jsonReleaseEscaped')) { Start-Sleep -Milliseconds 20 }
}
finally {
    `$stream.Dispose()
}
"@
$jsonHelperEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($jsonHelperCommand))
$jsonHelper = Start-Process -FilePath $PowerShellExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $jsonHelperEncoded) -WindowStyle Hidden -PassThru
try {
    for ($attempt = 0; $attempt -lt 400 -and -not (Test-Path -LiteralPath $jsonReadyPath); $attempt++) {
        Start-Sleep -Milliseconds 25
    }
    Assert-True (Test-Path -LiteralPath $jsonReadyPath) 'hooks.json lock helper did not become ready'
    $jsonCollision = Invoke-Install
    Assert-True ($jsonCollision.ExitCode -ne 0) 'locked hooks.json did not fail closed'
    Assert-True ($jsonCollision.Text -match 'MERGE NEEDED .*hooks\.json') 'locked hooks.json did not report MERGE NEEDED'
}
finally {
    [IO.File]::WriteAllText($jsonReleasePath, 'release')
    [void]$jsonHelper.WaitForExit(5000)
    if (-not $jsonHelper.HasExited) { Stop-Process -Id $jsonHelper.Id -Force }
    $jsonHelper.Dispose()
}
Assert-True (Test-ExactBytes ([IO.File]::ReadAllBytes($HooksDestination)) $ownerHooksBytes) 'locked hooks.json owner bytes were overwritten'

$priorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $forcedOutput = @(& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -ForceFailure 2>&1)
    $forcedExit = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $priorPreference
}
Assert-True ($forcedExit -ne 0) 'forced assertion negative control returned success'
Assert-True (($forcedOutput -join "`n") -match 'forced assertion negative control') 'forced assertion failure was not observable'

Write-Output (@{
    status = 'pass'
    assertions = $Cases
    fixture_root = $TempRoot
} | ConvertTo-Json -Compress)

# The final installer child is expected to exit 1 for the locked-owner case.
# Every real test failure throws before this point, so reaching here is PASS.
exit 0
