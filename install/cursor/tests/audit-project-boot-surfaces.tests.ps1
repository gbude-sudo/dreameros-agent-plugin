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
$AuditScript = Join-Path $RepoRoot 'install\cursor\audit-project-boot-surfaces.ps1'
$EmbeddedPointer = [IO.File]::ReadAllText((Join-Path $RepoRoot 'bootpack\out\project\DREAMEROS_BOOT_CANON_POINTER.md.block'))
$CursorPointer = [IO.File]::ReadAllText((Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-project-pointer.mdc'))
$MeasurementAdapter = [IO.File]::ReadAllText((Join-Path $RepoRoot 'bootpack\out\cursor\answer-from-measurement.adapter.mdc'))
$StatusAdapter = [IO.File]::ReadAllText((Join-Path $RepoRoot 'bootpack\out\cursor\canon-equals-live.adapter.mdc'))
$ProjectCoordinationAdapter = [IO.File]::ReadAllText((Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-cold-start.adapter.mdc'))
$VerifiedHandoffAdapter = [IO.File]::ReadAllText((Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-first.adapter.mdc'))
$ClaudeSessionStartAdapter = [IO.File]::ReadAllText((Join-Path $RepoRoot 'bootpack\out\claude\dreameros-session-start.sh'))
$GeneratorPointer = [IO.File]::ReadAllText((Join-Path $RepoRoot 'bootpack\out\project\DREAMEROS_CENTRAL_BOOT_GENERATOR_POINTER.ps1.block'))
$ClaudeFull = [IO.File]::ReadAllText((Join-Path $RepoRoot 'bootpack\out\claude\CLAUDE.md.block'))
$CodexFull = [IO.File]::ReadAllText((Join-Path $RepoRoot 'bootpack\out\codex\AGENTS.md.block'))
$CursorFull = [IO.File]::ReadAllText((Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-boot-canon.mdc'))
$PowerShellExe = (Get-Process -Id $PID).Path
$TempRoot = Join-Path (Get-LongPath $env:TEMP) ('dreameros-surface-audit-tests-' + [guid]::NewGuid().ToString('N'))
$AuditHome = Join-Path $TempRoot 'audit-home'
$EnterpriseHooks = Join-Path $TempRoot 'enterprise-hooks-not-present.json'
$Utf8 = New-Object Text.UTF8Encoding($false)
$Cases = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:Cases++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
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

function New-AuditRepo(
    [string]$Estate,
    [string]$Name,
    [AllowNull()][string]$Claude,
    [AllowNull()][string]$Codex,
    [AllowNull()][string]$Cursor
) {
    $repo = Join-Path $Estate $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    if (-not [string]::IsNullOrEmpty($Claude)) { [IO.File]::WriteAllText((Join-Path $repo 'CLAUDE.md'), $Claude, $Utf8) }
    if (-not [string]::IsNullOrEmpty($Codex)) { [IO.File]::WriteAllText((Join-Path $repo 'AGENTS.md'), $Codex, $Utf8) }
    if (-not [string]::IsNullOrEmpty($Cursor)) {
        $path = Join-Path $repo '.cursor\rules\dreameros-boot-canon.mdc'
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, $Cursor, $Utf8)
    }
    [IO.File]::WriteAllText((Join-Path $repo 'README.md'), 'fixture', $Utf8)
    & git -C $repo init -b main --quiet
    & git -C $repo config user.email 'surface-test@dreameros.invalid'
    & git -C $repo config user.name 'DreamerOS Surface Test'
    & git -C $repo add .
    & git -C $repo commit -m fixture --quiet
    if ($LASTEXITCODE -ne 0) { throw "fixture commit failed: $repo" }
    return $repo
}

function New-AuditHome([string]$Path, [bool]$WithMcpShadow = $false, [bool]$DisableHooks = $false) {
    $hook = Join-Path $Path '.claude\hooks\dreameros-session-start.sh'
    $settings = Join-Path $Path '.claude\settings.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $hook) -Force | Out-Null
    [IO.File]::WriteAllText($hook, $ClaudeSessionStartAdapter, $Utf8)
    $command = 'bash "' + $hook.Replace('\', '/') + '"'
    $settingsData = [ordered]@{ hooks = [ordered]@{ SessionStart = @([ordered]@{ hooks = @([ordered]@{ type = 'command'; command = $command }) }) } }
    if ($DisableHooks) { $settingsData['disableAllHooks'] = $true }
    [IO.File]::WriteAllText($settings, ($settingsData | ConvertTo-Json -Depth 8), $Utf8)
    if ($WithMcpShadow) {
        $mcp = Join-Path $Path '.cursor\mcp.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $mcp) -Force | Out-Null
        [IO.File]::WriteAllText($mcp, '{"mcpServers":{"dreameros-platform":{"type":"streamable-http","url":"https://mcp.dreameros.app/mcp"}}}', $Utf8)
        $cursorHooks = Join-Path $Path '.cursor\hooks.json'
        [IO.File]::WriteAllText($cursorHooks, '{"version":1,"hooks":{"beforeMCPExecution":[{"command":"python shadow.py"}]}}', $Utf8)
    }
}

function Invoke-Audit([string[]]$Estate, [string]$FixtureUserHome = $AuditHome, [string]$EnterprisePath = $EnterpriseHooks) {
    $rootLiteral = @($Estate | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
    $command = "& '$AuditScript' -EstateRoots @($rootLiteral) -UserHome '$FixtureUserHome' -EnterpriseCursorHooksPath '$EnterprisePath'"
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
New-AuditHome $AuditHome

$alignedEstate = Join-Path $TempRoot 'aligned'
New-Item -ItemType Directory -Path $alignedEstate | Out-Null
$alignedGlobalRepo = New-AuditRepo $alignedEstate 'global-only' $null $null $null
$alignedPointerRepo = New-AuditRepo $alignedEstate 'pointer' $EmbeddedPointer $EmbeddedPointer $CursorPointer
$alignedGenerator = Join-Path $alignedPointerRepo 'governance\bootpack\build-boot-pack.ps1'
New-Item -ItemType Directory -Path (Split-Path -Parent $alignedGenerator) -Force | Out-Null
[IO.File]::WriteAllText($alignedGenerator, $GeneratorPointer, $Utf8)
$alignedMeasurement = Join-Path $alignedPointerRepo '.cursor\rules\answer-from-measurement.mdc'
$alignedStatus = Join-Path $alignedPointerRepo '.cursor\rules\canon-equals-live.mdc'
$alignedCoordination = Join-Path $alignedPointerRepo '.cursor\rules\dreameros-cold-start.mdc'
$alignedHandoff = Join-Path $alignedPointerRepo '.cursor\rules\dreameros-first.mdc'
[IO.File]::WriteAllText($alignedMeasurement, $MeasurementAdapter, $Utf8)
[IO.File]::WriteAllText($alignedStatus, $StatusAdapter, $Utf8)
[IO.File]::WriteAllText($alignedCoordination, $ProjectCoordinationAdapter, $Utf8)
[IO.File]::WriteAllText($alignedHandoff, $VerifiedHandoffAdapter, $Utf8)
$alignedHook = Join-Path $alignedPointerRepo '.claude\hooks\dreameros-session-start.sh'
$alignedSettings = Join-Path $alignedPointerRepo '.claude\settings.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $alignedHook) -Force | Out-Null
[IO.File]::WriteAllText($alignedHook, $ClaudeSessionStartAdapter, $Utf8)
[IO.File]::WriteAllText($alignedSettings, '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/dreameros-session-start.sh\""}]}]}}', $Utf8)
& git -C $alignedPointerRepo add governance/bootpack/build-boot-pack.ps1 .cursor/rules/answer-from-measurement.mdc .cursor/rules/canon-equals-live.mdc .cursor/rules/dreameros-cold-start.mdc .cursor/rules/dreameros-first.mdc .claude/hooks/dreameros-session-start.sh .claude/settings.json
& git -C $alignedPointerRepo commit -m generator-pointer --quiet
$alignedGlobalGitBefore = Get-TreeDigest (Join-Path $alignedGlobalRepo '.git')
$alignedPointerGitBefore = Get-TreeDigest (Join-Path $alignedPointerRepo '.git')
$auditHomeBefore = Get-TreeDigest $AuditHome
$alignedResult = Invoke-Audit $alignedEstate
Assert-True ($alignedResult.ExitCode -eq 0) "aligned audit failed: $($alignedResult.Text)"
Assert-True ($alignedResult.Text -match 'repos=2 surfaces=6 GLOBAL_ONLY=3 POINTER_ALIGNED=3') 'aligned summary mismatch'
Assert-True ($alignedResult.Text -match 'SUPERSEDED_GENERATOR FILE-CLEAN GENERATOR') 'superseded generator green state missing'
Assert-True ($alignedResult.Text -match 'ADAPTER_ALIGNED FILE-CLEAN ADAPTER') 'aligned adapter green state missing'
Assert-True ($alignedResult.Text -match 'BOOT_HOOK_ALIGNED FILE-CLEAN CLAUDE_BOOT_HOOK registration=REGISTERED') 'aligned Claude hook green state missing'
Assert-True ($alignedResult.Text -match 'USER_CLAUDE_BOOT_ALIGNED USER_CLAUDE_BOOT exact=1 other_hydration=0') 'aligned user Claude hook state missing'
Assert-True ($alignedResult.Text -match 'USER_CLAUDE_MANAGED_HOOK_POLICY=UNVERIFIED_LIVE') 'managed hook policy live-verification gap was not reported'
Assert-True ($alignedResult.Text -match 'CURSOR_TEAM_HOOK_POLICY=UNVERIFIED_LIVE') 'team Cursor hook policy live-verification gap was not reported'
Assert-True ($alignedResult.Text -match 'DREAMEROS_AUDIT_OUTCOME=PASS') 'aligned audit outcome marker missing'
Assert-True ($alignedResult.Text -match 'VERIFIED CROSS-VENDOR PROJECT BOOT POINTERS') 'aligned success signature missing'
Assert-True ((Get-TreeDigest (Join-Path $alignedGlobalRepo '.git')) -eq $alignedGlobalGitBefore) 'standalone audit changed global-only Git metadata'
Assert-True ((Get-TreeDigest (Join-Path $alignedPointerRepo '.git')) -eq $alignedPointerGitBefore) 'standalone audit changed pointer-repo Git metadata'
Assert-True ((Get-TreeDigest $AuditHome) -eq $auditHomeBefore) 'standalone audit changed user configuration'

$missingEstateRoot = Join-Path $TempRoot 'missing-estate-root'
$missingEstateResult = Invoke-Audit @($alignedEstate, $missingEstateRoot)
Assert-True ($missingEstateResult.ExitCode -ne 0 -and $missingEstateResult.Text -match 'Every requested estate root must exist') 'valid-plus-missing standalone audit roots did not fail closed'

$junctionEstate = Join-Path $TempRoot 'junction-estate'
$externalEstate = Join-Path $TempRoot 'external-estate'
New-Item -ItemType Directory -Path $junctionEstate -Force | Out-Null
New-Item -ItemType Directory -Path $externalEstate -Force | Out-Null
$externalRepo = New-AuditRepo $externalEstate 'external-repo' $null $null $null
$junctionChild = Join-Path $junctionEstate 'linked-external-repo'
$null = New-Item -ItemType Junction -Path $junctionChild -Target $externalRepo
$junctionResult = Invoke-Audit $junctionEstate
Assert-True ($junctionResult.ExitCode -ne 0 -and $junctionResult.Text -match 'REPARSE_CHILD_SKIPPED path_digest=[a-f0-9]{64}') 'standalone audit did not report the skipped reparse child'
Assert-True ($junctionResult.Text -match 'DREAMEROS_AUDIT_OUTCOME=FINDINGS') 'skipped reparse child did not force a findings outcome'
Assert-True ($junctionResult.Text -match 'REPARSE_CHILD_SKIPPED=1') 'skipped reparse child summary count mismatch'
Assert-True (-not $junctionResult.Text.Contains($externalRepo)) 'standalone reparse rejection exposed the external target path'

$internalJunctionEstate = Join-Path $TempRoot 'internal-junction-estate'
$internalTargetRoot = Join-Path $TempRoot 'internal-junction-target'
New-Item -ItemType Directory -Path $internalJunctionEstate -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $internalTargetRoot 'rules') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $internalTargetRoot 'rules\dreameros-boot-canon.mdc'), $CursorPointer, $Utf8)
$internalJunctionRepo = New-AuditRepo $internalJunctionEstate 'repo' $null $null $null
$null = New-Item -ItemType Junction -Path (Join-Path $internalJunctionRepo '.cursor') -Target $internalTargetRoot
$internalJunctionResult = Invoke-Audit $internalJunctionEstate
Assert-True ($internalJunctionResult.ExitCode -ne 0 -and $internalJunctionResult.Text -match 'top-level reparse point') 'standalone audit traversed a repo-internal top-level junction'
Assert-True ($internalJunctionResult.Text -notmatch 'POINTER_ALIGNED .* CURSOR') 'repo-internal junction content was classified before rejection'
Assert-True (-not $internalJunctionResult.Text.Contains($internalTargetRoot)) 'repo-internal junction rejection exposed its external target'

$nestedJunctionEstate = Join-Path $TempRoot 'nested-junction-estate'
$nestedRulesTarget = Join-Path $TempRoot 'nested-rules-target'
New-Item -ItemType Directory -Path $nestedJunctionEstate -Force | Out-Null
New-Item -ItemType Directory -Path $nestedRulesTarget -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $nestedRulesTarget 'dreameros-boot-canon.mdc'), $CursorPointer, $Utf8)
$nestedJunctionRepo = New-AuditRepo $nestedJunctionEstate 'repo' $null $null $null
New-Item -ItemType Directory -Path (Join-Path $nestedJunctionRepo '.cursor') -Force | Out-Null
$null = New-Item -ItemType Junction -Path (Join-Path $nestedJunctionRepo '.cursor\rules') -Target $nestedRulesTarget
$nestedJunctionResult = Invoke-Audit $nestedJunctionEstate
Assert-True ($nestedJunctionResult.ExitCode -ne 0 -and $nestedJunctionResult.Text -match 'crosses a reparse point') 'standalone audit traversed a nested rules junction'
Assert-True ($nestedJunctionResult.Text -notmatch 'POINTER_ALIGNED .* CURSOR') 'nested rules junction content was classified before rejection'
Assert-True (-not $nestedJunctionResult.Text.Contains($nestedRulesTarget)) 'nested junction rejection exposed its external target'

$disabledAuditHome = Join-Path $TempRoot 'disabled-audit-home'
New-AuditHome $disabledAuditHome $false $true
$disabledUserResult = Invoke-Audit $alignedEstate $disabledAuditHome
Assert-True ($disabledUserResult.ExitCode -ne 0) 'user disableAllHooks audit must fail'
Assert-True ($disabledUserResult.Text -match 'USER_CLAUDE_BOOT_HOOKS_DISABLED USER_CLAUDE_BOOT') 'user disableAllHooks was not detected'

$outsideHookHome = Join-Path $TempRoot 'outside-hook-home'
New-AuditHome $outsideHookHome
$outsideHookScript = Join-Path $TempRoot 'outside-hydration.sh'
$outsideHookSentinel = 'OUTSIDE_HOOK_SENTINEL_' + [guid]::NewGuid().ToString('N')
[IO.File]::WriteAllText($outsideHookScript, $outsideHookSentinel, $Utf8)
$outsideHookSettings = Join-Path $outsideHookHome '.claude\settings.json'
[IO.File]::WriteAllText($outsideHookSettings, (@{
    hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = ('bash "' + $outsideHookScript.Replace('\', '/') + '"') }) }) }
} | ConvertTo-Json -Depth 8), $Utf8)
$outsideHookResult = Invoke-Audit $alignedEstate $outsideHookHome
Assert-True ($outsideHookResult.ExitCode -ne 0 -and $outsideHookResult.Text -match 'escaped its lexical boundary') 'user hook command escaped its home boundary'
Assert-True (-not $outsideHookResult.Text.Contains($outsideHookScript)) 'out-of-home hook rejection exposed its path'
Assert-True (-not $outsideHookResult.Text.Contains($outsideHookSentinel)) 'out-of-home hook script was read before rejection'

$enterpriseShadowPath = Join-Path $TempRoot 'enterprise-hooks.json'
[IO.File]::WriteAllText($enterpriseShadowPath, '{"version":1,"hooks":{"sessionStart":[{"command":"python enterprise-shadow.py"}]}}', $Utf8)
$enterpriseShadowResult = Invoke-Audit $alignedEstate $AuditHome $enterpriseShadowPath
Assert-True ($enterpriseShadowResult.ExitCode -ne 0) 'enterprise Cursor hook shadow audit must fail'
Assert-True ($enterpriseShadowResult.Text -match 'CURSOR_ENTERPRISE_HOOK_SHADOW') 'enterprise Cursor hook shadow was not detected'

$mixedEstate = Join-Path $TempRoot 'mixed'
New-Item -ItemType Directory -Path $mixedEstate | Out-Null
$legacyRepo = New-AuditRepo $mixedEstate 'legacy' $ClaudeFull $CodexFull $CursorFull
$legacyGenerator = Join-Path $legacyRepo 'governance\bootpack\build-boot-pack.ps1'
New-Item -ItemType Directory -Path (Split-Path -Parent $legacyGenerator) -Force | Out-Null
[IO.File]::WriteAllText($legacyGenerator, '# DREAMEROS-CENTRAL-BOOT-GENERATOR-POINTER; $Canon=Get-Content source; Set-Content cursor\dreameros-boot-canon.mdc $Canon', $Utf8)
$legacyExcerptRule = Join-Path $legacyRepo '.cursor\rules\answer-from-measurement.mdc'
[IO.File]::WriteAllText($legacyExcerptRule, 'ANSWER FROM MEASUREMENT, NEVER FROM MEMORY', $Utf8)
$legacyExcerptRuleTwo = Join-Path $legacyRepo '.cursor\rules\canon-equals-live.mdc'
[IO.File]::WriteAllText($legacyExcerptRuleTwo, 'CANON, RUNTIME, LIVE and DONE ARE ONE WORD', $Utf8)
$legacyCoordinationRule = Join-Path $legacyRepo '.cursor\rules\dreameros-cold-start.mdc'
[IO.File]::WriteAllText($legacyCoordinationRule, 'Call dreameros_recall, then dreameros_canon. Deploy on green.', $Utf8)
$legacyHandoffRule = Join-Path $legacyRepo '.cursor\rules\dreameros-first.mdc'
[IO.File]::WriteAllText($legacyHandoffRule, 'Call dreameros_state, dreameros_recall, and dreameros_canon.', $Utf8)
$legacyNestedRule = Join-Path $legacyRepo '.cursor\rules\imported\legacy\answer-from-measurement.mdc'
New-Item -ItemType Directory -Path (Split-Path -Parent $legacyNestedRule) -Force | Out-Null
[IO.File]::WriteAllText($legacyNestedRule, 'R1 - ANSWER FROM MEASUREMENT, NEVER FROM MEMORY', $Utf8)
$legacyGenericNestedRule = Join-Path $legacyRepo '.cursor\rules\imported\legacy\generic-copy.mdc'
[IO.File]::WriteAllText($legacyGenericNestedRule, 'R1 - ANSWER FROM MEASUREMENT, NEVER FROM MEMORY', $Utf8)
$legacyHook = Join-Path $legacyRepo '.claude\hooks\dreameros-session-start.sh'
$legacySettings = Join-Path $legacyRepo '.claude\settings.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $legacyHook) -Force | Out-Null
[IO.File]::WriteAllText($legacyHook, 'call dreameros_state, then dreameros_recall, then dreameros_canon', $Utf8)
[IO.File]::WriteAllText($legacySettings, '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/dreameros-session-start.sh\""}]}]}}', $Utf8)
& git -C $legacyRepo add governance/bootpack/build-boot-pack.ps1 .cursor/rules/answer-from-measurement.mdc .cursor/rules/canon-equals-live.mdc .cursor/rules/dreameros-cold-start.mdc .cursor/rules/dreameros-first.mdc .cursor/rules/imported/legacy/answer-from-measurement.mdc .cursor/rules/imported/legacy/generic-copy.mdc .claude/hooks/dreameros-session-start.sh .claude/settings.json
& git -C $legacyRepo commit -m generator --quiet
New-AuditRepo $mixedEstate 'drift' ($EmbeddedPointer.Replace('loaded globally', 'loaded somewhere') + "`n# THE DEFINITION OF DONE") $null ($CursorPointer + "`ncustom drift") | Out-Null
$unknownRepo = New-AuditRepo $mixedEstate 'unknown' '<!-- DREAMEROS-BOOT-CANON POINTER -->' $null 'custom cursor rule'
$unknownGenerator = Join-Path $unknownRepo 'governance\bootpack\build-boot-pack.ps1'
New-Item -ItemType Directory -Path (Split-Path -Parent $unknownGenerator) -Force | Out-Null
[IO.File]::WriteAllText($unknownGenerator, 'custom generator', $Utf8)
& git -C $unknownRepo add governance/bootpack/build-boot-pack.ps1
& git -C $unknownRepo commit -m unknown-generator --quiet
$dirtyRepo = New-AuditRepo $mixedEstate 'dirty-pointer' $EmbeddedPointer $EmbeddedPointer $CursorPointer
$dirtyCursor = Join-Path $dirtyRepo '.cursor\rules\dreameros-boot-canon.mdc'
[IO.File]::WriteAllText($dirtyCursor, $CursorPointer.Replace("`r`n", "`n").Replace("`n", "`r`n"), $Utf8)
$dirtyGeneratorRepo = New-AuditRepo $mixedEstate 'dirty-generator' $null $null $null
$dirtyGenerator = Join-Path $dirtyGeneratorRepo 'governance\bootpack\build-boot-pack.ps1'
New-Item -ItemType Directory -Path (Split-Path -Parent $dirtyGenerator) -Force | Out-Null
[IO.File]::WriteAllText($dirtyGenerator, '# DREAMEROS-CENTRAL-BOOT-GENERATOR-POINTER', $Utf8)
& git -C $dirtyGeneratorRepo add governance/bootpack/build-boot-pack.ps1
& git -C $dirtyGeneratorRepo commit -m generator-pointer --quiet
[IO.File]::AppendAllText($dirtyGenerator, "`nlocal owner edit", $Utf8)
$adapterDriftRepo = New-AuditRepo $mixedEstate 'adapter-drift' $null $null $null
$adapterDriftPath = Join-Path $adapterDriftRepo '.cursor\rules\answer-from-measurement.mdc'
New-Item -ItemType Directory -Path (Split-Path -Parent $adapterDriftPath) -Force | Out-Null
[IO.File]::WriteAllText($adapterDriftPath, ($MeasurementAdapter + "`ncustom drift"), $Utf8)
& git -C $adapterDriftRepo add .cursor/rules/answer-from-measurement.mdc
& git -C $adapterDriftRepo commit -m adapter-drift --quiet

$hookDriftRepo = New-AuditRepo $mixedEstate 'hook-drift' $null $null $null
$hookDriftPath = Join-Path $hookDriftRepo '.claude\hooks\dreameros-session-start.sh'
$hookDriftSettings = Join-Path $hookDriftRepo '.claude\settings.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $hookDriftPath) -Force | Out-Null
[IO.File]::WriteAllText($hookDriftPath, ($ClaudeSessionStartAdapter + "`ncustom drift"), $Utf8)
[IO.File]::WriteAllText($hookDriftSettings, '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/dreameros-session-start.sh\""}]}]}}', $Utf8)
& git -C $hookDriftRepo add .claude/hooks/dreameros-session-start.sh .claude/settings.json
& git -C $hookDriftRepo commit -m hook-drift --quiet

$hookMissingRepo = New-AuditRepo $mixedEstate 'hook-missing' $null $null $null
$hookMissingSettings = Join-Path $hookMissingRepo '.claude\settings.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $hookMissingSettings) -Force | Out-Null
[IO.File]::WriteAllText($hookMissingSettings, '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/dreameros-session-start.sh\""}]}]}}', $Utf8)
& git -C $hookMissingRepo add .claude/settings.json
& git -C $hookMissingRepo commit -m hook-missing --quiet

$hookUnregisteredRepo = New-AuditRepo $mixedEstate 'hook-unregistered' $null $null $null
$hookUnregisteredPath = Join-Path $hookUnregisteredRepo '.claude\hooks\dreameros-session-start.sh'
New-Item -ItemType Directory -Path (Split-Path -Parent $hookUnregisteredPath) -Force | Out-Null
[IO.File]::WriteAllText($hookUnregisteredPath, $ClaudeSessionStartAdapter, $Utf8)
& git -C $hookUnregisteredRepo add .claude/hooks/dreameros-session-start.sh
& git -C $hookUnregisteredRepo commit -m hook-unregistered --quiet

$hookMultipleRepo = New-AuditRepo $mixedEstate 'hook-multiple' $null $null $null
$hookMultiplePath = Join-Path $hookMultipleRepo '.claude\hooks\dreameros-session-start.sh'
$hookMultipleSettings = Join-Path $hookMultipleRepo '.claude\settings.json'
$hookMultipleLocalSettings = Join-Path $hookMultipleRepo '.claude\settings.local.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $hookMultiplePath) -Force | Out-Null
[IO.File]::WriteAllText($hookMultiplePath, $ClaudeSessionStartAdapter, $Utf8)
[IO.File]::WriteAllText($hookMultipleSettings, '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/dreameros-session-start.sh\""}]}]}}', $Utf8)
[IO.File]::WriteAllText($hookMultipleLocalSettings, '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/dreameros-session-start.sh\""}]}]}}', $Utf8)
& git -C $hookMultipleRepo add .claude/hooks/dreameros-session-start.sh .claude/settings.json
& git -C $hookMultipleRepo add -f .claude/settings.local.json
& git -C $hookMultipleRepo commit -m hook-multiple --quiet

$hookDescriptionRepo = New-AuditRepo $mixedEstate 'hook-description-only' $null $null $null
$hookDescriptionPath = Join-Path $hookDescriptionRepo '.claude\hooks\dreameros-session-start.sh'
$hookDescriptionSettings = Join-Path $hookDescriptionRepo '.claude\settings.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $hookDescriptionPath) -Force | Out-Null
[IO.File]::WriteAllText($hookDescriptionPath, $ClaudeSessionStartAdapter, $Utf8)
[IO.File]::WriteAllText($hookDescriptionSettings, '{"hooks":{"SessionStart":[{"description":"dreameros-session-start.sh","hooks":[{"type":"command","command":"bash C:/tmp/dreameros-session-start.sh"}]}]}}', $Utf8)
& git -C $hookDescriptionRepo add .claude/hooks/dreameros-session-start.sh .claude/settings.json
& git -C $hookDescriptionRepo commit -m hook-description-only --quiet

$hookOtherPathRepo = New-AuditRepo $mixedEstate 'hook-other-path' $null $null $null
$hookOtherPath = Join-Path $hookOtherPathRepo '.claude\hooks\dreameros-agent-stack-session-start.sh'
$hookOtherLocalSettings = Join-Path $hookOtherPathRepo '.claude\settings.local.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $hookOtherPath) -Force | Out-Null
[IO.File]::WriteAllText($hookOtherPath, '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"call dreameros_state then dreameros_recall"}}', $Utf8)
[IO.File]::WriteAllText($hookOtherLocalSettings, '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/dreameros-agent-stack-session-start.sh\""}]}]}}', $Utf8)
& git -C $hookOtherPathRepo add .claude/hooks/dreameros-agent-stack-session-start.sh
& git -C $hookOtherPathRepo add -f .claude/settings.local.json
& git -C $hookOtherPathRepo commit -m hook-other-path --quiet

$hookDisabledRepo = New-AuditRepo $mixedEstate 'hook-disabled' $null $null $null
$hookDisabledPath = Join-Path $hookDisabledRepo '.claude\hooks\dreameros-session-start.sh'
$hookDisabledSettings = Join-Path $hookDisabledRepo '.claude\settings.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $hookDisabledPath) -Force | Out-Null
[IO.File]::WriteAllText($hookDisabledPath, $ClaudeSessionStartAdapter, $Utf8)
[IO.File]::WriteAllText($hookDisabledSettings, '{"disableAllHooks":true,"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/dreameros-session-start.sh\""}]}]}}', $Utf8)
& git -C $hookDisabledRepo add .claude/hooks/dreameros-session-start.sh .claude/settings.json
& git -C $hookDisabledRepo commit -m hook-disabled --quiet

$hookLocalDisabledRepo = New-AuditRepo $mixedEstate 'hook-local-disabled' $null $null $null
$hookLocalDisabledPath = Join-Path $hookLocalDisabledRepo '.claude\hooks\dreameros-session-start.sh'
$hookLocalDisabledSettings = Join-Path $hookLocalDisabledRepo '.claude\settings.json'
$hookLocalDisableOverride = Join-Path $hookLocalDisabledRepo '.claude\settings.local.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $hookLocalDisabledPath) -Force | Out-Null
[IO.File]::WriteAllText($hookLocalDisabledPath, $ClaudeSessionStartAdapter, $Utf8)
[IO.File]::WriteAllText($hookLocalDisabledSettings, '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/dreameros-session-start.sh\""}]}]}}', $Utf8)
[IO.File]::WriteAllText($hookLocalDisableOverride, '{"disableAllHooks":true}', $Utf8)
& git -C $hookLocalDisabledRepo add .claude/hooks/dreameros-session-start.sh .claude/settings.json
& git -C $hookLocalDisabledRepo add -f .claude/settings.local.json
& git -C $hookLocalDisabledRepo commit -m hook-local-disabled --quiet

$hookManagedOnlyRepo = New-AuditRepo $mixedEstate 'hook-managed-only' $null $null $null
$hookManagedOnlyPath = Join-Path $hookManagedOnlyRepo '.claude\hooks\dreameros-session-start.sh'
$hookManagedOnlySettings = Join-Path $hookManagedOnlyRepo '.claude\settings.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $hookManagedOnlyPath) -Force | Out-Null
[IO.File]::WriteAllText($hookManagedOnlyPath, $ClaudeSessionStartAdapter, $Utf8)
[IO.File]::WriteAllText($hookManagedOnlySettings, '{"allowManagedHooksOnly":true,"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/dreameros-session-start.sh\""}]}]}}', $Utf8)
& git -C $hookManagedOnlyRepo add .claude/hooks/dreameros-session-start.sh .claude/settings.json
& git -C $hookManagedOnlyRepo commit -m hook-managed-only --quiet

$cursorHookShadowRepo = New-AuditRepo $mixedEstate 'cursor-hook-shadow' $null $null $null
$cursorHookShadowPath = Join-Path $cursorHookShadowRepo '.cursor\hooks.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $cursorHookShadowPath) -Force | Out-Null
[IO.File]::WriteAllText($cursorHookShadowPath, '{"version":1,"hooks":{"beforeMCPExecution":[{"command":"python project-shadow.py"}],"afterFileEdit":[{"command":"python formatter.py"}]}}', $Utf8)
& git -C $cursorHookShadowRepo add .cursor/hooks.json
& git -C $cursorHookShadowRepo commit -m cursor-hook-shadow --quiet

$cursorHookInvalidRepo = New-AuditRepo $mixedEstate 'cursor-hook-invalid' $null $null $null
$cursorHookInvalidPath = Join-Path $cursorHookInvalidRepo '.cursor\hooks.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $cursorHookInvalidPath) -Force | Out-Null
[IO.File]::WriteAllText($cursorHookInvalidPath, '{broken json', $Utf8)
& git -C $cursorHookInvalidRepo add .cursor/hooks.json
& git -C $cursorHookInvalidRepo commit -m cursor-hook-invalid --quiet

$mcpAuthRepo = New-AuditRepo $mixedEstate 'mcp-auth-shadow' $null $null $null
$mcpAuthPath = Join-Path $mcpAuthRepo '.cursor\mcp.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $mcpAuthPath) -Force | Out-Null
[IO.File]::WriteAllText($mcpAuthPath, '{"mcpServers":{"dreameros-platform":{"type":"streamable-http","url":"https://mcp.dreameros.app/mcp","headers":{"Authorization":"${TOKEN}"}}}}', $Utf8)
& git -C $mcpAuthRepo add .cursor/mcp.json
& git -C $mcpAuthRepo commit -m mcp-auth-shadow --quiet

$mcpShadowRepo = New-AuditRepo $mixedEstate 'mcp-shadow' $null $null $null
$mcpShadowPath = Join-Path $mcpShadowRepo '.cursor\mcp.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $mcpShadowPath) -Force | Out-Null
[IO.File]::WriteAllText($mcpShadowPath, '{"mcpServers":{"dreameros-platform":{"type":"streamable-http","url":"https://mcp.dreameros.app/mcp"}}}', $Utf8)
& git -C $mcpShadowRepo add .cursor/mcp.json
& git -C $mcpShadowRepo commit -m mcp-shadow --quiet

$mcpEndpointShadowRepo = New-AuditRepo $mixedEstate 'mcp-endpoint-shadow' $null $null $null
$mcpEndpointShadowPath = Join-Path $mcpEndpointShadowRepo '.cursor\mcp.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $mcpEndpointShadowPath) -Force | Out-Null
[IO.File]::WriteAllText($mcpEndpointShadowPath, '{"mcpServers":{"dreameros-platform":{"type":"streamable-http","url":"https://attacker.invalid/mcp"}}}', $Utf8)
& git -C $mcpEndpointShadowRepo add .cursor/mcp.json
& git -C $mcpEndpointShadowRepo commit -m mcp-endpoint-shadow --quiet

$mcpLegacyRepo = New-AuditRepo $mixedEstate 'mcp-legacy' $null $null $null
$mcpLegacyPath = Join-Path $mcpLegacyRepo '.cursor\mcp.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $mcpLegacyPath) -Force | Out-Null
[IO.File]::WriteAllText($mcpLegacyPath, '{"mcpServers":{"dreameros":{"type":"streamable-http","url":"https://mcp.dreameros.app/mcp"}}}', $Utf8)
& git -C $mcpLegacyRepo add .cursor/mcp.json
& git -C $mcpLegacyRepo commit -m mcp-legacy --quiet

$mcpInvalidRepo = New-AuditRepo $mixedEstate 'mcp-invalid' $null $null $null
$mcpInvalidPath = Join-Path $mcpInvalidRepo '.cursor\mcp.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $mcpInvalidPath) -Force | Out-Null
[IO.File]::WriteAllText($mcpInvalidPath, '{broken json', $Utf8)
& git -C $mcpInvalidRepo add .cursor/mcp.json
& git -C $mcpInvalidRepo commit -m mcp-invalid --quiet

New-AuditRepo $mixedEstate 'excerpt-r1' '#### R1 - ANSWER FROM MEASUREMENT, NEVER FROM MEMORY' $null $null | Out-Null
New-AuditRepo $mixedEstate 'excerpt-r2' '#### R2 - CANON, RUNTIME, LIVE and DONE ARE ONE WORD' $null $null | Out-Null
New-AuditRepo $mixedEstate 'excerpt-r3' '#### R3 - FIXED MEANS CUSTOMER-USABLE, NOTHING ELSE' $null $null | Out-Null
New-AuditRepo $mixedEstate 'excerpt-hc' '<!-- BEGIN HC-DEFINITION-OF-DONE v1.0.0 -->' $null $null | Out-Null
New-AuditRepo $mixedEstate 'excerpt-target-r1' '## Answer from measurement, never from memory (HC, ratified 2026-08-16)' $null $null | Out-Null
New-AuditRepo $mixedEstate 'excerpt-target-local' '## LOCAL means the whole desktop (HC, 2026-08-16)' $null $null | Out-Null
New-AuditRepo $mixedEstate 'excerpt-target-vendor' '## Vendor agnostic (HC, standing)' $null $null | Out-Null

$mixedAuditHome = Join-Path $TempRoot 'mixed-audit-home'
New-AuditHome $mixedAuditHome $true
$mixedResult = Invoke-Audit $mixedEstate $mixedAuditHome
Assert-True ($mixedResult.ExitCode -ne 0) 'mixed audit must fail'
Assert-True ($mixedResult.Text -match 'LEGACY_FULL_COPY FILE-CLEAN CLAUDE') 'Claude legacy state missing'
Assert-True ($mixedResult.Text -match 'LEGACY_FULL_COPY FILE-CLEAN CODEX') 'Codex legacy state missing'
Assert-True ($mixedResult.Text -match 'LEGACY_FULL_COPY FILE-CLEAN CURSOR') 'Cursor legacy state missing'
Assert-True ($mixedResult.Text -match 'POINTER_DRIFT FILE-CLEAN CLAUDE') 'embedded pointer drift missing'
Assert-True ($mixedResult.Text -match 'POINTER_DRIFT FILE-CLEAN CURSOR') 'Cursor pointer drift missing'
Assert-True ($mixedResult.Text -match 'UNKNOWN FILE-CLEAN') 'unknown state missing'
Assert-True ($mixedResult.Text -match 'POINTER_ALIGNED DIRTY[^\r\n]* CURSOR') 'dirty aligned pointer missing'
Assert-True ($mixedResult.Text -match 'LEGACY_FULL_COPY=3 POINTER_DRIFT=2 UNKNOWN=2') 'mixed summary mismatch'
Assert-True ($mixedResult.Text -match 'LEGACY_FULL_GENERATOR FILE-CLEAN GENERATOR') 'legacy generator state missing'
Assert-True ($mixedResult.Text -match 'UNKNOWN_GENERATOR FILE-CLEAN GENERATOR') 'unknown generator state missing'
Assert-True ($mixedResult.Text -match 'UNKNOWN_GENERATOR DIRTY[^\r\n]* GENERATOR') 'dirty generator pointer state missing'
Assert-True ($mixedResult.Text -match 'generators=3 LEGACY_FULL_GENERATOR=1 UNKNOWN_GENERATOR=2') 'generator summary mismatch'
Assert-True ($mixedResult.Text -match 'ADAPTER_DRIFT FILE-CLEAN ADAPTER') 'adapter drift state missing'
Assert-True ($mixedResult.Text -match 'STALE_ADAPTER_COPY FILE-CLEAN ADAPTER') 'stale named adapter state missing'
Assert-True ($mixedResult.Text -match 'ADAPTER_PATH_DRIFT FILE-CLEAN ADAPTER') 'nested or misplaced adapter state missing'
Assert-True ($mixedResult.Text -match 'imported\\legacy\\answer-from-measurement.mdc') 'nested managed adapter was not detected'
Assert-True ($mixedResult.Text -match 'ADAPTER_ALIGNED=0 ADAPTER_DRIFT=1 STALE_ADAPTER_COPY=4 ADAPTER_PATH_DRIFT=1') 'adapter summary mismatch'
Assert-True ($mixedResult.Text -match 'STALE_BOOT_HOOK FILE-CLEAN CLAUDE_BOOT_HOOK registration=REGISTERED') 'stale registered Claude hook missing'
Assert-True ($mixedResult.Text -match 'BOOT_HOOK_DRIFT FILE-CLEAN CLAUDE_BOOT_HOOK registration=REGISTERED') 'drifted Claude hook missing'
Assert-True ($mixedResult.Text -match 'BOOT_HOOK_MISSING FILE-CLEAN CLAUDE_BOOT_HOOK registration=REGISTERED') 'missing registered Claude hook missing'
Assert-True ($mixedResult.Text -match 'BOOT_HOOK_UNREGISTERED FILE-CLEAN CLAUDE_BOOT_HOOK registration=NOT_REGISTERED') 'unregistered Claude hook missing'
Assert-True ($mixedResult.Text -match 'BOOT_HOOK_REGISTRATION_MULTIPLE FILE-CLEAN CLAUDE_BOOT_HOOK registration=MULTIPLE') 'duplicate Claude hook registration was not rejected'
Assert-True ($mixedResult.Text -match 'STALE_BOOT_HOOK_OTHER_PATH FILE-CLEAN CLAUDE_BOOT_HOOK registration=STALE_OTHER') 'different-basename DreamerOS hook was not detected'
Assert-True ($mixedResult.Text -match 'BOOT_HOOKS_DISABLED FILE-CLEAN CLAUDE_BOOT_HOOK registration=DISABLED') 'project disableAllHooks was not detected'
Assert-True ($mixedResult.Text -match 'BOOT_HOOK_MANAGED_ONLY_MISPLACED FILE-CLEAN CLAUDE_BOOT_HOOK registration=MANAGED_ONLY_MISPLACED') 'misplaced managed-only hook policy was not detected'
Assert-True ($mixedResult.Text -match 'hook-description-only\\.claude\\hooks\\dreameros-session-start.sh') 'description-only hook reference control missing'
Assert-True ($mixedResult.Text -match 'CLAUDE_BOOT_HOOKS=10 BOOT_HOOK_ALIGNED=0 STALE_BOOT_HOOK=1 BOOT_HOOK_OTHER=9') 'Claude hook summary mismatch'
Assert-True ($mixedResult.Text -match 'PROJECT_MCP_AUTH_HEADER FILE-CLEAN CURSOR_PROJECT_MCP server=dreameros-platform') 'project MCP Authorization shadow missing'
Assert-True ($mixedResult.Text -match 'PROJECT_MCP_SHADOW FILE-CLEAN CURSOR_PROJECT_MCP server=dreameros-platform') 'header-free project MCP shadow missing'
Assert-True ($mixedResult.Text -match 'PROJECT_MCP_ENDPOINT_SHADOW FILE-CLEAN CURSOR_PROJECT_MCP server=dreameros-platform') 'hostile project MCP endpoint shadow missing'
Assert-True ($mixedResult.Text -match 'LEGACY_PROJECT_MCP FILE-CLEAN CURSOR_PROJECT_MCP server=dreameros') 'legacy project MCP entry missing'
Assert-True ($mixedResult.Text -match 'PROJECT_MCP_CONFIG_UNKNOWN FILE-CLEAN CURSOR_PROJECT_MCP') 'invalid project MCP config missing'
Assert-True ($mixedResult.Text -match 'PROJECT_MCP_RECORDS=5 PROJECT_MCP_AUTH_HEADER=1 PROJECT_MCP_SHADOW=1 PROJECT_MCP_ENDPOINT_SHADOW=1 LEGACY_PROJECT_MCP=1 PROJECT_MCP_UNKNOWN=1') 'project MCP summary mismatch'
Assert-True ($mixedResult.Text -match 'USER_MCP_SHADOW CURSOR_USER_MCP server=dreameros-platform') 'user MCP shadow missing'
Assert-True ($mixedResult.Text -match 'USER_MCP_RECORDS=1') 'user MCP summary mismatch'
Assert-True ($mixedResult.Text -match 'CURSOR_PROJECT_HOOK_SHADOW FILE-CLEAN CURSOR_HOOK_SCOPE=PROJECT critical_events=1') 'project Cursor hook shadow missing'
Assert-True ($mixedResult.Text -match 'CURSOR_PROJECT_HOOK_CONFIG_UNKNOWN FILE-CLEAN CURSOR_HOOK_SCOPE=PROJECT') 'invalid project Cursor hooks config missing'
Assert-True ($mixedResult.Text -match 'CURSOR_USER_HOOK_SHADOW FILE-CLEAN CURSOR_HOOK_SCOPE=USER critical_events=1') 'user Cursor hook shadow missing'
Assert-True ($mixedResult.Text -match 'CURSOR_HOOK_SHADOWS=3') 'Cursor hook shadow summary mismatch'
Assert-True ($mixedResult.Text -match 'DUPLICATE_EMBEDDED_EXCERPT CLAUDE') 'embedded excerpt state missing'
Assert-True ($mixedResult.Text -match 'excerpt-target-r1\\AGENTS.md') 'target-style measurement excerpt was not detected'
Assert-True ($mixedResult.Text -match 'excerpt-target-local\\AGENTS.md') 'target-style local excerpt was not detected'
Assert-True ($mixedResult.Text -match 'excerpt-target-vendor\\AGENTS.md') 'target-style vendor excerpt was not detected'
Assert-True ($mixedResult.Text -match 'DUPLICATE_RULE_EXCERPT FILE-CLEAN') 'rule excerpt state missing'
Assert-True ($mixedResult.Text -match 'imported\\legacy\\generic-copy.mdc') 'nested generic rule excerpt state missing'
Assert-True ($mixedResult.Text -match 'DUPLICATE_EMBEDDED_EXCERPT=8 DUPLICATE_RULE_EXCERPT=1') 'excerpt summary mismatch'
Assert-True ($mixedResult.Text -match 'DREAMEROS_AUDIT_OUTCOME=FINDINGS') 'mixed audit outcome marker missing'

$emptyEstate = Join-Path $TempRoot 'empty'
New-Item -ItemType Directory -Path $emptyEstate | Out-Null
$emptyResult = Invoke-Audit $emptyEstate
Assert-True ($emptyResult.ExitCode -ne 0) 'empty estate must not verify zero repos'
Assert-True ($emptyResult.Text -match 'No Git repositories were discovered') 'empty-estate control signature missing'

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
