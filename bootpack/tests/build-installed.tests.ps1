param([switch]$KeepGreenFixture)

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

function Get-SemanticSha([string] $Text) {
    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($normalized)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLower()
    }
    finally {
        $sha.Dispose()
    }
}
function Test-ExactBytes([byte[]] $Left, [byte[]] $Right) {
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

$runtimeExportPath = Join-Path $BootRoot 'out\runtime\dreameros-boot-canon-stable-prefix.json'
$runtimeRawBytes = [IO.File]::ReadAllBytes($runtimeExportPath)
$runtimeRawText = [IO.File]::ReadAllText($runtimeExportPath).Replace("`r`n", "`n").Replace("`r", "`n")
$runtimeExpectedBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($runtimeRawText)
Assert-True (Test-ExactBytes $runtimeRawBytes $runtimeExpectedBytes) 'runtime export raw bytes are not exact UTF-8 without BOM'
$runtimeExport = Get-Content -Raw -LiteralPath $runtimeExportPath | ConvertFrom-Json
$sourceText = Get-Content -Raw -LiteralPath (Join-Path $BootRoot 'SOURCE-dreameros-boot-canon.md')
Assert-True ($runtimeExport.schema_version -ceq 'dreameros-session-package-stable-prefix-v1') 'runtime export schema mismatch'
Assert-True ($runtimeExport.version -ceq 'v2.5.0') 'runtime export version mismatch'
Assert-True ($runtimeExport.sha256 -ceq (Get-SemanticSha $sourceText)) 'runtime export source hash mismatch'
Assert-True ($runtimeExport.source_provenance.repository -ceq 'gbude-sudo/dreameros-agent-plugin') 'runtime export repository provenance mismatch'
Assert-True ($runtimeExport.source_provenance.path -ceq 'bootpack/SOURCE-dreameros-boot-canon.md') 'runtime export source path mismatch'
Assert-True ($runtimeExport.source_provenance.generator -ceq 'bootpack/build-boot-pack.ps1') 'runtime export generator provenance mismatch'
Assert-True ($runtimeExport.portable_text -ceq $sourceText) 'runtime export portable text differs from source'

$sourceVersion = 'v' + ([regex]::Match($sourceText, '(?m)^# DreamerOS Boot Canon v([0-9]+\.[0-9]+\.[0-9]+)\s*$').Groups[1].Value)
$sourceHash = Get-SemanticSha $sourceText
$projectPointer = Get-Content -Raw -LiteralPath (Join-Path $BootRoot 'out\project\DREAMEROS_BOOT_CANON_POINTER.md.block')
$cursorProjectPointer = Get-Content -Raw -LiteralPath (Join-Path $BootRoot 'out\cursor\dreameros-project-pointer.mdc')
$codexGlobalBlock = Get-Content -Raw -LiteralPath (Join-Path $BootRoot 'out\codex\AGENTS.md.block')
$claudeGlobalBlock = Get-Content -Raw -LiteralPath (Join-Path $BootRoot 'out\claude\CLAUDE.md.block')
$bootManifest = Get-Content -Raw -LiteralPath (Join-Path $BootRoot 'out\manifest\dreameros-boot-canon.json') | ConvertFrom-Json
Assert-True ($projectPointer.Contains('DREAMEROS-PROJECT-BOOT-POINTER v1.1.0')) 'project pointer v1.1 marker missing'
Assert-True ($projectPointer.Contains('Cloud carrier: a successful authenticated `dreameros_session_package`')) 'project pointer cloud carrier missing'
Assert-True (-not $projectPointer.Contains($sourceVersion) -and -not $projectPointer.Contains($sourceHash)) 'project pointer contains release-specific version or source hash'
Assert-True ($projectPointer.Contains('package_components.boot_canon')) 'project pointer cloud component missing'
Assert-True (-not $cursorProjectPointer.Contains($sourceHash)) 'Cursor project pointer contains a release-specific source hash'
Assert-True ($bootManifest.project_pointer.version -ceq 'v1.1.0') 'manifest project pointer version mismatch'
Assert-True ($bootManifest.project_pointer.cloud_session_package.proof -ceq 'one complete wrapper with matching schema, version, sha256, provenance, full-body hash, canaries, and fresh metadata') 'manifest cloud package proof mismatch'
Assert-True ((@($bootManifest.project_pointer.cloud_session_package.required_canary_ids) -join ',') -ceq 'R26,R27,HC-DEFINITION-OF-DONE') 'manifest cloud package required canary ids mismatch'
Assert-True ($null -eq $bootManifest.project_pointer.cloud_session_package.required_marker_ids) 'manifest retains obsolete cloud package marker ids'
Assert-True ($bootManifest.project_oauth_onramp.status -ceq 'TEMPLATE_WRITTEN_NOT_REGISTERED') 'OAuth on-ramp manifest status mismatch'
Assert-True ([regex]::Matches($codexGlobalBlock, '<dreameros_codex_client_adapter version="v1\.0\.0">').Count -eq 1) 'Codex client adapter marker missing or duplicated'
Assert-True ([regex]::Matches($codexGlobalBlock, 'When calling dreameros_session_package from Codex, pass engine: "chatgpt"\.').Count -eq 1) 'Codex package engine mapping missing or duplicated'
Assert-True ($codexGlobalBlock.IndexOf('<dreameros_codex_client_adapter') -lt $codexGlobalBlock.IndexOf('# DreamerOS Boot Canon')) 'Codex client adapter must load before the portable canon'
Assert-True ($codexGlobalBlock.IndexOf($sourceText) -ge 0 -and $codexGlobalBlock.IndexOf($sourceText) -eq $codexGlobalBlock.LastIndexOf($sourceText)) 'Codex global block must carry the portable canon exactly once'
Assert-True (-not $sourceText.Contains('dreameros_codex_client_adapter')) 'Codex client adapter leaked into the vendor-neutral source'
Assert-True (-not $claudeGlobalBlock.Contains('dreameros_codex_client_adapter')) 'Codex client adapter leaked into Claude output'
Assert-True ($bootManifest.client_adapters.codex.version -ceq 'v1.0.0') 'Codex client adapter manifest version mismatch'
Assert-True ($bootManifest.client_adapters.codex.package_engine -ceq 'chatgpt') 'Codex client adapter manifest engine mismatch'
Assert-True ($bootManifest.client_adapters.codex.source -ceq 'codex/AGENTS.md.block') 'Codex client adapter manifest source mismatch'

$freshHome = Join-Path $TempRoot 'fresh-install-home'
New-Item -ItemType Directory -Path $freshHome -Force | Out-Null
$freshInstallCommand = "`$env:USERPROFILE='$freshHome'; & '$Builder' -Install"
$freshInstallEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($freshInstallCommand))
$priorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $freshInstallOutput = @(& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $freshInstallEncoded 2>&1)
    $freshInstallExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $priorPreference
}
$freshInstallText = $freshInstallOutput -join [Environment]::NewLine
Assert-True ($freshInstallExitCode -eq 0) ("fresh empty-home install failed: {0}" -f $freshInstallText)
$freshCodexPath = Join-Path $freshHome '.codex\AGENTS.md'
$freshClaudePath = Join-Path $freshHome '.claude\CLAUDE.md'
Assert-True (Test-Path -LiteralPath $freshCodexPath -PathType Leaf) 'fresh install did not create Codex AGENTS.md'
Assert-True (Test-Path -LiteralPath $freshClaudePath -PathType Leaf) 'fresh install did not create Claude CLAUDE.md'
$freshCodexText = [IO.File]::ReadAllText($freshCodexPath)
Assert-True ([regex]::Matches($freshCodexText, '<dreameros_codex_client_adapter version="v1\.0\.0">').Count -eq 1) 'fresh Codex install lacks exactly one client adapter'
Assert-True ([regex]::Matches($freshCodexText, 'When calling dreameros_session_package from Codex, pass engine: "chatgpt"\.').Count -eq 1) 'fresh Codex install lacks exactly one package-engine mapping'
Assert-True ($freshCodexText.IndexOf($sourceText) -ge 0 -and $freshCodexText.IndexOf($sourceText) -eq $freshCodexText.LastIndexOf($sourceText)) 'fresh Codex install lacks exactly one portable canon'

$agentFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'install\claude-code\payload\agents') -Filter '*.md' -File)
Assert-True ($agentFiles.Count -eq 15) 'Claude agent inventory changed; review bootstrap coverage'
$safeSuffixes = @('session_package', 'context', 'recall', 'canon', 'session_handoff_read')
$safePrefix = 'mcp__dreameros__dreameros_'
foreach ($agentFile in $agentFiles) {
    $agentText = Get-Content -Raw -LiteralPath $agentFile.FullName
    $toolsLine = ([regex]::Match($agentText, '(?m)^tools:\s*(.+)$')).Groups[1].Value
    Assert-True ([regex]::Matches($agentText, 'DREAMEROS-READ-ONLY-BOOTSTRAP v1\.1\.0').Count -eq 1) "$($agentFile.Name) bootstrap marker missing or duplicated"
    foreach ($suffix in $safeSuffixes) {
        Assert-True ($toolsLine.Contains($safePrefix + $suffix)) "$($agentFile.Name) lacks $($safePrefix + $suffix)"
    }
    $tools = @($toolsLine.Trim().TrimStart('[').TrimEnd(']').Split(',') | ForEach-Object { $_.Trim() })
    foreach ($tool in @($tools | Where-Object { $_.StartsWith('mcp__') })) {
        Assert-True ($tool -match '^mcp__dreameros__dreameros_[a-z0-9_]+$') "$($agentFile.Name) has a nonportable DreamerOS tool id: $tool"
    }
    Assert-True (-not $agentText.Contains('dreameros_state')) "$($agentFile.Name) mentions the mixed state tool"
    Assert-True (-not $agentText.Contains('mcp__DreamerOS_Live__')) "$($agentFile.Name) retains a DreamerOS_Live alias"
    Assert-True ($agentText -notmatch '(?i)mcp__[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}__') "$($agentFile.Name) retains a UUID-shaped MCP alias"
    $unconditional = '`dreameros_session_package` is the only unconditional boot call. Call it first.'
    $conditional = 'When the package directs it or the assigned task needs read-only enrichment,'
    $orderedEnrichment = @('1. Call `dreameros_session_handoff_read` for the full record when present.', '2. Call `dreameros_context`. Use its SCS as the read-only current-state channel.', '3. Call scoped `dreameros_recall`.', '4. Call `dreameros_canon` when the task needs it.')
    $bootstrapSteps = @($unconditional, $conditional) + $orderedEnrichment
    $positions = @($bootstrapSteps | ForEach-Object { $agentText.IndexOf($_) })
    $sortedPositions = @($positions | Sort-Object)
    Assert-True ((-not ($positions | Where-Object { $_ -lt 0 })) -and (($positions -join ',') -eq ($sortedPositions -join ','))) "$($agentFile.Name) unconditional package and optional enrichment order is missing or drifted"
    Assert-True ([regex]::Matches($agentText, [regex]::Escape($unconditional)).Count -eq 1) "$($agentFile.Name) lacks exactly one unconditional package call"
    Assert-True ($agentText.Contains('Use its SCS as the read-only current-state channel.')) "$($agentFile.Name) lacks the safe SCS context expectation"
    Assert-True (-not $agentText.Contains('PARTIALLY CONNECTED')) "$($agentFile.Name) treats the absent mixed tool as degraded connectivity"
}

