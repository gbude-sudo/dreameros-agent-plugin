$ErrorActionPreference = 'Stop'

$InstallRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Installer = Join-Path $InstallRoot 'dreameros-global-setup.ps1'
$Payload = Join-Path $InstallRoot 'payload'
$PowerShellExe = (Get-Process -Id $PID).Path
$TempRoot = Join-Path $env:TEMP ('dreameros-claude-agent-merge-' + [guid]::NewGuid().ToString('N'))
$ClaudeHome = Join-Path $TempRoot 'home\.claude'
$FixtureRepoRoot = Join-Path $TempRoot 'repos'
$AgentHome = Join-Path $ClaudeHome 'agents'
$Cases = 0
$FrontmatterPattern = '\A---(?<open>\r?\n)(?<front>[\s\S]*?)(?<close>\r?\n---)(?<after>\r?\n)(?<body>[\s\S]*)\z'
$BootstrapPattern = '(?ms)^## DREAMEROS-READ-ONLY-BOOTSTRAP v[0-9]+\.[0-9]+\.[0-9]+\r?\n[\s\S]*?^external state\.\r?\n(?:\r?\n)?'

function Assert-True([bool]$Condition, [string]$Message) {
    $script:Cases++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Split-Agent([string]$Text) {
    $match = [regex]::Match($Text, $FrontmatterPattern)
    if (-not $match.Success) { throw 'fixture agent frontmatter did not parse' }
    return [pscustomobject]@{
        Open = $match.Groups['open'].Value
        Front = $match.Groups['front'].Value
        Close = $match.Groups['close'].Value
        After = $match.Groups['after'].Value
        Body = $match.Groups['body'].Value
    }
}

function Get-ToolsLine([string]$Front) {
    $rows = [regex]::Matches($Front, '(?m)^tools:[^\r\n]*(?=\r?$)')
    if ($rows.Count -ne 1) { throw "expected one tools line, found $($rows.Count)" }
    return $rows[0].Value
}

function Front-WithoutTools([string]$Front) {
    return [regex]::Replace($Front, '(?m)^tools:[^\r\n]*\r?\n?', '')
}

function Body-WithoutBootstrap([string]$Body) {
    return [regex]::Replace($Body, $BootstrapPattern, '')
}

function Invoke-Installer {
    $installerEscaped = $Installer.Replace("'", "''")
    $homeEscaped = $ClaudeHome.Replace("'", "''")
    $repoEscaped = $FixtureRepoRoot.Replace("'", "''")
    $payloadEscaped = $Payload.Replace("'", "''")
    $command = "& '$installerEscaped' -ClaudeHome '$homeEscaped' -RepoRoot '$repoEscaped' -PayloadPath '$payloadEscaped' -SkipCanon"
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

function New-LegacyAgent([string]$Name, [string]$OldTools, [bool]$KeepStaleBlock, [string]$Canary) {
    $sourcePath = Join-Path (Join-Path $Payload 'agents') $Name
    $sourceText = [IO.File]::ReadAllText($sourcePath)
    $source = Split-Agent $sourceText
    $sourceBlock = [regex]::Match($source.Body, $BootstrapPattern)
    if (-not $sourceBlock.Success) { throw "$Name source bootstrap block missing" }
    $front = [regex]::Replace($source.Front, '(?m)^tools:[^\r\n]*(?=\r?$)', $OldTools)
    $front += "`nowner-extra: preserve-$Canary"
    $bodyTail = Body-WithoutBootstrap $source.Body
    if ($KeepStaleBlock) {
        $staleBlock = $sourceBlock.Value.Replace('v1.1.0', 'v1.0.0')
        $body = $staleBlock + $bodyTail + "`nLOCAL-BODY-$Canary`n"
    }
    else {
        $body = $bodyTail + "`nLOCAL-BODY-$Canary`n"
    }
    $text = '---' + $source.Open + $front + $source.Close + $source.After + $body
    if ($Name -eq 'canon-citer.md') {
        $text = $text.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
    }
    $destination = Join-Path $AgentHome $Name
    [IO.File]::WriteAllText($destination, $text, (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Path = $destination; SourcePath = $sourcePath; Text = $text; Parts = (Split-Agent $text) }
}

New-Item -ItemType Directory -Path $AgentHome -Force | Out-Null
New-Item -ItemType Directory -Path $FixtureRepoRoot -Force | Out-Null
$canon = New-LegacyAgent 'canon-citer.md' 'tools: [mcp__247c12ae-5fb4-49e0-aec6-73f0d11c0013__dreameros_recall, mcp__247c12ae-5fb4-49e0-aec6-73f0d11c0013__dreameros_canon]' $false 'CANON'
$locator = New-LegacyAgent 'file-locator.md' 'tools: [Glob, Bash, Read, mcp__DreamerOS_Live__dreameros_recall]' $true 'LOCATOR'

$canonBeforeBytes = [IO.File]::ReadAllBytes($canon.Path)
$locatorBeforeBytes = [IO.File]::ReadAllBytes($locator.Path)
$canonFrontWithoutTools = Front-WithoutTools $canon.Parts.Front
$locatorFrontWithoutTools = Front-WithoutTools $locator.Parts.Front
$canonBodyWithoutBootstrap = Body-WithoutBootstrap $canon.Parts.Body
$locatorBodyWithoutBootstrap = Body-WithoutBootstrap $locator.Parts.Body

$first = Invoke-Installer
Assert-True ($first.ExitCode -eq 0) "managed agent installer failed: $($first.Text)"

$payloadAgents = @(Get-ChildItem -LiteralPath (Join-Path $Payload 'agents') -Filter '*.md' -File | Sort-Object Name)
$installedAgents = @(Get-ChildItem -LiteralPath $AgentHome -Filter '*.md' -File | Sort-Object Name)
Assert-True ($installedAgents.Count -eq $payloadAgents.Count) 'installed managed agent inventory differs from payload'
foreach ($payloadAgent in $payloadAgents) {
    $installedPath = Join-Path $AgentHome $payloadAgent.Name
    $installedText = [IO.File]::ReadAllText($installedPath)
    $installed = Split-Agent $installedText
    $payloadText = [IO.File]::ReadAllText($payloadAgent.FullName)
    $payloadParts = Split-Agent $payloadText
    Assert-True ([regex]::Matches($installedText, 'DREAMEROS-READ-ONLY-BOOTSTRAP v1\.1\.0').Count -eq 1) "$($payloadAgent.Name) bootstrap marker count is not one"
    Assert-True ([regex]::Matches($installedText, 'dreameros_session_package').Count -ge 1) "$($payloadAgent.Name) session package call missing"
    Assert-True ((Get-ToolsLine $installed.Front) -ceq (Get-ToolsLine $payloadParts.Front)) "$($payloadAgent.Name) tools line differs from payload"
    Assert-True ($installedText -notmatch 'mcp__(?:DreamerOS_Live|[0-9a-f]{8}-[0-9a-f-]{27})__') "$($payloadAgent.Name) retains a nonportable MCP alias"
}

$canonAfterText = [IO.File]::ReadAllText($canon.Path)
$locatorAfterText = [IO.File]::ReadAllText($locator.Path)
$canonAfter = Split-Agent $canonAfterText
$locatorAfter = Split-Agent $locatorAfterText
Assert-True ((Front-WithoutTools $canonAfter.Front) -ceq $canonFrontWithoutTools) 'canon-citer unrelated frontmatter changed'
Assert-True ((Front-WithoutTools $locatorAfter.Front) -ceq $locatorFrontWithoutTools) 'file-locator unrelated frontmatter changed'
Assert-True ((Body-WithoutBootstrap $canonAfter.Body) -ceq $canonBodyWithoutBootstrap) 'canon-citer local body changed'
Assert-True ((Body-WithoutBootstrap $locatorAfter.Body) -ceq $locatorBodyWithoutBootstrap) 'file-locator local body changed'
Assert-True ($canonAfterText -match 'owner-extra: preserve-CANON' -and $canonAfterText -match 'LOCAL-BODY-CANON') 'canon-citer local canaries were lost'
Assert-True ($locatorAfterText -match 'owner-extra: preserve-LOCATOR' -and $locatorAfterText -match 'LOCAL-BODY-LOCATOR') 'file-locator local canaries were lost'
Assert-True ($locatorAfterText -notmatch 'DREAMEROS-READ-ONLY-BOOTSTRAP v1\.0\.0') 'stale bootstrap block remains'

$backups = @(Get-ChildItem -LiteralPath (Join-Path $ClaudeHome 'backups') -Recurse -File)
$canonBackup = @($backups | Where-Object { $_.Name -eq 'canon-citer.md' })
$locatorBackup = @($backups | Where-Object { $_.Name -eq 'file-locator.md' })
Assert-True ($canonBackup.Count -eq 1) 'canon-citer backup missing'
Assert-True ($locatorBackup.Count -eq 1) 'file-locator backup missing'
Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($canonBackup[0].FullName)) -ceq [Convert]::ToBase64String($canonBeforeBytes)) 'canon-citer backup differs from owner bytes'
Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($locatorBackup[0].FullName)) -ceq [Convert]::ToBase64String($locatorBeforeBytes)) 'file-locator backup differs from owner bytes'

