# Read-only renderer. Consumes an independently sealed migration-plan JSON file
# and produces in-memory review diffs for the five deterministic project action
# classes. It never fetches, writes, applies, commits, pushes, or reads MCP
# credential values. It always returns JSON so every diff retains its gates.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'File')]
    [string]$PlanPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'StandardInput')]
    [switch]$PlanFromStandardInput,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedPlanSha256,

    [string[]]$RepositoryPath,

    [ValidatePattern('^[a-f0-9]{16}$')]
    [string[]]$ActionId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Utf8Strict = New-Object Text.UTF8Encoding($false, $true)
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$MaxPlanBytes = 64MB
$MaxContentBytes = 16MB
$MaxRenderedBytes = 64MB

$ExpectedHeldBack = @(
    'Every tracked write requires separate Human Conductor authorization.',
    'Every repository requires a fresh fetch-backed preflight before a write.',
    'Reparse-point child directories are not traversed. Every reported digest requires human scope review.',
    'The audit inspects MCP header structure. Neither layer prints, copies, or persists header values.',
    'The planner uses GIT_OPTIONAL_LOCKS=0 and does not fetch or write project files.',
    'This planner does not apply, commit, push, merge, deploy, or change production.'
)

$TopLevelProperties = @(
    'schema_version', 'generated_utc', 'mode', 'audit_outcome', 'audit_reported_outcome',
    'audit_source', 'requested_estate_roots', 'resolved_estate_roots', 'missing_estate_roots',
    'audit_summary', 'parser_reconciliation', 'overall_state', 'repositories',
    'global_findings', 'global_actions', 'held_back'
)
$SummaryProperties = @(
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
$ReconciliationProperties = @(
    'surfaces', 'GLOBAL_ONLY', 'POINTER_ALIGNED', 'LEGACY_FULL_COPY', 'POINTER_DRIFT', 'UNKNOWN',
    'generators', 'SUPERSEDED_GENERATOR', 'LEGACY_FULL_GENERATOR', 'UNKNOWN_GENERATOR',
    'adapters', 'ADAPTER_ALIGNED', 'ADAPTER_DRIFT', 'STALE_ADAPTER_COPY', 'ADAPTER_PATH_DRIFT',
    'claude_boot_hooks', 'BOOT_HOOK_ALIGNED', 'STALE_BOOT_HOOK', 'BOOT_HOOK_OTHER',
    'project_mcp', 'PROJECT_MCP_AUTH_HEADER', 'PROJECT_MCP_SHADOW',
    'PROJECT_MCP_ENDPOINT_SHADOW', 'LEGACY_PROJECT_MCP', 'PROJECT_MCP_UNKNOWN',
    'embedded_excerpts', 'rule_excerpts', 'cursor_hook_shadows', 'reparse_children',
    'user_mcp_records', 'user_claude_boot_records', 'live_policy_records'
)
$RepositoryProperties = @('path', 'name', 'git', 'cursor_rule_registry', 'plan_state', 'findings', 'actions')
$GitProperties = @(
    'state', 'branch', 'head', 'origin_main_tracking_ref', 'ahead_of_tracking_ref',
    'behind_tracking_ref', 'staged', 'unstaged', 'untracked', 'clean', 'fetch_head_utc',
    'fresh_fetch_required', 'current_main_against_tracking_ref'
)
$FindingProperties = @('kind', 'state', 'surface', 'path', 'ownership', 'dirty', 'allowed_root', 'metadata', 'action_id')
$ActionProperties = @(
    'id', 'action', 'target', 'generated_source', 'human_conductor_authorization_required',
    'fresh_fetch_required', 'apply_status', 'notes'
)
$SourceProperties = @('path', 'sha256')
$PolicyFindingProperties = @('kind', 'name', 'state', 'detail', 'action', 'action_id')
$RenderableActions = @(
    'MIGRATE_CURSOR_RULE_WITH_SYNC_TOOL',
    'REPLACE_GENERATED_BOOT_REGION_WITH_POINTER',
    'REPLACE_LEGACY_GENERATOR_WITH_POINTER_STUB',
    'REPLACE_WITH_GENERATED_CURSOR_ADAPTER',
    'REPLACE_WITH_GENERATED_THIN_CLAUDE_HOOK'
)
$KnownActions = @(
    $RenderableActions + @(
        'MANUAL_REVIEW_UNCLASSIFIED_BOOT_SURFACE',
        'PRESERVE_DIRTY_ALIGNED_POINTER_AND_REVIEW',
        'MANUAL_REVIEW_UNSUPPORTED_BOOT_STATE',
        'MANUAL_REVIEW_UNCLASSIFIED_GENERATOR',
        'MANUAL_REVIEW_UNMAPPED_ADAPTER',
        'MANUAL_REVIEW_ADAPTER_PATH_OR_STATE',
        'REVIEW_CLAUDE_HOOK_REGISTRATION_AND_CONTENT',
        'REMOVE_LEGACY_AUTHORIZATION_WITHOUT_OUTPUTTING_VALUE',
        'REVIEW_LEGACY_PROJECT_MCP_MIGRATION',
        'REVIEW_PROJECT_MCP_SHADOW_PRECEDENCE',
        'MANUAL_REVIEW_UNKNOWN_PROJECT_MCP_CONFIG',
        'REVIEW_AND_REMOVE_ONLY_VERIFIED_GENERATED_DUPLICATION',
        'REVIEW_CURSOR_RULE_EXCERPT_BOUNDARY',
        'REVIEW_CURSOR_HOOK_PRECEDENCE',
        'REPAIR_USER_CLAUDE_BOOT_WITH_GENERATED_HOOK',
        'REVIEW_USER_MCP_CONFIG_WITHOUT_OUTPUTTING_VALUE',
        'VERIFY_IN_EFFECTIVE_CLIENT_UI',
        'MANUAL_REVIEW_REPARSE_CHILD_OUTSIDE_AUDIT'
    )
)
$ExpectedSources = @{
    'MIGRATE_CURSOR_RULE_WITH_SYNC_TOOL' = Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-project-pointer.mdc'
    'REPLACE_GENERATED_BOOT_REGION_WITH_POINTER' = Join-Path $RepoRoot 'bootpack\out\project\DREAMEROS_BOOT_CANON_POINTER.md.block'
    'REPLACE_LEGACY_GENERATOR_WITH_POINTER_STUB' = Join-Path $RepoRoot 'bootpack\out\project\DREAMEROS_CENTRAL_BOOT_GENERATOR_POINTER.ps1.block'
    'REPLACE_WITH_GENERATED_THIN_CLAUDE_HOOK' = Join-Path $RepoRoot 'bootpack\out\claude\dreameros-session-start.sh'
}
$AdapterSources = @{
    'answer-from-measurement.mdc' = Join-Path $RepoRoot 'bootpack\out\cursor\answer-from-measurement.adapter.mdc'
    'canon-equals-live.mdc' = Join-Path $RepoRoot 'bootpack\out\cursor\canon-equals-live.adapter.mdc'
    'dreameros-cold-start.mdc' = Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-cold-start.adapter.mdc'
    'dreameros-first.mdc' = Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-first.adapter.mdc'
}

function Get-BytesSha([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-RawSha([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file is missing: $Path" }
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Get-StringSha([string]$Text) {
    return Get-BytesSha $Utf8NoBom.GetBytes($Text)
}

function Read-StandardInputBytes([int64]$MaximumBytes) {
    $inputStream = [Console]::OpenStandardInput()
    $memory = New-Object IO.MemoryStream
    [byte[]]$buffer = New-Object byte[] 8192
    try {
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $memory.Write($buffer, 0, $read)
            if ($memory.Length -gt $MaximumBytes) { throw 'Standard-input migration plan exceeds the read-only size limit.' }
        }
        return $memory.ToArray()
    } finally {
        $memory.Dispose()
    }
}

function Read-StrictUtf8([string]$Path, [int64]$MaximumBytes, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label is missing." }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Label is a reparse-point file." }
    if ($item.Length -gt $MaximumBytes) { throw "$Label exceeds the read-only size limit." }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($item.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    [byte[]]$contentBytes = if ($hasBom) {
        if ($bytes.Length -eq 3) { @() } else { $bytes[3..($bytes.Length - 1)] }
    } else { $bytes }
    try { $text = $Utf8Strict.GetString($contentBytes) }
    catch { throw "$Label is not strict UTF-8." }
    if ($text.IndexOf([char]0) -ge 0) { throw "$Label contains binary NUL content." }
    return [pscustomobject]@{
        Path = $item.FullName
        Bytes = $bytes
        ContentBytes = $contentBytes
        Text = $text
        HasBom = $hasBom
        Sha256 = Get-BytesSha $bytes
    }
}

function ConvertFrom-StrictJsonText([string]$Text, [string]$Label) {
    if (-not ('DreamerOS.StrictJsonValidatorV1' -as [type])) {
        $source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace DreamerOS {
    public static class StrictJsonValidatorV1 {
        private sealed class Parser {
            private readonly string text;
            private int index;

            internal Parser(string value) {
                if (value == null) { throw new InvalidDataException("JSON text is null."); }
                text = value;
                index = 0;
            }

            internal void Validate() {
                SkipWhitespace();
                ParseValue(0);
                SkipWhitespace();
                if (index != text.Length) {
                    throw new InvalidDataException("Trailing JSON content is not allowed.");
                }
            }

            private void ParseValue(int depth) {
                if (depth > 64) {
                    throw new InvalidDataException("JSON nesting exceeds the depth limit.");
                }
                SkipWhitespace();
                if (index >= text.Length) {
                    throw new InvalidDataException("JSON value is incomplete.");
                }
                char current = text[index];
                if (current == '{') { ParseObject(depth + 1); return; }
                if (current == '[') { ParseArray(depth + 1); return; }
                if (current == '"') { ParseString(); return; }
                if (current == 't') { ParseLiteral("true"); return; }
                if (current == 'f') { ParseLiteral("false"); return; }
                if (current == 'n') { ParseLiteral("null"); return; }
                if (current == '-' || (current >= '0' && current <= '9')) { ParseNumber(); return; }
                throw new InvalidDataException("JSON contains an unexpected token.");
            }

            private void ParseObject(int depth) {
                Expect('{');
                SkipWhitespace();
                var keys = new HashSet<string>(StringComparer.Ordinal);
                if (TryConsume('}')) { return; }
                while (true) {
                    SkipWhitespace();
                    if (index >= text.Length || text[index] != '"') {
                        throw new InvalidDataException("JSON object key must be a string.");
                    }
                    string key = ParseString();
                    if (!keys.Add(key)) {
                        throw new InvalidDataException("Duplicate JSON object key is not allowed.");
                    }
                    SkipWhitespace();
                    Expect(':');
                    ParseValue(depth);
                    SkipWhitespace();
                    if (TryConsume('}')) { return; }
                    Expect(',');
                }
            }

            private void ParseArray(int depth) {
                Expect('[');
                SkipWhitespace();
                if (TryConsume(']')) { return; }
                while (true) {
                    ParseValue(depth);
                    SkipWhitespace();
                    if (TryConsume(']')) { return; }
                    Expect(',');
                }
            }

            private string ParseString() {
                Expect('"');
                var builder = new StringBuilder();
                while (index < text.Length) {
                    char current = text[index++];
                    if (current == '"') { return builder.ToString(); }
                    if (current < 0x20) {
                        throw new InvalidDataException("JSON string contains a control character.");
                    }
                    if (current != '\\') {
                        builder.Append(current);
                        continue;
                    }
                    if (index >= text.Length) {
                        throw new InvalidDataException("JSON escape is incomplete.");
                    }
                    char escaped = text[index++];
                    switch (escaped) {
                        case '"': builder.Append('"'); break;
                        case '\\': builder.Append('\\'); break;
                        case '/': builder.Append('/'); break;
                        case 'b': builder.Append('\b'); break;
                        case 'f': builder.Append('\f'); break;
                        case 'n': builder.Append('\n'); break;
                        case 'r': builder.Append('\r'); break;
                        case 't': builder.Append('\t'); break;
                        case 'u': builder.Append(ParseUnicodeEscape()); break;
                        default: throw new InvalidDataException("JSON string has an invalid escape.");
                    }
                }
                throw new InvalidDataException("JSON string is unterminated.");
            }

            private char ParseUnicodeEscape() {
                if (index + 4 > text.Length) {
                    throw new InvalidDataException("JSON Unicode escape is incomplete.");
                }
                int value = 0;
                for (int count = 0; count < 4; count++) {
                    char current = text[index++];
                    int digit;
                    if (current >= '0' && current <= '9') { digit = current - '0'; }
                    else if (current >= 'a' && current <= 'f') { digit = current - 'a' + 10; }
                    else if (current >= 'A' && current <= 'F') { digit = current - 'A' + 10; }
                    else { throw new InvalidDataException("JSON Unicode escape is invalid."); }
                    value = (value * 16) + digit;
                }
                return (char)value;
            }

            private void ParseNumber() {
                if (TryConsume('-') && index >= text.Length) {
                    throw new InvalidDataException("JSON number is incomplete.");
                }
                if (TryConsume('0')) {
                    if (index < text.Length && text[index] >= '0' && text[index] <= '9') {
                        throw new InvalidDataException("JSON number has a leading zero.");
                    }
                } else {
                    if (index >= text.Length || text[index] < '1' || text[index] > '9') {
                        throw new InvalidDataException("JSON number has no integer component.");
                    }
                    while (index < text.Length && text[index] >= '0' && text[index] <= '9') { index++; }
                }
                if (TryConsume('.')) {
                    int start = index;
                    while (index < text.Length && text[index] >= '0' && text[index] <= '9') { index++; }
                    if (index == start) { throw new InvalidDataException("JSON fraction has no digits."); }
                }
                if (index < text.Length && (text[index] == 'e' || text[index] == 'E')) {
                    index++;
                    if (index < text.Length && (text[index] == '+' || text[index] == '-')) { index++; }
                    int start = index;
                    while (index < text.Length && text[index] >= '0' && text[index] <= '9') { index++; }
                    if (index == start) { throw new InvalidDataException("JSON exponent has no digits."); }
                }
            }

            private void ParseLiteral(string literal) {
                if (index + literal.Length > text.Length ||
                    !string.Equals(text.Substring(index, literal.Length), literal, StringComparison.Ordinal)) {
                    throw new InvalidDataException("JSON literal is invalid.");
                }
                index += literal.Length;
            }

            private void SkipWhitespace() {
                while (index < text.Length) {
                    char current = text[index];
                    if (current == ' ' || current == '\t' || current == '\r' || current == '\n') { index++; }
                    else { return; }
                }
            }

            private bool TryConsume(char expected) {
                if (index < text.Length && text[index] == expected) { index++; return true; }
                return false;
            }

            private void Expect(char expected) {
                if (!TryConsume(expected)) {
                    throw new InvalidDataException("JSON punctuation is invalid.");
                }
            }
        }

        public static void Validate(string text) {
            new Parser(text).Validate();
        }
    }
}
'@
        try {
            Add-Type -TypeDefinition $source -IgnoreWarnings -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
        } catch {
            throw "Strict JSON support could not be initialized: $($_.Exception.Message)"
        }
    }
    try {
        [DreamerOS.StrictJsonValidatorV1]::Validate($Text)
        return ($Text | ConvertFrom-Json)
    } catch {
        throw "$Label failed strict JSON validation: $($_.Exception.Message)"
    }
}

function Read-StrictJson([string]$Path, [int64]$MaximumBytes, [string]$Label) {
    $file = Read-StrictUtf8 $Path $MaximumBytes $Label
    $value = ConvertFrom-StrictJsonText $file.Text $Label
    return [pscustomobject]@{ File = $file; Value = $value }
}

function Assert-ExactProperties($Object, [string[]]$Expected, [string]$Context) {
    if ($null -eq $Object) { throw "$Context is null." }
    [string[]]$actual = @($Object.PSObject.Properties.Name)
    [string[]]$wanted = @($Expected)
    [Array]::Sort($actual, [StringComparer]::Ordinal)
    [Array]::Sort($wanted, [StringComparer]::Ordinal)
    if (($actual -join "`n") -cne ($wanted -join "`n")) {
        throw "$Context has an unknown or missing property set."
    }
}

function Test-PathWithin([string]$Path, [string]$Parent) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return $full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith(($root + '\'), [StringComparison]::OrdinalIgnoreCase)
}

function Assert-LocalFileSystemPath([string]$Path, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '^[^:]+::' -or $Path.StartsWith('\\')) {
        throw "$Label must be a local filesystem path."
    }
    try { $full = [IO.Path]::GetFullPath($Path) }
    catch { throw "$Label is not a valid local filesystem path." }
    if ($full -notmatch '^[A-Za-z]:\\') { throw "$Label must use a local drive-letter path." }
    try { $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($full)) }
    catch { throw "$Label drive could not be verified as local." }
    if ($drive.DriveType -notin @([IO.DriveType]::Fixed, [IO.DriveType]::Removable, [IO.DriveType]::Ram)) {
        throw "$Label drive is not a verified local drive."
    }
    return $full
}

function Get-OwningRoot([string]$Path, [string[]]$Roots) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($root in @($Roots | Sort-Object Length -Descending)) {
        if (Test-PathWithin $full $root) { return [IO.Path]::GetFullPath($root).TrimEnd('\') }
    }
    return $null
}

function Assert-NoReparseTraversal([string]$Path, [string]$AllowedRoot) {
    $full = [IO.Path]::GetFullPath($Path)
    $current = if (Test-Path -LiteralPath $full) { $full } else { Split-Path -Parent $full }
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'A selected path crosses a reparse point.'
            }
        }
        if ([IO.Path]::GetFullPath($current).TrimEnd('\').Equals(
            $AllowedRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { return }
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }
        $current = $parent
    }
    throw 'A selected path could not be proven inside its allowed root.'
}

function Get-RelativePath([string]$Path, [string]$Root) {
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not $full.StartsWith(($parent + '\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Target escaped its repository root.'
    }
    $relative = $full.Substring($parent.Length).TrimStart('\').Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative.StartsWith('../') -or $relative.Contains('/../')) {
        throw 'Target has an invalid repository-relative path.'
    }
    return $relative
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

function Get-CurrentGitInfo([string]$Root) {
    $top = Invoke-Git $Root @('rev-parse', '--show-toplevel')
    $branch = Invoke-Git $Root @('branch', '--show-current')
    $head = Invoke-Git $Root @('rev-parse', 'HEAD')
    $origin = Invoke-Git $Root @('rev-parse', '--verify', 'origin/main')
    $counts = if ($origin.ExitCode -eq 0) { Invoke-Git $Root @('rev-list', '--left-right', '--count', 'HEAD...origin/main') } else { $null }
    $staged = Invoke-Git $Root @('diff', '--cached', '--name-only')
    $unstaged = Invoke-Git $Root @('diff', '--name-only')
    $untracked = Invoke-Git $Root @('ls-files', '--others', '--exclude-standard')
    if ($top.ExitCode -ne 0 -or $branch.ExitCode -ne 0 -or $head.ExitCode -ne 0 -or
        $staged.ExitCode -ne 0 -or $unstaged.ExitCode -ne 0 -or $untracked.ExitCode -ne 0) {
        return [pscustomobject]@{ state = 'UNREADABLE' }
    }
    $ahead = $null
    $behind = $null
    if ($origin.ExitCode -eq 0) {
        if ($counts.ExitCode -ne 0 -or $counts.Text -notmatch '^(?<ahead>\d+)\s+(?<behind>\d+)$') {
            return [pscustomobject]@{ state = 'UNREADABLE' }
        }
        $ahead = [int]$Matches.ahead
        $behind = [int]$Matches.behind
    }
    $stagedCount = if ([string]::IsNullOrWhiteSpace($staged.Text)) { 0 } else { @($staged.Text -split "`n").Count }
    $unstagedCount = if ([string]::IsNullOrWhiteSpace($unstaged.Text)) { 0 } else { @($unstaged.Text -split "`n").Count }
    $untrackedCount = if ([string]::IsNullOrWhiteSpace($untracked.Text)) { 0 } else { @($untracked.Text -split "`n").Count }
    return [pscustomobject]@{
        state = 'READ'
        top = [IO.Path]::GetFullPath($top.Text).TrimEnd('\')
        branch = $branch.Text
        head = $head.Text
        origin_main_tracking_ref = if ($origin.ExitCode -eq 0) { $origin.Text } else { $null }
        ahead_of_tracking_ref = $ahead
        behind_tracking_ref = $behind
        staged = $stagedCount
        unstaged = $unstagedCount
        untracked = $untrackedCount
        clean = ($stagedCount + $unstagedCount + $untrackedCount) -eq 0
    }
}

function Get-JsonStringValues($Value) {
    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        Write-Output $Value
        return
    }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { Get-JsonStringValues $Value[$key] }
        return
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) { Get-JsonStringValues $property.Value }
        return
    }
    if ($Value -is [Collections.IEnumerable]) {
        foreach ($item in $Value) { Get-JsonStringValues $item }
    }
}

function Get-RegistryState([string]$Root) {
    $seen = $false
    foreach ($relative in @('Governance\CANON_REGISTRY.json', 'governance\CANON_REGISTRY.json')) {
        $path = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $seen = $true
        try { $parsed = Read-StrictJson $path $MaxContentBytes 'Canon registry' }
        catch { return 'INVALID_JSON' }
        foreach ($value in @(Get-JsonStringValues $parsed.Value)) {
            $normalized = ([regex]::Replace($value.Replace('\', '/'), '/+', '/')).ToLowerInvariant()
            if ($normalized.Contains('.cursor/rules/dreameros-boot-canon.mdc')) { return 'TRACKS_RULE' }
        }
    }
    if ($seen) { return 'NO_REFERENCE' }
    return 'ABSENT'
}

function ConvertTo-CanonicalMetadataJson($Metadata) {
    $ordered = [ordered]@{}
    [string[]]$keys = @($Metadata.PSObject.Properties | ForEach-Object { $_.Name })
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    foreach ($key in $keys) { $ordered[$key] = $Metadata.$key }
    return ($ordered | ConvertTo-Json -Compress -Depth 4)
}

function Get-Count($Items, [string]$Kind, [string]$State = '') {
    return @($Items | Where-Object {
        $_.kind -eq $Kind -and ([string]::IsNullOrWhiteSpace($State) -or $_.state -eq $State)
    }).Count
}

function Assert-PlanReconciliation($Plan) {
    Assert-ExactProperties $Plan.audit_summary $SummaryProperties 'audit_summary'
    Assert-ExactProperties $Plan.parser_reconciliation $ReconciliationProperties 'parser_reconciliation'
    $repoFindings = @($Plan.repositories | ForEach-Object { @($_.findings) })
    $globalFindings = @($Plan.global_findings)
    $allFindings = @($repoFindings + $globalFindings)
    $computed = [ordered]@{
        surfaces = Get-Count $repoFindings 'BOOT_SURFACE'
        GLOBAL_ONLY = Get-Count $repoFindings 'BOOT_SURFACE' 'GLOBAL_ONLY'
        POINTER_ALIGNED = Get-Count $repoFindings 'BOOT_SURFACE' 'POINTER_ALIGNED'
        LEGACY_FULL_COPY = Get-Count $repoFindings 'BOOT_SURFACE' 'LEGACY_FULL_COPY'
        POINTER_DRIFT = Get-Count $repoFindings 'BOOT_SURFACE' 'POINTER_DRIFT'
        UNKNOWN = Get-Count $repoFindings 'BOOT_SURFACE' 'UNKNOWN'
        generators = Get-Count $repoFindings 'GENERATOR'
        SUPERSEDED_GENERATOR = Get-Count $repoFindings 'GENERATOR' 'SUPERSEDED_GENERATOR'
        LEGACY_FULL_GENERATOR = Get-Count $repoFindings 'GENERATOR' 'LEGACY_FULL_GENERATOR'
        UNKNOWN_GENERATOR = Get-Count $repoFindings 'GENERATOR' 'UNKNOWN_GENERATOR'
        adapters = Get-Count $repoFindings 'ADAPTER'
        ADAPTER_ALIGNED = Get-Count $repoFindings 'ADAPTER' 'ADAPTER_ALIGNED'
        ADAPTER_DRIFT = Get-Count $repoFindings 'ADAPTER' 'ADAPTER_DRIFT'
        STALE_ADAPTER_COPY = Get-Count $repoFindings 'ADAPTER' 'STALE_ADAPTER_COPY'
        ADAPTER_PATH_DRIFT = Get-Count $repoFindings 'ADAPTER' 'ADAPTER_PATH_DRIFT'
        claude_boot_hooks = Get-Count $repoFindings 'CLAUDE_BOOT_HOOK'
        BOOT_HOOK_ALIGNED = Get-Count $repoFindings 'CLAUDE_BOOT_HOOK' 'BOOT_HOOK_ALIGNED'
        STALE_BOOT_HOOK = Get-Count $repoFindings 'CLAUDE_BOOT_HOOK' 'STALE_BOOT_HOOK'
        BOOT_HOOK_OTHER = @($repoFindings | Where-Object { $_.kind -eq 'CLAUDE_BOOT_HOOK' -and $_.state -notin @('BOOT_HOOK_ALIGNED', 'STALE_BOOT_HOOK') }).Count
        project_mcp = Get-Count $repoFindings 'CURSOR_PROJECT_MCP'
        PROJECT_MCP_AUTH_HEADER = Get-Count $repoFindings 'CURSOR_PROJECT_MCP' 'PROJECT_MCP_AUTH_HEADER'
        PROJECT_MCP_SHADOW = Get-Count $repoFindings 'CURSOR_PROJECT_MCP' 'PROJECT_MCP_SHADOW'
        PROJECT_MCP_ENDPOINT_SHADOW = Get-Count $repoFindings 'CURSOR_PROJECT_MCP' 'PROJECT_MCP_ENDPOINT_SHADOW'
        LEGACY_PROJECT_MCP = Get-Count $repoFindings 'CURSOR_PROJECT_MCP' 'LEGACY_PROJECT_MCP'
        PROJECT_MCP_UNKNOWN = Get-Count $repoFindings 'CURSOR_PROJECT_MCP' 'PROJECT_MCP_CONFIG_UNKNOWN'
        embedded_excerpts = Get-Count $repoFindings 'DUPLICATE_EMBEDDED_EXCERPT'
        rule_excerpts = Get-Count $repoFindings 'DUPLICATE_RULE_EXCERPT'
        cursor_hook_shadows = Get-Count $allFindings 'CURSOR_HOOK'
        reparse_children = Get-Count $globalFindings 'ESTATE_REPARSE_CHILD'
        user_mcp_records = Get-Count $globalFindings 'CURSOR_USER_MCP'
        user_claude_boot_records = Get-Count $globalFindings 'USER_CLAUDE_BOOT'
        live_policy_records = Get-Count $globalFindings 'LIVE_POLICY'
    }
    foreach ($key in $ReconciliationProperties) {
        if ([int]$Plan.parser_reconciliation.$key -ne [int]$computed[$key]) {
            throw "Plan reconciliation mismatch at $key."
        }
    }
    $summaryMap = [ordered]@{
        repos = @($Plan.repositories).Count
        surfaces = $computed.surfaces
        GLOBAL_ONLY = $computed.GLOBAL_ONLY
        POINTER_ALIGNED = $computed.POINTER_ALIGNED
        LEGACY_FULL_COPY = $computed.LEGACY_FULL_COPY
        POINTER_DRIFT = $computed.POINTER_DRIFT
        UNKNOWN = $computed.UNKNOWN
        generators = $computed.generators
        LEGACY_FULL_GENERATOR = $computed.LEGACY_FULL_GENERATOR
        UNKNOWN_GENERATOR = $computed.UNKNOWN_GENERATOR
        ADAPTER_ALIGNED = $computed.ADAPTER_ALIGNED
        ADAPTER_DRIFT = $computed.ADAPTER_DRIFT
        STALE_ADAPTER_COPY = $computed.STALE_ADAPTER_COPY
        ADAPTER_PATH_DRIFT = $computed.ADAPTER_PATH_DRIFT
        CLAUDE_BOOT_HOOKS = $computed.claude_boot_hooks
        BOOT_HOOK_ALIGNED = $computed.BOOT_HOOK_ALIGNED
        STALE_BOOT_HOOK = $computed.STALE_BOOT_HOOK
        BOOT_HOOK_OTHER = $computed.BOOT_HOOK_OTHER
        PROJECT_MCP_RECORDS = $computed.project_mcp
        PROJECT_MCP_AUTH_HEADER = $computed.PROJECT_MCP_AUTH_HEADER
        PROJECT_MCP_SHADOW = $computed.PROJECT_MCP_SHADOW
        PROJECT_MCP_ENDPOINT_SHADOW = $computed.PROJECT_MCP_ENDPOINT_SHADOW
        LEGACY_PROJECT_MCP = $computed.LEGACY_PROJECT_MCP
        PROJECT_MCP_UNKNOWN = $computed.PROJECT_MCP_UNKNOWN
        CURSOR_HOOK_SHADOWS = $computed.cursor_hook_shadows
        REPARSE_CHILD_SKIPPED = $computed.reparse_children
        USER_MCP_RECORDS = $computed.user_mcp_records
        DUPLICATE_EMBEDDED_EXCERPT = $computed.embedded_excerpts
        DUPLICATE_RULE_EXCERPT = $computed.rule_excerpts
    }
    foreach ($key in $summaryMap.Keys) {
        if ([int]$Plan.audit_summary.$key -ne [int]$summaryMap[$key]) {
            throw "Audit summary mismatch at $key."
        }
    }
    $userBoot = @($globalFindings | Where-Object kind -eq 'USER_CLAUDE_BOOT')
    if ($userBoot.Count -ne 1 -or $Plan.audit_summary.USER_CLAUDE_BOOT -cne $userBoot[0].state) {
        throw 'USER_CLAUDE_BOOT summary mismatch.'
    }
    foreach ($policyName in @('CURSOR_TEAM_HOOK_POLICY', 'USER_CLAUDE_MANAGED_HOOK_POLICY')) {
        $policy = @($globalFindings | Where-Object { $_.kind -eq 'LIVE_POLICY' -and $_.name -eq $policyName })
        if ($policy.Count -ne 1 -or $Plan.audit_summary.$policyName -cne $policy[0].state) {
            throw "$policyName summary mismatch."
        }
    }
}

function Get-ExpectedSource([string]$Action, [string]$Target) {
    if ($Action -eq 'REPLACE_WITH_GENERATED_CURSOR_ADAPTER') {
        return $AdapterSources[[IO.Path]::GetFileName($Target)]
    }
    return $ExpectedSources[$Action]
}

function Assert-ActionTuple($Action, $Finding, [bool]$IsGlobal) {
    Assert-ExactProperties $Action $ActionProperties 'action'
    if ($KnownActions -notcontains [string]$Action.action) { throw 'Plan contains an unknown action class.' }
    if ([string]$Action.id -notmatch '^[a-f0-9]{16}$') { throw 'Action ID is not lowercase 16-hex.' }
    if ($Action.human_conductor_authorization_required -ne $true) { throw 'Action removed the Human Conductor gate.' }
    if ($Action.apply_status -notin @('HELD', 'BLOCKED')) { throw 'Action has an invalid apply status.' }
    if ($IsGlobal) {
        if ($Action.fresh_fetch_required -ne $false) { throw 'Global action has an invalid fetch gate.' }
    } elseif ($Action.fresh_fetch_required -ne $true) {
        throw 'Repository action removed the fresh-fetch gate.'
    }
    foreach ($note in @($Action.notes)) {
        if ($note -isnot [string]) { throw 'Action notes must be strings.' }
    }

    if ($null -ne $Finding -and $Finding.PSObject.Properties.Name -contains 'path') {
        $actionTarget = Assert-LocalFileSystemPath ([string]$Action.target) 'Action target'
        $findingPath = Assert-LocalFileSystemPath ([string]$Finding.path) 'Finding path'
        if (-not [string]::Equals($actionTarget, $findingPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Action target does not match its finding.'
        }
        $metadataJson = ConvertTo-CanonicalMetadataJson $Finding.metadata
        $expectedId = (Get-StringSha ($Action.action + '|' + $Finding.path + '|' + $Finding.state + '|' + $metadataJson)).Substring(0, 16)
        if ($Action.id -cne $expectedId) { throw 'Action ID does not match the finding identity.' }
    } elseif ($Action.action -in @('VERIFY_IN_EFFECTIVE_CLIENT_UI', 'MANUAL_REVIEW_REPARSE_CHILD_OUTSIDE_AUDIT')) {
        if ($null -eq $Finding -or $Action.target -cne $Finding.name) { throw 'Global action target does not match its finding.' }
        $expectedId = (Get-StringSha ($Action.action + '|' + $Finding.name)).Substring(0, 16)
        if ($Action.id -cne $expectedId) { throw 'Global action ID does not match the finding identity.' }
    } else {
        throw 'Global action has no supported finding identity.'
    }

    switch ([string]$Action.action) {
        'MIGRATE_CURSOR_RULE_WITH_SYNC_TOOL' {
            if ($Finding.kind -ne 'BOOT_SURFACE' -or $Finding.surface -ne 'CURSOR' -or $Finding.state -ne 'LEGACY_FULL_COPY') {
                throw 'Cursor-rule action does not match its sealed finding tuple.'
            }
        }
        'REPLACE_GENERATED_BOOT_REGION_WITH_POINTER' {
            if ($Finding.kind -ne 'BOOT_SURFACE' -or $Finding.surface -notin @('CLAUDE', 'CODEX') -or
                $Finding.state -notin @('LEGACY_FULL_COPY', 'POINTER_DRIFT')) {
                throw 'Generated-region action does not match its sealed finding tuple.'
            }
        }
        'REPLACE_LEGACY_GENERATOR_WITH_POINTER_STUB' {
            if ($Finding.kind -ne 'GENERATOR' -or $Finding.surface -ne 'GENERATOR' -or $Finding.state -ne 'LEGACY_FULL_GENERATOR') {
                throw 'Generator action does not match its sealed finding tuple.'
            }
        }
        'REPLACE_WITH_GENERATED_CURSOR_ADAPTER' {
            if ($Finding.kind -ne 'ADAPTER' -or $Finding.surface -ne 'CURSOR' -or
                $Finding.state -notin @('STALE_ADAPTER_COPY', 'ADAPTER_DRIFT')) {
                throw 'Adapter action does not match its sealed finding tuple.'
            }
        }
        'REPLACE_WITH_GENERATED_THIN_CLAUDE_HOOK' {
            $metadataNames = @($Finding.metadata.PSObject.Properties | ForEach-Object { $_.Name })
            if ($Finding.kind -ne 'CLAUDE_BOOT_HOOK' -or $Finding.surface -ne 'CLAUDE' -or
                $Finding.state -ne 'STALE_BOOT_HOOK' -or ($metadataNames -join ',') -cne 'registration' -or
                $Finding.metadata.registration -ne 'REGISTERED') {
                throw 'Claude-hook action does not match its sealed finding tuple.'
            }
        }
        'REMOVE_LEGACY_AUTHORIZATION_WITHOUT_OUTPUTTING_VALUE' {
            $metadataNames = @($Finding.metadata.PSObject.Properties | ForEach-Object { $_.Name })
            if ($Finding.kind -ne 'CURSOR_PROJECT_MCP' -or $Finding.surface -ne 'CURSOR' -or
                $Finding.state -ne 'PROJECT_MCP_AUTH_HEADER' -or ($metadataNames -join ',') -cne 'server') {
                throw 'MCP Authorization action does not match its sealed structural finding.'
            }
        }
    }

    $expectedSource = Get-ExpectedSource $Action.action $Action.target
    if ($RenderableActions -contains $Action.action) {
        if ($Action.apply_status -cne 'HELD') { throw 'Renderable action is not HELD.' }
        if ($null -eq $expectedSource -or $null -eq $Action.generated_source) { throw 'Renderable action is missing its generated source.' }
        Assert-ExactProperties $Action.generated_source $SourceProperties 'generated_source'
        $actualSource = Assert-LocalFileSystemPath ([string]$Action.generated_source.path) 'Generated source'
        $allowedSource = Assert-LocalFileSystemPath $expectedSource 'Allowed generated source'
        if (-not $actualSource.Equals($allowedSource, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Generated source escaped its action allowlist.'
        }
        Assert-NoReparseTraversal $actualSource $RepoRoot
        $sourceHash = Get-RawSha $actualSource
        if ([string]$Action.generated_source.sha256 -cne $sourceHash) { throw 'Generated source SHA-256 does not match the sealed plan.' }
    } elseif ($Action.action -eq 'REPAIR_USER_CLAUDE_BOOT_WITH_GENERATED_HOOK') {
        if ($IsGlobal -ne $true -or $Action.apply_status -cne 'BLOCKED') { throw 'User Claude repair is not safely blocked.' }
        Assert-ExactProperties $Action.generated_source $SourceProperties 'blocked user Claude generated_source'
        $expectedUserSource = Assert-LocalFileSystemPath $ExpectedSources['REPLACE_WITH_GENERATED_THIN_CLAUDE_HOOK'] 'Allowed user Claude source'
        $actualUserSource = Assert-LocalFileSystemPath ([string]$Action.generated_source.path) 'Blocked user Claude source'
        if (-not $actualUserSource.Equals($expectedUserSource, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$Action.generated_source.sha256 -cne (Get-RawSha $actualUserSource)) {
            throw 'Blocked user Claude source does not match the generated hook.'
        }
    } elseif ($null -ne $Action.generated_source) {
        throw 'A metadata-only action unexpectedly contains generated content.'
    }
}

function Assert-FindingTuple($Finding, [string]$RepositoryRoot, [string[]]$AllowedRoots) {
    Assert-ExactProperties $Finding $FindingProperties 'repository finding'
    if ($Finding.ownership -notin @('FILE-CLEAN', 'DIRTY') -or
        (($Finding.ownership -eq 'DIRTY') -ne [bool]$Finding.dirty)) {
        throw 'Finding ownership and dirty flag disagree.'
    }
    $path = Assert-LocalFileSystemPath ([string]$Finding.path) 'Finding path'
    $allowed = Get-OwningRoot $path $AllowedRoots
    if (-not $allowed -or -not [string]::Equals($allowed, [IO.Path]::GetFullPath($Finding.allowed_root).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Finding allowed-root metadata is invalid.'
    }
    Assert-NoReparseTraversal $path $allowed
    $relative = Get-RelativePath $path $RepositoryRoot
    $valid = switch ($Finding.kind) {
        'BOOT_SURFACE' {
            ($Finding.surface -eq 'CLAUDE' -and $relative -ceq 'CLAUDE.md') -or
            ($Finding.surface -eq 'CODEX' -and $relative -ceq 'AGENTS.md') -or
            ($Finding.surface -eq 'CURSOR' -and $relative -ceq '.cursor/rules/dreameros-boot-canon.mdc')
        }
        'GENERATOR' { $Finding.surface -eq 'GENERATOR' -and $relative -ieq 'governance/bootpack/build-boot-pack.ps1' }
        'ADAPTER' { $Finding.surface -eq 'CURSOR' -and $relative -match '^\.cursor/rules/(?:answer-from-measurement|canon-equals-live|dreameros-cold-start|dreameros-first)\.mdc$' }
        'CLAUDE_BOOT_HOOK' { $Finding.surface -eq 'CLAUDE' -and $relative -ceq '.claude/hooks/dreameros-session-start.sh' }
        'CURSOR_PROJECT_MCP' { $Finding.surface -eq 'CURSOR' -and $relative -ceq '.cursor/mcp.json' }
        'DUPLICATE_EMBEDDED_EXCERPT' { $relative -in @('CLAUDE.md', 'AGENTS.md') }
        'DUPLICATE_RULE_EXCERPT' { $relative -match '^\.cursor/rules/[^/]+\.mdc$' }
        'CURSOR_HOOK' { $relative -ceq '.cursor/hooks.json' }
        default { $false }
    }
    if (-not $valid) { throw 'Finding kind, surface, and repository-relative path disagree.' }
}

function Get-ExpectedPlanState($Repository) {
    $actionCount = @($Repository.actions).Count
    $dirtyActionCount = @($Repository.findings | Where-Object dirty).Count
    $dirtyWorktree = $Repository.git.state -eq 'READ' -and -not $Repository.git.clean
    $manualBlock = @($Repository.actions | Where-Object apply_status -eq 'BLOCKED').Count -gt 0
    $registryBlock = $Repository.cursor_rule_registry -in @('TRACKS_RULE', 'INVALID_JSON')
    if ($actionCount -eq 0) { return 'NO_MIGRATION_ACTION' }
    if ($Repository.git.state -ne 'READ') { return 'BLOCKED_GIT_STATE' }
    if ($dirtyActionCount -gt 0 -or $dirtyWorktree) { return 'BLOCKED_DIRTY' }
    if ($manualBlock) { return 'MANUAL_REVIEW_BLOCKED' }
    if ($registryBlock) { return 'ATOMIC_REGISTRY_REVIEW_REQUIRED' }
    return 'REVIEW_REQUIRED'
}

function Get-TextInfo([string]$Path, [string]$Label) {
    $file = Read-StrictUtf8 $Path $MaxContentBytes $Label
    $crlf = [regex]::Matches($file.Text, "`r`n").Count
    $withoutCrlf = $file.Text.Replace("`r`n", '')
    $bareCr = [regex]::Matches($withoutCrlf, "`r").Count
    $bareLf = [regex]::Matches($withoutCrlf, "`n").Count
    if ($bareCr -gt 0 -or ($crlf -gt 0 -and $bareLf -gt 0)) { throw "$Label has mixed or unsupported line endings." }
    $newline = if ($crlf -gt 0) { "`r`n" } else { "`n" }
    $normalized = $file.Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $endsNewline = $normalized.EndsWith("`n")
    if ($normalized.Length -eq 0) {
        $lines = @()
    } else {
        $parts = @([regex]::Split($normalized, "`n"))
        if ($endsNewline) {
            $lines = if ($parts.Count -le 1) { @() } else { @($parts[0..($parts.Count - 2)]) }
        } else { $lines = $parts }
    }
    return [pscustomobject]@{
        File = $file
        Newline = $newline
        Normalized = $normalized
        Lines = @($lines)
        EndsNewline = $endsNewline
    }
}

function Convert-TextToBytes([string]$Text, [bool]$HasBom) {
    [byte[]]$content = $Utf8NoBom.GetBytes($Text)
    if (-not $HasBom) { return $content }
    [byte[]]$bom = @(0xEF, 0xBB, 0xBF)
    return [byte[]]($bom + $content)
}

function Test-StrongCredentialShape([string]$Text) {
    return $Text -match '(?im)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' -or
        $Text -match '(?im)\bBearer\s+[A-Za-z0-9._~+/=-]{16,}' -or
        $Text -match '(?im)\b(?:authorization|api[_-]?key|token|secret|password)\s*[:=]\s*["'']?(?:Bearer\s+)?[A-Za-z0-9._~+/=-]{16,}' -or
        $Text -match '(?im)\bsk-(?:proj-)?[A-Za-z0-9_-]{16,}'
}

function Get-SemanticSha([string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    return Get-BytesSha $Utf8NoBom.GetBytes($normalized)
}

function Add-DiffLine([Text.StringBuilder]$Builder, [string]$Prefix, [string]$Line) {
    [void]$Builder.Append($Prefix)
    [void]$Builder.Append($Line)
    [void]$Builder.Append("`n")
}

function Get-PatchLine([string]$Line, [bool]$UseCrLfTerminator) {
    if ($UseCrLfTerminator) { return $Line + "`r" }
    return $Line
}

function ConvertTo-EngineStableJson($Value) {
    $json = $Value | ConvertTo-Json -Compress -Depth 14
    $builder = New-Object Text.StringBuilder
    $index = 0
    while ($index -lt $json.Length) {
        if ($json[$index] -ne '\') {
            [void]$builder.Append($json[$index])
            $index++
            continue
        }
        $runStart = $index
        while ($index -lt $json.Length -and $json[$index] -eq '\') { $index++ }
        $slashCount = $index - $runStart
        $unicodeEscape = $slashCount % 2 -eq 1 -and $index + 5 -le $json.Length -and $json[$index] -eq 'u'
        $code = if ($unicodeEscape) { $json.Substring($index + 1, 4).ToLowerInvariant() } else { '' }
        $replacement = switch ($code) {
            '0027' { "'" }
            '0026' { '&' }
            '003c' { '<' }
            '003e' { '>' }
            default { $null }
        }
        if ($null -ne $replacement) {
            [void]$builder.Append(('\' * ($slashCount - 1)))
            [void]$builder.Append($replacement)
            $index += 5
        } else {
            [void]$builder.Append(('\' * $slashCount))
        }
    }
    return $builder.ToString()
}

function New-WholeFileDiff($TargetInfo, $SourceInfo, [string]$Relative) {
    if (Test-StrongCredentialShape $TargetInfo.File.Text) { throw 'Target contains a credential-value shape; content diff withheld.' }
    if (Test-StrongCredentialShape $SourceInfo.File.Text) { throw 'Generated source contains a credential-value shape; content diff withheld.' }
    if ($TargetInfo.File.Sha256 -ceq $SourceInfo.File.Sha256) { throw 'Target already equals the generated source; sealed action is stale.' }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append("--- a/$Relative`n+++ b/$Relative`n")
    [void]$builder.Append("@@ -1,$(@($TargetInfo.Lines).Count) +1,$(@($SourceInfo.Lines).Count) @@`n")
    for ($index = 0; $index -lt @($TargetInfo.Lines).Count; $index++) {
        $terminated = $index -lt @($TargetInfo.Lines).Count - 1 -or $TargetInfo.EndsNewline
        Add-DiffLine $builder '-' (Get-PatchLine $TargetInfo.Lines[$index] ($TargetInfo.Newline -eq "`r`n" -and $terminated))
        if ($index -eq @($TargetInfo.Lines).Count - 1 -and -not $TargetInfo.EndsNewline) {
            [void]$builder.Append("\ No newline at end of file`n")
        }
    }
    for ($index = 0; $index -lt @($SourceInfo.Lines).Count; $index++) {
        $terminated = $index -lt @($SourceInfo.Lines).Count - 1 -or $SourceInfo.EndsNewline
        Add-DiffLine $builder '+' (Get-PatchLine $SourceInfo.Lines[$index] ($SourceInfo.Newline -eq "`r`n" -and $terminated))
        if ($index -eq @($SourceInfo.Lines).Count - 1 -and -not $SourceInfo.EndsNewline) {
            [void]$builder.Append("\ No newline at end of file`n")
        }
    }
    return [pscustomobject]@{
        Diff = $builder.ToString()
        OriginalSha256 = $TargetInfo.File.Sha256
        ProposedSha256 = $SourceInfo.File.Sha256
        OriginalBytes = $TargetInfo.File.Bytes.Length
        ProposedBytes = $SourceInfo.File.Bytes.Length
        OutsideRegionVerified = $null
    }
}

function Test-ByteSegment([byte[]]$Whole, [int]$Offset, [byte[]]$Expected) {
    if ($Offset -lt 0 -or $Offset + $Expected.Length -gt $Whole.Length) { return $false }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Whole[$Offset + $index] -ne $Expected[$index]) { return $false }
    }
    return $true
}

function New-RegionDiff($TargetInfo, $SourceInfo, [string]$Relative, [string]$ClaimedState) {
    $fullPattern = '<!-- BEGIN DREAMEROS-BOOT-CANON v[0-9]+\.[0-9]+\.[0-9]+[\s\S]*?<!-- END DREAMEROS-BOOT-CANON v[0-9]+\.[0-9]+\.[0-9]+ -->'
    $pointerPattern = '<!-- DREAMEROS-BOOT-CANON: NOT DUPLICATED HERE -->[\s\S]*?<!-- END DREAMEROS-BOOT-CANON POINTER -->'
    $full = [regex]::Matches($TargetInfo.File.Text, $fullPattern)
    $pointer = [regex]::Matches($TargetInfo.File.Text, $pointerPattern)
    if ($ClaimedState -eq 'LEGACY_FULL_COPY') {
        if ($full.Count -ne 1 -or $pointer.Count -ne 0) { throw 'Legacy generated-region boundaries no longer match the sealed finding.' }
        $match = $full[0]
    } elseif ($ClaimedState -eq 'POINTER_DRIFT') {
        if ($full.Count -ne 0 -or $pointer.Count -ne 1) { throw 'Pointer-region boundaries no longer match the sealed finding.' }
        $match = $pointer[0]
    } else { throw 'Region action has an invalid claimed state.' }
    $before = $TargetInfo.File.Text.Substring(0, $match.Index)
    $after = $TargetInfo.File.Text.Substring($match.Index + $match.Length)
    if (($before.Length -gt 0 -and -not ($before.EndsWith("`n") -or $before.EndsWith("`r"))) -or
        ($after.Length -gt 0 -and -not ($after.StartsWith("`n") -or $after.StartsWith("`r")))) {
        throw 'Generated-region markers are not on complete line boundaries.'
    }
    $replacement = $SourceInfo.File.Text.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($TargetInfo.Newline -eq "`r`n") { $replacement = $replacement.Replace("`n", "`r`n") }
    $proposedText = $before + $replacement + $after
    [byte[]]$proposedBytes = Convert-TextToBytes $proposedText $TargetInfo.File.HasBom
    [byte[]]$prefixBytes = $Utf8NoBom.GetBytes($before)
    [byte[]]$suffixBytes = $Utf8NoBom.GetBytes($after)
    $content = $TargetInfo.File.ContentBytes
    $prefixSame = Test-ByteSegment $content 0 $prefixBytes
    $suffixSame = Test-ByteSegment $content ($content.Length - $suffixBytes.Length) $suffixBytes
    if (-not $prefixSame -or -not $suffixSame) { throw 'Byte preservation outside the generated region could not be proved.' }

    $oldRegionText = $match.Value.Replace("`r`n", "`n").Replace("`r", "`n")
    $newRegionText = $SourceInfo.File.Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $oldRegionLines = @([regex]::Split($oldRegionText, "`n"))
    $newRegionLines = @([regex]::Split($newRegionText, "`n"))
    $oldLines = @($TargetInfo.Lines)
    $proposedInfo = [pscustomobject]@{
        File = [pscustomobject]@{ Text = $proposedText; Sha256 = Get-BytesSha $proposedBytes; Bytes = $proposedBytes }
        Normalized = $proposedText.Replace("`r`n", "`n").Replace("`r", "`n")
        Lines = @()
        EndsNewline = $proposedText.EndsWith("`n") -or $proposedText.EndsWith("`r")
    }
    $proposedParts = @([regex]::Split($proposedInfo.Normalized, "`n"))
    $proposedInfo.Lines = if ($proposedInfo.EndsNewline) {
        if ($proposedParts.Count -le 1) { @() } else { @($proposedParts[0..($proposedParts.Count - 2)]) }
    } else { $proposedParts }
    $oldStart = [regex]::Matches($before.Replace("`r`n", "`n").Replace("`r", "`n"), "`n").Count
    $contextBefore = [Math]::Min(3, $oldStart)
    $oldAfterStart = $oldStart + $oldRegionLines.Count
    $contextAfter = [Math]::Min(3, $oldLines.Count - $oldAfterStart)
    $hunkStart = $oldStart - $contextBefore
    $oldCount = $contextBefore + $oldRegionLines.Count + $contextAfter
    $newCount = $contextBefore + $newRegionLines.Count + $contextAfter
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append("--- a/$Relative`n+++ b/$Relative`n")
    [void]$builder.Append("@@ -$($hunkStart + 1),$oldCount +$($hunkStart + 1),$newCount @@`n")
    $targetCrLf = $TargetInfo.Newline -eq "`r`n"
    for ($index = $hunkStart; $index -lt $oldStart; $index++) {
        Add-DiffLine $builder ' ' (Get-PatchLine $oldLines[$index] $targetCrLf)
    }
    for ($index = 0; $index -lt $oldRegionLines.Count; $index++) {
        $terminated = $index -lt $oldRegionLines.Count - 1 -or $after.Length -gt 0 -or $TargetInfo.EndsNewline
        Add-DiffLine $builder '-' (Get-PatchLine $oldRegionLines[$index] ($targetCrLf -and $terminated))
    }
    for ($index = 0; $index -lt $newRegionLines.Count; $index++) {
        $terminated = $index -lt $newRegionLines.Count - 1 -or $after.Length -gt 0 -or $proposedInfo.EndsNewline
        Add-DiffLine $builder '+' (Get-PatchLine $newRegionLines[$index] ($targetCrLf -and $terminated))
    }
    for ($index = $oldAfterStart; $index -lt ($oldAfterStart + $contextAfter); $index++) {
        $terminated = $index -lt $oldLines.Count - 1 -or $TargetInfo.EndsNewline
        Add-DiffLine $builder ' ' (Get-PatchLine $oldLines[$index] ($targetCrLf -and $terminated))
    }
    if (($oldAfterStart + $contextAfter) -eq $oldLines.Count -and -not $TargetInfo.EndsNewline) {
        [void]$builder.Append("\ No newline at end of file`n")
    }
    if (Test-StrongCredentialShape $builder.ToString()) { throw 'Rendered hunk contains a credential-value shape; content diff withheld.' }
    return [pscustomobject]@{
        Diff = $builder.ToString()
        OriginalSha256 = $TargetInfo.File.Sha256
        ProposedSha256 = $proposedInfo.File.Sha256
        OriginalBytes = $TargetInfo.File.Bytes.Length
        ProposedBytes = $proposedBytes.Length
        OutsideRegionVerified = $true
    }
}

function Get-ClaudeHookRegistration([string]$Root) {
    $registrations = @()
    $otherDreamerOsHooks = @()
    $hooksDisabled = $false
    $managedOnly = $false
    foreach ($relative in @('.claude\settings.json', '.claude\settings.local.json')) {
        $path = Join-Path $Root $relative
        Assert-NoReparseTraversal $path $Root
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try { $settings = (Read-StrictJson $path $MaxContentBytes 'Claude project settings').Value }
        catch { return 'UNKNOWN' }
        if ($settings.PSObject.Properties.Name -contains 'disableAllHooks' -and $settings.disableAllHooks -eq $true) { $hooksDisabled = $true }
        if ($settings.PSObject.Properties.Name -contains 'allowManagedHooksOnly' -and $settings.allowManagedHooksOnly -eq $true) { $managedOnly = $true }
        $sessionStart = @()
        if ($settings.PSObject.Properties.Name -contains 'hooks' -and $null -ne $settings.hooks -and
            $settings.hooks.PSObject.Properties.Name -contains 'SessionStart') {
            $sessionStart = @($settings.hooks.SessionStart)
        }
        foreach ($entry in $sessionStart) {
            foreach ($hook in @($entry.hooks)) {
                if ($null -eq $hook -or $hook.type -ne 'command' -or $hook.command -isnot [string]) { continue }
                if ($hook.command -match '(?i)^\s*(?:bash|sh)\s+["'']?\$(?:\{)?CLAUDE_PROJECT_DIR(?:\})?[\\/]\.claude[\\/]hooks[\\/]dreameros-session-start\.sh["'']?\s*$') {
                    $registrations += $hook.command
                } elseif ($hook.command -match '(?i)dreameros|dreamer[_-]?os|hydration') {
                    $otherDreamerOsHooks += $hook.command
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

function Assert-CurrentClassification($Action, $Finding, $TargetInfo, $SourceInfo, [string]$RepositoryRoot) {
    switch ($Action.action) {
        'MIGRATE_CURSOR_RULE_WITH_SYNC_TOOL' {
            if ($Finding.kind -ne 'BOOT_SURFACE' -or $Finding.surface -ne 'CURSOR' -or $Finding.state -ne 'LEGACY_FULL_COPY') {
                throw 'Cursor-rule action tuple is invalid.'
            }
            $text = $TargetInfo.File.Text.Replace("`r`n", "`n").Replace("`r", "`n")
            if ($text.Length -lt 5000 -or
                $text -notmatch '(?m)^alwaysApply:\s*true\s*$' -or
                $text -notmatch '(?m)^# DreamerOS Boot Canon v[0-9]+\.[0-9]+\.[0-9]+\s*$' -or
                -not $text.Contains('SINGLE SOURCE OF TRUTH. Every vendor file is generated from this one.') -or
                -not $text.Contains('HC-DEFINITION-OF-DONE')) {
                throw 'Cursor rule no longer classifies as a clean legacy full copy.'
            }
        }
        'REPLACE_GENERATED_BOOT_REGION_WITH_POINTER' {
            if ($Finding.kind -ne 'BOOT_SURFACE' -or $Finding.surface -notin @('CLAUDE', 'CODEX') -or
                $Finding.state -notin @('LEGACY_FULL_COPY', 'POINTER_DRIFT')) {
                throw 'Embedded-region action tuple is invalid.'
            }
        }
        'REPLACE_LEGACY_GENERATOR_WITH_POINTER_STUB' {
            if ($Finding.kind -ne 'GENERATOR' -or $Finding.state -ne 'LEGACY_FULL_GENERATOR' -or
                $TargetInfo.File.Text -notmatch 'cursor[\\/]dreameros-boot-canon\.mdc') {
                throw 'Generator no longer classifies as a legacy full generator.'
            }
        }
        'REPLACE_WITH_GENERATED_CURSOR_ADAPTER' {
            if ($Finding.kind -ne 'ADAPTER' -or $Finding.surface -ne 'CURSOR' -or
                $Finding.state -notin @('STALE_ADAPTER_COPY', 'ADAPTER_DRIFT')) {
                throw 'Adapter action tuple is invalid.'
            }
            $aligned = (Get-SemanticSha $TargetInfo.File.Text) -ceq (Get-SemanticSha $SourceInfo.File.Text)
            $hasMarker = $TargetInfo.File.Text.Contains('DREAMEROS-CURSOR-ENFORCEMENT-ADAPTER') -or
                $TargetInfo.File.Text.Contains('DREAMEROS-CURSOR-PROJECT-ADAPTER')
            if ($aligned -or ($Finding.state -eq 'ADAPTER_DRIFT' -and -not $hasMarker) -or
                ($Finding.state -eq 'STALE_ADAPTER_COPY' -and $hasMarker)) {
                throw 'Adapter classification no longer matches the sealed finding.'
            }
        }
        'REPLACE_WITH_GENERATED_THIN_CLAUDE_HOOK' {
            if ($Finding.kind -ne 'CLAUDE_BOOT_HOOK' -or $Finding.surface -ne 'CLAUDE' -or
                $Finding.state -ne 'STALE_BOOT_HOOK' -or $Finding.metadata.registration -ne 'REGISTERED') {
                throw 'Claude-hook action tuple is invalid.'
            }
            if ((Get-ClaudeHookRegistration $RepositoryRoot) -ne 'REGISTERED' -or
                (Get-SemanticSha $TargetInfo.File.Text) -ceq (Get-SemanticSha $SourceInfo.File.Text) -or
                $TargetInfo.File.Text.Contains('DREAMEROS-CLAUDE-SESSION-START-ADAPTER')) {
                throw 'Claude hook no longer classifies as a registered stale hook.'
            }
        }
    }
}

function Test-SnapshotMatch($PlannedGit, $CurrentGit, [string]$RepositoryRoot) {
    if ($CurrentGit.state -ne 'READ' -or
        -not $CurrentGit.top.Equals([IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    foreach ($property in @(
        'branch', 'head', 'origin_main_tracking_ref', 'ahead_of_tracking_ref', 'behind_tracking_ref',
        'staged', 'unstaged', 'untracked', 'clean'
    )) {
        if ([string]$CurrentGit.$property -cne [string]$PlannedGit.$property) { return $false }
    }
    return $CurrentGit.clean -eq $true
}

# Load and authenticate the same plan bytes that will be parsed before any
# target content is read.
if ($PSCmdlet.ParameterSetName -eq 'StandardInput') {
    [byte[]]$transportBytes = Read-StandardInputBytes ($MaxPlanBytes + 3)
    if ($transportBytes.Length -eq 0) { throw 'Standard-input migration plan is empty.' }
    if ($transportBytes.Length -ge 2 -and (
        ($transportBytes[0] -eq 0xFF -and $transportBytes[1] -eq 0xFE) -or
        ($transportBytes[0] -eq 0xFE -and $transportBytes[1] -eq 0xFF)
    )) { throw 'Standard-input migration plan must use UTF-8, not UTF-16.' }
    $hasUtf8Bom = $transportBytes.Length -ge 3 -and
        $transportBytes[0] -eq 0xEF -and $transportBytes[1] -eq 0xBB -and $transportBytes[2] -eq 0xBF
    [byte[]]$planBytes = if ($hasUtf8Bom) {
        if ($transportBytes.Length -eq 3) { @() } else { $transportBytes[3..($transportBytes.Length - 1)] }
    } else { $transportBytes }
    if ($planBytes.Length -eq 0) { throw 'Standard-input migration plan is empty.' }
    if ($planBytes.Length -gt $MaxPlanBytes) { throw 'Standard-input migration plan exceeds the read-only size limit.' }
    try { $planText = $Utf8Strict.GetString($planBytes) }
    catch { throw 'Standard-input migration plan is not strict UTF-8.' }
    if ($planText.IndexOf([char]0) -ge 0) { throw 'Standard-input migration plan contains binary NUL content.' }
    $planHash = Get-BytesSha $planBytes
    $Plan = ConvertFrom-StrictJsonText $planText 'Migration plan'
    $resolvedPlanPath = '<standard-input>'
} else {
    $planCandidate = Assert-LocalFileSystemPath $PlanPath 'Plan path'
    Assert-NoReparseTraversal $planCandidate ([IO.Path]::GetPathRoot($planCandidate))
    $resolvedPlanPath = (Resolve-Path -LiteralPath $planCandidate).Path
    $parsedPlan = Read-StrictJson $resolvedPlanPath $MaxPlanBytes 'Migration plan'
    $planHash = $parsedPlan.File.Sha256
    $Plan = $parsedPlan.Value
}
if ($planHash -cne $ExpectedPlanSha256.ToLowerInvariant()) { throw 'Plan SHA-256 does not match the independent receipt.' }
Assert-ExactProperties $Plan $TopLevelProperties 'migration plan'
if ([int]$Plan.schema_version -ne 1) { throw 'Unsupported migration-plan schema version.' }
if ($Plan.mode -cne 'READ_ONLY_NO_FETCH_NO_PROJECT_WRITE') { throw 'Migration plan is not the required read-only mode.' }
if ($Plan.audit_outcome -notin @('PASS', 'FINDINGS', 'CAPTURED') -or $Plan.audit_reported_outcome -notin @('PASS', 'FINDINGS')) {
    throw 'Migration plan has an invalid audit outcome.'
}
if ($Plan.overall_state -notin @('PARTIAL', 'NO_ACTION')) { throw 'Migration plan has an invalid overall state.' }
$generatedUtc = [DateTimeOffset]::MinValue
if ($Plan.generated_utc -is [DateTime]) {
    if ($Plan.generated_utc.Kind -ne [DateTimeKind]::Utc) { throw 'Migration plan generated_utc must use UTC.' }
    $generatedUtc = New-Object DateTimeOffset($Plan.generated_utc)
} elseif (-not [DateTimeOffset]::TryParse(
    [string]$Plan.generated_utc,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind,
    [ref]$generatedUtc
)) { throw 'Migration plan has an invalid generated_utc value.' }
if ($generatedUtc.Offset -ne [TimeSpan]::Zero) { throw 'Migration plan generated_utc must use UTC.' }
$planAge = [DateTimeOffset]::UtcNow - $generatedUtc
if ($planAge.TotalMinutes -lt -1) { throw 'Migration plan timestamp is in the future.' }
if ($planAge.TotalMinutes -gt 5) { throw 'Migration plan is older than the five-minute dynamic-state limit.' }
if (@($Plan.missing_estate_roots).Count -ne 0) { throw 'Migration plan contains missing estate roots.' }
if (@($Plan.requested_estate_roots).Count -eq 0 -or
    @($Plan.requested_estate_roots).Count -ne @($Plan.resolved_estate_roots).Count) {
    throw 'Migration plan estate-root accounting is invalid.'
}
$AllowedRoots = @()
foreach ($root in @($Plan.resolved_estate_roots)) {
    $full = (Assert-LocalFileSystemPath ([string]$root) 'Estate root').TrimEnd('\')
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw 'A sealed estate root no longer exists.' }
    $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $full).Path).TrimEnd('\')
    if (-not $full.Equals($resolved, [StringComparison]::OrdinalIgnoreCase)) { throw 'A sealed estate root now resolves elsewhere.' }
    Assert-NoReparseTraversal $full $full
    $AllowedRoots += $full
}
[string[]]$rootUniqueness = @($AllowedRoots | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
if ($rootUniqueness.Count -ne $AllowedRoots.Count) { throw 'Migration plan contains duplicate estate roots.' }
if (@($Plan.held_back).Count -ne $ExpectedHeldBack.Count) { throw 'Migration plan held-back contract changed.' }
for ($index = 0; $index -lt $ExpectedHeldBack.Count; $index++) {
    if ([string]$Plan.held_back[$index] -cne $ExpectedHeldBack[$index]) { throw 'Migration plan held-back contract changed.' }
}

$actionIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$repoKeys = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($repo in @($Plan.repositories)) {
    Assert-ExactProperties $repo $RepositoryProperties 'repository'
    Assert-ExactProperties $repo.git $GitProperties 'repository git snapshot'
    if ($repo.git.state -cne 'READ' -or $repo.git.fresh_fetch_required -ne $true) {
        throw 'Renderer accepts only fully readable repository snapshots with the fetch gate retained.'
    }
    $repoPath = (Assert-LocalFileSystemPath ([string]$repo.path) 'Repository path').TrimEnd('\')
    if (-not $repoKeys.Add($repoPath)) { throw 'Migration plan contains a duplicate repository.' }
    if ((Split-Path -Leaf $repoPath) -cne [string]$repo.name) { throw 'Repository name does not match its path.' }
    $repoAllowedRoot = Get-OwningRoot $repoPath $AllowedRoots
    if (-not $repoAllowedRoot) { throw 'Repository escaped every sealed estate root.' }
    Assert-NoReparseTraversal $repoPath $repoAllowedRoot
    if ($repo.cursor_rule_registry -notin @('ABSENT', 'NO_REFERENCE', 'TRACKS_RULE', 'INVALID_JSON')) {
        throw 'Repository has an unknown registry state.'
    }
    foreach ($finding in @($repo.findings)) { Assert-FindingTuple $finding $repoPath $AllowedRoots }
    $boot = @($repo.findings | Where-Object kind -eq 'BOOT_SURFACE')
    if ($boot.Count -ne 3 -or (@($boot.surface | Sort-Object) -join ',') -cne 'CLAUDE,CODEX,CURSOR') {
        throw 'Repository does not have exactly three reconciled boot surfaces.'
    }
    foreach ($action in @($repo.actions)) {
        if (-not $actionIds.Add([string]$action.id)) { throw 'Migration plan contains a duplicate action ID.' }
        $finding = @($repo.findings | Where-Object action_id -eq $action.id)
        if ($finding.Count -ne 1) { throw 'Repository action does not resolve to exactly one finding.' }
        Assert-ActionTuple $action $finding[0] $false
    }
    foreach ($finding in @($repo.findings | Where-Object { $null -ne $_.action_id })) {
        if (@($repo.actions | Where-Object id -eq $finding.action_id).Count -ne 1) { throw 'Finding action link is unresolved.' }
    }
    $expectedState = Get-ExpectedPlanState $repo
    if ($repo.plan_state -cne $expectedState) { throw 'Repository plan state does not reconcile.' }
}

foreach ($finding in @($Plan.global_findings)) {
    if ($finding.kind -in @('LIVE_POLICY', 'ESTATE_REPARSE_CHILD')) {
        Assert-ExactProperties $finding $PolicyFindingProperties 'global policy or boundary finding'
    } else {
        Assert-ExactProperties $finding $FindingProperties 'global file finding'
    }
}
foreach ($action in @($Plan.global_actions)) {
    if (-not $actionIds.Add([string]$action.id)) { throw 'Migration plan contains a duplicate global action ID.' }
    $finding = @($Plan.global_findings | Where-Object action_id -eq $action.id)
    if ($finding.Count -ne 1) { throw 'Global action does not resolve to exactly one finding.' }
    Assert-ActionTuple $action $finding[0] $true
}
Assert-PlanReconciliation $Plan
$expectedOverall = if (
    $Plan.audit_outcome -eq 'FINDINGS' -or
    @($Plan.repositories | Where-Object { @($_.actions).Count -gt 0 }).Count -gt 0 -or
    @($Plan.global_actions).Count -gt 0
) { 'PARTIAL' } else { 'NO_ACTION' }
if ($Plan.overall_state -cne $expectedOverall) { throw 'Migration plan overall state does not reconcile.' }

$selectedRepoKeys = $null
if ($RepositoryPath -and $RepositoryPath.Count -gt 0) {
    $selectedRepoKeys = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $RepositoryPath) {
        $full = (Assert-LocalFileSystemPath $path 'Repository selection').TrimEnd('\')
        if (-not $selectedRepoKeys.Add($full)) { throw 'Repository selection contains a duplicate path.' }
        if (-not $repoKeys.Contains($full)) { throw 'Repository selection is not present in the sealed plan.' }
    }
}
$selectedActionIds = $null
if ($ActionId -and $ActionId.Count -gt 0) {
    $selectedActionIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($id in $ActionId) {
        if (-not $selectedActionIds.Add($id)) { throw 'Action selection contains a duplicate ID.' }
        if (-not $actionIds.Contains($id)) { throw 'Action selection is not present in the sealed plan.' }
    }
}

$repositoryResults = New-Object 'Collections.Generic.List[object]'
$renderedCount = 0
$withheldCount = 0
$selectedCount = 0
$renderedBytes = 0L
$renderedTargets = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($repo in @($Plan.repositories | Sort-Object path)) {
    $repoPath = (Assert-LocalFileSystemPath ([string]$repo.path) 'Repository path').TrimEnd('\')
    if ($null -ne $selectedRepoKeys -and -not $selectedRepoKeys.Contains($repoPath)) { continue }
    $actions = @($repo.actions | Where-Object { $null -eq $selectedActionIds -or $selectedActionIds.Contains([string]$_.id) } | Sort-Object target, action, id)
    if ($null -ne $selectedActionIds -and $actions.Count -eq 0) { continue }
    $currentGit = Get-CurrentGitInfo $repoPath
    $snapshotMatches = Test-SnapshotMatch $repo.git $currentGit $repoPath
    $registryNow = if ($currentGit.state -eq 'READ') { Get-RegistryState $repoPath } else { 'UNREADABLE' }
    $repositoryReady = $repo.plan_state -eq 'REVIEW_REQUIRED' -and $snapshotMatches -and
        $registryNow -eq $repo.cursor_rule_registry -and $registryNow -in @('ABSENT', 'NO_REFERENCE')
    $actionResults = New-Object 'Collections.Generic.List[object]'
    foreach ($action in $actions) {
        $selectedCount++
        $finding = @($repo.findings | Where-Object action_id -eq $action.id)[0]
        $base = [ordered]@{
            id = $action.id
            action = $action.action
            target = $action.target
            apply_status = $action.apply_status
            human_conductor_authorization_required = $true
            fresh_fetch_required = $true
        }
        if (-not $repositoryReady) {
            $base.status = 'WITHHELD_REPOSITORY_GATE'
            $base.reason = if ($repo.plan_state -ne 'REVIEW_REQUIRED') {
                "sealed_plan_state=$($repo.plan_state)"
            } elseif (-not $snapshotMatches) {
                'current Git branch, HEAD, tracking ref, or cleanliness differs from the sealed plan'
            } else { 'current Canon registry state changed or is neither ABSENT nor NO_REFERENCE' }
            [void]$actionResults.Add([pscustomobject]$base)
            $withheldCount++
            continue
        }
        if ($RenderableActions -notcontains $action.action) {
            if ($action.action -eq 'REMOVE_LEGACY_AUTHORIZATION_WITHOUT_OUTPUTTING_VALUE') {
                $server = [string]$finding.metadata.server
                if ($server -notmatch '^[A-Za-z0-9._-]{1,64}$') { throw 'MCP server identity has an unsafe display shape.' }
                $base.status = 'WITHHELD_CREDENTIAL_SAFE_STRUCTURAL_ONLY'
                $base.reason = "server=$server; headers.Authorization: PRESENT -> ABSENT"
            } elseif ($action.apply_status -eq 'BLOCKED') {
                $base.status = 'WITHHELD_MANUAL_BLOCK'
                $base.reason = 'The sealed action requires manual review and has no deterministic content transform.'
            } else {
                $base.status = 'WITHHELD_NO_DETERMINISTIC_TRANSFORM'
                $base.reason = 'The sealed plan does not prove exact edit boundaries.'
            }
            [void]$actionResults.Add([pscustomobject]$base)
            $withheldCount++
            continue
        }
        $target = Assert-LocalFileSystemPath ([string]$action.target) 'Migration target'
        $relative = Get-RelativePath $target $repoPath
        if (-not $renderedTargets.Add($target)) { throw 'More than one content-renderable action targets the same file.' }
        try {
            Assert-NoReparseTraversal $target $repoPath
            $targetInfo = Get-TextInfo $target 'Migration target'
            $sourcePath = Assert-LocalFileSystemPath ([string]$action.generated_source.path) 'Generated source'
            $sourceInfo = Get-TextInfo $sourcePath 'Generated source'
            if ($sourceInfo.File.Sha256 -cne [string]$action.generated_source.sha256) {
                throw 'Generated source changed after sealed-plan validation.'
            }
            $gitAfterRead = Get-CurrentGitInfo $repoPath
            if (-not (Test-SnapshotMatch $repo.git $gitAfterRead $repoPath)) {
                throw 'Repository changed while target content was being read.'
            }
            Assert-CurrentClassification $action $finding $targetInfo $sourceInfo $repoPath
            $patch = if ($action.action -eq 'REPLACE_GENERATED_BOOT_REGION_WITH_POINTER') {
                New-RegionDiff $targetInfo $sourceInfo $relative $finding.state
            } else {
                New-WholeFileDiff $targetInfo $sourceInfo $relative
            }
            $diffBytes = $Utf8NoBom.GetByteCount($patch.Diff)
            $renderedBytes += $diffBytes
            if ($renderedBytes -gt $MaxRenderedBytes) { throw 'Rendered diff resource limit exceeded.' }
            $base.status = 'RENDERED_PREVIEW_HELD'
            $base.generated_source = [ordered]@{ path = $sourcePath; sha256 = $action.generated_source.sha256 }
            $base.original_sha256 = $patch.OriginalSha256
            $base.proposed_sha256 = $patch.ProposedSha256
            $base.original_bytes = $patch.OriginalBytes
            $base.proposed_bytes = $patch.ProposedBytes
            $base.outside_region_bytes_verified = $patch.OutsideRegionVerified
            $base.unified_diff = $patch.Diff
            [void]$actionResults.Add([pscustomobject]$base)
            $renderedCount++
        } catch {
            $base.status = 'WITHHELD_TARGET_REVALIDATION'
            $base.reason = $_.Exception.Message
            [void]$actionResults.Add([pscustomobject]$base)
            $withheldCount++
        }
    }
    [void]$repositoryResults.Add([pscustomobject][ordered]@{
        path = $repoPath
        sealed_plan_state = $repo.plan_state
        current_snapshot_matches = $snapshotMatches
        current_registry_state = $registryNow
        apply_preflight = 'FRESH_FETCH_CURRENT_MAIN_AND_SEPARATE_AUTHORIZATION_REQUIRED'
        actions = @($actionResults.ToArray())
    })
}

$globalResults = New-Object 'Collections.Generic.List[object]'
if ($null -eq $selectedRepoKeys) {
    foreach ($action in @($Plan.global_actions | Where-Object { $null -eq $selectedActionIds -or $selectedActionIds.Contains([string]$_.id) } | Sort-Object target, action, id)) {
        $selectedCount++
        [void]$globalResults.Add([pscustomobject][ordered]@{
            id = $action.id
            action = $action.action
            target = $action.target
            apply_status = $action.apply_status
            human_conductor_authorization_required = $true
            fresh_fetch_required = $false
            status = 'WITHHELD_GLOBAL_OR_LIVE_REVIEW'
            reason = 'Global, user, reparse-boundary, and effective-client actions do not produce project content diffs.'
        })
        $withheldCount++
    }
}
if ($selectedCount -eq 0 -and $null -ne $selectedActionIds) { throw 'Action selection resolved to no output records.' }

$Result = [ordered]@{
    schema_version = 1
    mode = 'READ_ONLY_IN_MEMORY_DIFF_NO_FETCH_NO_WRITE'
    plan = [ordered]@{
        path = $resolvedPlanPath
        sha256 = $planHash
        source_mode = $Plan.mode
        source_state = $Plan.overall_state
    }
    overall_state = if ($renderedCount -gt 0 -and $withheldCount -eq 0) {
        'RENDERED_PREVIEW_HELD'
    } elseif ($renderedCount -gt 0) {
        'PARTIAL_PREVIEW_HELD'
    } else { 'NO_CONTENT_DIFF_HELD' }
    summary = [ordered]@{
        selected_actions = $selectedCount
        rendered_content_diffs = $renderedCount
        withheld_actions = $withheldCount
        rendered_diff_bytes = $renderedBytes
        project_write_count = 0
        fetch_count = 0
    }
    repositories = @($repositoryResults.ToArray())
    global_actions = @($globalResults.ToArray())
    held_back = @(
        'A rendered preview is not authorization and is not apply-ready.',
        'Before any write, fetch each repository. Verify that main is current. Confirm that the worktree is clean.',
        'The renderer never serializes credential-bearing MCP configuration into a diff.',
        'This renderer does not create backups or exercise apply/restore transaction gates.',
        'No commit, push, pull request, merge, deploy, or production action occurred.'
    )
}

[Console]::Out.Write((ConvertTo-EngineStableJson $Result))
