# Read-only cross-vendor census. It proves whether repository-level Claude,
# Codex, and Cursor surfaces are global-only or carry the generated pointer,
# and detects any duplicated full canon that can override the native carrier.
[CmdletBinding()]
param(
    [string[]]$EstateRoots,
    [string]$UserHome,
    [string]$EnterpriseCursorHooksPath
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Builder = Join-Path $RepoRoot 'bootpack\build-boot-pack.ps1'
$EmbeddedPointer = Join-Path $RepoRoot 'bootpack\out\project\DREAMEROS_BOOT_CANON_POINTER.md.block'
$CursorPointer = Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-project-pointer.mdc'
$MeasurementAdapter = Join-Path $RepoRoot 'bootpack\out\cursor\answer-from-measurement.adapter.mdc'
$StatusAdapter = Join-Path $RepoRoot 'bootpack\out\cursor\canon-equals-live.adapter.mdc'
$ProjectCoordinationAdapter = Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-cold-start.adapter.mdc'
$VerifiedHandoffAdapter = Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-first.adapter.mdc'
$ClaudeSessionStartAdapter = Join-Path $RepoRoot 'bootpack\out\claude\dreameros-session-start.sh'
$GeneratorPointer = Join-Path $RepoRoot 'bootpack\out\project\DREAMEROS_CENTRAL_BOOT_GENERATOR_POINTER.ps1.block'

if ([string]::IsNullOrWhiteSpace($UserHome)) { $UserHome = $env:USERPROFILE }
$UserHome = [IO.Path]::GetFullPath($UserHome).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($EnterpriseCursorHooksPath)) {
    $EnterpriseCursorHooksPath = if ($env:ProgramData) {
        Join-Path $env:ProgramData 'Cursor\hooks.json'
    } else {
        ''
    }
}

if (-not $EstateRoots -or $EstateRoots.Count -eq 0) {
    $EstateRoots = @(
        (Join-Path $UserHome 'Documents\DreamerOS'),
        (Join-Path $UserHome 'Documents\Codex'),
        $UserHome
    )
}

function Normalize([string]$Text) {
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n").Trim()
}

function Get-ShaText([string]$Text) {
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes((Normalize $Text))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLower() }
    finally { $sha.Dispose() }
}

