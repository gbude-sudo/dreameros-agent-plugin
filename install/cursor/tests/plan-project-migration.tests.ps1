$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Planner = Join-Path $RepoRoot 'install\cursor\plan-project-migration.ps1'
$PowerShellExe = (Get-Process -Id $PID).Path
$TempRoot = Join-Path $env:TEMP ('dreameros migration plan tests-' + [guid]::NewGuid().ToString('N'))
$Estate = Join-Path $TempRoot 'estate'
$TestHome = Join-Path $TempRoot 'home'
$TestEnterpriseHooks = Join-Path $TestHome 'enterprise\Cursor\hooks.json'
$Utf8 = [Text.UTF8Encoding]::new($false)
$Cases = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:Cases++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function New-TestRepo([string]$Name, [string[]]$RelativePaths) {
    $root = Join-Path $Estate $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    foreach ($relative in $RelativePaths) {
        $path = Join-Path $root $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, "fixture $relative", $Utf8)
    }
    & git -C $root init -b main --quiet
    & git -C $root config user.name 'DreamerOS Planner Test'
    & git -C $root config user.email 'planner-test@dreameros.invalid'
    & git -C $root add .
    & git -C $root commit -m fixture --quiet
    if ($LASTEXITCODE -ne 0) { throw "Fixture commit failed: $root" }
    return $root
}

function Invoke-Planner(
    [string]$AuditPath = '',
    [string]$Format = 'Json',
    [string[]]$EstateRoot = @($Estate),
    [string]$Executable = $PowerShellExe
) {
    $rootLiteral = @($EstateRoot | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
    $command = "& '$Planner' -EstateRoots @($rootLiteral) -UserHome '$TestHome' -EnterpriseCursorHooksPath '$TestEnterpriseHooks' -Format '$Format'"
    if ($AuditPath) { $command += " -AuditInputPath '$AuditPath'" }
    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $Executable -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $priorPreference
    }
    return [pscustomobject]@{ ExitCode = $code; Text = ($output -join "`n") }
}

function Invoke-PlannerProcessStartInfo([string]$AuditPath) {
    function Quote-ProcessArgument([string]$Value) {
        if ($Value.Contains('"')) { throw 'Process argument contains an unsupported quote character.' }
        return '"' + $Value + '"'
    }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File $(Quote-ProcessArgument $Planner) -EstateRoots $(Quote-ProcessArgument $Estate) -UserHome $(Quote-ProcessArgument $TestHome) -AuditInputPath $(Quote-ProcessArgument $AuditPath) -EnterpriseCursorHooksPath $(Quote-ProcessArgument $TestEnterpriseHooks) -Format Json"
    $psi.WorkingDirectory = $RepoRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $null = $process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Text = $stdoutTask.Result
        ErrorText = $stderrTask.Result
    }
}

