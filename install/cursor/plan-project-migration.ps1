# Read-only planner. Converts the cross-vendor audit into one reconciled plan
# per physical Git checkout. It never fetches or writes project files. The
# audit inspects MCP header structure; neither layer prints, copies, or persists
# header values. JSON is the default so another engine can verify every row.
[CmdletBinding()]
param(
    [string[]]$EstateRoots,
    [string]$UserHome,
    [string]$AuditInputPath,
    [string]$EnterpriseCursorHooksPath,
    [ValidateSet('Json', 'Markdown')]
    [string]$Format = 'Json'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$AuditScript = Join-Path $PSScriptRoot 'audit-project-boot-surfaces.ps1'
$EmbeddedPointer = Join-Path $RepoRoot 'bootpack\out\project\DREAMEROS_BOOT_CANON_POINTER.md.block'
$CursorPointer = Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-project-pointer.mdc'
$GeneratorPointer = Join-Path $RepoRoot 'bootpack\out\project\DREAMEROS_CENTRAL_BOOT_GENERATOR_POINTER.ps1.block'
$ClaudeHookPointer = Join-Path $RepoRoot 'bootpack\out\claude\dreameros-session-start.sh'
$AdapterSources = @{
    'answer-from-measurement.mdc' = Join-Path $RepoRoot 'bootpack\out\cursor\answer-from-measurement.adapter.mdc'
    'canon-equals-live.mdc' = Join-Path $RepoRoot 'bootpack\out\cursor\canon-equals-live.adapter.mdc'
    'dreameros-cold-start.mdc' = Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-cold-start.adapter.mdc'
    'dreameros-first.mdc' = Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-first.adapter.mdc'
}

if ([string]::IsNullOrWhiteSpace($UserHome)) { $UserHome = $env:USERPROFILE }
$UserHome = [IO.Path]::GetFullPath($UserHome).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($EnterpriseCursorHooksPath)) {
    $EnterpriseCursorHooksPath = if ($env:ProgramData) { Join-Path $env:ProgramData 'Cursor\hooks.json' } else { '' }
}
if (-not [string]::IsNullOrWhiteSpace($EnterpriseCursorHooksPath)) {
    $EnterpriseCursorHooksPath = [IO.Path]::GetFullPath($EnterpriseCursorHooksPath)
}
if (-not $EstateRoots -or $EstateRoots.Count -eq 0) {
    $EstateRoots = @(
        (Join-Path $UserHome 'Documents\DreamerOS'),
        (Join-Path $UserHome 'Documents\Codex'),
        $UserHome
    )
}
$RequestedEstateRoots = @($EstateRoots | ForEach-Object {
    [IO.Path]::GetFullPath($_).TrimEnd('\')
} | Sort-Object -Unique)
$MissingEstateRoots = @($RequestedEstateRoots | Where-Object {
    -not (Test-Path -LiteralPath $_ -PathType Container)
})
if ($MissingEstateRoots.Count -gt 0) {
    throw "Every requested estate root must exist; missing_count=$($MissingEstateRoots.Count)."
}
$ResolvedEstateRoots = @($RequestedEstateRoots | ForEach-Object {
    [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $_).Path).TrimEnd('\')
} | Sort-Object -Unique)
$enterpriseRoot = if ($EnterpriseCursorHooksPath) { Split-Path -Parent $EnterpriseCursorHooksPath } else { $null }
$AllowedRoots = @($ResolvedEstateRoots + $UserHome + $enterpriseRoot | Where-Object { $_ } | Sort-Object -Unique)

function Get-RawSha([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Generated source is missing: $Path" }
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Get-StringSha([string]$Text) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function ConvertTo-CanonicalMetadataJson([hashtable]$Metadata) {
    $orderedMetadata = [ordered]@{}
    $keys = [string[]]@($Metadata.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    foreach ($key in $keys) { $orderedMetadata[$key] = $Metadata[$key] }
    return ($orderedMetadata | ConvertTo-Json -Compress -Depth 4)
}

function Get-OwningAllowedRoot([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($root in ($AllowedRoots | Sort-Object Length -Descending)) {
        if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith(($root + '\'), [StringComparison]::OrdinalIgnoreCase)) {
            return $root
        }
    }
    throw "Audit target escaped every requested estate root: $full"
}

function Get-OwningEstateRoot([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($root in ($ResolvedEstateRoots | Sort-Object Length -Descending)) {
        if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith(($root + '\'), [StringComparison]::OrdinalIgnoreCase)) {
            return $root
        }
    }
    return $null
}

function Assert-NoReparseTraversal([string]$Path, [string]$AllowedRoot) {
    $full = [IO.Path]::GetFullPath($Path)
    $currentPath = if (Test-Path -LiteralPath $full) { $full } else { Split-Path -Parent $full }
    while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
        if (Test-Path -LiteralPath $currentPath) {
            $item = Get-Item -LiteralPath $currentPath -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Audit target crosses a reparse point: $($item.FullName)"
            }
        }
        if ([IO.Path]::GetFullPath($currentPath).TrimEnd('\').Equals(
            $AllowedRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { return }
        $parent = Split-Path -Parent $currentPath
        if ($parent -eq $currentPath) { break }
        $currentPath = $parent
    }
    throw "Audit target could not be proven inside its allowed root: $full"
}

function Test-PathWithin([string]$Path, [string]$Parent) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return $full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith(($root + '\'), [StringComparison]::OrdinalIgnoreCase)
}

function Find-GitRoot([string]$Path) {
    $currentPath = if (Test-Path -LiteralPath $Path -PathType Container) { $Path } else { Split-Path -Parent $Path }
    while (-not [string]::IsNullOrWhiteSpace($currentPath) -and -not (Test-Path -LiteralPath $currentPath)) {
        $parent = Split-Path -Parent $currentPath
        if ($parent -eq $currentPath) { return $null }
        $currentPath = $parent
    }
    if ([string]::IsNullOrWhiteSpace($currentPath)) { return $null }
    $current = Get-Item -LiteralPath $currentPath -Force
    while ($current) {
        if (Test-Path -LiteralPath (Join-Path $current.FullName '.git')) { return $current.FullName }
        $current = $current.Parent
    }
    return $null
}

function Invoke-Git([string]$Root, [string[]]$Arguments) {
    $priorPreference = $ErrorActionPreference
    $priorOptionalLocks = $env:GIT_OPTIONAL_LOCKS
    try {
        $ErrorActionPreference = 'Continue'
        $env:GIT_OPTIONAL_LOCKS = '0'
        $output = @(& git -c "safe.directory=$Root" -C $Root @Arguments 2>$null)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $priorPreference
        if ($null -eq $priorOptionalLocks) { Remove-Item Env:GIT_OPTIONAL_LOCKS -ErrorAction SilentlyContinue }
        else { $env:GIT_OPTIONAL_LOCKS = $priorOptionalLocks }
    }
    return [pscustomobject]@{ ExitCode = $code; Text = (($output -join "`n").Trim()) }
}

function Get-GitInfo([string]$Root) {
    $branchResult = Invoke-Git $Root @('branch', '--show-current')
    $headResult = Invoke-Git $Root @('rev-parse', 'HEAD')
    if ($branchResult.ExitCode -ne 0 -or $headResult.ExitCode -ne 0) {
        return [ordered]@{ state = 'UNREADABLE'; fresh_fetch_required = $true }
    }

    $remoteResult = Invoke-Git $Root @('rev-parse', '--verify', 'origin/main')
    $ahead = $null
    $behind = $null
    $trackingReadFailed = $false
    if ($remoteResult.ExitCode -eq 0) {
        $counts = Invoke-Git $Root @('rev-list', '--left-right', '--count', 'HEAD...origin/main')
        if ($counts.ExitCode -eq 0 -and $counts.Text -match '^(?<ahead>\d+)\s+(?<behind>\d+)$') {
            $ahead = [int]$Matches.ahead
            $behind = [int]$Matches.behind
        } else {
            $trackingReadFailed = $true
        }
    }

    $staged = Invoke-Git $Root @('diff', '--cached', '--name-only')
    $unstaged = Invoke-Git $Root @('diff', '--name-only')
    $untracked = Invoke-Git $Root @('ls-files', '--others', '--exclude-standard')
    $fetchPathResult = Invoke-Git $Root @('rev-parse', '--git-path', 'FETCH_HEAD')
    if ($trackingReadFailed -or $staged.ExitCode -ne 0 -or $unstaged.ExitCode -ne 0 -or
        $untracked.ExitCode -ne 0 -or $fetchPathResult.ExitCode -ne 0) {
        return [ordered]@{
            state = 'UNREADABLE'
            branch = $branchResult.Text
            head = $headResult.Text
            origin_main_tracking_ref = if ($remoteResult.ExitCode -eq 0) { $remoteResult.Text } else { $null }
            fresh_fetch_required = $true
            failure = 'One or more Git status or metadata reads failed.'
        }
    }
    $fetchHeadUtc = $null
    if ($fetchPathResult.ExitCode -eq 0) {
        $fetchHead = $fetchPathResult.Text
        if (-not [IO.Path]::IsPathRooted($fetchHead)) { $fetchHead = Join-Path $Root $fetchHead }
        $fetchHead = [IO.Path]::GetFullPath($fetchHead)
        if (Test-Path -LiteralPath $fetchHead -PathType Leaf) {
            $fetchHeadUtc = (Get-Item -LiteralPath $fetchHead).LastWriteTimeUtc.ToString('o')
        }
    }

    $stagedCount = if ([string]::IsNullOrWhiteSpace($staged.Text)) { 0 } else { @($staged.Text -split "`n").Count }
    $unstagedCount = if ([string]::IsNullOrWhiteSpace($unstaged.Text)) { 0 } else { @($unstaged.Text -split "`n").Count }
    $untrackedCount = if ([string]::IsNullOrWhiteSpace($untracked.Text)) { 0 } else { @($untracked.Text -split "`n").Count }
    return [ordered]@{
        state = 'READ'
        branch = $branchResult.Text
        head = $headResult.Text
        origin_main_tracking_ref = if ($remoteResult.ExitCode -eq 0) { $remoteResult.Text } else { $null }
        ahead_of_tracking_ref = $ahead
        behind_tracking_ref = $behind
        staged = $stagedCount
        unstaged = $unstagedCount
        untracked = $untrackedCount
        clean = ($stagedCount + $unstagedCount + $untrackedCount) -eq 0
        fetch_head_utc = $fetchHeadUtc
        fresh_fetch_required = $true
        current_main_against_tracking_ref = (
            $branchResult.Text -eq 'main' -and
            $remoteResult.ExitCode -eq 0 -and
            $headResult.Text -eq $remoteResult.Text
        )
    }
}

function Get-RegistryState([string]$Root) {
    $seen = $false
    foreach ($relative in @('Governance\CANON_REGISTRY.json', 'governance\CANON_REGISTRY.json')) {
        $path = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $seen = $true
        try { $raw = [IO.File]::ReadAllText($path); $null = $raw | ConvertFrom-Json }
        catch { return 'INVALID_JSON' }
        $normalized = $raw.Replace('\', '/').ToLowerInvariant()
        if ($normalized -match '\.cursor/+rules/+dreameros-boot-canon\.mdc') { return 'TRACKS_RULE' }
    }
    if ($seen) { return 'NO_REFERENCE' }
    return 'ABSENT'
}

function New-Finding(
    [string]$Kind,
    [string]$State,
    [string]$Surface,
    [string]$Path,
    [string]$Ownership,
    [hashtable]$Metadata = @{}
) {
    $allowedRoot = Get-OwningAllowedRoot $Path
    Assert-NoReparseTraversal $Path $allowedRoot
    return [pscustomobject]@{
        kind = $Kind
        state = $State
        surface = $Surface
        path = [IO.Path]::GetFullPath($Path)
        ownership = if ($Ownership.StartsWith('DIRTY', [StringComparison]::OrdinalIgnoreCase)) { 'DIRTY' } else { 'FILE-CLEAN' }
        dirty = $Ownership.StartsWith('DIRTY', [StringComparison]::OrdinalIgnoreCase)
        allowed_root = $allowedRoot
        metadata = $Metadata
    }
}

function Assert-AuditMetadataContract([bool]$Condition, [string]$Kind, [string]$Line) {
    if (-not $Condition) {
        throw "Audit state/metadata contradiction; kind=$Kind digest=$(Get-StringSha $Line)."
    }
}

function Parse-AuditLine([string]$Line) {
    if ($Line -match '^(?<state>GLOBAL_ONLY|POINTER_ALIGNED|LEGACY_FULL_COPY|POINTER_DRIFT|UNKNOWN) (?<ownership>FILE-CLEAN|DIRTY .*?) (?<surface>CLAUDE|CODEX|CURSOR) (?<path>[A-Za-z]:\\.*)$') {
        return New-Finding 'BOOT_SURFACE' $Matches.state $Matches.surface $Matches.path $Matches.ownership
    }
    if ($Line -match '^(?<state>SUPERSEDED_GENERATOR|LEGACY_FULL_GENERATOR|UNKNOWN_GENERATOR) (?<ownership>FILE-CLEAN|DIRTY .*?) GENERATOR (?<path>[A-Za-z]:\\.*)$') {
        return New-Finding 'GENERATOR' $Matches.state 'GENERATOR' $Matches.path $Matches.ownership
    }
    if ($Line -match '^(?<state>ADAPTER_ALIGNED|ADAPTER_DRIFT|STALE_ADAPTER_COPY|ADAPTER_PATH_DRIFT) (?<ownership>FILE-CLEAN|DIRTY .*?) ADAPTER (?<path>[A-Za-z]:\\.*)$') {
        return New-Finding 'ADAPTER' $Matches.state 'CURSOR' $Matches.path $Matches.ownership
    }
    if ($Line -match '^DUPLICATE_EMBEDDED_EXCERPT (?<surface>CLAUDE|CODEX) (?<path>[A-Za-z]:\\.*)$') {
        return New-Finding 'DUPLICATE_EMBEDDED_EXCERPT' 'DUPLICATE_EMBEDDED_EXCERPT' $Matches.surface $Matches.path 'FILE-CLEAN'
    }
    if ($Line -match '^DUPLICATE_RULE_EXCERPT (?<ownership>FILE-CLEAN|DIRTY .*?) (?<path>[A-Za-z]:\\.*)$') {
        return New-Finding 'DUPLICATE_RULE_EXCERPT' 'DUPLICATE_RULE_EXCERPT' 'CURSOR' $Matches.path $Matches.ownership
    }
    if ($Line -match '^(?<state>BOOT_HOOK_REGISTRATION_UNKNOWN|BOOT_HOOKS_DISABLED|BOOT_HOOK_MANAGED_ONLY_MISPLACED|BOOT_HOOK_REGISTRATION_MULTIPLE|STALE_BOOT_HOOK_OTHER_PATH|BOOT_HOOK_MISSING|BOOT_HOOK_UNREGISTERED|BOOT_HOOK_ALIGNED|BOOT_HOOK_DRIFT|STALE_BOOT_HOOK) (?<ownership>FILE-CLEAN|DIRTY .*?) CLAUDE_BOOT_HOOK registration=(?<registration>UNKNOWN|DISABLED|MANAGED_ONLY_MISPLACED|MULTIPLE|STALE_OTHER|REGISTERED|NOT_REGISTERED) (?<path>[A-Za-z]:\\.*)$') {
        $expectedRegistration = @{
            BOOT_HOOK_REGISTRATION_UNKNOWN = 'UNKNOWN'
            BOOT_HOOKS_DISABLED = 'DISABLED'
            BOOT_HOOK_MANAGED_ONLY_MISPLACED = 'MANAGED_ONLY_MISPLACED'
            BOOT_HOOK_REGISTRATION_MULTIPLE = 'MULTIPLE'
            STALE_BOOT_HOOK_OTHER_PATH = 'STALE_OTHER'
            BOOT_HOOK_MISSING = 'REGISTERED'
            BOOT_HOOK_UNREGISTERED = 'NOT_REGISTERED'
            BOOT_HOOK_ALIGNED = 'REGISTERED'
            BOOT_HOOK_DRIFT = 'REGISTERED'
            STALE_BOOT_HOOK = 'REGISTERED'
        }
        Assert-AuditMetadataContract ($Matches.registration -eq $expectedRegistration[$Matches.state]) 'CLAUDE_BOOT_HOOK' $Line
        return New-Finding 'CLAUDE_BOOT_HOOK' $Matches.state 'CLAUDE' $Matches.path $Matches.ownership @{ registration = $Matches.registration }
    }
    if ($Line -match '^(?<state>PROJECT_MCP_AUTH_HEADER|PROJECT_MCP_SHADOW|PROJECT_MCP_ENDPOINT_SHADOW|LEGACY_PROJECT_MCP|PROJECT_MCP_CONFIG_UNKNOWN) (?<ownership>FILE-CLEAN|DIRTY .*?) CURSOR_PROJECT_MCP server=(?<server>\S+) (?<path>[A-Za-z]:\\.*)$') {
        return New-Finding 'CURSOR_PROJECT_MCP' $Matches.state 'CURSOR' $Matches.path $Matches.ownership @{ server = $Matches.server }
    }
    if ($Line -match '^(?<state>CURSOR_PROJECT_HOOK_SHADOW|CURSOR_PROJECT_HOOK_CONFIG_UNKNOWN|CURSOR_USER_HOOK_SHADOW|CURSOR_USER_HOOK_CONFIG_UNKNOWN|CURSOR_ENTERPRISE_HOOK_SHADOW|CURSOR_ENTERPRISE_HOOK_CONFIG_UNKNOWN) (?<ownership>FILE-CLEAN|DIRTY .*?) CURSOR_HOOK_SCOPE=(?<scope>PROJECT|USER|ENTERPRISE) critical_events=(?<critical>-?\d+) (?<path>[A-Za-z]:\\.*)$') {
        $expectedScope = if ($Matches.state.StartsWith('CURSOR_PROJECT_')) { 'PROJECT' } elseif (
            $Matches.state.StartsWith('CURSOR_USER_')) { 'USER' } else { 'ENTERPRISE' }
        $expectedCriticalShape = if ($Matches.state.EndsWith('_SHADOW')) {
            [int]$Matches.critical -gt 0
        } else {
            [int]$Matches.critical -eq -1
        }
        Assert-AuditMetadataContract (
            $Matches.scope -eq $expectedScope -and $expectedCriticalShape
        ) 'CURSOR_HOOK' $Line
        return New-Finding 'CURSOR_HOOK' $Matches.state 'CURSOR' $Matches.path $Matches.ownership @{
            scope = $Matches.scope
            critical_events = [int]$Matches.critical
        }
    }
    if ($Line -match '^(?<state>USER_CLAUDE_BOOT_SETTINGS_UNKNOWN|USER_CLAUDE_BOOT_HOOKS_DISABLED|USER_CLAUDE_BOOT_MANAGED_ONLY_MISPLACED|USER_CLAUDE_BOOT_REGISTRATION_DRIFT|USER_CLAUDE_BOOT_HOOK_MISSING|USER_CLAUDE_BOOT_HOOK_DRIFT|USER_CLAUDE_BOOT_ALIGNED) USER_CLAUDE_BOOT exact=(?<exact>\d+) other_hydration=(?<other>\d+) (?<path>[A-Za-z]:\\.*)$') {
        $exact = [int]$Matches.exact
        $other = [int]$Matches.other
        $requiresExactCentralHook = $Matches.state -in @(
            'USER_CLAUDE_BOOT_HOOK_MISSING',
            'USER_CLAUDE_BOOT_HOOK_DRIFT',
            'USER_CLAUDE_BOOT_ALIGNED'
        )
        $validCounts = if ($requiresExactCentralHook) {
            $exact -eq 1 -and $other -eq 0
        } elseif ($Matches.state -eq 'USER_CLAUDE_BOOT_REGISTRATION_DRIFT') {
            $exact -ne 1 -or $other -ne 0
        } else {
            $true
        }
        Assert-AuditMetadataContract $validCounts 'USER_CLAUDE_BOOT' $Line
        return New-Finding 'USER_CLAUDE_BOOT' $Matches.state 'CLAUDE' $Matches.path 'FILE-CLEAN' @{
            exact = $exact
            other_hydration = $other
        }
    }
    if ($Line -match '^(?<state>USER_MCP_AUTH_HEADER|USER_MCP_ENDPOINT_SHADOW|USER_MCP_SHADOW|USER_MCP_LEGACY|USER_MCP_CONFIG_UNKNOWN) CURSOR_USER_MCP server=(?<server>\S+) (?<path>[A-Za-z]:\\.*)$') {
        return New-Finding 'CURSOR_USER_MCP' $Matches.state 'CURSOR' $Matches.path 'FILE-CLEAN' @{ server = $Matches.server }
    }
    return $null
}

function Parse-PolicyLine([string]$Line) {
    if ($Line -match '^(?<name>USER_CLAUDE_MANAGED_HOOK_POLICY|CURSOR_TEAM_HOOK_POLICY)=(?<state>UNVERIFIED_LIVE)(?:\s+.*)?$') {
        return [pscustomobject]@{
            kind = 'LIVE_POLICY'
            name = $Matches.name
            state = $Matches.state
            detail = if ($Matches.name -eq 'CURSOR_TEAM_HOOK_POLICY') {
                'Verify the effective Team hook policy in Cursor Customize.'
            } else {
                'Verify the effective managed hook policy in Claude Code.'
            }
            action = 'VERIFY_IN_EFFECTIVE_CLIENT_UI'
        }
    }
    return $null
}

function Parse-BoundaryLine([string]$Line) {
    if ($Line -match '^REPARSE_CHILD_SKIPPED path_digest=(?<digest>[a-f0-9]{64})$') {
        return [pscustomobject]@{
            kind = 'ESTATE_REPARSE_CHILD'
            name = "path_digest:$($Matches.digest)"
            state = 'SKIPPED_UNREAD'
            detail = 'The audit did not traverse this reparse-point child. Human scope review is required.'
            action = 'MANUAL_REVIEW_REPARSE_CHILD_OUTSIDE_AUDIT'
        }
    }
    return $null
}

function Assert-FindingPath($Finding, [string]$GitRoot) {
    if ($GitRoot) {
        $estateRoot = Get-OwningEstateRoot $Finding.path
        if (-not $estateRoot) {
            throw "Repository audit finding is outside every requested estate root."
        }
        Assert-NoReparseTraversal $Finding.path $estateRoot
        if (-not (Test-PathWithin $GitRoot $estateRoot)) {
            throw "Discovered Git root escaped the requested estate root."
        }
        $relative = $Finding.path.Substring($GitRoot.Length).TrimStart('\').Replace('\', '/')
        $valid = switch ($Finding.kind) {
            'BOOT_SURFACE' {
                ($Finding.surface -eq 'CLAUDE' -and $relative -ceq 'CLAUDE.md') -or
                ($Finding.surface -eq 'CODEX' -and $relative -ceq 'AGENTS.md') -or
                ($Finding.surface -eq 'CURSOR' -and $relative -ceq '.cursor/rules/dreameros-boot-canon.mdc')
            }
            'GENERATOR' { $relative -ieq 'governance/bootpack/build-boot-pack.ps1' }
            'ADAPTER' { $relative -match '^\.cursor/rules/(?:answer-from-measurement|canon-equals-live|dreameros-cold-start|dreameros-first)\.mdc$' }
            'CLAUDE_BOOT_HOOK' { $relative -ceq '.claude/hooks/dreameros-session-start.sh' }
            'CURSOR_PROJECT_MCP' { $relative -ceq '.cursor/mcp.json' }
            'DUPLICATE_EMBEDDED_EXCERPT' {
                ($Finding.surface -eq 'CLAUDE' -and $relative -ceq 'CLAUDE.md') -or
                ($Finding.surface -eq 'CODEX' -and $relative -ceq 'AGENTS.md')
            }
            'DUPLICATE_RULE_EXCERPT' { $relative -match '^\.cursor/rules/[^/]+\.mdc$' }
            'CURSOR_HOOK' { $relative -ceq '.cursor/hooks.json' }
            default { $false }
        }
        if (-not $valid) {
            throw "Audit finding path is not valid for its kind and surface: kind=$($Finding.kind) surface=$($Finding.surface) relative=$relative"
        }
        return
    }

    $expected = switch ($Finding.kind) {
        'USER_CLAUDE_BOOT' { Join-Path $UserHome '.claude\hooks\dreameros-session-start.sh' }
        'CURSOR_USER_MCP' { Join-Path $UserHome '.cursor\mcp.json' }
        'CURSOR_HOOK' {
            $userHook = Join-Path $UserHome '.cursor\hooks.json'
            if ($Finding.path.Equals([IO.Path]::GetFullPath($userHook), [StringComparison]::OrdinalIgnoreCase)) { return }
            if ($EnterpriseCursorHooksPath -and $Finding.path.Equals(
                $EnterpriseCursorHooksPath, [StringComparison]::OrdinalIgnoreCase)) { return }
            $null
        }
        default { $null }
    }
    if (-not $expected -or -not $Finding.path.Equals(
        [IO.Path]::GetFullPath($expected), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Non-repository audit finding has an unexpected path: kind=$($Finding.kind) path=$($Finding.path)"
    }
}

function Get-GeneratedDescriptor([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    return [ordered]@{ path = $Path; sha256 = Get-RawSha $Path }
}

function New-Action($Finding) {
    $action = $null
    $source = $null
    $notes = @()
    $manualBlock = $false
    switch ($Finding.kind) {
        'BOOT_SURFACE' {
            if ($Finding.state -in @('GLOBAL_ONLY', 'POINTER_ALIGNED') -and -not $Finding.dirty) { return $null }
            if ($Finding.state -eq 'UNKNOWN') {
                $action = 'MANUAL_REVIEW_UNCLASSIFIED_BOOT_SURFACE'
                $manualBlock = $true
            } elseif ($Finding.state -eq 'POINTER_ALIGNED' -and $Finding.dirty) {
                $action = 'PRESERVE_DIRTY_ALIGNED_POINTER_AND_REVIEW'
                $manualBlock = $true
            } elseif ($Finding.surface -eq 'CURSOR' -and $Finding.state -eq 'LEGACY_FULL_COPY') {
                $action = 'MIGRATE_CURSOR_RULE_WITH_SYNC_TOOL'
                $source = $CursorPointer
            } elseif ($Finding.surface -in @('CLAUDE', 'CODEX') -and
                $Finding.state -in @('LEGACY_FULL_COPY', 'POINTER_DRIFT')) {
                $action = 'REPLACE_GENERATED_BOOT_REGION_WITH_POINTER'
                $source = $EmbeddedPointer
                $notes += 'Preserve every repository-specific byte outside the verified generated region.'
            } else {
                $action = 'MANUAL_REVIEW_UNSUPPORTED_BOOT_STATE'
                $manualBlock = $true
            }
        }
        'GENERATOR' {
            if ($Finding.state -eq 'SUPERSEDED_GENERATOR' -and -not $Finding.dirty) { return $null }
            if ($Finding.state -eq 'LEGACY_FULL_GENERATOR') {
                $action = 'REPLACE_LEGACY_GENERATOR_WITH_POINTER_STUB'
                $source = $GeneratorPointer
            } else {
                $action = 'MANUAL_REVIEW_UNCLASSIFIED_GENERATOR'
                $manualBlock = $true
            }
        }
        'ADAPTER' {
            if ($Finding.state -eq 'ADAPTER_ALIGNED' -and -not $Finding.dirty) { return $null }
            if ($Finding.state -in @('STALE_ADAPTER_COPY', 'ADAPTER_DRIFT')) {
                $action = 'REPLACE_WITH_GENERATED_CURSOR_ADAPTER'
                $source = $AdapterSources[[IO.Path]::GetFileName($Finding.path)]
                if (-not $source) {
                    $action = 'MANUAL_REVIEW_UNMAPPED_ADAPTER'
                    $manualBlock = $true
                }
            } else {
                $action = 'MANUAL_REVIEW_ADAPTER_PATH_OR_STATE'
                $manualBlock = $true
            }
        }
        'CLAUDE_BOOT_HOOK' {
            if ($Finding.state -eq 'BOOT_HOOK_ALIGNED' -and -not $Finding.dirty) { return $null }
            if ($Finding.state -eq 'STALE_BOOT_HOOK' -and $Finding.metadata.registration -eq 'REGISTERED') {
                $action = 'REPLACE_WITH_GENERATED_THIN_CLAUDE_HOOK'
                $source = $ClaudeHookPointer
            } else {
                $action = 'REVIEW_CLAUDE_HOOK_REGISTRATION_AND_CONTENT'
                $manualBlock = $true
                $notes += 'Review project and local hook registrations atomically.'
            }
        }
        'CURSOR_PROJECT_MCP' {
            switch ($Finding.state) {
                'PROJECT_MCP_AUTH_HEADER' {
                    $action = 'REMOVE_LEGACY_AUTHORIZATION_WITHOUT_OUTPUTTING_VALUE'
                    $notes += 'Parse JSON structurally. Never print, copy, or persist the header value.'
                }
                'LEGACY_PROJECT_MCP' {
                    $action = 'REVIEW_LEGACY_PROJECT_MCP_MIGRATION'
                    $manualBlock = $true
                }
                { $_ -in @('PROJECT_MCP_SHADOW', 'PROJECT_MCP_ENDPOINT_SHADOW') } {
                    $action = 'REVIEW_PROJECT_MCP_SHADOW_PRECEDENCE'
                    $manualBlock = $true
                }
                default {
                    $action = 'MANUAL_REVIEW_UNKNOWN_PROJECT_MCP_CONFIG'
                    $manualBlock = $true
                }
            }
        }
        'DUPLICATE_EMBEDDED_EXCERPT' {
            $action = 'REVIEW_AND_REMOVE_ONLY_VERIFIED_GENERATED_DUPLICATION'
            $notes += 'Prove exact start and end boundaries before any edit.'
        }
        'DUPLICATE_RULE_EXCERPT' {
            $action = 'REVIEW_CURSOR_RULE_EXCERPT_BOUNDARY'
            $notes += 'Do not replace a standalone project rule without ownership review.'
        }
        'CURSOR_HOOK' {
            $action = 'REVIEW_CURSOR_HOOK_PRECEDENCE'
            $manualBlock = $true
            $notes += 'Effective cloud Team policy still requires a live Cursor Hooks check.'
        }
        'USER_CLAUDE_BOOT' {
            if ($Finding.state -eq 'USER_CLAUDE_BOOT_ALIGNED') { return $null }
            $action = 'REPAIR_USER_CLAUDE_BOOT_WITH_GENERATED_HOOK'
            $source = $ClaudeHookPointer
            $manualBlock = $true
        }
        'CURSOR_USER_MCP' {
            $action = 'REVIEW_USER_MCP_CONFIG_WITHOUT_OUTPUTTING_VALUE'
            $manualBlock = $true
            $notes += 'Never print, copy, or persist any configured header value.'
        }
    }
    if (-not $action) { return $null }
    if ($Finding.dirty) { $notes += 'Target is dirty. Preserve owner work and stop before writing.' }
    $metadataIdentity = ConvertTo-CanonicalMetadataJson $Finding.metadata
    return [ordered]@{
        id = (Get-StringSha ($action + '|' + $Finding.path + '|' + $Finding.state + '|' + $metadataIdentity)).Substring(0, 16)
        action = $action
        target = $Finding.path
        generated_source = Get-GeneratedDescriptor $source
        human_conductor_authorization_required = $true
        fresh_fetch_required = (
            $Finding.kind -notin @('USER_CLAUDE_BOOT', 'CURSOR_USER_MCP') -and
            -not ($Finding.kind -eq 'CURSOR_HOOK' -and $Finding.metadata.scope -in @('USER', 'ENTERPRISE'))
        )
        apply_status = if ($manualBlock) { 'BLOCKED' } else { 'HELD' }
        notes = @($notes)
    }
}

if ($AuditInputPath) {
    if (-not (Test-Path -LiteralPath $AuditInputPath -PathType Leaf)) { throw "Audit input does not exist: $AuditInputPath" }
    $AuditLines = @([IO.File]::ReadAllLines((Resolve-Path -LiteralPath $AuditInputPath).Path))
    $AuditOutcome = 'CAPTURED'
} else {
    $captured = [Collections.Generic.List[string]]::new()
    $auditFailure = $null
    $priorOptionalLocks = $env:GIT_OPTIONAL_LOCKS
    try {
        $env:GIT_OPTIONAL_LOCKS = '0'
        & $AuditScript -EstateRoots $ResolvedEstateRoots -UserHome $UserHome `
            -EnterpriseCursorHooksPath $EnterpriseCursorHooksPath `
            2>&1 3>$null 4>$null 5>$null 6>$null |
            ForEach-Object { [void]$captured.Add([string]$_) }
    } catch {
        $auditFailure = $_
    } finally {
        if ($null -eq $priorOptionalLocks) { Remove-Item Env:GIT_OPTIONAL_LOCKS -ErrorAction SilentlyContinue }
        else { $env:GIT_OPTIONAL_LOCKS = $priorOptionalLocks }
    }
    $AuditLines = @($captured)
}

$OutcomeLine = @($AuditLines | Where-Object { $_ -match '^DREAMEROS_AUDIT_OUTCOME=(?:PASS|FINDINGS)$' })
if ($OutcomeLine.Count -ne 1) {
    throw "Audit output must contain exactly one trusted outcome marker; found $($OutcomeLine.Count)."
}
$ReportedAuditOutcome = ($OutcomeLine[0] -split '=', 2)[1]
if (-not $AuditInputPath) {
    if ($ReportedAuditOutcome -eq 'FINDINGS' -and $null -ne $auditFailure) {
        $AuditOutcome = 'FINDINGS'
    } elseif ($ReportedAuditOutcome -eq 'PASS' -and $null -eq $auditFailure) {
        $AuditOutcome = 'PASS'
    } else {
        $failureType = if ($auditFailure) { $auditFailure.Exception.GetType().FullName } else { 'none' }
        throw "Audit outcome and process result disagree; reported=$ReportedAuditOutcome failure_type=$failureType."
    }
}

$SummaryLine = @($AuditLines | Where-Object { $_ -match '^repos=\d+\s+surfaces=' })
if ($SummaryLine.Count -ne 1) { throw "Audit output must contain exactly one parseable summary line; found $($SummaryLine.Count)." }
$RequiredSummaryKeys = @(
    'repos', 'surfaces', 'GLOBAL_ONLY', 'POINTER_ALIGNED', 'LEGACY_FULL_COPY', 'POINTER_DRIFT', 'UNKNOWN',
    'generators', 'LEGACY_FULL_GENERATOR', 'UNKNOWN_GENERATOR',
    'ADAPTER_ALIGNED', 'ADAPTER_DRIFT', 'STALE_ADAPTER_COPY', 'ADAPTER_PATH_DRIFT',
    'CLAUDE_BOOT_HOOKS', 'BOOT_HOOK_ALIGNED', 'STALE_BOOT_HOOK', 'BOOT_HOOK_OTHER',
    'PROJECT_MCP_RECORDS', 'PROJECT_MCP_AUTH_HEADER', 'PROJECT_MCP_SHADOW',
    'PROJECT_MCP_ENDPOINT_SHADOW', 'LEGACY_PROJECT_MCP', 'PROJECT_MCP_UNKNOWN',
    'CURSOR_HOOK_SHADOWS', 'REPARSE_CHILD_SKIPPED', 'CURSOR_TEAM_HOOK_POLICY', 'USER_CLAUDE_BOOT',
    'USER_CLAUDE_MANAGED_HOOK_POLICY', 'USER_MCP_RECORDS',
    'DUPLICATE_EMBEDDED_EXCERPT', 'DUPLICATE_RULE_EXCERPT'
)
$requiredKeySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($key in $RequiredSummaryKeys) { [void]$requiredKeySet.Add($key) }
$Summary = [ordered]@{}
$summaryTokens = @($SummaryLine[0] -split '\s+')
for ($tokenIndex = 0; $tokenIndex -lt $summaryTokens.Count; $tokenIndex++) {
    $token = $summaryTokens[$tokenIndex]
    if ($token -notmatch '^(?<key>[A-Za-z0-9_]+)=(?<value>\S+)$') {
        throw "Malformed audit summary token at position=$tokenIndex digest=$(Get-StringSha $token)."
    }
    $key = $Matches.key
    if (-not $requiredKeySet.Contains($key)) {
        throw "Unknown audit summary key at position=$tokenIndex digest=$(Get-StringSha $token)."
    }
    if ($Summary.Contains($key)) { throw "Duplicate audit summary key: $key" }
    $value = $Matches.value
    $Summary[$key] = if ($value -match '^\d+$') { [int]$value } else { $value }
}
foreach ($key in $RequiredSummaryKeys) {
    if (-not $Summary.Contains($key)) { throw "Missing required audit summary key: $key" }
}

$Findings = [Collections.Generic.List[object]]::new()
$PolicyFindings = [Collections.Generic.List[object]]::new()
$BoundaryFindings = [Collections.Generic.List[object]]::new()
$UnparsedAuditRows = [Collections.Generic.List[string]]::new()
for ($lineIndex = 0; $lineIndex -lt $AuditLines.Count; $lineIndex++) {
    $line = [string]$AuditLines[$lineIndex]
    $finding = Parse-AuditLine ([string]$line)
    if ($finding) {
        [void]$Findings.Add($finding)
        continue
    }
    $policy = Parse-PolicyLine ([string]$line)
    if ($policy) {
        [void]$PolicyFindings.Add($policy)
        continue
    }
    $boundary = Parse-BoundaryLine ([string]$line)
    if ($boundary) {
        [void]$BoundaryFindings.Add($boundary)
        continue
    }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -eq $SummaryLine[0] -or $line -eq $OutcomeLine[0] -or
        $line -match '^VERIFIED CROSS-VENDOR PROJECT BOOT POINTERS repos=') { continue }
    [void]$UnparsedAuditRows.Add("line=$($lineIndex + 1) digest=$(Get-StringSha $line)")
}
if ($UnparsedAuditRows.Count -gt 0) {
    throw "Planner found unparsed audit record(s); count=$($UnparsedAuditRows.Count) $($UnparsedAuditRows -join ' ')"
}

$reconciliation = [ordered]@{
    surfaces = @($Findings | Where-Object kind -eq 'BOOT_SURFACE').Count
    GLOBAL_ONLY = @($Findings | Where-Object { $_.kind -eq 'BOOT_SURFACE' -and $_.state -eq 'GLOBAL_ONLY' }).Count
    POINTER_ALIGNED = @($Findings | Where-Object { $_.kind -eq 'BOOT_SURFACE' -and $_.state -eq 'POINTER_ALIGNED' }).Count
    LEGACY_FULL_COPY = @($Findings | Where-Object { $_.kind -eq 'BOOT_SURFACE' -and $_.state -eq 'LEGACY_FULL_COPY' }).Count
    POINTER_DRIFT = @($Findings | Where-Object { $_.kind -eq 'BOOT_SURFACE' -and $_.state -eq 'POINTER_DRIFT' }).Count
    UNKNOWN = @($Findings | Where-Object { $_.kind -eq 'BOOT_SURFACE' -and $_.state -eq 'UNKNOWN' }).Count
    generators = @($Findings | Where-Object kind -eq 'GENERATOR').Count
    SUPERSEDED_GENERATOR = @($Findings | Where-Object { $_.kind -eq 'GENERATOR' -and $_.state -eq 'SUPERSEDED_GENERATOR' }).Count
    LEGACY_FULL_GENERATOR = @($Findings | Where-Object { $_.kind -eq 'GENERATOR' -and $_.state -eq 'LEGACY_FULL_GENERATOR' }).Count
    UNKNOWN_GENERATOR = @($Findings | Where-Object { $_.kind -eq 'GENERATOR' -and $_.state -eq 'UNKNOWN_GENERATOR' }).Count
    adapters = @($Findings | Where-Object kind -eq 'ADAPTER').Count
    ADAPTER_ALIGNED = @($Findings | Where-Object { $_.kind -eq 'ADAPTER' -and $_.state -eq 'ADAPTER_ALIGNED' }).Count
    ADAPTER_DRIFT = @($Findings | Where-Object { $_.kind -eq 'ADAPTER' -and $_.state -eq 'ADAPTER_DRIFT' }).Count
    STALE_ADAPTER_COPY = @($Findings | Where-Object { $_.kind -eq 'ADAPTER' -and $_.state -eq 'STALE_ADAPTER_COPY' }).Count
    ADAPTER_PATH_DRIFT = @($Findings | Where-Object { $_.kind -eq 'ADAPTER' -and $_.state -eq 'ADAPTER_PATH_DRIFT' }).Count
    claude_boot_hooks = @($Findings | Where-Object kind -eq 'CLAUDE_BOOT_HOOK').Count
    BOOT_HOOK_ALIGNED = @($Findings | Where-Object { $_.kind -eq 'CLAUDE_BOOT_HOOK' -and $_.state -eq 'BOOT_HOOK_ALIGNED' }).Count
    STALE_BOOT_HOOK = @($Findings | Where-Object { $_.kind -eq 'CLAUDE_BOOT_HOOK' -and $_.state -eq 'STALE_BOOT_HOOK' }).Count
    BOOT_HOOK_OTHER = @($Findings | Where-Object { $_.kind -eq 'CLAUDE_BOOT_HOOK' -and $_.state -notin @('BOOT_HOOK_ALIGNED', 'STALE_BOOT_HOOK') }).Count
    project_mcp = @($Findings | Where-Object kind -eq 'CURSOR_PROJECT_MCP').Count
    PROJECT_MCP_AUTH_HEADER = @($Findings | Where-Object { $_.kind -eq 'CURSOR_PROJECT_MCP' -and $_.state -eq 'PROJECT_MCP_AUTH_HEADER' }).Count
    PROJECT_MCP_SHADOW = @($Findings | Where-Object { $_.kind -eq 'CURSOR_PROJECT_MCP' -and $_.state -eq 'PROJECT_MCP_SHADOW' }).Count
    PROJECT_MCP_ENDPOINT_SHADOW = @($Findings | Where-Object { $_.kind -eq 'CURSOR_PROJECT_MCP' -and $_.state -eq 'PROJECT_MCP_ENDPOINT_SHADOW' }).Count
    LEGACY_PROJECT_MCP = @($Findings | Where-Object { $_.kind -eq 'CURSOR_PROJECT_MCP' -and $_.state -eq 'LEGACY_PROJECT_MCP' }).Count
    PROJECT_MCP_UNKNOWN = @($Findings | Where-Object { $_.kind -eq 'CURSOR_PROJECT_MCP' -and $_.state -eq 'PROJECT_MCP_CONFIG_UNKNOWN' }).Count
    embedded_excerpts = @($Findings | Where-Object kind -eq 'DUPLICATE_EMBEDDED_EXCERPT').Count
    rule_excerpts = @($Findings | Where-Object kind -eq 'DUPLICATE_RULE_EXCERPT').Count
    cursor_hook_shadows = @($Findings | Where-Object kind -eq 'CURSOR_HOOK').Count
    reparse_children = $BoundaryFindings.Count
    user_mcp_records = @($Findings | Where-Object kind -eq 'CURSOR_USER_MCP').Count
    user_claude_boot_records = @($Findings | Where-Object kind -eq 'USER_CLAUDE_BOOT').Count
    live_policy_records = $PolicyFindings.Count
}
$mismatches = @()
foreach ($pair in @(
    @('surfaces', [int]$Summary.surfaces),
    @('GLOBAL_ONLY', [int]$Summary.GLOBAL_ONLY),
    @('POINTER_ALIGNED', [int]$Summary.POINTER_ALIGNED),
    @('LEGACY_FULL_COPY', [int]$Summary.LEGACY_FULL_COPY),
    @('POINTER_DRIFT', [int]$Summary.POINTER_DRIFT),
    @('UNKNOWN', [int]$Summary.UNKNOWN),
    @('generators', [int]$Summary.generators),
    @('SUPERSEDED_GENERATOR', ([int]$Summary.generators - [int]$Summary.LEGACY_FULL_GENERATOR - [int]$Summary.UNKNOWN_GENERATOR)),
    @('LEGACY_FULL_GENERATOR', [int]$Summary.LEGACY_FULL_GENERATOR),
    @('UNKNOWN_GENERATOR', [int]$Summary.UNKNOWN_GENERATOR),
    @('adapters', ([int]$Summary.ADAPTER_ALIGNED + [int]$Summary.ADAPTER_DRIFT + [int]$Summary.STALE_ADAPTER_COPY + [int]$Summary.ADAPTER_PATH_DRIFT)),
    @('ADAPTER_ALIGNED', [int]$Summary.ADAPTER_ALIGNED),
    @('ADAPTER_DRIFT', [int]$Summary.ADAPTER_DRIFT),
    @('STALE_ADAPTER_COPY', [int]$Summary.STALE_ADAPTER_COPY),
    @('ADAPTER_PATH_DRIFT', [int]$Summary.ADAPTER_PATH_DRIFT),
    @('claude_boot_hooks', [int]$Summary.CLAUDE_BOOT_HOOKS),
    @('BOOT_HOOK_ALIGNED', [int]$Summary.BOOT_HOOK_ALIGNED),
    @('STALE_BOOT_HOOK', [int]$Summary.STALE_BOOT_HOOK),
    @('BOOT_HOOK_OTHER', [int]$Summary.BOOT_HOOK_OTHER),
    @('project_mcp', [int]$Summary.PROJECT_MCP_RECORDS),
    @('PROJECT_MCP_AUTH_HEADER', [int]$Summary.PROJECT_MCP_AUTH_HEADER),
    @('PROJECT_MCP_SHADOW', [int]$Summary.PROJECT_MCP_SHADOW),
    @('PROJECT_MCP_ENDPOINT_SHADOW', [int]$Summary.PROJECT_MCP_ENDPOINT_SHADOW),
    @('LEGACY_PROJECT_MCP', [int]$Summary.LEGACY_PROJECT_MCP),
    @('PROJECT_MCP_UNKNOWN', [int]$Summary.PROJECT_MCP_UNKNOWN),
    @('embedded_excerpts', [int]$Summary.DUPLICATE_EMBEDDED_EXCERPT),
    @('rule_excerpts', [int]$Summary.DUPLICATE_RULE_EXCERPT),
    @('cursor_hook_shadows', [int]$Summary.CURSOR_HOOK_SHADOWS),
    @('reparse_children', [int]$Summary.REPARSE_CHILD_SKIPPED),
    @('user_mcp_records', [int]$Summary.USER_MCP_RECORDS),
    @('user_claude_boot_records', 1),
    @('live_policy_records', 2)
)) {
    if ([int]$reconciliation[$pair[0]] -ne [int]$pair[1]) {
        $mismatches += "$($pair[0]) parsed=$($reconciliation[$pair[0]]) expected=$($pair[1])"
    }
}
if (@($Findings | Where-Object kind -eq 'USER_CLAUDE_BOOT')[0].state -ne [string]$Summary.USER_CLAUDE_BOOT) {
    $mismatches += "USER_CLAUDE_BOOT parsed=$(@($Findings | Where-Object kind -eq 'USER_CLAUDE_BOOT')[0].state) expected=$($Summary.USER_CLAUDE_BOOT)"
}
foreach ($policyName in @('CURSOR_TEAM_HOOK_POLICY', 'USER_CLAUDE_MANAGED_HOOK_POLICY')) {
    $policy = @($PolicyFindings | Where-Object name -eq $policyName)
    if ($policy.Count -ne 1 -or $policy[0].state -ne [string]$Summary[$policyName]) {
        $mismatches += "$policyName policy record does not match the summary"
    }
}
if ($mismatches.Count -gt 0) { throw "Planner reconciliation failed: $($mismatches -join '; ')" }

$RepoMap = @{}
$GlobalFindings = [Collections.Generic.List[object]]::new()
$GlobalActions = [Collections.Generic.List[object]]::new()
foreach ($finding in $Findings) {
    $gitRoot = Find-GitRoot $finding.path
    Assert-FindingPath $finding $gitRoot
    if (-not $gitRoot) {
        [void]$GlobalFindings.Add($finding)
        $globalAction = New-Action $finding
        if ($globalAction) {
            $finding | Add-Member -NotePropertyName action_id -NotePropertyValue $globalAction.id -Force
            if (-not @($GlobalActions | Where-Object id -eq $globalAction.id)) {
                [void]$GlobalActions.Add($globalAction)
            }
        } else {
            $finding | Add-Member -NotePropertyName action_id -NotePropertyValue $null -Force
        }
        continue
    }
    $key = $gitRoot.ToLowerInvariant()
    if (-not $RepoMap.ContainsKey($key)) {
        $RepoMap[$key] = [ordered]@{
            path = $gitRoot
            name = Split-Path -Leaf $gitRoot
            git = Get-GitInfo $gitRoot
            cursor_rule_registry = Get-RegistryState $gitRoot
            findings = [Collections.Generic.List[object]]::new()
            actions = [Collections.Generic.List[object]]::new()
        }
    }
    [void]$RepoMap[$key].findings.Add($finding)
    $action = New-Action $finding
    if ($action) {
        $finding | Add-Member -NotePropertyName action_id -NotePropertyValue $action.id -Force
        if (-not @($RepoMap[$key].actions | Where-Object id -eq $action.id)) {
            [void]$RepoMap[$key].actions.Add($action)
        }
    } else {
        $finding | Add-Member -NotePropertyName action_id -NotePropertyValue $null -Force
    }
}
foreach ($policy in $PolicyFindings) {
    [void]$GlobalFindings.Add($policy)
    $policyAction = [ordered]@{
        id = (Get-StringSha ('VERIFY_IN_EFFECTIVE_CLIENT_UI|' + $policy.name)).Substring(0, 16)
        action = 'VERIFY_IN_EFFECTIVE_CLIENT_UI'
        target = $policy.name
        generated_source = $null
        human_conductor_authorization_required = $true
        fresh_fetch_required = $false
        apply_status = 'HELD'
        notes = @($policy.detail)
    }
    $policy | Add-Member -NotePropertyName action_id -NotePropertyValue $policyAction.id -Force
    [void]$GlobalActions.Add($policyAction)
}
foreach ($boundary in $BoundaryFindings) {
    [void]$GlobalFindings.Add($boundary)
    $boundaryAction = [ordered]@{
        id = (Get-StringSha ('MANUAL_REVIEW_REPARSE_CHILD_OUTSIDE_AUDIT|' + $boundary.name)).Substring(0, 16)
        action = 'MANUAL_REVIEW_REPARSE_CHILD_OUTSIDE_AUDIT'
        target = $boundary.name
        generated_source = $null
        human_conductor_authorization_required = $true
        fresh_fetch_required = $false
        apply_status = 'BLOCKED'
        notes = @($boundary.detail)
    }
    $boundary | Add-Member -NotePropertyName action_id -NotePropertyValue $boundaryAction.id -Force
    [void]$GlobalActions.Add($boundaryAction)
}

foreach ($repo in $RepoMap.Values) {
    $bootFindings = @($repo.findings | Where-Object kind -eq 'BOOT_SURFACE')
    $surfaceNames = @($bootFindings | ForEach-Object surface | Sort-Object)
    if ($bootFindings.Count -ne 3 -or
        ($surfaceNames -join ',') -cne 'CLAUDE,CODEX,CURSOR') {
        throw "Repository boot-surface reconciliation failed; repo_digest=$(Get-StringSha $repo.path)."
    }
}

$Repositories = @($RepoMap.Values | Sort-Object path | ForEach-Object {
    $repo = $_
    $actionCount = @($repo.actions).Count
    $dirtyActionCount = @($repo.findings | Where-Object dirty).Count
    $dirtyWorktree = $repo.git.state -eq 'READ' -and -not $repo.git.clean
    $manualBlock = @($repo.actions | Where-Object apply_status -eq 'BLOCKED').Count -gt 0
    $registryBlocks = $repo.cursor_rule_registry -in @('TRACKS_RULE', 'INVALID_JSON')
    [ordered]@{
        path = $repo.path
        name = $repo.name
        git = $repo.git
        cursor_rule_registry = $repo.cursor_rule_registry
        plan_state = if ($actionCount -eq 0) {
            'NO_MIGRATION_ACTION'
        } elseif ($repo.git.state -ne 'READ') {
            'BLOCKED_GIT_STATE'
        } elseif ($dirtyActionCount -gt 0 -or $dirtyWorktree) {
            'BLOCKED_DIRTY'
        } elseif ($manualBlock) {
            'MANUAL_REVIEW_BLOCKED'
        } elseif ($registryBlocks) {
            'ATOMIC_REGISTRY_REVIEW_REQUIRED'
        } else {
            'REVIEW_REQUIRED'
        }
        findings = @($repo.findings | Sort-Object kind, path)
        actions = @($repo.actions | Sort-Object target, action)
    }
})

if ($Repositories.Count -ne [int]$Summary.repos) {
    throw "Planner repository reconciliation failed: parsed=$($Repositories.Count) expected=$($Summary.repos)"
}

$Plan = [ordered]@{
    schema_version = 1
    generated_utc = [DateTime]::UtcNow.ToString('o')
    mode = 'READ_ONLY_NO_FETCH_NO_PROJECT_WRITE'
    audit_outcome = $AuditOutcome
    audit_reported_outcome = $ReportedAuditOutcome
    audit_source = if ($AuditInputPath) { (Resolve-Path -LiteralPath $AuditInputPath).Path } else { $AuditScript }
    requested_estate_roots = @($RequestedEstateRoots)
    resolved_estate_roots = @($ResolvedEstateRoots)
    missing_estate_roots = @($MissingEstateRoots)
    audit_summary = $Summary
    parser_reconciliation = $reconciliation
    overall_state = if (
        $AuditOutcome -eq 'FINDINGS' -or
        @($Repositories | Where-Object { $_.actions.Count -gt 0 }).Count -gt 0 -or
        $GlobalActions.Count -gt 0
    ) { 'PARTIAL' } else { 'NO_ACTION' }
    repositories = $Repositories
    global_findings = @($GlobalFindings)
    global_actions = @($GlobalActions)
    held_back = @(
        'Every tracked write requires separate Human Conductor authorization.',
        'Every repository requires a fresh fetch-backed preflight before a write.',
        'Reparse-point child directories are not traversed. Every reported digest requires human scope review.',
        'The audit inspects MCP header structure. Neither layer prints, copies, or persists header values.',
        'The planner uses GIT_OPTIONAL_LOCKS=0 and does not fetch or write project files.',
        'This planner does not apply, commit, push, merge, deploy, or change production.'
    )
}

if ($Format -eq 'Json') {
    Write-Output ($Plan | ConvertTo-Json -Depth 14)
    exit 0
}

function ConvertTo-MarkdownCell($Value) {
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", '<br>')
}

function Add-MarkdownActionTable([Text.StringBuilder]$Builder, $Actions) {
    [void]$Builder.AppendLine('### Planned actions')
    [void]$Builder.AppendLine('')
    [void]$Builder.AppendLine('| Action ID | Action | Target | Apply status | HC authorization | Fresh fetch | Generated source | SHA-256 | Notes |')
    [void]$Builder.AppendLine('|---|---|---|---|---|---|---|---|---|')
    $items = @($Actions)
    if ($items.Count -eq 0) {
        [void]$Builder.AppendLine('| NONE | NONE |  | N/A | N/A | N/A |  |  | No migration action is planned. |')
    } else {
        foreach ($action in $items) {
            $sourcePath = if ($action.generated_source) { $action.generated_source.path } else { '' }
            $sourceHash = if ($action.generated_source) { $action.generated_source.sha256 } else { '' }
            $notes = @($action.notes) -join '<br>'
            [void]$Builder.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f
                (ConvertTo-MarkdownCell $action.id),
                (ConvertTo-MarkdownCell $action.action),
                (ConvertTo-MarkdownCell $action.target),
                (ConvertTo-MarkdownCell $action.apply_status),
                (ConvertTo-MarkdownCell $action.human_conductor_authorization_required),
                (ConvertTo-MarkdownCell $action.fresh_fetch_required),
                (ConvertTo-MarkdownCell $sourcePath),
                (ConvertTo-MarkdownCell $sourceHash),
                (ConvertTo-MarkdownCell $notes)))
        }
    }
    [void]$Builder.AppendLine('')
}

$builder = [Text.StringBuilder]::new()
[void]$builder.AppendLine('# DreamerOS Cursor Repository Migration Plan')
[void]$builder.AppendLine('')
[void]$builder.AppendLine("Generated UTC: $($Plan.generated_utc)")
[void]$builder.AppendLine('')
[void]$builder.AppendLine("Mode: $($Plan.mode)")
[void]$builder.AppendLine('')
[void]$builder.AppendLine("Overall state: $($Plan.overall_state)")
[void]$builder.AppendLine("")
[void]$builder.AppendLine("Audit execution: $($Plan.audit_outcome)")
[void]$builder.AppendLine("")
[void]$builder.AppendLine("Audit reported outcome: $($Plan.audit_reported_outcome)")
[void]$builder.AppendLine('')
[void]$builder.AppendLine("Audit: $($SummaryLine[0])")
[void]$builder.AppendLine('')
foreach ($repo in $Repositories) {
    [void]$builder.AppendLine("## $($repo.path)")
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine("Plan state: $($repo.plan_state)")
    [void]$builder.AppendLine("Git: state=$($repo.git.state) branch=$($repo.git.branch) staged=$($repo.git.staged) unstaged=$($repo.git.unstaged) untracked=$($repo.git.untracked) fresh_fetch_required=$($repo.git.fresh_fetch_required)")
    [void]$builder.AppendLine("Cursor rule registry: $($repo.cursor_rule_registry)")
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('| State | Kind | Target | Planned action |')
    [void]$builder.AppendLine('|---|---|---|---|')
    foreach ($finding in $repo.findings) {
        $action = @($repo.actions | Where-Object id -eq $finding.action_id)
        $actionName = if ($action.Count -eq 1) { $action[0].action } else { 'NONE' }
        $target = ConvertTo-MarkdownCell $finding.path
        [void]$builder.AppendLine("| $($finding.state) | $($finding.kind) | $target | $actionName |")
    }
    [void]$builder.AppendLine('')
    Add-MarkdownActionTable $builder $repo.actions
}
[void]$builder.AppendLine('## User and global findings')
[void]$builder.AppendLine('')
[void]$builder.AppendLine('| State | Kind | Target | Planned action |')
[void]$builder.AppendLine('|---|---|---|---|')
foreach ($finding in $Plan.global_findings) {
    $target = if ($finding.PSObject.Properties.Name -contains 'path') { $finding.path } else { $finding.name }
    $action = @($Plan.global_actions | Where-Object id -eq $finding.action_id)
    $actionName = if ($action.Count -eq 1) { $action[0].action } else { 'NONE' }
    [void]$builder.AppendLine("| $($finding.state) | $($finding.kind) | $target | $actionName |")
}
[void]$builder.AppendLine('')
Add-MarkdownActionTable $builder $Plan.global_actions
[void]$builder.AppendLine('## Held back')
[void]$builder.AppendLine('')
foreach ($item in $Plan.held_back) { [void]$builder.AppendLine("- $item") }
Write-Output $builder.ToString()