function Assert-NoReparseTraversal([string]$Path, [string]$BoundaryRoot) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $boundary = [IO.Path]::GetFullPath($BoundaryRoot).TrimEnd('\')
    if (-not ($full.Equals($boundary, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith(($boundary + '\'), [StringComparison]::OrdinalIgnoreCase))) {
        throw "Audit path escaped its lexical boundary; path_digest=$(Get-ShaText $full)."
    }
    if (-not (Test-Path -LiteralPath $boundary -PathType Container)) {
        throw "Audit boundary does not exist; boundary_digest=$(Get-ShaText $boundary)."
    }
    $boundaryItem = Get-Item -LiteralPath $boundary -Force
    if ($boundaryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Audit boundary is a reparse point; boundary_digest=$(Get-ShaText $boundary)."
    }
    $relative = $full.Substring($boundary.Length).TrimStart('\')
    $current = $boundary
    foreach ($segment in @($relative -split '\\' | Where-Object { $_ })) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { break }
        $item = Get-Item -LiteralPath $current -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Audit path crosses a reparse point; path_digest=$(Get-ShaText $current)."
        }
    }
}

function Get-SafeRuleFiles([string]$Root, [string]$BoundaryRoot) {
    Assert-NoReparseTraversal $Root $BoundaryRoot
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    $queue = [Collections.Generic.Queue[string]]::new()
    $files = [Collections.Generic.List[object]]::new()
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        foreach ($item in (Get-ChildItem -LiteralPath $current -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Cursor rule discovery encountered a reparse point; path_digest=$(Get-ShaText $item.FullName)."
            }
            if ($item.PSIsContainer) { $queue.Enqueue($item.FullName) }
            elseif ($item.Extension -ieq '.mdc') { [void]$files.Add($item) }
        }
    }
    return @($files)
}

function Get-ClaudeHookRegistration([string[]]$SettingsPaths, [string]$ProjectRoot) {
    $registrations = @()
    $otherDreamerOsHooks = @()
    $hooksDisabled = $false
    $managedOnly = $false
    foreach ($settingsPath in $SettingsPaths) {
        Assert-NoReparseTraversal $settingsPath $ProjectRoot
        if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { continue }
        try {
            $settings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
        } catch {
            return 'UNKNOWN'
        }
        if ($settings.disableAllHooks -eq $true) { $hooksDisabled = $true }
        if ($settings.allowManagedHooksOnly -eq $true) { $managedOnly = $true }
        $sessionStart = $settings.hooks.SessionStart
        if ($null -eq $sessionStart) { continue }
        foreach ($entry in @($sessionStart)) {
            foreach ($hook in @($entry.hooks)) {
                if ($null -eq $hook -or $hook.type -ne 'command' -or $hook.command -isnot [string]) { continue }
                if ($hook.command -match '(?i)^\s*(?:bash|sh)\s+["'']?\$(?:\{)?CLAUDE_PROJECT_DIR(?:\})?[\\/]\.claude[\\/]hooks[\\/]dreameros-session-start\.sh["'']?\s*$') {
                    $registrations += $hook.command
                } else {
                    $isOtherHydration = $hook.command -match '(?i)dreameros|dreamer[_-]?os|hydration'
                    $projectPathMatch = [regex]::Match($hook.command, '(?i)\$(?:\{)?CLAUDE_PROJECT_DIR(?:\})?[\\/](?<relative>\.claude[\\/]hooks[\\/][^"'']+\.(?:sh|py|ps1))')
                    if ($projectPathMatch.Success) {
                        $projectScript = Join-Path $ProjectRoot $projectPathMatch.Groups['relative'].Value.Replace('/', '\')
                        Assert-NoReparseTraversal $projectScript $ProjectRoot
                        if (Test-Path -LiteralPath $projectScript -PathType Leaf) {
                            $projectScriptText = [IO.File]::ReadAllText($projectScript)
                            $isOtherHydration = $isOtherHydration -or (
                                $projectScriptText -match '(?i)hookSpecificOutput' -and
                                $projectScriptText -match '(?i)dreameros_(?:session_package|context|state|recall|canon)|DreamerOS session/context/state'
                            )
                        }
                    }
                    if ($isOtherHydration) { $otherDreamerOsHooks += $hook.command }
                }
            }
        }
    }
    if ($hooksDisabled) { return 'DISABLED' }
    if ($managedOnly) { return 'MANAGED_ONLY_MISPLACED' }
    if ($registrations.Count -eq 0 -and $otherDreamerOsHooks.Count -eq 0) { return 'NOT_REGISTERED' }
    if ($registrations.Count -eq 1 -and $otherDreamerOsHooks.Count -eq 0) { return 'REGISTERED' }
    if ($registrations.Count -eq 0 -and $otherDreamerOsHooks.Count -eq 1) { return 'STALE_OTHER' }
    return 'MULTIPLE'
}

function Get-ShellScriptPath([string]$Command, [string]$HomePath) {
    $match = [regex]::Match($Command, '(?i)^\s*(?:bash|sh)\s+(?:["''](?<quoted>[^"'']+\.sh)["'']|(?<plain>\S+\.sh))\s*$')
    if (-not $match.Success) { return $null }
    $path = if ($match.Groups['quoted'].Success) { $match.Groups['quoted'].Value } else { $match.Groups['plain'].Value }
    $path = $path.Replace('/', '\')
    if ($path.StartsWith('~\')) { $path = Join-Path $HomePath $path.Substring(2) }
    $path = $path.Replace('$HOME', $HomePath).Replace('${HOME}', $HomePath)
    $path = $path.Replace('$env:USERPROFILE', $HomePath).Replace('%USERPROFILE%', $HomePath)
    if (-not [IO.Path]::IsPathRooted($path)) { return $null }
    return [IO.Path]::GetFullPath($path)
}

function Get-CursorCriticalHookCount([string]$Path) {
    $data = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ($data.version -ne 1 -or $null -eq $data.hooks) { throw 'Cursor hooks config requires version 1 and a hooks object.' }
    $critical = @('sessionStart', 'beforeMCPExecution', 'afterMCPExecution', 'postToolUse', 'beforeShellExecution', 'beforeReadFile')
    $count = 0
    foreach ($event in $critical) {
        $entries = @($data.hooks.$event)
        $count += @($entries | Where-Object { $null -ne $_ }).Count
    }
    return $count
}

function Get-EmbeddedState([string]$Path, [string]$ExpectedPointer) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'GLOBAL_ONLY' }
    try { $text = [IO.File]::ReadAllText($Path) } catch { return 'UNKNOWN' }
    $fullPattern = '<!-- BEGIN DREAMEROS-BOOT-CANON v[0-9]+\.[0-9]+\.[0-9]+[\s\S]*?<!-- END DREAMEROS-BOOT-CANON v[0-9]+\.[0-9]+\.[0-9]+ -->'
    $pointerPattern = '<!-- DREAMEROS-BOOT-CANON: NOT DUPLICATED HERE -->[\s\S]*?<!-- END DREAMEROS-BOOT-CANON POINTER -->'
    $full = [regex]::Matches($text, $fullPattern)
    $pointer = [regex]::Matches($text, $pointerPattern)
    if ($full.Count -eq 1 -and $pointer.Count -eq 0) { return 'LEGACY_FULL_COPY' }
    if ($full.Count -eq 0 -and $pointer.Count -eq 1) {
        if ((Normalize $pointer[0].Value) -ceq (Normalize $ExpectedPointer)) { return 'POINTER_ALIGNED' }
        return 'POINTER_DRIFT'
    }
    if ($full.Count -eq 0 -and $pointer.Count -eq 0) {
        if ($text -match 'DreamerOS Boot Canon v|DREAMEROS-PROJECT-BOOT-POINTER|DREAMEROS-BOOT-CANON POINTER') {
            return 'UNKNOWN'
        }
        return 'GLOBAL_ONLY'
    }
    return 'UNKNOWN'
}

function Test-EmbeddedExcerpt([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { $text = [IO.File]::ReadAllText($Path) } catch { return $false }
    $fullPattern = '<!-- BEGIN DREAMEROS-BOOT-CANON v[0-9]+\.[0-9]+\.[0-9]+[\s\S]*?<!-- END DREAMEROS-BOOT-CANON v[0-9]+\.[0-9]+\.[0-9]+ -->'
    $pointerPattern = '<!-- DREAMEROS-BOOT-CANON: NOT DUPLICATED HERE -->[\s\S]*?<!-- END DREAMEROS-BOOT-CANON POINTER -->'
    $remainder = [regex]::Replace($text, $fullPattern, '')
    $remainder = [regex]::Replace($remainder, $pointerPattern, '')
    $canonicalHeading = '(?im)^\s{0,3}#{1,6}\s+(?:(?:R1|R2|R3)\s+-\s+)?(?:ANSWER FROM MEASUREMENT(?:,\s+NEVER FROM MEMORY)?|CANON, RUNTIME, LIVE(?:\s+AND\s+DONE)?\s+(?:ARE|IS)\s+ONE\s+WORD|FIXED MEANS CUSTOMER-USABLE|LOCAL MEANS THE WHOLE DESKTOP|VENDOR AGNOSTIC)\b'
    return $remainder -match $canonicalHeading -or
        $remainder -match '(?i)THE DEFINITION OF DONE|HC-DEFINITION-OF-DONE'
}

function Get-CursorState([string]$Path, [string]$ExpectedPointer, [string]$ExpectedHash) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'GLOBAL_ONLY' }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return 'UNKNOWN' }
        $text = [IO.File]::ReadAllText($Path)
    } catch { return 'UNKNOWN' }
    if ((Get-ShaText $text) -eq $ExpectedHash) { return 'POINTER_ALIGNED' }
    if ($text.Contains('DREAMEROS-PROJECT-BOOT-POINTER')) { return 'POINTER_DRIFT' }
    if ($text.Length -ge 5000 -and
        $text -match '(?m)^# DreamerOS Boot Canon v[0-9]+\.[0-9]+\.[0-9]+\s*$' -and
        $text.Contains('SINGLE SOURCE OF TRUTH. Every vendor file is generated from this one.') -and
        $text.Contains('HC-DEFINITION-OF-DONE')) {
        return 'LEGACY_FULL_COPY'
    }
    return 'UNKNOWN'
}

$priorOptionalLocks = $env:GIT_OPTIONAL_LOCKS
try {
$env:GIT_OPTIONAL_LOCKS = '0'
& $Builder -Verify
$embeddedText = [IO.File]::ReadAllText($EmbeddedPointer)
$cursorText = [IO.File]::ReadAllText($CursorPointer)
$cursorHash = Get-ShaText $cursorText
$measurementAdapterHash = Get-ShaText ([IO.File]::ReadAllText($MeasurementAdapter))
$statusAdapterHash = Get-ShaText ([IO.File]::ReadAllText($StatusAdapter))
$projectCoordinationAdapterHash = Get-ShaText ([IO.File]::ReadAllText($ProjectCoordinationAdapter))
$verifiedHandoffAdapterHash = Get-ShaText ([IO.File]::ReadAllText($VerifiedHandoffAdapter))
$claudeSessionStartAdapterHash = Get-ShaText ([IO.File]::ReadAllText($ClaudeSessionStartAdapter))
$generatorPointerHash = Get-ShaText ([IO.File]::ReadAllText($GeneratorPointer))
$expectedAdapterHashes = @{
    'answer-from-measurement.mdc' = $measurementAdapterHash
    'canon-equals-live.mdc' = $statusAdapterHash
    'dreameros-cold-start.mdc' = $projectCoordinationAdapterHash
    'dreameros-first.mdc' = $verifiedHandoffAdapterHash
}

$requestedRoots = @($EstateRoots | ForEach-Object {
    [IO.Path]::GetFullPath($_).TrimEnd('\')
} | Sort-Object -Unique)
$missingRoots = @($requestedRoots | Where-Object {
    -not (Test-Path -LiteralPath $_ -PathType Container)
})
if ($missingRoots.Count -gt 0) {
    throw "Every requested estate root must exist; missing_count=$($missingRoots.Count)."
}
$reparseRoots = @($requestedRoots | Where-Object {
    (Get-Item -LiteralPath $_ -Force).Attributes -band [IO.FileAttributes]::ReparsePoint
})
if ($reparseRoots.Count -gt 0) {
    throw "Requested estate roots cannot be reparse points; count=$($reparseRoots.Count)."
}
$resolvedRoots = @($requestedRoots | ForEach-Object {
    [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $_).Path).TrimEnd('\')
} | Sort-Object -Unique)

$repos = @()
$reparseChildRecords = @()
foreach ($root in $resolvedRoots) {
    if (Test-Path -LiteralPath (Join-Path $root '.git')) { $repos += $root }
    foreach ($child in (Get-ChildItem -LiteralPath $root -Directory -Force)) {
        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $reparseChildRecords += [pscustomobject]@{ PathDigest = Get-ShaText $child.FullName }
            continue
        }
        if (Test-Path -LiteralPath (Join-Path $child.FullName '.git')) { $repos += $child.FullName }
    }
}
$repos = @($repos | Sort-Object -Unique)
if ($repos.Count -eq 0 -and $reparseChildRecords.Count -eq 0) {
    throw 'No Git repositories were discovered at the estate roots or their direct children.'
}

$records = @()
$generatorRecords = @()
$excerptRecords = @()
$ruleExcerptRecords = @()
$adapterRecords = @()
$claudeHookRecords = @()
$mcpRecords = @()
$userScopeRecords = @()
$userMcpRecords = @()
$cursorHookRecords = @()
foreach ($repo in $repos) {
    foreach ($topLevelItem in (Get-ChildItem -LiteralPath $repo -Force)) {
        if ($topLevelItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Repository audit encountered a top-level reparse point; path_digest=$(Get-ShaText $topLevelItem.FullName)."
        }
    }
    $surfaces = @(
        [pscustomobject]@{ Name = 'CLAUDE'; Path = Join-Path $repo 'CLAUDE.md'; Kind = 'embedded' },
        [pscustomobject]@{ Name = 'CODEX'; Path = Join-Path $repo 'AGENTS.md'; Kind = 'embedded' },
        [pscustomobject]@{ Name = 'CURSOR'; Path = Join-Path $repo '.cursor\rules\dreameros-boot-canon.mdc'; Kind = 'cursor' }
    )
    foreach ($surface in $surfaces) {
        Assert-NoReparseTraversal $surface.Path $repo
        $state = if ($surface.Kind -eq 'cursor') {
            Get-CursorState -Path $surface.Path -ExpectedPointer $cursorText -ExpectedHash $cursorHash
        } else {
            Get-EmbeddedState -Path $surface.Path -ExpectedPointer $embeddedText
        }
        $relative = $surface.Path.Substring($repo.Length).TrimStart([char[]]@('\', '/'))
        $status = @()
        if (Test-Path -LiteralPath $surface.Path -PathType Leaf) {
            $status = @(& git -c "safe.directory=$repo" -C $repo status --porcelain=v1 -- $relative)
            if ($LASTEXITCODE -ne 0) { throw "Git status failed for $($surface.Path)" }
        }
        $records += [pscustomobject]@{
            Repo = $repo
            Surface = $surface.Name
            State = $state
            Dirty = $status.Count -gt 0
            Status = ($status -join ' ')
            Path = $surface.Path
        }
        if ($surface.Kind -eq 'embedded' -and (Test-EmbeddedExcerpt $surface.Path)) {
            $excerptRecords += [pscustomobject]@{
                Repo = $repo
                Surface = $surface.Name
                Path = $surface.Path
            }
        }
    }

    $cursorRuleDir = Join-Path $repo '.cursor\rules'
    if (Test-Path -LiteralPath $cursorRuleDir -PathType Container) {
        Assert-NoReparseTraversal $cursorRuleDir $repo
        $managedRootRule = Join-Path $cursorRuleDir 'dreameros-boot-canon.mdc'
        foreach ($rule in (Get-SafeRuleFiles $cursorRuleDir $repo |
            Where-Object { $_.FullName -ne $managedRootRule })) {
            Assert-NoReparseTraversal $rule.FullName $repo
            $text = [IO.File]::ReadAllText($rule.FullName)
            $ruleHash = Get-ShaText $text
            $isRootRule = [string]::Equals(
                [IO.Path]::GetFullPath($rule.DirectoryName).TrimEnd('\'),
                [IO.Path]::GetFullPath($cursorRuleDir).TrimEnd('\'),
                [StringComparison]::OrdinalIgnoreCase
            )
            $namedAdapterHash = $expectedAdapterHashes[$rule.Name]
            $hasAdapterMarker = $text.Contains('DREAMEROS-CURSOR-ENFORCEMENT-ADAPTER') -or
                $text.Contains('DREAMEROS-CURSOR-PROJECT-ADAPTER')
            $expectedAdapterHash = if ($isRootRule) { $namedAdapterHash } else { $null }
            if ((-not $isRootRule -and ($namedAdapterHash -or $hasAdapterMarker)) -or
                ($isRootRule -and -not $namedAdapterHash -and $hasAdapterMarker)) {
                $relative = $rule.FullName.Substring($repo.Length).TrimStart([char[]]@('\', '/'))
                $status = @(& git -c "safe.directory=$repo" -C $repo status --porcelain=v1 -- $relative)
                if ($LASTEXITCODE -ne 0) { throw "Git status failed for $($rule.FullName)" }
                $adapterRecords += [pscustomobject]@{
                    Repo = $repo
                    State = 'ADAPTER_PATH_DRIFT'
                    Dirty = $status.Count -gt 0
                    Status = ($status -join ' ')
                    Path = $rule.FullName
                }
            } elseif ($expectedAdapterHash) {
                $relative = $rule.FullName.Substring($repo.Length).TrimStart([char[]]@('\', '/'))
                $status = @(& git -c "safe.directory=$repo" -C $repo status --porcelain=v1 -- $relative)
                if ($LASTEXITCODE -ne 0) { throw "Git status failed for $($rule.FullName)" }
                $state = if ($ruleHash -eq $expectedAdapterHash) {
                    'ADAPTER_ALIGNED'
                } elseif ($text.Contains('DREAMEROS-CURSOR-ENFORCEMENT-ADAPTER') -or
                    $text.Contains('DREAMEROS-CURSOR-PROJECT-ADAPTER')) {
                    'ADAPTER_DRIFT'
                } else {
                    'STALE_ADAPTER_COPY'
                }
                $adapterRecords += [pscustomobject]@{
                    Repo = $repo
                    State = $state
                    Dirty = $status.Count -gt 0
                    Status = ($status -join ' ')
                    Path = $rule.FullName
                }
            } elseif ($text -match '(?i)ANSWER FROM MEASUREMENT, NEVER FROM MEMORY|CANON, RUNTIME, LIVE and DONE|FIXED MEANS CUSTOMER-USABLE|THE DEFINITION OF DONE') {
                $relative = $rule.FullName.Substring($repo.Length).TrimStart([char[]]@('\', '/'))
                $status = @(& git -c "safe.directory=$repo" -C $repo status --porcelain=v1 -- $relative)
                if ($LASTEXITCODE -ne 0) { throw "Git status failed for $($rule.FullName)" }
                $ruleExcerptRecords += [pscustomobject]@{ Repo = $repo; Dirty = $status.Count -gt 0; Status = ($status -join ' '); Path = $rule.FullName }
            }
        }
    }

    $claudeHookPath = Join-Path $repo '.claude\hooks\dreameros-session-start.sh'
    $claudeSettingsPaths = @(
        (Join-Path $repo '.claude\settings.json'),
        (Join-Path $repo '.claude\settings.local.json')
    )
    Assert-NoReparseTraversal $claudeHookPath $repo
    foreach ($claudeSettingsPath in $claudeSettingsPaths) {
        Assert-NoReparseTraversal $claudeSettingsPath $repo
    }
    $registration = Get-ClaudeHookRegistration -SettingsPaths $claudeSettingsPaths -ProjectRoot $repo
    if ((Test-Path -LiteralPath $claudeHookPath -PathType Leaf) -or $registration -ne 'NOT_REGISTERED') {
        $hookText = if (Test-Path -LiteralPath $claudeHookPath -PathType Leaf) {
            [IO.File]::ReadAllText($claudeHookPath)
        } else {
            ''
        }
        $hookState = if ($registration -eq 'UNKNOWN') {
            'BOOT_HOOK_REGISTRATION_UNKNOWN'
        } elseif ($registration -eq 'DISABLED') {
            'BOOT_HOOKS_DISABLED'
        } elseif ($registration -eq 'MANAGED_ONLY_MISPLACED') {
            'BOOT_HOOK_MANAGED_ONLY_MISPLACED'
        } elseif ($registration -eq 'MULTIPLE') {
            'BOOT_HOOK_REGISTRATION_MULTIPLE'
        } elseif ($registration -eq 'STALE_OTHER') {
            'STALE_BOOT_HOOK_OTHER_PATH'
        } elseif (-not (Test-Path -LiteralPath $claudeHookPath -PathType Leaf)) {
            'BOOT_HOOK_MISSING'
        } elseif ($registration -ne 'REGISTERED') {
            'BOOT_HOOK_UNREGISTERED'
        } elseif ((Get-ShaText $hookText) -eq $claudeSessionStartAdapterHash) {
            'BOOT_HOOK_ALIGNED'
        } elseif ($hookText.Contains('DREAMEROS-CLAUDE-SESSION-START-ADAPTER')) {
            'BOOT_HOOK_DRIFT'
        } else {
            'STALE_BOOT_HOOK'
        }
        $relativeHook = $claudeHookPath.Substring($repo.Length).TrimStart([char[]]@('\', '/'))
        $hookStatus = @()
        if (Test-Path -LiteralPath $claudeHookPath -PathType Leaf) {
            $hookStatus += @(& git -c "safe.directory=$repo" -C $repo status --porcelain=v1 -- $relativeHook)
            if ($LASTEXITCODE -ne 0) { throw "Git status failed for $claudeHookPath" }
        }
        foreach ($claudeSettingsPath in $claudeSettingsPaths) {
            if (-not (Test-Path -LiteralPath $claudeSettingsPath -PathType Leaf)) { continue }
            $relativeSettings = $claudeSettingsPath.Substring($repo.Length).TrimStart([char[]]@('\', '/'))
            $hookStatus += @(& git -c "safe.directory=$repo" -C $repo status --porcelain=v1 -- $relativeSettings)
            if ($LASTEXITCODE -ne 0) { throw "Git status failed for $claudeSettingsPath" }
        }
        $claudeHookRecords += [pscustomobject]@{
            Repo = $repo
            State = $hookState
            Registration = $registration
            Dirty = $hookStatus.Count -gt 0
            Status = ($hookStatus -join ' ')
            Path = $claudeHookPath
        }
    }

    $projectMcpPath = Join-Path $repo '.cursor\mcp.json'
    Assert-NoReparseTraversal $projectMcpPath $repo
    if (Test-Path -LiteralPath $projectMcpPath -PathType Leaf) {
        $relativeMcp = $projectMcpPath.Substring($repo.Length).TrimStart([char[]]@('\', '/'))
        $mcpStatus = @(& git -c "safe.directory=$repo" -C $repo status --porcelain=v1 -- $relativeMcp)
        if ($LASTEXITCODE -ne 0) { throw "Git status failed for $projectMcpPath" }
        try {
            $projectMcp = [IO.File]::ReadAllText($projectMcpPath) | ConvertFrom-Json
            $servers = $projectMcp.mcpServers
            if ($null -eq $servers) { throw 'mcpServers object missing' }
            foreach ($server in $servers.PSObject.Properties) {
                $url = ([string]$server.Value.url).Trim().TrimEnd('/')
                $headers = $server.Value.headers
                $hasAuthorization = $null -ne $headers -and $null -ne $headers.Authorization
                $isPluginName = $server.Name -ceq 'dreameros-platform'
                $isDreamerOsUrl = $url -ceq 'https://mcp.dreameros.app/mcp'
                if (-not $isPluginName -and -not $isDreamerOsUrl) { continue }
                $state = if ($hasAuthorization) {
                    'PROJECT_MCP_AUTH_HEADER'
                } elseif ($isPluginName -and -not $isDreamerOsUrl) {
                    'PROJECT_MCP_ENDPOINT_SHADOW'
                } elseif ($isPluginName) {
                    'PROJECT_MCP_SHADOW'
                } else {
                    'LEGACY_PROJECT_MCP'
                }
                $mcpRecords += [pscustomobject]@{
                    Repo = $repo
                    State = $state
                    Server = $server.Name
                    Dirty = $mcpStatus.Count -gt 0
                    Status = ($mcpStatus -join ' ')
                    Path = $projectMcpPath
                }
            }
        } catch {
            $mcpRecords += [pscustomobject]@{
                Repo = $repo
                State = 'PROJECT_MCP_CONFIG_UNKNOWN'
                Server = 'unknown'
                Dirty = $mcpStatus.Count -gt 0
                Status = ($mcpStatus -join ' ')
                Path = $projectMcpPath
            }
        }
    }

    $projectCursorHooksPath = Join-Path $repo '.cursor\hooks.json'
    Assert-NoReparseTraversal $projectCursorHooksPath $repo
    if (Test-Path -LiteralPath $projectCursorHooksPath -PathType Leaf) {
        $relativeCursorHooks = $projectCursorHooksPath.Substring($repo.Length).TrimStart([char[]]@('\', '/'))
        $cursorHookStatus = @(& git -c "safe.directory=$repo" -C $repo status --porcelain=v1 -- $relativeCursorHooks)
        if ($LASTEXITCODE -ne 0) { throw "Git status failed for $projectCursorHooksPath" }
        try {
            $criticalCount = Get-CursorCriticalHookCount $projectCursorHooksPath
            if ($criticalCount -gt 0) {
                $cursorHookRecords += [pscustomobject]@{
                    State = 'CURSOR_PROJECT_HOOK_SHADOW'
                    Scope = 'PROJECT'
                    CriticalCount = $criticalCount
                    Dirty = $cursorHookStatus.Count -gt 0
                    Status = ($cursorHookStatus -join ' ')
                    Path = $projectCursorHooksPath
                }
            }
        } catch {
            $cursorHookRecords += [pscustomobject]@{
                State = 'CURSOR_PROJECT_HOOK_CONFIG_UNKNOWN'
                Scope = 'PROJECT'
                CriticalCount = -1
                Dirty = $cursorHookStatus.Count -gt 0
                Status = ($cursorHookStatus -join ' ')
                Path = $projectCursorHooksPath
            }
        }
    }

    $generatorPath = Join-Path $repo 'governance\bootpack\build-boot-pack.ps1'
    Assert-NoReparseTraversal $generatorPath $repo
    if (Test-Path -LiteralPath $generatorPath -PathType Leaf) {
        $generatorText = [IO.File]::ReadAllText($generatorPath)
        $generatorState = if ($generatorText -match 'cursor[\\/]dreameros-boot-canon\.mdc') {
            'LEGACY_FULL_GENERATOR'
        } elseif ((Get-ShaText $generatorText) -eq $generatorPointerHash) {
            'SUPERSEDED_GENERATOR'
        } else {
            'UNKNOWN_GENERATOR'
        }
        $relative = $generatorPath.Substring($repo.Length).TrimStart([char[]]@('\', '/'))
        $status = @(& git -c "safe.directory=$repo" -C $repo status --porcelain=v1 -- $relative)
        if ($LASTEXITCODE -ne 0) { throw "Git status failed for $generatorPath" }
        $generatorRecords += [pscustomobject]@{
            Repo = $repo
            State = $generatorState
            Dirty = $status.Count -gt 0
            Status = ($status -join ' ')
            Path = $generatorPath
        }
    }
}

$globalClaudeHookPath = Join-Path $UserHome '.claude\hooks\dreameros-session-start.sh'
$globalClaudeSettingsPaths = @(
    (Join-Path $UserHome '.claude\settings.json'),
    (Join-Path $UserHome '.claude\settings.local.json')
)
Assert-NoReparseTraversal $globalClaudeHookPath $UserHome
foreach ($globalClaudeSettingsPath in $globalClaudeSettingsPaths) {
    Assert-NoReparseTraversal $globalClaudeSettingsPath $UserHome
}
$globalCommands = @()
$globalSettingsUnknown = $false
$globalHooksDisabled = $false
$globalManagedOnly = $false
foreach ($settingsPath in $globalClaudeSettingsPaths) {
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { continue }
    try { $settings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json }
    catch { $globalSettingsUnknown = $true; continue }
    if ($settings.disableAllHooks -eq $true) { $globalHooksDisabled = $true }
    if ($settings.allowManagedHooksOnly -eq $true) { $globalManagedOnly = $true }
    foreach ($entry in @($settings.hooks.SessionStart)) {
        foreach ($hook in @($entry.hooks)) {
            if ($null -ne $hook -and $hook.type -eq 'command' -and $hook.command -is [string]) {
                $globalCommands += [string]$hook.command
            }
        }
    }
}
$exactGlobalHookCount = 0
$otherHydrationHooks = @()
foreach ($command in $globalCommands) {
    $scriptPath = Get-ShellScriptPath -Command $command -HomePath $UserHome
    if ($scriptPath -and [string]::Equals($scriptPath, $globalClaudeHookPath, [StringComparison]::OrdinalIgnoreCase)) {
        $exactGlobalHookCount++
        continue
    }
    $isHydration = $false
    if ($scriptPath) { Assert-NoReparseTraversal $scriptPath $UserHome }
    if ($scriptPath -and (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        $scriptText = [IO.File]::ReadAllText($scriptPath)
        $scriptName = [IO.Path]::GetFileName($scriptPath)
        $isHydration = $scriptName -match '(?i)dreameros|dreamer[_-]?os|hydration' -or (
            $scriptText -match '(?i)hookSpecificOutput' -and
            $scriptText -match '(?i)dreameros_(?:session_package|context|state|recall|canon)|DreamerOS session/context/state'
        )
    } elseif ($command -match '(?i)^\s*(?:bash|sh|python)\b.*(?:dreameros|dreamer[_-]?os|hydration).*\.(?:sh|py)') {
        $isHydration = $true
    }
    if ($isHydration) { $otherHydrationHooks += $command }
}
$globalHookState = if ($globalSettingsUnknown) {
    'USER_CLAUDE_BOOT_SETTINGS_UNKNOWN'
} elseif ($globalHooksDisabled) {
    'USER_CLAUDE_BOOT_HOOKS_DISABLED'
} elseif ($globalManagedOnly) {
    'USER_CLAUDE_BOOT_MANAGED_ONLY_MISPLACED'
} elseif ($exactGlobalHookCount -ne 1 -or $otherHydrationHooks.Count -gt 0) {
    'USER_CLAUDE_BOOT_REGISTRATION_DRIFT'
} elseif (-not (Test-Path -LiteralPath $globalClaudeHookPath -PathType Leaf)) {
    'USER_CLAUDE_BOOT_HOOK_MISSING'
} elseif ((Get-ShaText ([IO.File]::ReadAllText($globalClaudeHookPath))) -ne $claudeSessionStartAdapterHash) {
    'USER_CLAUDE_BOOT_HOOK_DRIFT'
} else {
    'USER_CLAUDE_BOOT_ALIGNED'
}
$userScopeRecords += [pscustomobject]@{
    State = $globalHookState
    ExactRegistrations = $exactGlobalHookCount
    OtherHydrationHooks = $otherHydrationHooks.Count
    Path = $globalClaudeHookPath
}

$userMcpPath = Join-Path $UserHome '.cursor\mcp.json'
Assert-NoReparseTraversal $userMcpPath $UserHome
if (Test-Path -LiteralPath $userMcpPath -PathType Leaf) {
    try {
        $userMcp = [IO.File]::ReadAllText($userMcpPath) | ConvertFrom-Json
        if ($null -eq $userMcp.mcpServers) { throw 'mcpServers object missing' }
        foreach ($server in $userMcp.mcpServers.PSObject.Properties) {
            $url = ([string]$server.Value.url).Trim().TrimEnd('/')
            $headers = $server.Value.headers
            $hasAuthorization = $null -ne $headers -and $null -ne $headers.Authorization
            $isPluginName = $server.Name -ceq 'dreameros-platform'
            $isDreamerOsUrl = $url -ceq 'https://mcp.dreameros.app/mcp'
            if (-not $isPluginName -and -not $isDreamerOsUrl) { continue }
            $state = if ($hasAuthorization) {
                'USER_MCP_AUTH_HEADER'
            } elseif ($isPluginName -and -not $isDreamerOsUrl) {
                'USER_MCP_ENDPOINT_SHADOW'
            } elseif ($isPluginName) {
                'USER_MCP_SHADOW'
            } else {
                'USER_MCP_LEGACY'
            }
            $userMcpRecords += [pscustomobject]@{ State = $state; Server = $server.Name; Path = $userMcpPath }
        }
    } catch {
        $userMcpRecords += [pscustomobject]@{ State = 'USER_MCP_CONFIG_UNKNOWN'; Server = 'unknown'; Path = $userMcpPath }
    }
}

$userCursorHooksPath = Join-Path $UserHome '.cursor\hooks.json'
Assert-NoReparseTraversal $userCursorHooksPath $UserHome
if (Test-Path -LiteralPath $userCursorHooksPath -PathType Leaf) {
    try {
        $criticalCount = Get-CursorCriticalHookCount $userCursorHooksPath
        if ($criticalCount -gt 0) {
            $cursorHookRecords += [pscustomobject]@{ State = 'CURSOR_USER_HOOK_SHADOW'; Scope = 'USER'; CriticalCount = $criticalCount; Dirty = $false; Status = ''; Path = $userCursorHooksPath }
        }
    } catch {
        $cursorHookRecords += [pscustomobject]@{ State = 'CURSOR_USER_HOOK_CONFIG_UNKNOWN'; Scope = 'USER'; CriticalCount = -1; Dirty = $false; Status = ''; Path = $userCursorHooksPath }
    }
}
if (-not [string]::IsNullOrWhiteSpace($EnterpriseCursorHooksPath) -and (Test-Path -LiteralPath $EnterpriseCursorHooksPath -PathType Leaf)) {
    Assert-NoReparseTraversal $EnterpriseCursorHooksPath (Split-Path -Parent $EnterpriseCursorHooksPath)
    try {
        $criticalCount = Get-CursorCriticalHookCount $EnterpriseCursorHooksPath
        if ($criticalCount -gt 0) {
            $cursorHookRecords += [pscustomobject]@{ State = 'CURSOR_ENTERPRISE_HOOK_SHADOW'; Scope = 'ENTERPRISE'; CriticalCount = $criticalCount; Dirty = $false; Status = ''; Path = $EnterpriseCursorHooksPath }
        }
    } catch {
        $cursorHookRecords += [pscustomobject]@{ State = 'CURSOR_ENTERPRISE_HOOK_CONFIG_UNKNOWN'; Scope = 'ENTERPRISE'; CriticalCount = -1; Dirty = $false; Status = ''; Path = $EnterpriseCursorHooksPath }
    }
}

foreach ($record in ($records | Sort-Object Repo, Surface)) {
    $ownership = if ($record.Dirty) { "DIRTY $($record.Status)" } else { 'FILE-CLEAN' }
    Write-Output ("{0} {1} {2} {3}" -f $record.State, $ownership, $record.Surface, $record.Path)
}
foreach ($record in ($generatorRecords | Sort-Object Repo)) {
    $ownership = if ($record.Dirty) { "DIRTY $($record.Status)" } else { 'FILE-CLEAN' }
    Write-Output ("{0} {1} GENERATOR {2}" -f $record.State, $ownership, $record.Path)
}
foreach ($record in ($excerptRecords | Sort-Object Repo, Surface)) {
    Write-Output ("DUPLICATE_EMBEDDED_EXCERPT {0} {1}" -f $record.Surface, $record.Path)
}
foreach ($record in ($adapterRecords | Sort-Object Repo, Path)) {
    $ownership = if ($record.Dirty) { "DIRTY $($record.Status)" } else { 'FILE-CLEAN' }
    Write-Output ("{0} {1} ADAPTER {2}" -f $record.State, $ownership, $record.Path)
}
foreach ($record in ($ruleExcerptRecords | Sort-Object Repo, Path)) {
    $ownership = if ($record.Dirty) { "DIRTY $($record.Status)" } else { 'FILE-CLEAN' }
    Write-Output ("DUPLICATE_RULE_EXCERPT {0} {1}" -f $ownership, $record.Path)
}
foreach ($record in ($claudeHookRecords | Sort-Object Repo, Path)) {
    $ownership = if ($record.Dirty) { "DIRTY $($record.Status)" } else { 'FILE-CLEAN' }
    Write-Output ("{0} {1} CLAUDE_BOOT_HOOK registration={2} {3}" -f $record.State, $ownership, $record.Registration, $record.Path)
}
foreach ($record in ($mcpRecords | Sort-Object Repo, Path, Server)) {
    $ownership = if ($record.Dirty) { "DIRTY $($record.Status)" } else { 'FILE-CLEAN' }
    Write-Output ("{0} {1} CURSOR_PROJECT_MCP server={2} {3}" -f $record.State, $ownership, $record.Server, $record.Path)
}
foreach ($record in $userScopeRecords) {
    Write-Output ("{0} USER_CLAUDE_BOOT exact={1} other_hydration={2} {3}" -f $record.State, $record.ExactRegistrations, $record.OtherHydrationHooks, $record.Path)
}
Write-Output 'USER_CLAUDE_MANAGED_HOOK_POLICY=UNVERIFIED_LIVE verify with Claude Code /hooks after authentication; managed policy can come from server, registry, or system files.'
foreach ($record in ($userMcpRecords | Sort-Object Path, Server)) {
    Write-Output ("{0} CURSOR_USER_MCP server={1} {2}" -f $record.State, $record.Server, $record.Path)
}
foreach ($record in ($cursorHookRecords | Sort-Object Scope, Path)) {
    $ownership = if ($record.Dirty) { "DIRTY $($record.Status)" } else { 'FILE-CLEAN' }
    Write-Output ("{0} {1} CURSOR_HOOK_SCOPE={2} critical_events={3} {4}" -f $record.State, $ownership, $record.Scope, $record.CriticalCount, $record.Path)
}
foreach ($record in ($reparseChildRecords | Sort-Object PathDigest)) {
    Write-Output ("REPARSE_CHILD_SKIPPED path_digest={0}" -f $record.PathDigest)
}
Write-Output 'CURSOR_TEAM_HOOK_POLICY=UNVERIFIED_LIVE verify the effective Hooks list in Cursor Customize; team hooks can be cloud-distributed.'

$blocking = @($records | Where-Object {
    $_.State -in @('LEGACY_FULL_COPY', 'POINTER_DRIFT', 'UNKNOWN') -or
    ($_.State -eq 'POINTER_ALIGNED' -and $_.Dirty)
})
$generatorBlocking = @($generatorRecords | Where-Object {
    $_.State -ne 'SUPERSEDED_GENERATOR' -or $_.Dirty
})
$adapterBlocking = @($adapterRecords | Where-Object { $_.State -ne 'ADAPTER_ALIGNED' -or $_.Dirty })
$claudeHookBlocking = @($claudeHookRecords | Where-Object { $_.State -ne 'BOOT_HOOK_ALIGNED' -or $_.Dirty })
$mcpBlocking = @($mcpRecords)
$userScopeBlocking = @($userScopeRecords | Where-Object { $_.State -ne 'USER_CLAUDE_BOOT_ALIGNED' })
$userMcpBlocking = @($userMcpRecords)
$cursorHookBlocking = @($cursorHookRecords)
$counts = @{}
foreach ($state in @('GLOBAL_ONLY', 'POINTER_ALIGNED', 'LEGACY_FULL_COPY', 'POINTER_DRIFT', 'UNKNOWN')) {
    $counts[$state] = @($records | Where-Object { $_.State -eq $state }).Count
}
$legacyGeneratorCount = @($generatorRecords | Where-Object { $_.State -eq 'LEGACY_FULL_GENERATOR' }).Count
$unknownGeneratorCount = @($generatorRecords | Where-Object { $_.State -eq 'UNKNOWN_GENERATOR' }).Count
$adapterAlignedCount = @($adapterRecords | Where-Object { $_.State -eq 'ADAPTER_ALIGNED' }).Count
$adapterDriftCount = @($adapterRecords | Where-Object { $_.State -eq 'ADAPTER_DRIFT' }).Count
$staleAdapterCount = @($adapterRecords | Where-Object { $_.State -eq 'STALE_ADAPTER_COPY' }).Count
$adapterPathDriftCount = @($adapterRecords | Where-Object { $_.State -eq 'ADAPTER_PATH_DRIFT' }).Count
$alignedHookCount = @($claudeHookRecords | Where-Object { $_.State -eq 'BOOT_HOOK_ALIGNED' }).Count
$staleHookCount = @($claudeHookRecords | Where-Object { $_.State -eq 'STALE_BOOT_HOOK' }).Count
$hookOtherCount = @($claudeHookRecords | Where-Object { $_.State -notin @('BOOT_HOOK_ALIGNED', 'STALE_BOOT_HOOK') }).Count
$projectMcpAuthCount = @($mcpRecords | Where-Object { $_.State -eq 'PROJECT_MCP_AUTH_HEADER' }).Count
$projectMcpShadowCount = @($mcpRecords | Where-Object { $_.State -eq 'PROJECT_MCP_SHADOW' }).Count
$projectMcpEndpointShadowCount = @($mcpRecords | Where-Object { $_.State -eq 'PROJECT_MCP_ENDPOINT_SHADOW' }).Count
$legacyProjectMcpCount = @($mcpRecords | Where-Object { $_.State -eq 'LEGACY_PROJECT_MCP' }).Count
$projectMcpUnknownCount = @($mcpRecords | Where-Object { $_.State -eq 'PROJECT_MCP_CONFIG_UNKNOWN' }).Count
$summary = "repos=$($repos.Count) surfaces=$($records.Count) GLOBAL_ONLY=$($counts.GLOBAL_ONLY) POINTER_ALIGNED=$($counts.POINTER_ALIGNED) LEGACY_FULL_COPY=$($counts.LEGACY_FULL_COPY) POINTER_DRIFT=$($counts.POINTER_DRIFT) UNKNOWN=$($counts.UNKNOWN) generators=$($generatorRecords.Count) LEGACY_FULL_GENERATOR=$legacyGeneratorCount UNKNOWN_GENERATOR=$unknownGeneratorCount ADAPTER_ALIGNED=$adapterAlignedCount ADAPTER_DRIFT=$adapterDriftCount STALE_ADAPTER_COPY=$staleAdapterCount ADAPTER_PATH_DRIFT=$adapterPathDriftCount CLAUDE_BOOT_HOOKS=$($claudeHookRecords.Count) BOOT_HOOK_ALIGNED=$alignedHookCount STALE_BOOT_HOOK=$staleHookCount BOOT_HOOK_OTHER=$hookOtherCount PROJECT_MCP_RECORDS=$($mcpRecords.Count) PROJECT_MCP_AUTH_HEADER=$projectMcpAuthCount PROJECT_MCP_SHADOW=$projectMcpShadowCount PROJECT_MCP_ENDPOINT_SHADOW=$projectMcpEndpointShadowCount LEGACY_PROJECT_MCP=$legacyProjectMcpCount PROJECT_MCP_UNKNOWN=$projectMcpUnknownCount CURSOR_HOOK_SHADOWS=$($cursorHookRecords.Count) REPARSE_CHILD_SKIPPED=$($reparseChildRecords.Count) CURSOR_TEAM_HOOK_POLICY=UNVERIFIED_LIVE USER_CLAUDE_BOOT=$($userScopeRecords[0].State) USER_CLAUDE_MANAGED_HOOK_POLICY=UNVERIFIED_LIVE USER_MCP_RECORDS=$($userMcpRecords.Count) DUPLICATE_EMBEDDED_EXCERPT=$($excerptRecords.Count) DUPLICATE_RULE_EXCERPT=$($ruleExcerptRecords.Count)"
if ($blocking.Count -gt 0 -or $generatorBlocking.Count -gt 0 -or $adapterBlocking.Count -gt 0 -or $claudeHookBlocking.Count -gt 0 -or $mcpBlocking.Count -gt 0 -or $userScopeBlocking.Count -gt 0 -or $userMcpBlocking.Count -gt 0 -or $cursorHookBlocking.Count -gt 0 -or $reparseChildRecords.Count -gt 0 -or $excerptRecords.Count -gt 0 -or $ruleExcerptRecords.Count -gt 0) {
    Write-Output 'DREAMEROS_AUDIT_OUTCOME=FINDINGS'
    Write-Output $summary
    throw "$($blocking.Count) project boot surface(s), $($generatorBlocking.Count) generator(s), $($adapterBlocking.Count) adapter(s), $($claudeHookBlocking.Count) project Claude boot hook(s), $($mcpBlocking.Count) project MCP entry/entries, $($userScopeBlocking.Count) user Claude boot surface(s), $($userMcpBlocking.Count) user MCP entry/entries, $($cursorHookBlocking.Count) Cursor hook shadow(s), $($reparseChildRecords.Count) reparse child location(s), $($excerptRecords.Count) embedded excerpt(s), and $($ruleExcerptRecords.Count) rule excerpt(s) require reviewed migration. $summary"
}
Write-Output 'DREAMEROS_AUDIT_OUTCOME=PASS'
Write-Output $summary
Write-Output "VERIFIED CROSS-VENDOR PROJECT BOOT POINTERS $summary"
} finally {
    if ($null -eq $priorOptionalLocks) { Remove-Item Env:GIT_OPTIONAL_LOCKS -ErrorAction SilentlyContinue }
    else { $env:GIT_OPTIONAL_LOCKS = $priorOptionalLocks }
}