$claudeSessionStart = Get-Content -Raw -LiteralPath (Join-Path $BootRoot 'out\claude\dreameros-session-start.sh')
Assert-True ([regex]::Matches($claudeSessionStart, 'DREAMEROS-CLAUDE-SESSION-START-ADAPTER v1\.1\.0').Count -eq 1) 'Claude SessionStart adapter v1.1 marker missing or duplicated'
Assert-True (-not $claudeSessionStart.Contains('dreameros_state')) 'Claude SessionStart adapter leaks the mixed state tool'
$adapterSteps = @(
    'Call dreameros_session_package first for the active Claude engine and current project. It is the only unconditional boot call',
    'When the package directs it or the current task needs read-only enrichment, call in this order:',
    'dreameros_session_handoff_read for the full record when present',
    'dreameros_context and use its SCS as the read-only current-state channel',
    'a scoped dreameros_recall for the current topic',
    'relevant dreameros_canon'
)
$adapterPositions = @($adapterSteps | ForEach-Object { $claudeSessionStart.IndexOf($_) })
$sortedAdapterPositions = @($adapterPositions | Sort-Object)
Assert-True ((-not ($adapterPositions | Where-Object { $_ -lt 0 })) -and (($adapterPositions -join ',') -eq ($sortedAdapterPositions -join ','))) 'Claude SessionStart adapter v1.1 order is missing or drifted'

