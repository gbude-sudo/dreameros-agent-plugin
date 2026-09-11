$ErrorActionPreference = 'Stop'

$InstallRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Installer = Join-Path $InstallRoot 'dreameros-global-setup.ps1'
$Payload = Join-Path $InstallRoot 'payload'
$PowerShellExe = (Get-Process -Id $PID).Path
$TempRoot = Join-Path $env:TEMP ('dreameros-claude-settings-merge-' + [guid]::NewGuid().ToString('N'))
$ClaudeHome = Join-Path $TempRoot 'home\.claude'
$FixtureRepoRoot = Join-Path $TempRoot 'repos'
$SettingsPath = Join-Path $ClaudeHome 'settings.json'
$Cases = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:Cases++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Get-CanonicalJson($Value) {
    return ConvertTo-Json -InputObject $Value -Depth 100 -Compress
}

function Get-HookCommands($Root, [string]$Event) {
    $commands = New-Object System.Collections.ArrayList
    foreach ($group in @($Root.hooks.$Event)) {
        foreach ($hook in @($group.hooks)) {
            if ([string]$hook.type -eq 'command') { [void]$commands.Add([string]$hook.command) }
        }
    }
    return $commands
}

function Get-HookCount($Root, [string]$Event) {
    $count = 0
    foreach ($group in @($Root.hooks.$Event)) { $count += @($group.hooks).Count }
    return $count
}

function Get-DuplicateCommandCount($Root, [string[]]$Events) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $duplicates = 0
    foreach ($eventName in $Events) {
        foreach ($command in @(Get-HookCommands $Root $eventName)) {
            if (-not $seen.Add(($eventName + ':' + $command))) { $duplicates++ }
        }
    }
    return $duplicates
}