$beforeSecond = [ordered]@{}
foreach ($agent in $installedAgents) { $beforeSecond[$agent.Name] = (Get-FileHash -Algorithm SHA256 -LiteralPath $agent.FullName).Hash }
$second = Invoke-Installer
Assert-True ($second.ExitCode -eq 0) "second managed agent install failed: $($second.Text)"
foreach ($agent in $installedAgents) {
    Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $agent.FullName).Hash -ceq $beforeSecond[$agent.Name]) "$($agent.Name) changed on second install"
}
Assert-True ($second.Text -notmatch 'MERGE agent ') 'second install repeated a managed agent merge'

$probePath = Join-Path $AgentHome 'probe-runner.md'
$probeText = [IO.File]::ReadAllText($probePath)
$probeParts = Split-Agent $probeText
$malformedBlockBody = "## DREAMEROS-READ-ONLY-BOOTSTRAP v1.0.0`nLOCAL-OWNER-MUST-STAY`nThis is not a managed block.`nexternal state.`nTAIL-MUST-STAY`n" + (Body-WithoutBootstrap $probeParts.Body)
$malformedBlockText = '---' + $probeParts.Open + $probeParts.Front + $probeParts.Close + $probeParts.After + $malformedBlockBody
$malformedBlockBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($malformedBlockText)
[IO.File]::WriteAllBytes($probePath, $malformedBlockBytes)
$malformedBlockRun = Invoke-Installer
Assert-True ($malformedBlockRun.ExitCode -ne 0) 'malformed managed bootstrap did not fail closed'
Assert-True ($malformedBlockRun.Text -match 'FAIL\s+agent probe-runner') 'malformed managed bootstrap failure was not named'
Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($probePath)) -ceq [Convert]::ToBase64String($malformedBlockBytes)) 'malformed bootstrap overreach deleted owner bytes'