$runtimeFixture = Join-Path $TempRoot 'runtime-export-drift'
Copy-Item -LiteralPath $BootRoot -Destination $runtimeFixture -Recurse
$runtimeFixtureBuilder = Join-Path $runtimeFixture 'build-boot-pack.ps1'
$runtimeFixtureExport = Join-Path $runtimeFixture 'out\runtime\dreameros-boot-canon-stable-prefix.json'
$runtimeFixturePluginRule = Join-Path $TempRoot 'cursor\rules\dreameros-boot-canon.mdc'
New-Item -ItemType Directory -Path (Split-Path -Parent $runtimeFixturePluginRule) -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $RepoRoot 'cursor\rules\dreameros-boot-canon.mdc') -Destination $runtimeFixturePluginRule
$runtimeFixtureText = [IO.File]::ReadAllText($runtimeFixtureExport)
$runtimeCaseDrift = $runtimeFixtureText.Replace(
    '"schema_version":"dreameros-session-package-stable-prefix-v1"',
    '"schema_version":"Dreameros-session-package-stable-prefix-v1"'
)
Assert-True ($runtimeCaseDrift -cne $runtimeFixtureText) 'runtime export case-drift fixture was not created'
[IO.File]::WriteAllText($runtimeFixtureExport, $runtimeCaseDrift, (New-Object System.Text.UTF8Encoding($false)))
$runtimeVerifyCommand = "& '$runtimeFixtureBuilder' -Verify"
$runtimeVerifyEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($runtimeVerifyCommand))
$priorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $runtimeVerifyOutput = @(& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $runtimeVerifyEncoded 2>&1)
    $runtimeVerifyExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $priorPreference
}
Assert-True ($runtimeVerifyExitCode -ne 0) 'case-drifted runtime export did not fail -Verify'
Assert-True (($runtimeVerifyOutput -join "`n") -match 'runtime\\dreameros-boot-canon-stable-prefix\.json') 'case-drifted runtime export was not identified'
$runtimeBom = [byte[]]@(0xEF, 0xBB, 0xBF) + [IO.File]::ReadAllBytes($runtimeFixtureExport)
[IO.File]::WriteAllBytes($runtimeFixtureExport, $runtimeBom)
$priorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $runtimeBomOutput = @(& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $runtimeVerifyEncoded 2>&1)
    $runtimeBomExitCode = $LASTEXITCODE
} finally { $ErrorActionPreference = $priorPreference }
Assert-True ($runtimeBomExitCode -ne 0) 'BOM runtime export did not fail -Verify'
Assert-True (($runtimeBomOutput -join "`n") -match 'runtime\\dreameros-boot-canon-stable-prefix\.json') 'BOM runtime export was not identified'
[IO.File]::WriteAllBytes($runtimeFixtureExport, (New-Object System.Text.UnicodeEncoding($false, $true)).GetBytes($runtimeFixtureText))
try {
    $ErrorActionPreference = 'Continue'
    $runtimeUtf16Output = @(& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $runtimeVerifyEncoded 2>&1)
    $runtimeUtf16ExitCode = $LASTEXITCODE
} finally { $ErrorActionPreference = $priorPreference }
Assert-True ($runtimeUtf16ExitCode -ne 0) 'UTF-16 runtime export did not fail -Verify'
Assert-True (($runtimeUtf16Output -join "`n") -match 'runtime\\dreameros-boot-canon-stable-prefix\.json') 'UTF-16 runtime export was not identified'