function Find-CommandHook($Root, [string]$Event, [string]$Pattern) {
    foreach ($group in @($Root.hooks.$Event)) {
        foreach ($hook in @($group.hooks)) {
            if ([string]$hook.command -match $Pattern) { return $hook }
        }
    }
    return $null
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

New-Item -ItemType Directory -Path $ClaudeHome -Force | Out-Null
New-Item -ItemType Directory -Path $FixtureRepoRoot -Force | Out-Null
$homeUnix = $ClaudeHome.Replace('\', '/')
$sessionPackage = "bash `"$homeUnix/hooks/dreameros-session-start.sh`""
$openLoop = "bash `"$homeUnix/hooks/open-loop-surface.sh`""
$verifyOnly = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:/Users/PC/Documents/Codex/dreameros-agent-plugin/bootpack/build-boot-pack.ps1" -VerifyInstalled'
$retiredInstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:/Users/PC/Documents/Codex/dreameros-agent-plugin/bootpack/build-boot-pack.ps1" -Install'
$ownerNearInstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:/owner/owner-build-boot-pack.ps1" -Install'
$retiredStandingOrders = "bash `"$homeUnix/hooks/operator-standing-orders.sh`""
$retiredStackSession = "bash `"$homeUnix/hooks/dreameros-agent-stack-session-start.sh`""
$ownerNearStandingOrders = "bash `"$homeUnix/hooks/owner-operator-standing-orders.sh`""
$ownerNearStackSession = "bash `"$homeUnix/hooks/owner-dreameros-agent-stack-session-start.sh`""
$gateStop = "bash `"$homeUnix/hooks/gate-stop-no-half-states.sh`""
$claim = "bash `"$homeUnix/hooks/gate-claim-verification.sh`""
$stackStop = "bash `"$homeUnix/hooks/dreameros-agent-stack-stop.sh`""
$phase = "bash `"$homeUnix/hooks/model-phase-boundary.sh`""
$switchShell = "bash `"$homeUnix/hooks/model-switch-ack.sh`""
$switchPython = "python `"$homeUnix/hooks/model-switch-ack.py`""
$ownerNearSwitch = "bash `"$homeUnix/hooks/owner-model-switch-ack.sh`""
$sharedPreTool = "python `"$homeUnix/hooks/shared-pretool.py`""
$sharedAgentPrompt = 'Same owner prompt under two lifecycle matchers must remain twice.'

$fixture = [ordered]@{
    permissions = [ordered]@{ defaultMode = 'auto'; deny = @('OwnerDeny'); allow = @('OwnerAllow') }
    enabledPlugins = [ordered]@{ owner = $true }
    mcpServers = [ordered]@{ owner = [ordered]@{ type = 'stdio'; command = 'owner-tool' } }
    env = [ordered]@{ SAFE_TEST_VALUE = 'preserve-me' }
    ownerMetadata = [ordered]@{ nested = @('alpha', 'beta'); flag = $true }
    hooks = [ordered]@{
        SessionStart = @(
            [ordered]@{ hooks = @(
                [ordered]@{ type = 'command'; command = $sessionPackage; owner = 'session-package-first' },
                [ordered]@{ type = 'command'; command = $openLoop; timeout = 99; owner = 'open-loop-first' }
            ) },
            [ordered]@{ matcher = 'cloud'; label = 'keep-cloud-group'; hooks = @(
                [ordered]@{ type = 'command'; command = $openLoop; timeout = 45; owner = 'duplicate-later' },
                [ordered]@{ type = 'command'; command = $verifyOnly; owner = 'verify-only' }
            ) },
            [ordered]@{ hooks = @(
                [ordered]@{ type = 'command'; command = $retiredInstall },
                [ordered]@{ type = 'command'; command = $retiredStandingOrders },
                [ordered]@{ type = 'command'; command = $retiredStackSession },
                [ordered]@{ type = 'command'; command = $ownerNearStandingOrders; owner = 'near-standing-orders-name' },
                [ordered]@{ type = 'command'; command = $ownerNearStackSession; owner = 'near-stack-session-name' }
            ) },
            [ordered]@{ matcher = '*'; ownerGroup = 'keep-session-group'; hooks = @(
                [ordered]@{ type = 'command'; command = "python `"$homeUnix/hooks/gate_session_reanchor.py`""; owner = 'unique-session' },
                [ordered]@{ type = 'command'; command = $ownerNearInstall; owner = 'near-install-name' }
            ) }
        )
        Stop = @(
            [ordered]@{ hooks = @(
                [ordered]@{ type = 'command'; command = $gateStop; owner = 'gate-stop' },
                [ordered]@{ type = 'command'; command = $claim; timeout = 91; owner = 'claim-first' },
                [ordered]@{ type = 'command'; command = $stackStop; owner = 'stack-first' },
                [ordered]@{ type = 'command'; command = $phase; owner = 'phase-first' },
                [ordered]@{ type = 'command'; command = $switchShell; owner = 'retired-wrapper' },
                [ordered]@{ type = 'command'; command = "python `"$homeUnix/hooks/owner-stop-a.py`""; owner = 'unique-base' }
            ) },
            [ordered]@{ matcher = '*'; label = 'keep-star-group'; hooks = @(
                [ordered]@{ type = 'command'; command = $claim; timeout = 45; owner = 'claim-duplicate' },
                [ordered]@{ type = 'command'; command = $switchPython; owner = 'direct-switch' },
                [ordered]@{ type = 'command'; command = "python `"$homeUnix/hooks/owner-stop-b.py`""; owner = 'unique-star' }
            ) },
            [ordered]@{ matcher = 'custom'; label = 'keep-custom-group'; hooks = @(
                [ordered]@{ type = 'command'; command = $stackStop; owner = 'stack-duplicate' },
                [ordered]@{ type = 'command'; command = "python `"$homeUnix/hooks/owner-stop-c.py`""; owner = 'unique-custom' }
            ) },
            [ordered]@{ hooks = @([ordered]@{ type = 'command'; command = $phase; owner = 'phase-duplicate' }) },
            [ordered]@{ matcher = 'agent'; label = 'keep-agent-group'; hooks = @(
                [ordered]@{ type = 'agent'; prompt = $sharedAgentPrompt; owner = 'agent-alpha' },
                [ordered]@{ type = 'command'; command = $ownerNearSwitch; owner = 'near-switch-name' }
            ) },
            [ordered]@{ matcher = 'agent-two'; label = 'keep-second-agent-group'; hooks = @(
                [ordered]@{ type = 'agent'; prompt = $sharedAgentPrompt; owner = 'agent-beta' }
            ) }
        )
        PreToolUse = @(
            [ordered]@{ matcher = 'Bash'; label = 'keep-bash'; hooks = @([ordered]@{ type = 'command'; command = $sharedPreTool; owner = 'bash-copy' }) },
            [ordered]@{ matcher = 'Write'; label = 'keep-write'; hooks = @([ordered]@{ type = 'command'; command = $sharedPreTool; owner = 'write-copy' }) }
        )
        Notification = @(
            [ordered]@{ matcher = 'idle'; label = 'keep-notification'; hooks = @([ordered]@{ type = 'command'; command = "python `"$homeUnix/hooks/owner-notify.py`""; owner = 'notification' }) }
        )
    }
}

[IO.File]::WriteAllText($SettingsPath, ((ConvertTo-Json -InputObject $fixture -Depth 100) + "`n"), (New-Object Text.UTF8Encoding($false)))
$before = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
$beforeLifecycleCount = (Get-HookCount $before 'SessionStart') + (Get-HookCount $before 'Stop')
$beforeDuplicateCount = Get-DuplicateCommandCount $before @('SessionStart', 'Stop')
$beforeOwnerMetadata = Get-CanonicalJson $before.ownerMetadata
$beforeEnabledPlugins = Get-CanonicalJson $before.enabledPlugins
$beforeMcpServers = Get-CanonicalJson $before.mcpServers
$beforeEnv = Get-CanonicalJson $before.env
$beforeNotification = Get-CanonicalJson $before.hooks.Notification
$beforeFirstOpenLoop = Get-CanonicalJson (Find-CommandHook $before 'SessionStart' 'open-loop-surface\.sh')
$beforeFirstClaim = Get-CanonicalJson (Find-CommandHook $before 'Stop' 'gate-claim-verification\.sh')

Assert-True ($beforeDuplicateCount -eq 4) 'fixture must start with exactly four cross-group duplicate commands'
Assert-True (@(Get-HookCommands $before 'SessionStart' | Where-Object { $_ -ceq $retiredInstall }).Count -eq 1) 'fixture retired auto-install control missing'
Assert-True (@(Get-HookCommands $before 'SessionStart' | Where-Object { $_ -ceq $retiredStandingOrders -or $_ -ceq $retiredStackSession }).Count -eq 2) 'fixture exact retired hydration controls missing'
Assert-True (@(Get-HookCommands $before 'Stop' | Where-Object { $_ -ceq $switchShell }).Count -eq 1) 'fixture retired model-switch wrapper control missing'

$first = Invoke-Installer
Assert-True ($first.ExitCode -eq 0) "installer failed: $($first.Text)"
$after = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
$afterLifecycleCount = (Get-HookCount $after 'SessionStart') + (Get-HookCount $after 'Stop')
$afterDuplicateCount = Get-DuplicateCommandCount $after @('SessionStart', 'Stop')
$sessionCommands = @(Get-HookCommands $after 'SessionStart')
$stopCommands = @(Get-HookCommands $after 'Stop')

Assert-True ($afterLifecycleCount -eq ($beforeLifecycleCount - 8)) 'lifecycle hook count did not decrease by exactly eight'
Assert-True ($afterDuplicateCount -eq 0) 'cross-group lifecycle duplicates remain'
Assert-True (@($sessionCommands | Where-Object { $_ -match 'open-loop-surface\.sh' }).Count -eq 1) 'open-loop SessionStart count is not one'
Assert-True (@($stopCommands | Where-Object { $_ -match 'gate-claim-verification\.sh' }).Count -eq 1) 'claim verification Stop count is not one'
Assert-True (@($stopCommands | Where-Object { $_ -match 'dreameros-agent-stack-stop\.sh' }).Count -eq 1) 'agent stack Stop count is not one'
Assert-True (@($stopCommands | Where-Object { $_ -match 'model-phase-boundary\.sh' }).Count -eq 1) 'model phase Stop count is not one'
Assert-True (@($sessionCommands | Where-Object { $_ -ceq $retiredInstall }).Count -eq 0) 'retired SessionStart auto-install remains'
Assert-True (@($sessionCommands | Where-Object { $_ -match 'build-boot-pack\.ps1.*-VerifyInstalled' }).Count -eq 1) 'verify-only SessionStart hook was removed'
Assert-True (@($sessionCommands | Where-Object { $_ -match 'dreameros-session-start\.sh' }).Count -eq 1) 'session-package bootstrap hook was removed or duplicated'
Assert-True (@($stopCommands | Where-Object { $_ -ceq $switchShell }).Count -eq 0) 'retired model-switch shell wrapper remains registered'
Assert-True (@($stopCommands | Where-Object { $_ -ceq $switchPython }).Count -eq 1) 'direct model-switch Python hook was removed or duplicated'
Assert-True (@($sessionCommands | Where-Object { $_ -ceq $ownerNearInstall }).Count -eq 1) 'near-name owner build hook was removed'
Assert-True (@($sessionCommands | Where-Object { $_ -ceq $retiredStandingOrders -or $_ -ceq $retiredStackSession }).Count -eq 0) 'exact retired hydration hook remains'
Assert-True (@($sessionCommands | Where-Object { $_ -ceq $ownerNearStandingOrders }).Count -eq 1) 'owner-prefixed standing-orders hook was removed'
Assert-True (@($sessionCommands | Where-Object { $_ -ceq $ownerNearStackSession }).Count -eq 1) 'owner-prefixed stack-session hook was removed'
Assert-True (@($stopCommands | Where-Object { $_ -ceq $ownerNearSwitch }).Count -eq 1) 'near-name owner switch hook was removed'
$samePromptHooks = @($after.hooks.Stop | ForEach-Object { $_.hooks } | Where-Object { [string]$_.type -eq 'agent' -and [string]$_.prompt -ceq $sharedAgentPrompt })
Assert-True ($samePromptHooks.Count -eq 2) 'same-prompt agent hooks were deduped across lifecycle matcher groups'
$secondAgentGroup = @($after.hooks.Stop | Where-Object { [string]$_.matcher -eq 'agent-two' })
Assert-True ($secondAgentGroup.Count -eq 1 -and [string]$secondAgentGroup[0].label -eq 'keep-second-agent-group') 'second same-prompt agent matcher group was removed'
Assert-True ((Get-CanonicalJson (Find-CommandHook $after 'SessionStart' 'open-loop-surface\.sh')) -ceq $beforeFirstOpenLoop) 'first open-loop hook was not preserved exactly'
Assert-True ((Get-CanonicalJson (Find-CommandHook $after 'Stop' 'gate-claim-verification\.sh')) -ceq $beforeFirstClaim) 'first claim hook was not preserved exactly'
Assert-True ((Get-CanonicalJson $after.ownerMetadata) -ceq $beforeOwnerMetadata) 'unrelated owner metadata changed'
Assert-True ((Get-CanonicalJson $after.enabledPlugins) -ceq $beforeEnabledPlugins) 'enabledPlugins changed'
Assert-True ((Get-CanonicalJson $after.mcpServers) -ceq $beforeMcpServers) 'mcpServers changed'
Assert-True ((Get-CanonicalJson $after.env) -ceq $beforeEnv) 'env changed'
Assert-True ((Get-CanonicalJson $after.hooks.Notification) -ceq $beforeNotification) 'unrelated hook event changed'
Assert-True (@(Get-HookCommands $after 'PreToolUse' | Where-Object { $_ -eq $sharedPreTool }).Count -eq 2) 'PreToolUse hooks were deduped across matcher groups'
$cloudGroup = @($after.hooks.SessionStart | Where-Object { [string]$_.matcher -eq 'cloud' })
Assert-True ($cloudGroup.Count -eq 1 -and [string]$cloudGroup[0].label -eq 'keep-cloud-group') 'nonduplicate SessionStart matcher group was not preserved'
$customGroup = @($after.hooks.Stop | Where-Object { [string]$_.matcher -eq 'custom' })
Assert-True ($customGroup.Count -eq 1 -and [string]$customGroup[0].label -eq 'keep-custom-group') 'nonduplicate Stop matcher group was not preserved'
Assert-True ($first.Text -match 'hooks.SessionStart removed 1 duplicate hook') 'SessionStart duplicate receipt missing'
Assert-True ($first.Text -match 'hooks.Stop removed 3 duplicate hook') 'Stop duplicate receipt missing'
Assert-True ($first.Text -match 'hooks.SessionStart removed 3 retired hook') 'retired SessionStart receipt missing'
Assert-True ($first.Text -match 'hooks.Stop removed 1 retired hook') 'retired shell-wrapper receipt missing'

$firstHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SettingsPath).Hash
$second = Invoke-Installer
Assert-True ($second.ExitCode -eq 0) "second installer run failed: $($second.Text)"
$secondHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SettingsPath).Hash
Assert-True ($secondHash -ceq $firstHash) 'second install changed settings.json bytes'

Write-Output (@{
    status = 'pass'
    assertions = $Cases
    initial_lifecycle_hooks = $beforeLifecycleCount
    final_lifecycle_hooks = $afterLifecycleCount
    removed_exactly = $beforeLifecycleCount - $afterLifecycleCount
    fixture_root = $TempRoot
} | ConvertTo-Json -Compress)
