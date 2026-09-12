#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$InstallRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Installer = Join-Path $InstallRoot 'dreameros-global-setup.ps1'
$Payload = Join-Path $InstallRoot 'payload'
$PowerShellExe = (Get-Process -Id $PID).Path
$TempBase = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
$TempRoot = Join-Path $env:TEMP ('dreameros-claude-skill-tree-' + [guid]::NewGuid().ToString('N'))
$ClaudeHome = Join-Path $TempRoot 'home\.claude'
$FixtureRepoRoot = Join-Path $TempRoot 'repos'
$VerifiedBashPath = 'C:\Program Files\Git\bin\bash.exe'
$Cases = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:Cases++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Invoke-Installer([bool]$ForceInstall = $false) {
    $installerEscaped = $Installer.Replace("'", "''")
    $homeEscaped = $ClaudeHome.Replace("'", "''")
    $repoEscaped = $FixtureRepoRoot.Replace("'", "''")
    $payloadEscaped = $Payload.Replace("'", "''")
    $bashEscaped = $VerifiedBashPath.Replace("'", "''")
    $forceArg = if ($ForceInstall) { ' -Force' } else { '' }
    $command = "& '$installerEscaped' -ClaudeHome '$homeEscaped' -RepoRoot '$repoEscaped' -PayloadPath '$payloadEscaped' -BashPath '$bashEscaped' -SkipCanon$forceArg"
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

try {
    New-Item -ItemType Directory -Path $FixtureRepoRoot -Force | Out-Null
    Assert-True (Test-Path -LiteralPath $VerifiedBashPath -PathType Leaf) 'verified Git Bash fixture is missing'

    $first = Invoke-Installer
    Assert-True ($first.ExitCode -eq 0) "first skill-tree install failed: $($first.Text)"

    $payloadSkills = Join-Path $Payload 'skills'
    $payloadFiles = @(Get-ChildItem -LiteralPath $payloadSkills -Recurse -File | Sort-Object FullName)
    Assert-True ($payloadFiles.Count -gt 0) 'payload skill inventory is empty'
    foreach ($source in $payloadFiles) {
        $relative = $source.FullName.Substring($payloadSkills.Length).TrimStart([char[]]@('\', '/'))
        $destination = Join-Path (Join-Path $ClaudeHome 'skills') $relative
        Assert-True (Test-Path -LiteralPath $destination -PathType Leaf) "$relative was not installed"
        Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash -ceq (Get-FileHash -Algorithm SHA256 -LiteralPath $source.FullName).Hash) "$relative differs from payload"
    }

    $referenceRelative = 'model-tiered-offload\references\kimi-fireworks-claude.md'
    $referenceDestination = Join-Path (Join-Path $ClaudeHome 'skills') $referenceRelative
    $ownerCanary = "LOCAL OWNER CONTENT`n"
    [IO.File]::WriteAllText($referenceDestination, $ownerCanary, (New-Object Text.UTF8Encoding($false)))
    $withoutForce = Invoke-Installer
    Assert-True ($withoutForce.ExitCode -eq 0) "non-force rerun failed: $($withoutForce.Text)"
    Assert-True ([IO.File]::ReadAllText($referenceDestination) -ceq $ownerCanary) 'non-force install overwrote local reference content'

    $withForce = Invoke-Installer $true
    Assert-True ($withForce.ExitCode -eq 0) "force rerun failed: $($withForce.Text)"
    $payloadReference = Join-Path $payloadSkills $referenceRelative
    Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $referenceDestination).Hash -ceq (Get-FileHash -Algorithm SHA256 -LiteralPath $payloadReference).Hash) 'force install did not restore packaged reference'
    $backups = @(Get-ChildItem -LiteralPath (Join-Path $ClaudeHome 'backups') -Recurse -File | Where-Object { $_.Name -eq 'kimi-fireworks-claude.md' })
    Assert-True ($backups.Count -eq 1) 'changed nested skill reference was not backed up'
    Assert-True ([IO.File]::ReadAllText($backups[0].FullName) -ceq $ownerCanary) 'nested skill reference backup lost owner bytes'

    $before = (Get-FileHash -Algorithm SHA256 -LiteralPath $referenceDestination).Hash
    $idempotent = Invoke-Installer $true
    Assert-True ($idempotent.ExitCode -eq 0) "idempotent rerun failed: $($idempotent.Text)"
    Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $referenceDestination).Hash -ceq $before) 'idempotent rerun changed nested reference bytes'

    Write-Output (@{
        status = 'pass'
        assertions = $Cases
        payload_files = $payloadFiles.Count
        fixture_root = $TempRoot
    } | ConvertTo-Json -Compress)
}
finally {
    $resolvedTempRoot = [IO.Path]::GetFullPath($TempRoot)
    if ($resolvedTempRoot.StartsWith($TempBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTempRoot).StartsWith('dreameros-claude-skill-tree-', [StringComparison]::Ordinal)) {
        if (Test-Path -LiteralPath $resolvedTempRoot) {
            Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
        }
    }
    else {
        throw "Refusing cleanup outside the test temp root: $resolvedTempRoot"
    }
}