Copy-Carrier (Join-Path $BootRoot 'out\claude\CLAUDE.md.block') '.claude\CLAUDE.md'
Copy-Carrier (Join-Path $BootRoot 'out\codex\AGENTS.md.block') '.codex\AGENTS.md'
Copy-Carrier (Join-Path $BootRoot 'out\cursor\dreameros-global-plugin-pointer.mdc') '.cursor\rules\dreameros-boot-canon.mdc'
Copy-Carrier (Join-Path $BootRoot 'out\skill\dreameros-boot\SKILL.md') '.claude\skills\dreameros-boot\SKILL.md'
Copy-Carrier (Join-Path $BootRoot 'out\skill\dreameros-boot\SKILL.md') '.codex\skills\dreameros-boot\SKILL.md'
Copy-Carrier (Join-Path $BootRoot 'out\skill\dreameros-boot\SKILL.md') '.agents\skills\dreameros-boot\SKILL.md'
Copy-Carrier (Join-Path $BootRoot 'out\evidence\HC_ATTRIBUTED_QUOTES_v1_0_0.md') '.agents\evidence\dreameros\HC_ATTRIBUTED_QUOTES_v1_0_0.md'
Copy-Carrier (Join-Path $BootRoot 'out\claude\dreameros-session-start.sh') '.claude\hooks\dreameros-session-start.sh'
$pluginRoot = Join-Path $FakeHome '.cursor\plugins\local\dreameros-agent-plugin-test'
New-Item -ItemType Directory -Path (Join-Path $pluginRoot '.cursor-plugin') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $pluginRoot 'rules') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $pluginRoot '.cursor-plugin\plugin.json'), '{"repository":"https://github.com/gbude-sudo/dreameros-agent-plugin","rules":"./rules"}', (New-Object System.Text.UTF8Encoding($false)))
Copy-Item -LiteralPath (Join-Path $RepoRoot 'cursor\rules\dreameros-boot-canon.mdc') -Destination (Join-Path $pluginRoot 'rules\dreameros-boot-canon.mdc')
$fakeSettings = @{ hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = 'bash "C:/fake/.claude/hooks/dreameros-session-start.sh"' }, @{ type = 'command'; command = 'bash "C:/fake/.claude/hooks/open-loop-surface.sh"' }) }) } }
New-Item -ItemType Directory -Path (Join-Path $FakeHome '.claude') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $FakeHome '.claude\settings.json'), ($fakeSettings | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

$pass = Invoke-InstalledVerify
Assert-True ($pass.ExitCode -eq 0) "aligned installed carriers failed: $($pass.Text)"
Assert-True ([regex]::Matches($pass.Text, 'DREAMEROS_VERIFY_INSTALLED_JSON=').Count -eq 1) 'installed verification JSON receipt missing or duplicated'
Assert-True ($pass.Text -match '"schema_version":"dreameros-verify-installed-v1"') 'installed verification JSON schema missing'
$receiptLine = @($pass.Text -split "`n" | Where-Object { $_ -like 'DREAMEROS_VERIFY_INSTALLED_JSON=*' })[0]
$receipt = ($receiptLine.Substring('DREAMEROS_VERIFY_INSTALLED_JSON='.Length) | ConvertFrom-Json)
$carrierIds = @('claude_global_boot','codex_global_boot','cursor_global_pointer','cursor_registered_plugin_rule','claude_boot_skill','codex_boot_skill','shared_boot_skill','agent_plugin_boot_skill','shared_quote_evidence','claude_session_start_hook','claude_session_start_registration') | Sort-Object
Assert-True ($receipt.ok -eq $true -and $receipt.boot_canon.version -ceq 'v2.4.0' -and $receipt.boot_canon.sha256 -match '^[0-9a-f]{64}$') 'installed verification receipt boot metadata invalid'
Assert-True ((@($receipt.required_carriers | Sort-Object) -join ',') -ceq ($carrierIds -join ',') -and (@($receipt.verified_carriers | Sort-Object) -join ',') -ceq ($carrierIds -join ',')) 'installed verification receipt carrier ids invalid'
Write-Output $receiptLine
if ($KeepGreenFixture) {
    Write-Output (@{ status = 'green_fixture'; fixture_root = $FakeHome } | ConvertTo-Json -Compress)
    exit 0
}
$savedSettings = [IO.File]::ReadAllText((Join-Path $FakeHome '.claude\settings.json'))
[IO.File]::WriteAllText((Join-Path $FakeHome '.claude\settings.json'), '{}', (New-Object System.Text.UTF8Encoding($false)))
$missingRegistration = Invoke-InstalledVerify
Assert-True ($missingRegistration.ExitCode -ne 0 -and $missingRegistration.Text -match 'Claude SessionStart registration') 'missing Claude registration did not fail'
[IO.File]::WriteAllText((Join-Path $FakeHome '.claude\settings.json'), $savedSettings, (New-Object System.Text.UTF8Encoding($false)))

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

# The last child process above is a deliberate drift run that exits 1.
# GitHub's powershell step wrapper ends with "exit $LASTEXITCODE", so
# without this line a passing test reports failure. Every assertion
# throws on failure, so reaching here means pass.
exit 0
