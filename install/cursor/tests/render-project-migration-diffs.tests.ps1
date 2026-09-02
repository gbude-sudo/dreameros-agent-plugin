$ErrorActionPreference = 'Stop'

# GitHub's windows runner exposes TEMP in 8.3 short form (C:\Users\RUNNER~1).
# Windows PowerShell 5.1 expands that form when it reports children, so a
# fixture path built from the raw value compares unequal to Get-ChildItem
# output. Both engines must also receive identical fixture paths. Ask Win32
# for the long form once and build every fixture path from it.
if (-not ('DreamerOS.Tests.Win32Path' -as [type])) {
    Add-Type -Namespace DreamerOS.Tests -Name Win32Path -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern uint GetLongPathNameW(string shortPath, System.Text.StringBuilder longPath, uint bufferLength);
'@
}

function Get-LongPath([string]$Path) {
    $buffer = New-Object Text.StringBuilder 32768
    $length = [DreamerOS.Tests.Win32Path]::GetLongPathNameW($Path, $buffer, $buffer.Capacity)
    if ($length -eq 0 -or $length -gt $buffer.Capacity) { throw "GetLongPathNameW failed for $Path" }
    return $buffer.ToString()
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Planner = Join-Path $RepoRoot 'install\cursor\plan-project-migration.ps1'
$Renderer = Join-Path $RepoRoot 'install\cursor\render-project-migration-diffs.ps1'
$CurrentPowerShell = (Get-Process -Id $PID).Path
$WindowsPowerShell = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
$PowerShellCore = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
$TempRoot = Join-Path (Get-LongPath $env:TEMP) ('dreameros migration diff tests-' + [guid]::NewGuid().ToString('N'))
$Estate = Join-Path $TempRoot 'estate with spaces'
$TestHome = Join-Path $TempRoot 'home with spaces'
$EnterpriseHooks = Join-Path $TestHome 'enterprise\Cursor\hooks.json'
$AuditPath = Join-Path $TempRoot 'audit.txt'
$PlanPath = Join-Path $TempRoot 'sealed plan.json'
$Utf8 = New-Object Text.UTF8Encoding($false)
$Cases = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:Cases++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Get-RawSha([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Get-TextSha([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Utf8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-TreeDigest([string]$Path) {
    $records = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($Path.Length).TrimStart('\').Replace('\', '/')
        "$relative|$(Get-RawSha $_.FullName)"
    })
    return Get-TextSha ($records -join "`n")
}

function Quote-ProcessArgument([string]$Value) {
    if ($Value.Contains('"')) { throw 'Process argument contains an unsupported quote character.' }
    return '"' + $Value + '"'
}

function Invoke-ScriptProcess(
    [string]$Executable,
    [string]$ScriptPath,
    [string[]]$Arguments,
    [AllowNull()]
    [string]$StandardInput = $null
) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $prefix = @('-NoProfile')
    if ([IO.Path]::GetFileName($Executable) -ieq 'powershell.exe') { $prefix += @('-ExecutionPolicy', 'Bypass') }
    $allArguments = @($prefix + @('-File', $ScriptPath) + $Arguments)
    $psi.Arguments = (@($allArguments | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join ' ')
    $psi.WorkingDirectory = $RepoRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $null -ne $StandardInput
    $psi.CreateNoWindow = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    $null = $process.Start()
    if ($null -ne $StandardInput) {
        $defaultWriter = $process.StandardInput
        $utf8Writer = New-Object IO.StreamWriter($defaultWriter.BaseStream, $Utf8)
        $utf8Writer.Write($StandardInput)
        $utf8Writer.Flush()
        $utf8Writer.Dispose()
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Text = $stdoutTask.Result
        ErrorText = $stderrTask.Result
    }
}

function Invoke-Renderer(
    [string]$Executable,
    [string]$InputPlan,
    [string]$ExpectedHash,
    [string]$Repository,
    [string[]]$SelectedAction = @()
) {
    $arguments = @(
        '-PlanPath', $InputPlan,
        '-ExpectedPlanSha256', $ExpectedHash,
        '-RepositoryPath', $Repository
    )
    foreach ($id in $SelectedAction) { $arguments += @('-ActionId', $id) }
    return Invoke-ScriptProcess $Executable $Renderer $arguments
}

function Write-Utf8([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, $Utf8)
}

function Write-JsonFixture([string]$Path, $Value) {
    Write-Utf8 $Path ($Value | ConvertTo-Json -Depth 14 -Compress)
}

function Get-ActionIdentity([string]$Action, $Finding) {
    $ordered = [ordered]@{}
    [string[]]$keys = @($Finding.metadata.PSObject.Properties | ForEach-Object { $_.Name })
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    foreach ($key in $keys) { $ordered[$key] = $Finding.metadata.$key }
    $metadataJson = $ordered | ConvertTo-Json -Compress -Depth 4
    return (Get-TextSha ($Action + '|' + $Finding.path + '|' + $Finding.state + '|' + $metadataJson)).Substring(0, 16)
}

New-Item -ItemType Directory -Path $Estate -Force | Out-Null
New-Item -ItemType Directory -Path $TestHome -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $EnterpriseHooks) -Force | Out-Null

$userHook = Join-Path $TestHome '.claude\hooks\dreameros-session-start.sh'
New-Item -ItemType Directory -Path (Split-Path -Parent $userHook) -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $RepoRoot 'bootpack\out\claude\dreameros-session-start.sh') -Destination $userHook

$project = Join-Path $Estate "repo apostrophe's fixture"
New-Item -ItemType Directory -Path $project -Force | Out-Null
$legacyCursor = @"
---
description: Legacy full DreamerOS boot copy
alwaysApply: true
---
# DreamerOS Boot Canon v2.1.0
SINGLE SOURCE OF TRUTH. Every vendor file is generated from this one.
## R1 - ANSWER FROM MEASUREMENT, NEVER FROM MEMORY
$('legacy body ' * 520)
<!-- BEGIN HC-DEFINITION-OF-DONE v1.0.0 -->
customer usable boundary
<!-- END HC-DEFINITION-OF-DONE v1.0.0 -->
"@.TrimEnd("`r", "`n")
$legacyRegion = @"
<!-- BEGIN DREAMEROS-BOOT-CANON v2.1.0 -->
# DreamerOS Boot Canon v2.1.0
SINGLE SOURCE OF TRUTH. Every vendor file is generated from this one.
## R1 - ANSWER FROM MEASUREMENT, NEVER FROM MEMORY
<!-- BEGIN HC-DEFINITION-OF-DONE v1.0.0 -->
legacy region
<!-- END HC-DEFINITION-OF-DONE v1.0.0 -->
<!-- END DREAMEROS-BOOT-CANON v2.1.0 -->
"@.TrimEnd("`r", "`n")
$driftRegion = @"
<!-- DREAMEROS-BOOT-CANON: NOT DUPLICATED HERE -->
stale pointer content
<!-- END DREAMEROS-BOOT-CANON POINTER -->
"@.TrimEnd("`r", "`n")
$claudeText = "repo-specific Claude prefix`r`n$($legacyRegion.Replace("`n", "`r`n"))`r`nrepo-specific Claude suffix`r`n"
$agentsText = "repo-specific Codex prefix`n$driftRegion`nrepo-specific Codex suffix"
$staleHook = "#!/usr/bin/env bash`n# Continuity is the Raison d'Etre`necho stale hook"
$secretSentinel = 'Bearer ' + ('S' * 48)

Write-Utf8 (Join-Path $project 'CLAUDE.md') $claudeText
Write-Utf8 (Join-Path $project 'AGENTS.md') $agentsText
Write-Utf8 (Join-Path $project '.cursor\rules\dreameros-boot-canon.mdc') $legacyCursor
Write-Utf8 (Join-Path $project '.cursor\rules\answer-from-measurement.mdc') 'old adapter content'
Write-Utf8 (Join-Path $project 'governance\bootpack\build-boot-pack.ps1') "# legacy generator`n`$target = 'cursor/dreameros-boot-canon.mdc'"
Write-Utf8 (Join-Path $project '.claude\hooks\dreameros-session-start.sh') $staleHook
Write-Utf8 (Join-Path $project '.claude\settings.json') (@{
    hooks = @{
        SessionStart = @(@{
            hooks = @(@{
                type = 'command'
                command = 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/dreameros-session-start.sh"'
            })
        })
    }
} | ConvertTo-Json -Depth 8)
Write-Utf8 (Join-Path $project '.cursor\mcp.json') (@{
    mcpServers = @{
        dreameros = @{
            type = 'http'
            url = 'https://mcp.dreameros.app/mcp'
            headers = @{ Authorization = $secretSentinel }
        }
    }
} | ConvertTo-Json -Depth 8)
Write-Utf8 (Join-Path $project 'governance\CANON_REGISTRY.json') '{"files":["README.md"]}'

& git -C $project init -b main --quiet
& git -C $project config user.name 'DreamerOS Diff Renderer Test'
& git -C $project config user.email 'diff-renderer-test@dreameros.invalid'
& git -C $project config core.autocrlf false
& git -C $project add .
& git -C $project commit -m fixture --quiet
if ($LASTEXITCODE -ne 0) { throw 'Fixture commit failed.' }

$auditLines = @(
    "LEGACY_FULL_COPY FILE-CLEAN CLAUDE $project\CLAUDE.md",
    "POINTER_DRIFT FILE-CLEAN CODEX $project\AGENTS.md",
    "LEGACY_FULL_COPY FILE-CLEAN CURSOR $project\.cursor\rules\dreameros-boot-canon.mdc",
    "LEGACY_FULL_GENERATOR FILE-CLEAN GENERATOR $project\governance\bootpack\build-boot-pack.ps1",
    "STALE_ADAPTER_COPY FILE-CLEAN ADAPTER $project\.cursor\rules\answer-from-measurement.mdc",
    "STALE_BOOT_HOOK FILE-CLEAN CLAUDE_BOOT_HOOK registration=REGISTERED $project\.claude\hooks\dreameros-session-start.sh",
    "PROJECT_MCP_AUTH_HEADER FILE-CLEAN CURSOR_PROJECT_MCP server=dreameros $project\.cursor\mcp.json",
    "USER_CLAUDE_BOOT_ALIGNED USER_CLAUDE_BOOT exact=1 other_hydration=0 $userHook",
    'USER_CLAUDE_MANAGED_HOOK_POLICY=UNVERIFIED_LIVE verify in Claude Code',
    'CURSOR_TEAM_HOOK_POLICY=UNVERIFIED_LIVE verify in Cursor Customize',
    'DREAMEROS_AUDIT_OUTCOME=FINDINGS',
    'repos=1 surfaces=3 GLOBAL_ONLY=0 POINTER_ALIGNED=0 LEGACY_FULL_COPY=2 POINTER_DRIFT=1 UNKNOWN=0 generators=1 LEGACY_FULL_GENERATOR=1 UNKNOWN_GENERATOR=0 ADAPTER_ALIGNED=0 ADAPTER_DRIFT=0 STALE_ADAPTER_COPY=1 ADAPTER_PATH_DRIFT=0 CLAUDE_BOOT_HOOKS=1 BOOT_HOOK_ALIGNED=0 STALE_BOOT_HOOK=1 BOOT_HOOK_OTHER=0 PROJECT_MCP_RECORDS=1 PROJECT_MCP_AUTH_HEADER=1 PROJECT_MCP_SHADOW=0 PROJECT_MCP_ENDPOINT_SHADOW=0 LEGACY_PROJECT_MCP=0 PROJECT_MCP_UNKNOWN=0 CURSOR_HOOK_SHADOWS=0 REPARSE_CHILD_SKIPPED=0 CURSOR_TEAM_HOOK_POLICY=UNVERIFIED_LIVE USER_CLAUDE_BOOT=USER_CLAUDE_BOOT_ALIGNED USER_CLAUDE_MANAGED_HOOK_POLICY=UNVERIFIED_LIVE USER_MCP_RECORDS=0 DUPLICATE_EMBEDDED_EXCERPT=0 DUPLICATE_RULE_EXCERPT=0'
)
[IO.File]::WriteAllLines($AuditPath, $auditLines, $Utf8)

$plannerResult = Invoke-ScriptProcess $CurrentPowerShell $Planner @(
    '-EstateRoots', $Estate,
    '-UserHome', $TestHome,
    '-AuditInputPath', $AuditPath,
    '-EnterpriseCursorHooksPath', $EnterpriseHooks,
    '-Format', 'Json'
)
Assert-True ($plannerResult.ExitCode -eq 0) "fixture planner failed: $($plannerResult.ErrorText) $($plannerResult.Text)"
Assert-True ([string]::IsNullOrWhiteSpace($plannerResult.ErrorText)) 'fixture planner emitted stderr'
Assert-True (-not $plannerResult.Text.Contains($secretSentinel)) 'fixture planner exposed the MCP credential sentinel'
Write-Utf8 $PlanPath $plannerResult.Text
$planHash = Get-RawSha $PlanPath
$plan = $plannerResult.Text | ConvertFrom-Json
$plannedRepo = @($plan.repositories | Where-Object path -eq $project)[0]
Assert-True ($plannedRepo.plan_state -eq 'REVIEW_REQUIRED') 'fixture repository is not review-required'
Assert-True ($plannedRepo.actions.Count -eq 7) 'fixture action count mismatch'

$repoBefore = Get-TreeDigest $project
$gitBefore = Get-TreeDigest (Join-Path $project '.git')
$homeBefore = Get-TreeDigest $TestHome
$planBefore = Get-RawSha $PlanPath
$sourcePaths = @($plannedRepo.actions | Where-Object generated_source | ForEach-Object { $_.generated_source.path } | Sort-Object -Unique)
$sourceBefore = @{}
foreach ($path in $sourcePaths) { $sourceBefore[$path] = Get-RawSha $path }

Assert-True (-not [string]::IsNullOrWhiteSpace($WindowsPowerShell)) 'Windows PowerShell 5.1 is required'
Assert-True (-not [string]::IsNullOrWhiteSpace($PowerShellCore)) 'PowerShell 7 is required'
$ps5Result = Invoke-Renderer $WindowsPowerShell $PlanPath $planHash $project
$ps7Result = Invoke-Renderer $PowerShellCore $PlanPath $planHash $project
Assert-True ($ps5Result.ExitCode -eq 0) "PS5 renderer failed: $($ps5Result.ErrorText)"
Assert-True ($ps7Result.ExitCode -eq 0) "PS7 renderer failed: $($ps7Result.ErrorText)"
Assert-True ([string]::IsNullOrWhiteSpace($ps5Result.ErrorText)) 'PS5 renderer emitted stderr'
Assert-True ([string]::IsNullOrWhiteSpace($ps7Result.ErrorText)) 'PS7 renderer emitted stderr'
Assert-True ($ps5Result.Text -ceq $ps7Result.Text) 'PS5 and PS7 renderer bytes differ'
Assert-True ((Get-TextSha $ps5Result.Text) -eq (Get-TextSha $ps7Result.Text)) 'PS5 and PS7 renderer SHA-256 differs'
Assert-True (-not $ps5Result.Text.Contains($secretSentinel)) 'renderer exposed the MCP credential sentinel'

$stdinResult = Invoke-ScriptProcess $PowerShellCore $Renderer @(
    '-PlanFromStandardInput',
    '-ExpectedPlanSha256', (Get-TextSha $plannerResult.Text),
    '-RepositoryPath', $project
) $plannerResult.Text
Assert-True ($stdinResult.ExitCode -eq 0) "standard-input renderer failed: $($stdinResult.ErrorText)"
Assert-True ([string]::IsNullOrWhiteSpace($stdinResult.ErrorText)) 'standard-input renderer emitted stderr'
$stdinJson = $stdinResult.Text | ConvertFrom-Json
Assert-True ($stdinJson.plan.path -eq '<standard-input>') 'standard-input renderer did not identify its input mode'
Assert-True ($stdinJson.plan.sha256 -eq (Get-TextSha $plannerResult.Text)) 'standard-input renderer did not hash the parsed bytes'
Assert-True ($stdinJson.summary.rendered_content_diffs -eq 6 -and $stdinJson.summary.withheld_actions -eq 1) 'standard-input renderer summary mismatch'
Assert-True (-not $stdinResult.Text.Contains($secretSentinel)) 'standard-input renderer exposed the MCP sentinel'

$result = $ps7Result.Text | ConvertFrom-Json
Assert-True ($result.schema_version -eq 1) 'renderer schema version mismatch'
Assert-True ($result.mode -eq 'READ_ONLY_IN_MEMORY_DIFF_NO_FETCH_NO_WRITE') 'renderer mode mismatch'
Assert-True ($result.plan.sha256 -eq $planHash) 'renderer did not carry the independent plan seal'
Assert-True ($result.overall_state -eq 'PARTIAL_PREVIEW_HELD') 'renderer did not preserve partial/held truth'
Assert-True ($result.summary.selected_actions -eq 7) 'selected-action count mismatch'
Assert-True ($result.summary.rendered_content_diffs -eq 6) 'rendered-action count mismatch'
Assert-True ($result.summary.withheld_actions -eq 1) 'withheld-action count mismatch'
Assert-True ($result.summary.project_write_count -eq 0 -and $result.summary.fetch_count -eq 0) 'renderer reported a write or fetch'
Assert-True ($result.repositories.Count -eq 1) 'renderer repository count mismatch'
Assert-True ($result.repositories[0].current_snapshot_matches -eq $true) 'current Git snapshot did not match the plan'
Assert-True ($result.repositories[0].current_registry_state -eq 'NO_REFERENCE') 'registry state mismatch'

$actionResults = @($result.repositories[0].actions)
$rendered = @($actionResults | Where-Object status -eq 'RENDERED_PREVIEW_HELD')
$withheld = @($actionResults | Where-Object status -ne 'RENDERED_PREVIEW_HELD')
Assert-True ($rendered.Count -eq 6) 'six deterministic actions were not rendered'
Assert-True ($withheld.Count -eq 1) 'exactly one action was not withheld'
Assert-True ($withheld[0].action -eq 'REMOVE_LEGACY_AUTHORIZATION_WITHOUT_OUTPUTTING_VALUE') 'wrong action was withheld'
Assert-True ($withheld[0].status -eq 'WITHHELD_CREDENTIAL_SAFE_STRUCTURAL_ONLY') 'MCP action was not structurally withheld'
Assert-True ($withheld[0].reason -eq 'server=dreameros; headers.Authorization: PRESENT -> ABSENT') 'MCP structural summary mismatch'
Assert-True (-not ($withheld[0].PSObject.Properties.Name -contains 'unified_diff')) 'MCP action received a content diff'
Assert-True (@($rendered | Where-Object { [string]::IsNullOrWhiteSpace($_.unified_diff) }).Count -eq 0) 'a rendered action has an empty diff'
Assert-True (@($rendered | Where-Object { $_.unified_diff -match '(?i)\.cursor/mcp\.json|Bearer\s+S' }).Count -eq 0) 'a rendered diff mentions MCP credential content'
Assert-True (@($rendered | Where-Object action -eq 'REPLACE_GENERATED_BOOT_REGION_WITH_POINTER').Count -eq 2) 'embedded-region actions missing'
Assert-True (@($rendered | Where-Object action -eq 'MIGRATE_CURSOR_RULE_WITH_SYNC_TOOL').Count -eq 1) 'Cursor pointer action missing'
Assert-True (@($rendered | Where-Object action -eq 'REPLACE_LEGACY_GENERATOR_WITH_POINTER_STUB').Count -eq 1) 'generator action missing'
Assert-True (@($rendered | Where-Object action -eq 'REPLACE_WITH_GENERATED_CURSOR_ADAPTER').Count -eq 1) 'adapter action missing'
Assert-True (@($rendered | Where-Object action -eq 'REPLACE_WITH_GENERATED_THIN_CLAUDE_HOOK').Count -eq 1) 'Claude hook action missing'
Assert-True (@($rendered | Where-Object action -eq 'REPLACE_GENERATED_BOOT_REGION_WITH_POINTER' | Where-Object outside_region_bytes_verified -ne $true).Count -eq 0) 'outside-region byte preservation was not proved'

$patchText = @($rendered | Sort-Object target | ForEach-Object unified_diff) -join "`n"
$patchPath = Join-Path $TempRoot 'rendered.patch'
Write-Utf8 $patchPath $patchText
$applyCopy = Join-Path $TempRoot 'disposable apply copy'
& git -c core.autocrlf=false clone --quiet --no-hardlinks $project $applyCopy
if ($LASTEXITCODE -ne 0) { throw 'Disposable clone failed.' }
& git -C $applyCopy config core.autocrlf false
& git -C $applyCopy apply --check $patchPath
Assert-True ($LASTEXITCODE -eq 0) 'rendered patch failed git apply --check'
& git -C $applyCopy apply $patchPath
Assert-True ($LASTEXITCODE -eq 0) 'rendered patch failed in the disposable copy'
foreach ($action in $rendered) {
    $relative = $action.target.Substring($project.Length).TrimStart('\')
    $applied = Join-Path $applyCopy $relative
    Assert-True ((Get-RawSha $applied) -eq $action.proposed_sha256) "applied bytes do not match proposed hash for $($action.action)"
}
$copyMcp = Join-Path $applyCopy '.cursor\mcp.json'
Assert-True ([IO.File]::ReadAllText($copyMcp).Contains($secretSentinel)) 'disposable apply altered the withheld MCP file'

$adapterId = @($plannedRepo.actions | Where-Object action -eq 'REPLACE_WITH_GENERATED_CURSOR_ADAPTER')[0].id
$singleResult = Invoke-Renderer $PowerShellCore $PlanPath $planHash $project @($adapterId)
Assert-True ($singleResult.ExitCode -eq 0) "single-action JSON failed: $($singleResult.ErrorText)"
Assert-True ([string]::IsNullOrWhiteSpace($singleResult.ErrorText)) 'single-action JSON emitted stderr'
$singleJson = $singleResult.Text | ConvertFrom-Json
$singleAction = @($singleJson.repositories[0].actions)[0]
Assert-True ($singleJson.summary.selected_actions -eq 1 -and $singleJson.summary.rendered_content_diffs -eq 1) 'single-action JSON selection mismatch'
Assert-True ($singleAction.id -eq $adapterId -and $singleAction.status -eq 'RENDERED_PREVIEW_HELD') 'single-action JSON did not retain HELD status'
Assert-True ($singleAction.apply_status -eq 'HELD' -and $singleAction.human_conductor_authorization_required -eq $true -and $singleAction.fresh_fetch_required -eq $true) 'single-action JSON stripped an authorization gate'
Assert-True ($singleJson.repositories[0].apply_preflight -eq 'FRESH_FETCH_CURRENT_MAIN_AND_SEPARATE_AUTHORIZATION_REQUIRED') 'single-action JSON stripped the apply preflight'
Assert-True (-not $singleResult.Text.Contains($secretSentinel)) 'single-action JSON exposed the MCP sentinel'

$mcpId = @($plannedRepo.actions | Where-Object action -eq 'REMOVE_LEGACY_AUTHORIZATION_WITHOUT_OUTPUTTING_VALUE')[0].id
$mcpSelected = Invoke-Renderer $PowerShellCore $PlanPath $planHash $project @($mcpId)
Assert-True ($mcpSelected.ExitCode -eq 0) "selected MCP JSON failed: $($mcpSelected.ErrorText)"
$mcpSelectedJson = $mcpSelected.Text | ConvertFrom-Json
Assert-True ($mcpSelectedJson.summary.rendered_content_diffs -eq 0 -and $mcpSelectedJson.summary.withheld_actions -eq 1) 'selected MCP action was not withheld'
Assert-True (-not $mcpSelected.Text.Contains($secretSentinel)) 'selected MCP JSON exposed the sentinel'

$unsupportedFormat = Invoke-ScriptProcess $PowerShellCore $Renderer @(
    '-PlanPath', $PlanPath,
    '-ExpectedPlanSha256', $planHash,
    '-RepositoryPath', $project,
    '-Format', 'UnifiedDiff'
)
Assert-True ($unsupportedFormat.ExitCode -ne 0) 'removed standalone UnifiedDiff mode is still callable'
Assert-True ([string]::IsNullOrWhiteSpace($unsupportedFormat.Text)) 'removed standalone UnifiedDiff mode emitted stdout'
Assert-True (-not $unsupportedFormat.ErrorText.Contains($secretSentinel)) 'removed-format failure exposed the sentinel'

$wrongHash = Invoke-Renderer $PowerShellCore $PlanPath ('0' * 64) $project
Assert-True ($wrongHash.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($wrongHash.Text)) 'wrong plan hash did not fail before stdout'
Assert-True (-not $wrongHash.ErrorText.Contains($secretSentinel)) 'wrong-hash failure exposed the sentinel'

$duplicatePlanPath = Join-Path $TempRoot 'duplicate-key plan.json'
$duplicateText = $plannerResult.Text.Insert(1, '"schema_version":1,')
Write-Utf8 $duplicatePlanPath $duplicateText
$duplicateResult = Invoke-Renderer $PowerShellCore $duplicatePlanPath (Get-RawSha $duplicatePlanPath) $project
Assert-True ($duplicateResult.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($duplicateResult.Text)) 'duplicate JSON key did not fail closed'
Assert-True ($duplicateResult.ErrorText -match 'Duplicate JSON[\s\S]*object key') 'duplicate-key failure signature missing'

$unknownPlanPath = Join-Path $TempRoot 'unknown-property plan.json'
$unknownPlan = $plannerResult.Text | ConvertFrom-Json
$unknownPlan | Add-Member -NotePropertyName unexpected_write_mode -NotePropertyValue 'apply'
Write-JsonFixture $unknownPlanPath $unknownPlan
$unknownResult = Invoke-Renderer $PowerShellCore $unknownPlanPath (Get-RawSha $unknownPlanPath) $project
Assert-True ($unknownResult.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($unknownResult.Text)) 'unknown plan property did not fail closed'

$sourceMismatchPath = Join-Path $TempRoot 'source-mismatch plan.json'
$sourceMismatchPlan = $plannerResult.Text | ConvertFrom-Json
$sourceAction = @($sourceMismatchPlan.repositories[0].actions | Where-Object generated_source)[0]
$sourceAction.generated_source.sha256 = '0' * 64
Write-JsonFixture $sourceMismatchPath $sourceMismatchPlan
$sourceMismatch = Invoke-Renderer $PowerShellCore $sourceMismatchPath (Get-RawSha $sourceMismatchPath) $project
Assert-True ($sourceMismatch.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($sourceMismatch.Text)) 'generated-source mismatch did not fail closed'
Assert-True ($sourceMismatch.ErrorText -match 'Generated source SHA-256') 'generated-source mismatch signature missing'

$isolatedPlugin = Join-Path $TempRoot 'isolated plugin source'
$isolatedRenderer = Join-Path $isolatedPlugin 'install\cursor\render-project-migration-diffs.ps1'
New-Item -ItemType Directory -Path (Split-Path -Parent $isolatedRenderer) -Force | Out-Null
Copy-Item -LiteralPath $Renderer -Destination $isolatedRenderer
$credentialPlan = $plannerResult.Text | ConvertFrom-Json
foreach ($action in @($credentialPlan.repositories[0].actions | Where-Object generated_source)) {
    $sourcePath = [IO.Path]::GetFullPath([string]$action.generated_source.path)
    $relativeSource = $sourcePath.Substring($RepoRoot.Length).TrimStart('\')
    $isolatedSource = Join-Path $isolatedPlugin $relativeSource
    New-Item -ItemType Directory -Path (Split-Path -Parent $isolatedSource) -Force | Out-Null
    if (-not (Test-Path -LiteralPath $isolatedSource -PathType Leaf)) {
        Copy-Item -LiteralPath $sourcePath -Destination $isolatedSource
    }
    $action.generated_source.path = $isolatedSource
    $action.generated_source.sha256 = Get-RawSha $isolatedSource
}
$credentialSentinel = 'Q' * 48
$credentialAdapterAction = @($credentialPlan.repositories[0].actions | Where-Object action -eq 'REPLACE_WITH_GENERATED_CURSOR_ADAPTER')[0]
$credentialAdapterPath = [string]$credentialAdapterAction.generated_source.path
[IO.File]::AppendAllText($credentialAdapterPath, "`ntoken=$credentialSentinel", $Utf8)
$credentialAdapterAction.generated_source.sha256 = Get-RawSha $credentialAdapterPath
$credentialPlanPath = Join-Path $TempRoot 'credential-source plan.json'
Write-JsonFixture $credentialPlanPath $credentialPlan
$isolatedSourceBefore = Get-TreeDigest $isolatedPlugin
$credentialResult = Invoke-ScriptProcess $PowerShellCore $isolatedRenderer @(
    '-PlanPath', $credentialPlanPath,
    '-ExpectedPlanSha256', (Get-RawSha $credentialPlanPath),
    '-RepositoryPath', $project
)
Assert-True ($credentialResult.ExitCode -eq 0) "credential-source render failed: $($credentialResult.ErrorText)"
Assert-True (-not $credentialResult.Text.Contains($credentialSentinel)) 'generated-source credential sentinel reached output'
$credentialJson = $credentialResult.Text | ConvertFrom-Json
$credentialAdapterResult = @($credentialJson.repositories[0].actions | Where-Object action -eq 'REPLACE_WITH_GENERATED_CURSOR_ADAPTER')[0]
Assert-True ($credentialAdapterResult.status -eq 'WITHHELD_TARGET_REVALIDATION') 'credential-bearing generated source was rendered'
Assert-True ($credentialAdapterResult.reason -match 'credential-value shape') 'credential-source refusal reason missing'
Assert-True (-not ($credentialAdapterResult.PSObject.Properties.Name -contains 'unified_diff')) 'credential-bearing generated source received a diff'
Assert-True ((Get-TreeDigest $isolatedPlugin) -eq $isolatedSourceBefore) 'renderer changed the isolated generated-source tree'

$badMcpTuplePath = Join-Path $TempRoot 'bad-mcp-tuple plan.json'
$badMcpTuplePlan = $plannerResult.Text | ConvertFrom-Json
$badMcpRepo = $badMcpTuplePlan.repositories[0]
$adapterFinding = @($badMcpRepo.findings | Where-Object kind -eq 'ADAPTER')[0]
$adapterAction = @($badMcpRepo.actions | Where-Object id -eq $adapterFinding.action_id)[0]
$adapterAction.action = 'REMOVE_LEGACY_AUTHORIZATION_WITHOUT_OUTPUTTING_VALUE'
$adapterAction.generated_source = $null
$adapterAction.id = Get-ActionIdentity $adapterAction.action $adapterFinding
$adapterFinding.action_id = $adapterAction.id
Write-JsonFixture $badMcpTuplePath $badMcpTuplePlan
$badMcpTuple = Invoke-Renderer $PowerShellCore $badMcpTuplePath (Get-RawSha $badMcpTuplePath) $project
Assert-True ($badMcpTuple.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($badMcpTuple.Text)) 'malformed MCP tuple did not fail closed'
Assert-True ($badMcpTuple.ErrorText -match 'MCP Authorization action') 'malformed MCP tuple failure signature missing'

$stalePlanPath = Join-Path $TempRoot 'stale plan.json'
$stalePlan = $plannerResult.Text | ConvertFrom-Json
$stalePlan.generated_utc = [DateTime]::UtcNow.AddMinutes(-6).ToString('o')
Write-JsonFixture $stalePlanPath $stalePlan
$staleResult = Invoke-Renderer $PowerShellCore $stalePlanPath (Get-RawSha $stalePlanPath) $project
Assert-True ($staleResult.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($staleResult.Text)) 'stale dynamic plan did not fail closed'
Assert-True ($staleResult.ErrorText -match 'five-minute dynamic-state limit') 'stale-plan failure signature missing'

$uncResult = Invoke-ScriptProcess $PowerShellCore $Renderer @(
    '-PlanPath', '\\localhost\never-read\plan.json',
    '-ExpectedPlanSha256', ('0' * 64),
    '-RepositoryPath', $project
)
Assert-True ($uncResult.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($uncResult.Text)) 'UNC plan path did not fail before output'
Assert-True ($uncResult.ErrorText -match 'local filesystem path') 'UNC rejection signature missing'

$invalidUtf8Path = Join-Path $TempRoot 'invalid-utf8 plan.json'
[IO.File]::WriteAllBytes($invalidUtf8Path, [byte[]]@(0x7B, 0x22, 0x78, 0x22, 0x3A, 0xC3, 0x28, 0x7D))
$invalidUtf8 = Invoke-Renderer $PowerShellCore $invalidUtf8Path (Get-RawSha $invalidUtf8Path) $project
Assert-True ($invalidUtf8.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($invalidUtf8.Text)) 'invalid UTF-8 plan did not fail closed'
Assert-True ($invalidUtf8.ErrorText -match 'strict UTF-8') 'invalid UTF-8 failure signature missing'

Assert-True ((Get-TreeDigest $project) -eq $repoBefore) 'renderer changed the fixture repository'
Assert-True ((Get-TreeDigest (Join-Path $project '.git')) -eq $gitBefore) 'renderer changed fixture Git metadata'
Assert-True ((Get-TreeDigest $TestHome) -eq $homeBefore) 'renderer changed user or enterprise configuration'
Assert-True ((Get-RawSha $PlanPath) -eq $planBefore) 'renderer changed the sealed plan'
foreach ($path in $sourcePaths) { Assert-True ((Get-RawSha $path) -eq $sourceBefore[$path]) "renderer changed generated source $path" }
Assert-True (@(& git -C $project status --porcelain=v1 --untracked-files=all).Count -eq 0) 'renderer dirtied the fixture worktree'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $project '.git\index.lock'))) 'renderer left a Git index lock'

Write-Output (@{
    status = 'pass'
    assertions = $Cases
    fixture_root = $TempRoot
    ps5_ps7_sha256 = Get-TextSha $ps5Result.Text
} | ConvertTo-Json -Compress)

# The last child process above may be a deliberate failure run that exits
# non-zero. GitHub's powershell step wrapper ends with "exit $LASTEXITCODE",
# so without this line a passing test reports failure. Every assertion
# throws on failure, so reaching here means pass.
exit 0