function Get-TreeDigest([string]$Path) {
    $lines = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($Path.Length).TrimStart('\').Replace('\', '/')
        "$relative|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"
    })
    $bytes = $Utf8.GetBytes(($lines -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

New-Item -ItemType Directory -Path $Estate -Force | Out-Null
New-Item -ItemType Directory -Path $TestHome -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $TestEnterpriseHooks) -Force | Out-Null
$userHook = Join-Path $TestHome '.claude\hooks\dreameros-session-start.sh'
New-Item -ItemType Directory -Path (Split-Path -Parent $userHook) -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $RepoRoot 'bootpack\out\claude\dreameros-session-start.sh') -Destination $userHook
$userSettings = Join-Path $TestHome '.claude\settings.json'
[IO.File]::WriteAllText($userSettings, (@{
    hooks = @{
        SessionStart = @(@{
            hooks = @(@{ type = 'command'; command = ('bash "' + $userHook.Replace('\', '/') + '"') })
        })
    }
} | ConvertTo-Json -Depth 8), $Utf8)

$repoA = New-TestRepo 'repo-a' @(
    'CLAUDE.md',
    'AGENTS.md',
    '.cursor\rules\dreameros-boot-canon.mdc',
    '.cursor\rules\answer-from-measurement.mdc',
    '.cursor\mcp.json',
    '.claude\hooks\dreameros-session-start.sh',
    'governance\bootpack\build-boot-pack.ps1',
    'governance\CANON_REGISTRY.json'
)
[IO.File]::WriteAllText(
    (Join-Path $repoA 'governance\CANON_REGISTRY.json'),
    '{"files":[{"path":".cursor/rules/dreameros-boot-canon.mdc"}]}',
    $Utf8)
$secretSentinel = 'Bearer ' + ('S' * 32)
[IO.File]::WriteAllText((Join-Path $repoA '.cursor\mcp.json'), (@{
    mcpServers = @{
        dreameros = @{
            type = 'http'
            url = 'https://mcp.dreameros.app/mcp'
            headers = @{ Authorization = $secretSentinel }
        }
    }
} | ConvertTo-Json -Depth 8), $Utf8)
& git -C $repoA add governance/CANON_REGISTRY.json
& git -C $repoA add .cursor/mcp.json
& git -C $repoA commit -m registry --quiet

$repoB = New-TestRepo 'repo-b' @(
    'CLAUDE.md',
    'AGENTS.md'
)

$auditPath = Join-Path $TempRoot 'audit.txt'
$auditLines = @(
    "LEGACY_FULL_COPY FILE-CLEAN CLAUDE $repoA\CLAUDE.md",
    "LEGACY_FULL_COPY FILE-CLEAN CODEX $repoA\AGENTS.md",
    "LEGACY_FULL_COPY FILE-CLEAN CURSOR $repoA\.cursor\rules\dreameros-boot-canon.mdc",
    "GLOBAL_ONLY FILE-CLEAN CLAUDE $repoB\CLAUDE.md",
    "GLOBAL_ONLY FILE-CLEAN CODEX $repoB\AGENTS.md",
    "GLOBAL_ONLY FILE-CLEAN CURSOR $repoB\.cursor\rules\dreameros-boot-canon.mdc",
    "LEGACY_FULL_GENERATOR FILE-CLEAN GENERATOR $repoA\governance\bootpack\build-boot-pack.ps1",
    "STALE_ADAPTER_COPY FILE-CLEAN ADAPTER $repoA\.cursor\rules\answer-from-measurement.mdc",
    "STALE_BOOT_HOOK FILE-CLEAN CLAUDE_BOOT_HOOK registration=REGISTERED $repoA\.claude\hooks\dreameros-session-start.sh",
    "PROJECT_MCP_AUTH_HEADER FILE-CLEAN CURSOR_PROJECT_MCP server=dreameros $repoA\.cursor\mcp.json",
    "DUPLICATE_EMBEDDED_EXCERPT CLAUDE $repoA\CLAUDE.md",
    "USER_CLAUDE_BOOT_ALIGNED USER_CLAUDE_BOOT exact=1 other_hydration=0 $userHook",
    'USER_CLAUDE_MANAGED_HOOK_POLICY=UNVERIFIED_LIVE verify in Claude Code',
    'CURSOR_TEAM_HOOK_POLICY=UNVERIFIED_LIVE verify in Cursor Customize',
    'DREAMEROS_AUDIT_OUTCOME=FINDINGS',
    'repos=2 surfaces=6 GLOBAL_ONLY=3 POINTER_ALIGNED=0 LEGACY_FULL_COPY=3 POINTER_DRIFT=0 UNKNOWN=0 generators=1 LEGACY_FULL_GENERATOR=1 UNKNOWN_GENERATOR=0 ADAPTER_ALIGNED=0 ADAPTER_DRIFT=0 STALE_ADAPTER_COPY=1 ADAPTER_PATH_DRIFT=0 CLAUDE_BOOT_HOOKS=1 BOOT_HOOK_ALIGNED=0 STALE_BOOT_HOOK=1 BOOT_HOOK_OTHER=0 PROJECT_MCP_RECORDS=1 PROJECT_MCP_AUTH_HEADER=1 PROJECT_MCP_SHADOW=0 PROJECT_MCP_ENDPOINT_SHADOW=0 LEGACY_PROJECT_MCP=0 PROJECT_MCP_UNKNOWN=0 CURSOR_HOOK_SHADOWS=0 REPARSE_CHILD_SKIPPED=0 CURSOR_TEAM_HOOK_POLICY=UNVERIFIED_LIVE USER_CLAUDE_BOOT=USER_CLAUDE_BOOT_ALIGNED USER_CLAUDE_MANAGED_HOOK_POLICY=UNVERIFIED_LIVE USER_MCP_RECORDS=0 DUPLICATE_EMBEDDED_EXCERPT=1 DUPLICATE_RULE_EXCERPT=0'
)
[IO.File]::WriteAllLines($auditPath, $auditLines, $Utf8)

$jsonResult = Invoke-Planner $auditPath
Assert-True ($jsonResult.ExitCode -eq 0) "JSON planner failed: $($jsonResult.Text)"
$plan = $jsonResult.Text | ConvertFrom-Json
Assert-True ($plan.schema_version -eq 1) 'schema version mismatch'
Assert-True ($plan.mode -eq 'READ_ONLY_NO_FETCH_NO_PROJECT_WRITE') 'read-only mode missing'
Assert-True ($plan.audit_outcome -eq 'CAPTURED') 'captured audit mode missing'
Assert-True ($plan.audit_reported_outcome -eq 'FINDINGS') 'captured audit reported outcome missing'
Assert-True ($plan.requested_estate_roots.Count -eq 1 -and $plan.missing_estate_roots.Count -eq 0) 'estate-root accounting mismatch'
Assert-True ($plan.overall_state -eq 'PARTIAL') 'overall state must be partial'
Assert-True ($plan.repositories.Count -eq 2) 'repository count mismatch'
Assert-True ($plan.parser_reconciliation.surfaces -eq 6) 'surface reconciliation mismatch'
Assert-True ($plan.parser_reconciliation.adapters -eq 1) 'adapter reconciliation mismatch'
Assert-True ($plan.parser_reconciliation.user_claude_boot_records -eq 1) 'user Claude reconciliation mismatch'
Assert-True ($plan.parser_reconciliation.live_policy_records -eq 2) 'live-policy reconciliation mismatch'
Assert-True ($plan.parser_reconciliation.reparse_children -eq 0) 'reparse-child reconciliation mismatch'
Assert-True ($plan.global_findings.Count -eq 3) 'global finding count mismatch'
Assert-True ($plan.global_actions.Count -eq 2) 'global action count mismatch'

$plannedA = @($plan.repositories | Where-Object path -eq $repoA)[0]
$plannedB = @($plan.repositories | Where-Object path -eq $repoB)[0]
Assert-True ($plannedA.cursor_rule_registry -eq 'TRACKS_RULE') 'registry reference was not detected'
Assert-True ($plannedA.plan_state -eq 'ATOMIC_REGISTRY_REVIEW_REQUIRED') 'atomic registry plan state missing'
Assert-True ($plannedA.findings.Count -eq 8) 'repo-a finding count mismatch'
Assert-True ($plannedA.actions.Count -eq 8) 'repo-a action count mismatch'
Assert-True (@($plannedA.actions | Where-Object action -eq 'REMOVE_LEGACY_AUTHORIZATION_WITHOUT_OUTPUTTING_VALUE').Count -eq 1) 'MCP structural action missing'
Assert-True (@($plannedA.actions | Where-Object action -eq 'REPLACE_WITH_GENERATED_CURSOR_ADAPTER').Count -eq 1) 'adapter action missing'
Assert-True ($plannedA.git.fresh_fetch_required -eq $true) 'fresh-fetch gate missing'
Assert-True ($plannedB.plan_state -eq 'NO_MIGRATION_ACTION') 'global-only repo should have no action'
Assert-True ($plannedB.actions.Count -eq 0) 'global-only repo received an action'
Assert-True (-not $jsonResult.Text.Contains($secretSentinel)) 'planner output exposed the sentinel credential value'
Assert-True (@(& git -C $repoA status --porcelain=v1).Count -eq 0) 'planner changed repo-a'
Assert-True (@(& git -C $repoB status --porcelain=v1).Count -eq 0) 'planner changed repo-b'

$redirectedProcessResult = Invoke-PlannerProcessStartInfo $auditPath
Assert-True ($redirectedProcessResult.ExitCode -eq 0) "ProcessStartInfo planner failed: $($redirectedProcessResult.ErrorText)"
Assert-True (-not [string]::IsNullOrWhiteSpace($redirectedProcessResult.Text)) 'ProcessStartInfo planner emitted empty stdout'
Assert-True ([string]::IsNullOrWhiteSpace($redirectedProcessResult.ErrorText)) 'ProcessStartInfo planner emitted stderr'
$redirectedProcessPlan = $redirectedProcessResult.Text | ConvertFrom-Json
Assert-True ($null -ne $redirectedProcessPlan -and $redirectedProcessPlan.repositories.Count -eq 2) 'ProcessStartInfo planner output was not parseable JSON'

$repoAGitBefore = Get-TreeDigest (Join-Path $repoA '.git')
$repoBGitBefore = Get-TreeDigest (Join-Path $repoB '.git')
$testHomeBefore = Get-TreeDigest $TestHome
$integratedResult = Invoke-Planner
Assert-True ($integratedResult.ExitCode -eq 0) "default-path planner failed: $($integratedResult.Text)"
$integratedPlan = $integratedResult.Text | ConvertFrom-Json
Assert-True ($integratedPlan.audit_outcome -eq 'FINDINGS') 'default audit outcome must report findings'
Assert-True ($integratedPlan.repositories.Count -eq 2) 'default-path repository count mismatch'
Assert-True (-not $integratedResult.Text.Contains($secretSentinel)) 'default-path output exposed the sentinel credential value'
Assert-True ((Get-TreeDigest (Join-Path $repoA '.git')) -eq $repoAGitBefore) 'default planner changed repo-a Git metadata'
Assert-True ((Get-TreeDigest (Join-Path $repoB '.git')) -eq $repoBGitBefore) 'default planner changed repo-b Git metadata'
Assert-True ((Get-TreeDigest $TestHome) -eq $testHomeBefore) 'default planner changed user or enterprise configuration'

$parallelOwnerFile = Join-Path $repoA 'parallel-owner.txt'
[IO.File]::WriteAllText($parallelOwnerFile, 'preserve parallel owner work', $Utf8)
$parallelOwnerHash = (Get-FileHash -LiteralPath $parallelOwnerFile -Algorithm SHA256).Hash
$dirtyResult = Invoke-Planner $auditPath
Assert-True ($dirtyResult.ExitCode -eq 0) "dirty-worktree planner failed: $($dirtyResult.Text)"
$dirtyPlan = $dirtyResult.Text | ConvertFrom-Json
$dirtyPlannedA = @($dirtyPlan.repositories | Where-Object path -eq $repoA)[0]
Assert-True ($dirtyPlannedA.plan_state -eq 'BLOCKED_DIRTY') 'whole-worktree dirty gate missing'
Assert-True (Test-Path -LiteralPath $parallelOwnerFile) 'planner removed parallel owner work'
Assert-True ((Get-FileHash -LiteralPath $parallelOwnerFile -Algorithm SHA256).Hash -eq $parallelOwnerHash) 'planner changed parallel owner bytes'
Move-Item -LiteralPath $parallelOwnerFile -Destination (Join-Path $TempRoot 'preserved-parallel-owner.txt')

$indexPath = Join-Path $repoA '.git\index'
$indexBytes = [IO.File]::ReadAllBytes($indexPath)
try {
    [IO.File]::WriteAllBytes($indexPath, [byte[]](0x42, 0x41, 0x44))
    $badGitResult = Invoke-Planner $auditPath
    Assert-True ($badGitResult.ExitCode -eq 0) "unreadable-Git planner failed: $($badGitResult.Text)"
    $badGitPlan = $badGitResult.Text | ConvertFrom-Json
    $badGitRepo = @($badGitPlan.repositories | Where-Object path -eq $repoA)[0]
    Assert-True ($badGitRepo.git.state -eq 'UNREADABLE') 'Git status failure did not become unreadable'
    Assert-True ($badGitRepo.plan_state -eq 'BLOCKED_GIT_STATE') 'unreadable Git state did not block the plan'
} finally {
    [IO.File]::WriteAllBytes($indexPath, $indexBytes)
}

$markdownResult = Invoke-Planner $auditPath 'Markdown'
Assert-True ($markdownResult.ExitCode -eq 0) "Markdown planner failed: $($markdownResult.Text)"
Assert-True ($markdownResult.Text -match '# DreamerOS Cursor Repository Migration Plan') 'Markdown heading missing'
Assert-True ($markdownResult.Text -match 'ATOMIC_REGISTRY_REVIEW_REQUIRED') 'Markdown plan state missing'
Assert-True ($markdownResult.Text -match 'Every tracked write requires separate Human Conductor authorization') 'Markdown held-back gate missing'
Assert-True ($markdownResult.Text -match 'REPLACE_GENERATED_BOOT_REGION_WITH_POINTER') 'Markdown boot action missing'
Assert-True ($markdownResult.Text -match 'REVIEW_AND_REMOVE_ONLY_VERIFIED_GENERATED_DUPLICATION') 'Markdown duplicate action missing'
Assert-True ($markdownResult.Text -match '## User and global findings') 'Markdown global section missing'
Assert-True (([regex]::Matches($markdownResult.Text, '\| UNVERIFIED_LIVE \| LIVE_POLICY \| [^|]+ \| VERIFY_IN_EFFECTIVE_CLIENT_UI \|')).Count -eq 2) 'Markdown live-policy actions are not linked exactly twice'
Assert-True ($markdownResult.Text -notmatch '\| UNVERIFIED_LIVE \| LIVE_POLICY \| [^|]+ \| NONE \|') 'Markdown rendered a live-policy finding without its action'
Assert-True ($markdownResult.Text -match 'Overall state: PARTIAL') 'Markdown overall state missing'
Assert-True ($markdownResult.Text -match 'Audit execution: CAPTURED') 'Markdown audit execution missing'
Assert-True ($markdownResult.Text -match 'Audit reported outcome: FINDINGS') 'Markdown reported outcome missing'
Assert-True ($markdownResult.Text -match '\| Action ID \| Action \| Target \| Apply status \| HC authorization \| Fresh fetch \| Generated source \| SHA-256 \| Notes \|') 'Markdown action-detail schema missing'
Assert-True ($markdownResult.Text -match '\| HELD \| True \| True \| .*DREAMEROS_BOOT_CANON_POINTER\.md\.block \| [a-f0-9]{64} \|') 'Markdown generated source, hash, and gates missing'

$scopeAuditPath = Join-Path $TempRoot 'audit-global-and-hook-scope.txt'
$scopePrefix = @($auditLines[0..($auditLines.Count - 3)] | ForEach-Object {
    if ($_ -match ' USER_CLAUDE_BOOT exact=') {
        "USER_CLAUDE_BOOT_REGISTRATION_DRIFT USER_CLAUDE_BOOT exact=0 other_hydration=1 $userHook"
    } else { $_ }
})
$scopeLines = $scopePrefix + @(
    "USER_MCP_AUTH_HEADER CURSOR_USER_MCP server=dreameros-platform $TestHome\.cursor\mcp.json",
    "CURSOR_PROJECT_HOOK_SHADOW FILE-CLEAN CURSOR_HOOK_SCOPE=PROJECT critical_events=1 $repoA\.cursor\hooks.json",
    "CURSOR_USER_HOOK_SHADOW FILE-CLEAN CURSOR_HOOK_SCOPE=USER critical_events=1 $TestHome\.cursor\hooks.json",
    "CURSOR_ENTERPRISE_HOOK_SHADOW FILE-CLEAN CURSOR_HOOK_SCOPE=ENTERPRISE critical_events=1 $TestEnterpriseHooks",
    $auditLines[-2],
    $auditLines[-1].Replace('CURSOR_HOOK_SHADOWS=0', 'CURSOR_HOOK_SHADOWS=3').Replace('USER_CLAUDE_BOOT=USER_CLAUDE_BOOT_ALIGNED', 'USER_CLAUDE_BOOT=USER_CLAUDE_BOOT_REGISTRATION_DRIFT').Replace('USER_MCP_RECORDS=0', 'USER_MCP_RECORDS=1')
)
[IO.File]::WriteAllLines($scopeAuditPath, $scopeLines, $Utf8)
$scopeResult = Invoke-Planner $scopeAuditPath
Assert-True ($scopeResult.ExitCode -eq 0) "global/hook scope planner failed: $($scopeResult.Text)"
$scopePlan = $scopeResult.Text | ConvertFrom-Json
$scopeRepoA = @($scopePlan.repositories | Where-Object path -eq $repoA)[0]
$projectHookAction = @($scopeRepoA.actions | Where-Object action -eq 'REVIEW_CURSOR_HOOK_PRECEDENCE')
Assert-True ($projectHookAction.Count -eq 1 -and $projectHookAction[0].fresh_fetch_required -eq $true) 'project Cursor hook did not require fresh fetch'
$globalHookActions = @($scopePlan.global_actions | Where-Object action -eq 'REVIEW_CURSOR_HOOK_PRECEDENCE')
Assert-True ($globalHookActions.Count -eq 2 -and @($globalHookActions | Where-Object fresh_fetch_required -eq $false).Count -eq 2) 'user/enterprise Cursor hooks did not stay outside fetch gate'
Assert-True (@($scopePlan.global_actions | Where-Object action -eq 'REVIEW_USER_MCP_CONFIG_WITHOUT_OUTPUTTING_VALUE').Count -eq 1) 'user MCP action missing'
Assert-True (@($scopePlan.global_actions | Where-Object action -eq 'REPAIR_USER_CLAUDE_BOOT_WITH_GENERATED_HOOK').Count -eq 1) 'misaligned user Claude action missing'

$windowsPowerShell = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
$powerShellCore = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
Assert-True (-not [string]::IsNullOrWhiteSpace($windowsPowerShell) -and -not [string]::IsNullOrWhiteSpace($powerShellCore)) 'both PowerShell engines are required for action-identity verification'
$ps5IdentityResult = Invoke-Planner $scopeAuditPath 'Json' @($Estate) $windowsPowerShell
$ps7IdentityResult = Invoke-Planner $scopeAuditPath 'Json' @($Estate) $powerShellCore
Assert-True ($ps5IdentityResult.ExitCode -eq 0 -and $ps7IdentityResult.ExitCode -eq 0) 'cross-engine identity planner invocation failed'
$ps5IdentityPlan = $ps5IdentityResult.Text | ConvertFrom-Json
$ps7IdentityPlan = $ps7IdentityResult.Text | ConvertFrom-Json
$ps5ActionIdentity = @(@($ps5IdentityPlan.repositories | ForEach-Object actions) + @($ps5IdentityPlan.global_actions) |
    Sort-Object target, action | ForEach-Object { "$($_.target)|$($_.action)|$($_.id)" }) -join "`n"
$ps7ActionIdentity = @(@($ps7IdentityPlan.repositories | ForEach-Object actions) + @($ps7IdentityPlan.global_actions) |
    Sort-Object target, action | ForEach-Object { "$($_.target)|$($_.action)|$($_.id)" }) -join "`n"
Assert-True ($ps5ActionIdentity -ceq $ps7ActionIdentity) 'action identities differ between PowerShell 5.1 and 7'

$reparseDigest = 'a' * 64
$reparseAuditPath = Join-Path $TempRoot 'audit-reparse-boundary.txt'
$reparseLines = @($auditLines[0..($auditLines.Count - 3)]) + @(
    "REPARSE_CHILD_SKIPPED path_digest=$reparseDigest",
    $auditLines[-2],
    $auditLines[-1].Replace('REPARSE_CHILD_SKIPPED=0', 'REPARSE_CHILD_SKIPPED=1')
)
[IO.File]::WriteAllLines($reparseAuditPath, $reparseLines, $Utf8)
$reparseResult = Invoke-Planner $reparseAuditPath
Assert-True ($reparseResult.ExitCode -eq 0) "reparse boundary planner failed: $($reparseResult.Text)"
$reparsePlan = $reparseResult.Text | ConvertFrom-Json
$reparseFinding = @($reparsePlan.global_findings | Where-Object kind -eq 'ESTATE_REPARSE_CHILD')
$reparseAction = @($reparsePlan.global_actions | Where-Object action -eq 'MANUAL_REVIEW_REPARSE_CHILD_OUTSIDE_AUDIT')
Assert-True ($reparseFinding.Count -eq 1 -and $reparsePlan.parser_reconciliation.reparse_children -eq 1) 'reparse boundary finding did not reconcile'
Assert-True ($reparseAction.Count -eq 1 -and $reparseAction[0].apply_status -eq 'BLOCKED') 'reparse boundary action was not blocked'
Assert-True ($reparseAction[0].target -eq "path_digest:$reparseDigest") 'reparse boundary action exposed more than the digest'

$badCountPath = Join-Path $TempRoot 'audit-bad-count.txt'
$badCountLines = @($auditLines)
$badCountLines[-1] = $badCountLines[-1].Replace('surfaces=6', 'surfaces=7')
[IO.File]::WriteAllLines($badCountPath, $badCountLines, $Utf8)
$badCountResult = Invoke-Planner $badCountPath
Assert-True ($badCountResult.ExitCode -ne 0) 'mismatched audit count must fail'
Assert-True ($badCountResult.Text -match 'Planner reconciliation failed') 'mismatched audit signature missing'

$stateMismatchPath = Join-Path $TempRoot 'audit-state-mismatch.txt'
$stateMismatchLines = @($auditLines)
$stateMismatchLines[0] = $stateMismatchLines[0].Replace('LEGACY_FULL_COPY', 'POINTER_DRIFT')
[IO.File]::WriteAllLines($stateMismatchPath, $stateMismatchLines, $Utf8)
$stateMismatchResult = Invoke-Planner $stateMismatchPath
Assert-True ($stateMismatchResult.ExitCode -ne 0) 'per-state mismatch must fail'
Assert-True ($stateMismatchResult.Text -match 'Planner reconciliation failed') 'per-state mismatch signature missing'

$manualPath = Join-Path $TempRoot 'audit-manual-states.txt'
$manualLines = @($auditLines)
$manualLines[0] = $manualLines[0].Replace('LEGACY_FULL_COPY', 'UNKNOWN')
$manualLines[6] = $manualLines[6].Replace('LEGACY_FULL_GENERATOR', 'UNKNOWN_GENERATOR')
$manualLines[8] = $manualLines[8].Replace('STALE_BOOT_HOOK FILE-CLEAN CLAUDE_BOOT_HOOK registration=REGISTERED', 'BOOT_HOOK_REGISTRATION_MULTIPLE FILE-CLEAN CLAUDE_BOOT_HOOK registration=MULTIPLE')
$manualLines[9] = $manualLines[9].Replace('PROJECT_MCP_AUTH_HEADER', 'PROJECT_MCP_CONFIG_UNKNOWN')
$manualLines[-1] = $manualLines[-1].Replace('LEGACY_FULL_COPY=3', 'LEGACY_FULL_COPY=2').Replace(' UNKNOWN=0 ', ' UNKNOWN=1 ')
$manualLines[-1] = $manualLines[-1].Replace('LEGACY_FULL_GENERATOR=1', 'LEGACY_FULL_GENERATOR=0').Replace('UNKNOWN_GENERATOR=0', 'UNKNOWN_GENERATOR=1')
$manualLines[-1] = $manualLines[-1].Replace('STALE_BOOT_HOOK=1', 'STALE_BOOT_HOOK=0').Replace('BOOT_HOOK_OTHER=0', 'BOOT_HOOK_OTHER=1')
$manualLines[-1] = $manualLines[-1].Replace('PROJECT_MCP_AUTH_HEADER=1', 'PROJECT_MCP_AUTH_HEADER=0').Replace('PROJECT_MCP_UNKNOWN=0', 'PROJECT_MCP_UNKNOWN=1')
[IO.File]::WriteAllLines($manualPath, $manualLines, $Utf8)
$manualResult = Invoke-Planner $manualPath
Assert-True ($manualResult.ExitCode -eq 0) "manual-state planner failed: $($manualResult.Text)"
$manualPlan = $manualResult.Text | ConvertFrom-Json
$manualRepo = @($manualPlan.repositories | Where-Object path -eq $repoA)[0]
Assert-True ($manualRepo.plan_state -eq 'MANUAL_REVIEW_BLOCKED') 'manual states did not block the repository plan'
foreach ($manualAction in @(
    'MANUAL_REVIEW_UNCLASSIFIED_BOOT_SURFACE',
    'MANUAL_REVIEW_UNCLASSIFIED_GENERATOR',
    'REVIEW_CLAUDE_HOOK_REGISTRATION_AND_CONTENT',
    'MANUAL_REVIEW_UNKNOWN_PROJECT_MCP_CONFIG'
)) {
    Assert-True (@($manualRepo.actions | Where-Object action -eq $manualAction).Count -eq 1) "missing manual action $manualAction"
}
Assert-True (@($manualRepo.actions | Where-Object apply_status -eq 'BLOCKED').Count -ge 4) 'manual actions were not marked blocked'

$userContradictionPath = Join-Path $TempRoot 'audit-user-metadata-contradiction.txt'
$userContradictionLines = @($auditLines | ForEach-Object {
    if ($_ -match '^USER_CLAUDE_BOOT_ALIGNED USER_CLAUDE_BOOT ') {
        $_.Replace('exact=1 other_hydration=0', 'exact=0 other_hydration=99')
    } else { $_ }
})
[IO.File]::WriteAllLines($userContradictionPath, $userContradictionLines, $Utf8)
$userContradictionResult = Invoke-Planner $userContradictionPath
Assert-True ($userContradictionResult.ExitCode -ne 0 -and $userContradictionResult.Text -match 'state/metadata contradiction') 'aligned user Claude state accepted contradictory counts'
Assert-True ($userContradictionResult.Text -notmatch 'other_hydration=99') 'user contradiction error echoed raw audit content'

$hookContradictionPath = Join-Path $TempRoot 'audit-hook-metadata-contradiction.txt'
$hookContradictionLines = @($auditLines)
$hookContradictionLines[8] = $hookContradictionLines[8].Replace(
    'STALE_BOOT_HOOK FILE-CLEAN CLAUDE_BOOT_HOOK registration=REGISTERED',
    'BOOT_HOOK_ALIGNED FILE-CLEAN CLAUDE_BOOT_HOOK registration=NOT_REGISTERED')
$hookContradictionLines[-1] = $hookContradictionLines[-1].Replace(
    'BOOT_HOOK_ALIGNED=0 STALE_BOOT_HOOK=1',
    'BOOT_HOOK_ALIGNED=1 STALE_BOOT_HOOK=0')
[IO.File]::WriteAllLines($hookContradictionPath, $hookContradictionLines, $Utf8)
$hookContradictionResult = Invoke-Planner $hookContradictionPath
Assert-True ($hookContradictionResult.ExitCode -ne 0 -and $hookContradictionResult.Text -match 'state/metadata contradiction') 'aligned Claude hook accepted contradictory registration'

$cursorHookContradictionPath = Join-Path $TempRoot 'audit-cursor-hook-scope-contradiction.txt'
$cursorHookContradictionLines = @($scopeLines | ForEach-Object {
    if ($_ -match '^CURSOR_PROJECT_HOOK_SHADOW ') {
        $_.Replace('CURSOR_HOOK_SCOPE=PROJECT', 'CURSOR_HOOK_SCOPE=USER')
    } else { $_ }
})
[IO.File]::WriteAllLines($cursorHookContradictionPath, $cursorHookContradictionLines, $Utf8)
$cursorHookContradictionResult = Invoke-Planner $cursorHookContradictionPath
Assert-True ($cursorHookContradictionResult.ExitCode -ne 0 -and $cursorHookContradictionResult.Text -match 'state/metadata contradiction') 'Cursor hook state accepted contradictory scope'

$missingKeyPath = Join-Path $TempRoot 'audit-missing-key.txt'
$missingKeyLines = @($auditLines)
$missingKeyLines[-1] = $missingKeyLines[-1].Replace(' USER_MCP_RECORDS=0', '')
[IO.File]::WriteAllLines($missingKeyPath, $missingKeyLines, $Utf8)
$missingKeyResult = Invoke-Planner $missingKeyPath
Assert-True ($missingKeyResult.ExitCode -ne 0 -and $missingKeyResult.Text -match 'Missing required audit summary key') 'missing summary key did not fail'

$unknownKeyPath = Join-Path $TempRoot 'audit-unknown-key.txt'
$unknownKeyLines = @($auditLines)
$unknownKeyLines[-1] += ' UNRECOGNIZED_FIELD=fixture'
[IO.File]::WriteAllLines($unknownKeyPath, $unknownKeyLines, $Utf8)
$unknownKeyResult = Invoke-Planner $unknownKeyPath
Assert-True ($unknownKeyResult.ExitCode -ne 0 -and $unknownKeyResult.Text -match 'Unknown audit summary key') 'unknown summary key did not fail'
Assert-True ($unknownKeyResult.Text -notmatch 'UNRECOGNIZED_FIELD=fixture') 'unknown summary error echoed raw replay content'

$missingOutcomePath = Join-Path $TempRoot 'audit-missing-outcome.txt'
$missingOutcomeLines = @($auditLines | Where-Object { $_ -notmatch '^DREAMEROS_AUDIT_OUTCOME=' })
[IO.File]::WriteAllLines($missingOutcomePath, $missingOutcomeLines, $Utf8)
$missingOutcomeResult = Invoke-Planner $missingOutcomePath
Assert-True ($missingOutcomeResult.ExitCode -ne 0 -and $missingOutcomeResult.Text -match 'trusted outcome marker') 'missing audit outcome marker did not fail'

$malformedSentinel = 'Bearer ' + ('Z' * 40)
$malformedReplayPath = Join-Path $TempRoot 'audit-malformed-sentinel.txt'
$malformedReplayLines = @($auditLines[0..($auditLines.Count - 2)]) + "MALFORMED $malformedSentinel $repoA\CLAUDE.md" + $auditLines[-1]
[IO.File]::WriteAllLines($malformedReplayPath, $malformedReplayLines, $Utf8)
$malformedReplayResult = Invoke-Planner $malformedReplayPath
Assert-True ($malformedReplayResult.ExitCode -ne 0 -and $malformedReplayResult.Text -match 'unparsed audit record') 'malformed replay row did not fail'
Assert-True (-not $malformedReplayResult.Text.Contains($malformedSentinel)) 'malformed replay error exposed sentinel content'

$duplicateSummaryPath = Join-Path $TempRoot 'audit-duplicate-summary.txt'
$duplicateSummaryLines = @($auditLines) + $auditLines[-1]
[IO.File]::WriteAllLines($duplicateSummaryPath, $duplicateSummaryLines, $Utf8)
$duplicateSummaryResult = Invoke-Planner $duplicateSummaryPath
Assert-True ($duplicateSummaryResult.ExitCode -ne 0 -and $duplicateSummaryResult.Text -match 'exactly one parseable summary line') 'duplicate summary did not fail'

$missingEstateRoot = Join-Path $TempRoot 'missing-estate-root'
$missingEstateResult = Invoke-Planner $auditPath 'Json' @($Estate, $missingEstateRoot)
Assert-True ($missingEstateResult.ExitCode -ne 0 -and $missingEstateResult.Text -match 'Every requested estate root must exist') 'valid-plus-missing estate roots did not fail closed'

$rogueRepo = Join-Path $TestHome 'rogue-repo'
New-Item -ItemType Directory -Path $rogueRepo -Force | Out-Null
& git -C $rogueRepo init -b main --quiet
& git -C $rogueRepo config user.name 'DreamerOS Planner Test'
& git -C $rogueRepo config user.email 'planner-test@dreameros.invalid'
$rogueAuditPath = Join-Path $TempRoot 'audit-rogue-home-repo.txt'
$rogueLines = @($auditLines | ForEach-Object { $_.Replace($repoA, $rogueRepo) })
[IO.File]::WriteAllLines($rogueAuditPath, $rogueLines, $Utf8)
$rogueResult = Invoke-Planner $rogueAuditPath
Assert-True ($rogueResult.ExitCode -ne 0 -and $rogueResult.Text -match 'outside every requested estate root') 'unrequested Git repository under UserHome did not fail'

$duplicateSurfacePath = Join-Path $TempRoot 'audit-duplicate-surface.txt'
$duplicateSurfaceLines = @($auditLines)
$duplicateSurfaceLines[1] = "LEGACY_FULL_COPY FILE-CLEAN CLAUDE $repoA\CLAUDE.md"
[IO.File]::WriteAllLines($duplicateSurfacePath, $duplicateSurfaceLines, $Utf8)
$duplicateSurfaceResult = Invoke-Planner $duplicateSurfacePath
Assert-True ($duplicateSurfaceResult.ExitCode -ne 0 -and $duplicateSurfaceResult.Text -match 'boot-surface reconciliation failed') 'balanced duplicate/missing repository surface did not fail'

$unknownRowPath = Join-Path $TempRoot 'audit-unknown-row.txt'
$unknownRowLines = @($auditLines[0..($auditLines.Count - 2)]) + "NEW_AUDIT_KIND FILE-CLEAN MYSTERY $repoA\CLAUDE.md" + $auditLines[-1]
[IO.File]::WriteAllLines($unknownRowPath, $unknownRowLines, $Utf8)
$unknownRowResult = Invoke-Planner $unknownRowPath
Assert-True ($unknownRowResult.ExitCode -ne 0 -and $unknownRowResult.Text -match 'unparsed audit record') 'unknown audit row did not fail'

$escapePath = Join-Path $TempRoot 'audit-escape.txt'
$escapeLines = @($auditLines)
$escapeLines[0] = 'LEGACY_FULL_COPY FILE-CLEAN CLAUDE C:\outside-estate\CLAUDE.md'
[IO.File]::WriteAllLines($escapePath, $escapeLines, $Utf8)
$escapeResult = Invoke-Planner $escapePath
Assert-True ($escapeResult.ExitCode -ne 0) 'out-of-estate target must fail'
Assert-True ($escapeResult.Text -match 'escaped every requested estate root') 'out-of-estate signature missing'

$semanticPath = Join-Path $TempRoot 'audit-semantic-path.txt'
$semanticLines = @($auditLines)
$semanticLines[0] = "LEGACY_FULL_COPY FILE-CLEAN CLAUDE $repoA\.git\config"
[IO.File]::WriteAllLines($semanticPath, $semanticLines, $Utf8)
$semanticResult = Invoke-Planner $semanticPath
Assert-True ($semanticResult.ExitCode -ne 0 -and $semanticResult.Text -match 'not valid for its kind and surface') 'semantic path forgery did not fail'

$singleSummary = 'repos=1 surfaces=1 GLOBAL_ONLY=0 POINTER_ALIGNED=0 LEGACY_FULL_COPY=1 POINTER_DRIFT=0 UNKNOWN=0 generators=0 LEGACY_FULL_GENERATOR=0 UNKNOWN_GENERATOR=0 ADAPTER_ALIGNED=0 ADAPTER_DRIFT=0 STALE_ADAPTER_COPY=0 ADAPTER_PATH_DRIFT=0 CLAUDE_BOOT_HOOKS=0 BOOT_HOOK_ALIGNED=0 STALE_BOOT_HOOK=0 BOOT_HOOK_OTHER=0 PROJECT_MCP_RECORDS=0 PROJECT_MCP_AUTH_HEADER=0 PROJECT_MCP_SHADOW=0 PROJECT_MCP_ENDPOINT_SHADOW=0 LEGACY_PROJECT_MCP=0 PROJECT_MCP_UNKNOWN=0 CURSOR_HOOK_SHADOWS=0 REPARSE_CHILD_SKIPPED=0 CURSOR_TEAM_HOOK_POLICY=UNVERIFIED_LIVE USER_CLAUDE_BOOT=USER_CLAUDE_BOOT_ALIGNED USER_CLAUDE_MANAGED_HOOK_POLICY=UNVERIFIED_LIVE USER_MCP_RECORDS=0 DUPLICATE_EMBEDDED_EXCERPT=0 DUPLICATE_RULE_EXCERPT=0'
$ancestorRoot = Join-Path $TempRoot 'ancestor-repo'
$nestedEstate = Join-Path $ancestorRoot 'nested-estate'
$nestedTarget = Join-Path $nestedEstate 'CLAUDE.md'
New-Item -ItemType Directory -Path $nestedEstate -Force | Out-Null
[IO.File]::WriteAllText($nestedTarget, 'ancestor fixture', $Utf8)
& git -C $ancestorRoot init -b main --quiet
& git -C $ancestorRoot config user.name 'DreamerOS Planner Test'
& git -C $ancestorRoot config user.email 'planner-test@dreameros.invalid'
& git -C $ancestorRoot add .
& git -C $ancestorRoot commit -m fixture --quiet
$ancestorAudit = Join-Path $TempRoot 'audit-ancestor.txt'
[IO.File]::WriteAllLines($ancestorAudit, @(
    "LEGACY_FULL_COPY FILE-CLEAN CLAUDE $nestedTarget",
    "USER_CLAUDE_BOOT_ALIGNED USER_CLAUDE_BOOT exact=1 other_hydration=0 $userHook",
    'USER_CLAUDE_MANAGED_HOOK_POLICY=UNVERIFIED_LIVE verify in Claude Code',
    'CURSOR_TEAM_HOOK_POLICY=UNVERIFIED_LIVE verify in Cursor Customize',
    'DREAMEROS_AUDIT_OUTCOME=FINDINGS',
    $singleSummary
), $Utf8)
$ancestorResult = Invoke-Planner $ancestorAudit 'Json' $nestedEstate
Assert-True ($ancestorResult.ExitCode -ne 0 -and $ancestorResult.Text -match 'Git root escaped') 'ancestor Git-root escape did not fail'

$junctionPath = Join-Path $Estate 'repo-junction'
$junctionCreated = $false
try {
    $null = New-Item -ItemType Junction -Path $junctionPath -Target $repoA -ErrorAction Stop
    $junctionCreated = $true
} catch {
    Write-Output 'Junction fixture unavailable; reparse guard remains covered by source review.'
}
if ($junctionCreated) {
    $junctionAudit = Join-Path $TempRoot 'audit-junction.txt'
    [IO.File]::WriteAllLines($junctionAudit, @(
        "LEGACY_FULL_COPY FILE-CLEAN CLAUDE $junctionPath\CLAUDE.md",
        "USER_CLAUDE_BOOT_ALIGNED USER_CLAUDE_BOOT exact=1 other_hydration=0 $userHook",
        'USER_CLAUDE_MANAGED_HOOK_POLICY=UNVERIFIED_LIVE verify in Claude Code',
        'CURSOR_TEAM_HOOK_POLICY=UNVERIFIED_LIVE verify in Cursor Customize',
        'DREAMEROS_AUDIT_OUTCOME=FINDINGS',
        $singleSummary
    ), $Utf8)
    $junctionResult = Invoke-Planner $junctionAudit
    Assert-True ($junctionResult.ExitCode -ne 0 -and $junctionResult.Text -match 'reparse point') 'junction traversal did not fail'
}

Write-Output (@{
    status = 'pass'
    assertions = $Cases
    fixture_root = $TempRoot
} | ConvertTo-Json -Compress)
