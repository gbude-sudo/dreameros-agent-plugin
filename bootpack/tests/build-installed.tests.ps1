$ErrorActionPreference = 'Stop'

$BootRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$RepoRoot = Split-Path -Parent $BootRoot
$Builder = Join-Path $BootRoot 'build-boot-pack.ps1'
$PowerShellExe = (Get-Process -Id $PID).Path
$TempRoot = Join-Path $env:TEMP ('dreameros-installed-carrier-tests-' + [guid]::NewGuid().ToString('N'))
$FakeHome = Join-Path $TempRoot 'home'
$Cases = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:Cases++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Copy-Carrier([string]$Source, [string]$Relative) {
    $destination = Join-Path $FakeHome $Relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $destination
}

function Invoke-InstalledVerify {
    $command = "`$env:USERPROFILE='$FakeHome'; & '$Builder' -VerifyInstalled"
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

Copy-Carrier (Join-Path $BootRoot 'out\claude\CLAUDE.md.block') '.claude\CLAUDE.md'
Copy-Carrier (Join-Path $BootRoot 'out\codex\AGENTS.md.block') '.codex\AGENTS.md'
Copy-Carrier (Join-Path $BootRoot 'out\cursor\dreameros-global-plugin-pointer.mdc') '.cursor\rules\dreameros-boot-canon.mdc'
Copy-Carrier (Join-Path $BootRoot 'out\skill\dreameros-boot\SKILL.md') '.claude\skills\dreameros-boot\SKILL.md'
Copy-Carrier (Join-Path $BootRoot 'out\skill\dreameros-boot\SKILL.md') '.codex\skills\dreameros-boot\SKILL.md'
Copy-Carrier (Join-Path $BootRoot 'out\skill\dreameros-boot\SKILL.md') '.agents\skills\dreameros-boot\SKILL.md'
Copy-Carrier (Join-Path $BootRoot 'out\evidence\HC_ATTRIBUTED_QUOTES_v1_0_0.md') '.agents\evidence\dreameros\HC_ATTRIBUTED_QUOTES_v1_0_0.md'
Copy-Carrier (Join-Path $BootRoot 'out\claude\dreameros-session-start.sh') '.claude\hooks\dreameros-session-start.sh'

$pass = Invoke-InstalledVerify
Assert-True ($pass.ExitCode -eq 0) "aligned installed carriers failed: $($pass.Text)"
Assert-True ($pass.Text -match 'VERIFIED installed Claude, Codex, Cursor pointer, skills, evidence, and Claude hook') 'installed-carrier success signature missing'

[IO.File]::AppendAllText((Join-Path $FakeHome '.codex\skills\dreameros-boot\SKILL.md'), "`ndrift")
$drift = Invoke-InstalledVerify
Assert-True ($drift.ExitCode -ne 0) 'drifted installed skill did not fail'
Assert-True ($drift.Text -match 'Codex boot skill') 'drifted installed skill was not identified'

[IO.File]::WriteAllText((Join-Path $FakeHome '.codex\skills\dreameros-boot\SKILL.md'), [IO.File]::ReadAllText((Join-Path $BootRoot 'out\skill\dreameros-boot\SKILL.md')))
[IO.File]::AppendAllText((Join-Path $FakeHome '.claude\CLAUDE.md'), "`n<!-- BEGIN DREAMEROS-BOOT-CANON v9.9.9 - GENERATED, DO NOT EDIT. Source: SOURCE-dreameros-boot-canon.md -->`nduplicate`n<!-- END DREAMEROS-BOOT-CANON v9.9.9 -->")
$duplicate = Invoke-InstalledVerify
Assert-True ($duplicate.ExitCode -ne 0) 'duplicate global boot block did not fail'
Assert-True ($duplicate.Text -match 'Claude global boot block') 'duplicate global boot block was not identified'

Write-Output (@{
    status = 'pass'
    assertions = $Cases
    fixture_root = $TempRoot
} | ConvertTo-Json -Compress)