$malformedPath = Join-Path $AgentHome 'queue-checker.md'
$malformedBytes = (New-Object Text.UTF8Encoding($false)).GetBytes("owner malformed agent bytes`n")
[IO.File]::WriteAllBytes($malformedPath, $malformedBytes)
$malformedRun = Invoke-Installer
Assert-True ($malformedRun.ExitCode -ne 0) 'malformed managed agent did not fail closed'
Assert-True ($malformedRun.Text -match 'FAIL\s+agent queue-checker') 'malformed managed agent failure was not named'
Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($malformedPath)) -ceq [Convert]::ToBase64String($malformedBytes)) 'malformed managed agent owner bytes were overwritten'

Copy-Item -LiteralPath (Join-Path (Join-Path $Payload 'agents') 'probe-runner.md') -Destination $probePath -Force
Copy-Item -LiteralPath (Join-Path (Join-Path $Payload 'agents') 'queue-checker.md') -Destination $malformedPath -Force
$canonLockedBytes = [IO.File]::ReadAllBytes($canon.Path)
$readyPath = Join-Path $TempRoot 'agent-lock-ready'
$releasePath = Join-Path $TempRoot 'agent-lock-release'
$canonEscaped = $canon.Path.Replace("'", "''")
$readyEscaped = $readyPath.Replace("'", "''")
$releaseEscaped = $releasePath.Replace("'", "''")
$helperCommand = @"
`$stream = [IO.File]::Open('$canonEscaped', [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
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
    for ($attempt = 0; $attempt -lt 400 -and -not (Test-Path -LiteralPath $readyPath); $attempt++) { Start-Sleep -Milliseconds 25 }
    Assert-True (Test-Path -LiteralPath $readyPath) 'managed-agent lock helper did not become ready'
    $lockedRun = Invoke-Installer
    Assert-True ($lockedRun.ExitCode -ne 0) 'locked managed agent did not fail closed'
    Assert-True ($lockedRun.Text -match 'FAIL\s+agent canon-citer') 'locked managed agent failure was not named'
}
finally {
    [IO.File]::WriteAllText($releasePath, 'release')
    [void]$helper.WaitForExit(5000)
    if (-not $helper.HasExited) { Stop-Process -Id $helper.Id -Force }
    $helper.Dispose()
}
Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($canon.Path)) -ceq [Convert]::ToBase64String($canonLockedBytes)) 'locked managed agent owner bytes were overwritten'
$installerText = [IO.File]::ReadAllText($Installer)
Assert-True ($installerText -match 'Merge-ManagedAgentFile[\s\S]*?FileShare\]::None[\s\S]*?SetLength\(0\)') 'managed agent merge does not hold an exclusive lock through write'

Write-Output (@{
    status = 'pass'
    assertions = $Cases
    managed_agents = $installedAgents.Count
    fixture_root = $TempRoot
} | ConvertTo-Json -Compress)

# The malformed-file child is expected to exit 1. Every real test failure
# throws before this point, so reaching this line is PASS.
exit 0
