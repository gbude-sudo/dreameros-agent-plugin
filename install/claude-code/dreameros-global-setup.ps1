#Requires -Version 5.1
<#
.SYNOPSIS
  Installs the DreamerOS global Claude Code environment onto a Windows machine.

.DESCRIPTION
  This installer places the DreamerOS agent layer, hook gates, and canon file
  into a Claude Code home directory. It merges settings rather than replacing
  them. It backs up every file it changes. It reports what it did.

  Design rules, all load bearing:
    - Idempotent. A second run makes no further change.
    - Merge, never clobber. Existing permissions, hooks, and MCP config stay.
    - Back up before every write, with a timestamp in the file name.
    - No secrets, no tokens, no machine specific paths in the payload.
    - Fail loudly. Every failure appears in the summary and sets the exit code.

.PARAMETER ClaudeHome
  The Claude Code home directory. Default: $env:USERPROFILE\.claude

.PARAMETER RepoRoot
  The directory that holds your DreamerOS repositories. The hook gates read
  this to find repositories to check. Missing repositories are skipped safely.
  Default: $env:USERPROFILE\Documents\DreamerOS

.PARAMETER PayloadPath
  The payload directory. Default: the payload folder next to this script.

.PARAMETER BashPath
  Optional absolute path to bash. On Windows the installer otherwise resolves
  and verifies Git for Windows bash.exe. On other systems it keeps the portable
  bash command name.

.PARAMETER DryRun
  Print every action and change nothing.

.PARAMETER Force
  Overwrite CLAUDE.md when it already exists. Without this switch the
  installer keeps your CLAUDE.md and reports it as skipped.

.PARAMETER SkipCanon
  Do not install CLAUDE.md at all.

.EXAMPLE
  .\dreameros-global-setup.ps1 -DryRun

.EXAMPLE
  .\dreameros-global-setup.ps1

.EXAMPLE
  .\dreameros-global-setup.ps1 -ClaudeHome D:\claude -RepoRoot D:\code\DreamerOS
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ClaudeHome = (Join-Path $env:USERPROFILE '.claude'),
    [string] $RepoRoot = (Join-Path $env:USERPROFILE 'Documents\DreamerOS'),
    [string] $PayloadPath,
    [string] $BashPath,
    [switch] $DryRun,
    [switch] $Force,
    [switch] $SkipCanon
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Result ledger. Every step records here. The summary reads only from this.
# ---------------------------------------------------------------------------
$script:Installed = New-Object System.Collections.ArrayList
$script:Skipped   = New-Object System.Collections.ArrayList
$script:Failed    = New-Object System.Collections.ArrayList
$script:Warnings  = New-Object System.Collections.ArrayList

$script:Stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$script:BashCommandPrefix = 'bash'

function Write-Step {
    param([string] $Message)
    Write-Host "  $Message"
}

function Write-Head {
    param([string] $Message)
    Write-Host ""
    Write-Host "== $Message" -ForegroundColor Cyan
}

function Add-Installed { param([string] $Item, [string] $Note = '')
    [void] $script:Installed.Add([pscustomobject]@{ Item = $Item; Note = $Note }) }

function Add-Skipped { param([string] $Item, [string] $Note = '')
    [void] $script:Skipped.Add([pscustomobject]@{ Item = $Item; Note = $Note }) }

function Add-Failed { param([string] $Item, [string] $Note = '')
    [void] $script:Failed.Add([pscustomobject]@{ Item = $Item; Note = $Note }) }

function Add-Warning { param([string] $Text)
    [void] $script:Warnings.Add($Text) }

# ---------------------------------------------------------------------------
# File helpers
# ---------------------------------------------------------------------------

function Get-Utf8NoBom { return New-Object System.Text.UTF8Encoding($false) }

function Read-TextFile {
    param([Parameter(Mandatory)][string] $Path)
    return [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-LockedBytes {
    param([Parameter(Mandatory)][System.IO.FileStream] $Stream)
    $Stream.Position = 0
    [byte[]]$bytes = New-Object byte[] ([int]$Stream.Length)
    $offset = 0
    while ($offset -lt $bytes.Length) {
        $read = $Stream.Read($bytes, $offset, $bytes.Length - $offset)
        if ($read -eq 0) { break }
        $offset += $read
    }
    if ($offset -ne $bytes.Length) {
        throw "short locked-file read: expected $($bytes.Length) bytes and read $offset."
    }
    return ,$bytes
}

function Decode-Utf8Bytes {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Bytes)
    $offset = 0
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        $offset = 3
    }
    return (Get-Utf8NoBom).GetString($Bytes, $offset, $Bytes.Length - $offset)
}

function Backup-LockedBytes {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Bytes
    )
    $backupDir = Join-Path $ClaudeHome ('backups\dreameros-install-' + $script:Stamp)
    $target = Join-Path $backupDir (Split-Path -Leaf $Path)
    $n = 1
    while (Test-Path -LiteralPath $target) {
        $target = Join-Path $backupDir ((Split-Path -Leaf $Path) + ".$n")
        $n++
    }
    if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    $backupStream = $null
    try {
        $backupStream = [System.IO.File]::Open(
            $target,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None)
        $backupStream.Write($Bytes, 0, $Bytes.Length)
        $backupStream.Flush($true)
    }
    finally {
        if ($null -ne $backupStream) { $backupStream.Dispose() }
    }
    if ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($target)) -cne [Convert]::ToBase64String($Bytes)) {
        throw "managed backup verification failed for $Path."
    }
    Write-Step "backed up to $target"
    return $target
}

function Write-TextFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Content
    )
    if ($DryRun) { Write-Step "DRYRUN would write $Path"; return }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Write file')) { return }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (Get-Utf8NoBom))
}

function Backup-File {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $backupDir = Join-Path $ClaudeHome ('backups\dreameros-install-' + $script:Stamp)
    $target = Join-Path $backupDir (Split-Path -Leaf $Path)
    # Two files with the same leaf name would collide. Disambiguate.
    $n = 1
    while (Test-Path -LiteralPath $target) {
        $target = Join-Path $backupDir ((Split-Path -Leaf $Path) + ".$n")
        $n++
    }
    if ($DryRun) { Write-Step "DRYRUN would back up $Path to $target"; return $target }
    if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $Path -Destination $target -Force
    Write-Step "backed up to $target"
    return $target
}

function Expand-Tokens {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)
    $home1 = ($ClaudeHome -replace '\\', '/').TrimEnd('/')
    $root1 = ($RepoRoot -replace '\\', '/').TrimEnd('/')
    $out = $Text.Replace('__DREAMEROS_CLAUDE_HOME__', $home1)
    $out = $out.Replace('__DREAMEROS_REPO_ROOT__', $root1)
    return $out
}

function Test-WindowsHost {
    return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function Test-BashExecutable {
    param([Parameter(Mandatory)][string] $Path)
    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $Path --version 2>&1)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $priorPreference
    }
    return $code -eq 0 -and (($output -join "`n") -match '(?m)^GNU bash, version ')
}

function Resolve-BashLauncher {
    param([string] $RequestedPath)

    if (-not (Test-WindowsHost)) {
        return [pscustomobject]@{
            Executable = 'bash'
            CommandPrefix = 'bash'
        }
    }

    $candidates = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (-not [System.IO.Path]::IsPathRooted($RequestedPath)) {
            throw '-BashPath must be an absolute path.'
        }
        [void]$candidates.Add($RequestedPath)
    }
    else {
        foreach ($git in @(Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue)) {
            $gitSource = [string]$git.Source
            if ([string]::IsNullOrWhiteSpace($gitSource)) { continue }
            $gitRoot = Split-Path -Parent (Split-Path -Parent $gitSource)
            [void]$candidates.Add((Join-Path $gitRoot 'bin\bash.exe'))
        }
        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if (-not [string]::IsNullOrWhiteSpace($base)) {
                [void]$candidates.Add((Join-Path $base 'Git\bin\bash.exe'))
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe'))
        }
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate) -or -not $seen.Add([string]$candidate)) { continue }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $resolved = (Resolve-Path -LiteralPath $candidate).Path
        if ((Split-Path -Leaf $resolved) -ine 'bash.exe') { continue }
        if (-not (Test-BashExecutable -Path $resolved)) { continue }
        $portable = $resolved.Replace('\', '/')
        return [pscustomobject]@{
            Executable = $resolved
            CommandPrefix = '"' + $portable + '"'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        throw "The requested Git Bash executable was not found or failed verification: $RequestedPath"
    }
    throw 'Git for Windows bash.exe was not found or failed GNU bash verification.'
}

function Install-TemplatedFile {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][string] $Label,
        [switch] $OverwriteWhenDifferent
    )
    try {
        $wanted = Expand-Tokens (Read-TextFile $Source)
        if (Test-Path -LiteralPath $Destination) {
            $current = Read-TextFile $Destination
            if ($current -eq $wanted) {
                Add-Skipped $Label 'already present and identical'
                Write-Step "SKIP  $Label (identical)"
                return
            }
            if (-not $OverwriteWhenDifferent) {
                Add-Skipped $Label 'present with local changes, left alone'
                Write-Step "SKIP  $Label (local changes kept)"
                return
            }
            Backup-File $Destination | Out-Null
            Write-TextFile -Path $Destination -Content $wanted
            Add-Installed $Label 'updated, previous version backed up'
            Write-Step "UPDATE $Label"
            return
        }
        Write-TextFile -Path $Destination -Content $wanted
        Add-Installed $Label 'new'
        Write-Step "ADD   $Label"
    }
    catch {
        Add-Failed $Label $_.Exception.Message
        Write-Host "  FAIL  $Label : $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Split-ManagedAgentMarkdown {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Label
    )
    $pattern = '\A---(?<open>\r?\n)(?<front>[\s\S]*?)(?<close>\r?\n---)(?<after>\r?\n)(?<body>[\s\S]*)\z'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) {
        throw "$Label does not have one readable leading YAML frontmatter block."
    }
    return [pscustomobject]@{
        Open = $match.Groups['open'].Value
        Front = $match.Groups['front'].Value
        Close = $match.Groups['close'].Value
        After = $match.Groups['after'].Value
        Body = $match.Groups['body'].Value
    }
}

function Merge-ManagedAgentContent {
    param(
        [Parameter(Mandatory)][string] $Current,
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Label
    )
    $currentParts = Split-ManagedAgentMarkdown -Text $Current -Label "$Label destination"
    $sourceParts = Split-ManagedAgentMarkdown -Text $Source -Label "$Label payload"
    $toolsPattern = '(?m)^tools:[^\r\n]*(?=\r?$)'
    $sourceTools = [regex]::Matches($sourceParts.Front, $toolsPattern)
    $currentTools = [regex]::Matches($currentParts.Front, $toolsPattern)
    if ($sourceTools.Count -ne 1) { throw "$Label payload must contain exactly one tools line." }
    if ($currentTools.Count -gt 1) { throw "$Label destination contains more than one tools line." }
    $wantedTools = $sourceTools[0].Value
    if ($wantedTools -match '(?i)mcp__(?:DreamerOS_Live|[0-9a-f]{8}-[0-9a-f-]{27})__') {
        throw "$Label payload tools include a nonportable MCP alias."
    }
    if ($currentTools.Count -eq 1) {
        $newFront = [regex]::Replace(
            $currentParts.Front,
            $toolsPattern,
            [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $wantedTools })
    }
    else {
        $newFront = $currentParts.Front + $currentParts.Open + $wantedTools
    }

    $sourceBodyLf = $sourceParts.Body.Replace("`r`n", "`n").Replace("`r", "`n")
    $sourceHeader = "## DREAMEROS-READ-ONLY-BOOTSTRAP v1.1.0`n"
    $sourceEnd = "Do not call bootstrap tools that write, route, govern, administer, or change`nexternal state.`n`n"
    $headerIndex = $sourceBodyLf.IndexOf($sourceHeader, [StringComparison]::Ordinal)
    $endIndex = $sourceBodyLf.IndexOf($sourceEnd, [Math]::Max(0, $headerIndex), [StringComparison]::Ordinal)
    if ($headerIndex -lt 0 -or $sourceBodyLf.Substring(0, $headerIndex).Trim().Length -ne 0 -or $endIndex -lt $headerIndex) {
        throw "$Label payload does not have the exact managed v1.1.0 bootstrap structure."
    }
    $sourceBlockLf = $sourceBodyLf.Substring($headerIndex, $endIndex + $sourceEnd.Length - $headerIndex)
    $sourceNewline = if ($sourceParts.Body.Contains("`r`n")) { "`r`n" } else { "`n" }
    $wantedBlock = $sourceBlockLf.Replace("`n", $sourceNewline)
    $compatiblePattern = [regex]::Escape($sourceBlockLf)
    $compatiblePattern = $compatiblePattern.Replace('v1\.1\.0', 'v[0-9]+\.[0-9]+\.[0-9]+')
    $compatiblePattern = '(?m)^' + $compatiblePattern.Replace('\n', '\r?\n')
    $currentHeaders = [regex]::Matches($currentParts.Body, '(?m)^## DREAMEROS-READ-ONLY-BOOTSTRAP v')
    $currentBlocks = [regex]::Matches($currentParts.Body, $compatiblePattern)
    if ($currentHeaders.Count -gt 1 -or $currentHeaders.Count -ne $currentBlocks.Count) {
        throw "$Label destination has an ambiguous or malformed managed bootstrap block."
    }
    if ($currentBlocks.Count -eq 1) {
        $newBody = [regex]::Replace(
            $currentParts.Body,
            $compatiblePattern,
            [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $wantedBlock })
    }
    else {
        $newBody = $wantedBlock + $currentParts.Body
    }

    $merged = '---' + $currentParts.Open + $newFront + $currentParts.Close + $currentParts.After + $newBody
    $mergedParts = Split-ManagedAgentMarkdown -Text $merged -Label "$Label merged result"
    if ([regex]::Matches($mergedParts.Front, $toolsPattern).Count -ne 1) {
        throw "$Label merged result does not contain exactly one tools line."
    }
    if ([regex]::Matches($mergedParts.Body, '(?m)^## DREAMEROS-READ-ONLY-BOOTSTRAP v').Count -ne 1 -or
        [regex]::Matches($mergedParts.Body, [regex]::Escape($wantedBlock)).Count -ne 1) {
        throw "$Label merged result does not contain exactly one v1.1.0 bootstrap block."
    }
    return $merged
}

function Merge-ManagedAgentFile {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][string] $Label
    )
    $destinationStream = $null
    try {
        $wanted = Expand-Tokens (Read-TextFile $Source)
        [byte[]]$wantedBytes = (Get-Utf8NoBom).GetBytes($wanted)
        $dryMode = $DryRun -or [bool]$WhatIfPreference
        if (-not (Test-Path -LiteralPath $Destination)) {
            if ($dryMode) {
                Write-Step "DRYRUN would add $Label"
                Add-Installed $Label 'new'
                return
            }
            $dir = Split-Path -Parent $Destination
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $destinationStream = [System.IO.File]::Open(
                $Destination,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None)
            $destinationStream.Write($wantedBytes, 0, $wantedBytes.Length)
            $destinationStream.Flush($true)
            $destinationStream.Dispose()
            $destinationStream = $null
            if ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Destination)) -cne [Convert]::ToBase64String($wantedBytes)) {
                throw "$Label exclusive-create verification failed."
            }
            Add-Installed $Label 'new'
            Write-Step "ADD   $Label"
            return
        }

        $access = if ($dryMode) { [System.IO.FileAccess]::Read } else { [System.IO.FileAccess]::ReadWrite }
        $destinationStream = [System.IO.File]::Open(
            $Destination,
            [System.IO.FileMode]::Open,
            $access,
            [System.IO.FileShare]::None)
        [byte[]]$currentBytes = Read-LockedBytes $destinationStream
        $current = Decode-Utf8Bytes $currentBytes
        if ($current -eq $wanted) {
            Add-Skipped $Label 'already present and identical'
            Write-Step "SKIP  $Label (identical)"
            return
        }
        $merged = Merge-ManagedAgentContent -Current $current -Source $wanted -Label $Label
        if ($merged -eq $current) {
            Add-Skipped $Label 'managed tools and bootstrap already aligned; local content kept'
            Write-Step "SKIP  $Label (managed regions aligned, local content kept)"
            return
        }
        if ($dryMode) {
            Add-Installed $Label 'managed tools and bootstrap would merge; local fields and body stay'
            Write-Step "MERGE $Label (managed regions only)"
            return
        }

        Backup-LockedBytes -Path $Destination -Bytes $currentBytes | Out-Null
        [byte[]]$immediateBytes = Read-LockedBytes $destinationStream
        if ([Convert]::ToBase64String($immediateBytes) -cne [Convert]::ToBase64String($currentBytes)) {
            throw "$Label changed after read and before write."
        }
        [byte[]]$mergedBytes = (Get-Utf8NoBom).GetBytes($merged)
        $destinationStream.Position = 0
        $destinationStream.SetLength(0)
        $destinationStream.Write($mergedBytes, 0, $mergedBytes.Length)
        $destinationStream.Flush($true)
        [byte[]]$verifiedBytes = Read-LockedBytes $destinationStream
        if ([Convert]::ToBase64String($verifiedBytes) -cne [Convert]::ToBase64String($mergedBytes)) {
            throw "$Label locked-write verification failed."
        }
        Add-Installed $Label 'managed tools and bootstrap merged; local fields and body kept'
        Write-Step "MERGE $Label (managed regions only)"
    }
    catch {
        Add-Failed $Label $_.Exception.Message
        Write-Host "  FAIL  $Label : $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        if ($null -ne $destinationStream) { $destinationStream.Dispose() }
    }
}

# ---------------------------------------------------------------------------
# JSON helpers. PowerShell 5.1 has no ConvertFrom-Json -AsHashtable, so build
# ordered hashtables by hand. Ordered keeps a merged file readable.
# ---------------------------------------------------------------------------

function ConvertTo-OrderedHash {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) {
            $h[$p.Name] = ConvertTo-OrderedHash $p.Value
        }
        return $h
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-OrderedHash $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $a = New-Object System.Collections.ArrayList
        foreach ($i in $InputObject) { [void] $a.Add((ConvertTo-OrderedHash $i)) }
        return , $a
    }
    return $InputObject
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string] $Path)
    $raw = Read-TextFile $Path
    if ([string]::IsNullOrWhiteSpace($raw)) { return [ordered]@{} }
    return ConvertTo-OrderedHash (ConvertFrom-Json $raw)
}

function Get-CanonicalJson {
    param($Value)
    return (ConvertTo-Json -InputObject $Value -Depth 100 -Compress)
}

function Merge-StringList {
    <#
      Union of two lists, existing order first. Returns the merged list and
      the count of genuinely new entries. This is what makes a second run a
      no-op instead of a file full of duplicates.
    #>
    param($Existing, $Incoming)
    $result = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($null -ne $Existing) {
        foreach ($e in $Existing) {
            $k = [string] $e
            if ($seen.Add($k)) { [void] $result.Add($e) }
        }
    }
    $added = 0
    if ($null -ne $Incoming) {
        foreach ($i in $Incoming) {
            $k = [string] $i
            if ($seen.Add($k)) { [void] $result.Add($i); $added++ }
        }
    }
    return [pscustomobject]@{ List = $result; Added = $added }
}

function Get-HookSemanticKey {
    param($Hook)
    $hookHash = ConvertTo-OrderedHash $Hook
    if ($hookHash.Contains('command')) { return 'cmd:' + [string]$hookHash['command'] }
    if ($hookHash.Contains('prompt')) { return 'agent:' + [string]$hookHash['prompt'] }
    return 'raw:' + (Get-CanonicalJson $hookHash)
}

function Get-ClaudeHomeBashInvocation {
    param([Parameter(Mandatory)][string] $Command)

    $invocation = [regex]::Match(
        $Command,
        '(?i)^(?<launcher>bash(?:\.exe)?|"[^"]*[\\/]bash(?:\.exe)?"|''[^'']*[\\/]bash(?:\.exe)?''|[^\s"'']*[\\/]bash(?:\.exe)?)\s+(?<rest>[\s\S]+)$')
    if (-not $invocation.Success) { return $null }

    $rest = $invocation.Groups['rest'].Value
    $scriptMatch = [regex]::Match(
        $rest,
        '^(?:"(?<double>[^"]+\.sh)"|''(?<single>[^'']+\.sh)''|(?<bare>\S+\.sh))(?=$|\s)')
    if (-not $scriptMatch.Success) { return $null }
    $scriptPath = $scriptMatch.Groups['double'].Value
    if ([string]::IsNullOrEmpty($scriptPath)) { $scriptPath = $scriptMatch.Groups['single'].Value }
    if ([string]::IsNullOrEmpty($scriptPath)) { $scriptPath = $scriptMatch.Groups['bare'].Value }

    try {
        $hooksRoot = [System.IO.Path]::GetFullPath((Join-Path $ClaudeHome 'hooks')).TrimEnd([char[]]@('\', '/'))
        $fullScript = [System.IO.Path]::GetFullPath($scriptPath)
    }
    catch {
        return $null
    }
    $boundary = $hooksRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullScript.StartsWith($boundary, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    return [pscustomobject]@{
        Launcher = $invocation.Groups['launcher'].Value
        Rest = $rest
    }
}

function Render-FragmentBashCommands {
    param($FragmentHooks)

    $rendered = 0
    foreach ($eventName in @($FragmentHooks.Keys)) {
        foreach ($group in @($FragmentHooks[$eventName])) {
            if ($group -isnot [System.Collections.IDictionary] -or -not $group.Contains('hooks') -or $null -eq $group['hooks']) { continue }
            foreach ($hook in @($group['hooks'])) {
                if ($hook -isnot [System.Collections.IDictionary] -or -not $hook.Contains('command')) { continue }
                $command = [string]$hook['command']
                $token = '__DREAMEROS_BASH_COMMAND__ '
                if (-not $command.StartsWith($token, [System.StringComparison]::Ordinal)) { continue }
                $hook['command'] = $script:BashCommandPrefix + ' ' + $command.Substring($token.Length)
                $rendered++
            }
        }
    }
    return $rendered
}

function Get-ManagedBashRegistrationKey {
    param(
        [Parameter(Mandatory)][string] $EventName,
        [Parameter(Mandatory)][string] $CommandTail
    )
    return $EventName + [string][char]0 + $CommandTail
}

function Update-ClaudeHomeBashHookLaunchers {
    param($Hooks, $FragmentHooks)

    if ($script:BashCommandPrefix -ceq 'bash') { return 0 }
    $managedCommands = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($eventName in @($FragmentHooks.Keys)) {
        foreach ($group in @($FragmentHooks[$eventName])) {
            $groupHash = ConvertTo-OrderedHash $group
            if (-not $groupHash.Contains('hooks') -or $null -eq $groupHash['hooks']) { continue }
            foreach ($hook in @($groupHash['hooks'])) {
                $hookHash = ConvertTo-OrderedHash $hook
                if (-not $hookHash.Contains('command')) { continue }
                $wanted = [string]$hookHash['command']
                $wantedParts = Get-ClaudeHomeBashInvocation -Command $wanted
                if ($null -ne $wantedParts) {
                    $managedCommands[(Get-ManagedBashRegistrationKey -EventName $eventName -CommandTail $wantedParts.Rest)] = $wanted
                }
            }
        }
    }
    $updated = 0
    foreach ($eventName in @($Hooks.Keys)) {
        $updatedGroups = New-Object System.Collections.ArrayList
        foreach ($group in @($Hooks[$eventName])) {
            $groupHash = ConvertTo-OrderedHash $group
            if (-not $groupHash.Contains('hooks') -or $null -eq $groupHash['hooks']) {
                [void]$updatedGroups.Add($groupHash)
                continue
            }
            $updatedHooks = New-Object System.Collections.ArrayList
            foreach ($hook in @($groupHash['hooks'])) {
                $hookHash = ConvertTo-OrderedHash $hook
                if ($hookHash.Contains('command')) {
                    $command = [string]$hookHash['command']
                    $parts = Get-ClaudeHomeBashInvocation -Command $command
                    $managedKey = if ($null -ne $parts) { Get-ManagedBashRegistrationKey -EventName $eventName -CommandTail $parts.Rest } else { $null }
                    if ($null -ne $managedKey -and $managedCommands.ContainsKey($managedKey)) {
                        $wanted = $managedCommands[$managedKey]
                        if ($wanted -cne $command) {
                            $hookHash['command'] = $wanted
                            $updated++
                        }
                    }
                }
                [void]$updatedHooks.Add($hookHash)
            }
            $groupHash['hooks'] = $updatedHooks
            [void]$updatedGroups.Add($groupHash)
        }
        $Hooks[$eventName] = $updatedGroups
    }
    return $updated
}

function Merge-HookEvent {
    <#
      Merge one hook event, for example PreToolUse.

      An event holds groups. A group has an optional matcher and a hooks list.
      Identity of a group is its matcher. Identity of a single hook inside a
      group is its command string for a command hook, or its prompt text for
      an agent hook. Both are compared after token expansion, so a second run
      recognises what the first run wrote.
    #>
    param($Existing, $Incoming)

    $added = 0
    $result = New-Object System.Collections.ArrayList
    if ($null -ne $Existing) { foreach ($g in $Existing) { [void] $result.Add($g) } }

    function Get-Matcher($g) {
        $gg = ConvertTo-OrderedHash $g
        if ($gg.Contains('matcher')) { return [string] $gg['matcher'] }
        return ''
    }

    foreach ($inGroup in $Incoming) {
        $inMatcher = Get-Matcher $inGroup
        $target = $null
        foreach ($ex in $result) {
            if ((Get-Matcher $ex) -eq $inMatcher) { $target = $ex; break }
        }
        if ($null -eq $target) {
            [void] $result.Add((ConvertTo-OrderedHash $inGroup))
            $inH = ConvertTo-OrderedHash $inGroup
            if ($inH.Contains('hooks')) { $added += @($inH['hooks']).Count }
            continue
        }
        # Group with this matcher exists. Add only hooks it does not carry.
        $targetH = ConvertTo-OrderedHash $target
        $have = New-Object 'System.Collections.Generic.HashSet[string]'
        $mergedHooks = New-Object System.Collections.ArrayList
        if ($targetH.Contains('hooks') -and $null -ne $targetH['hooks']) {
            foreach ($h in @($targetH['hooks'])) {
                [void] $have.Add((Get-HookSemanticKey $h))
                [void] $mergedHooks.Add((ConvertTo-OrderedHash $h))
            }
        }
        $inH = ConvertTo-OrderedHash $inGroup
        if ($inH.Contains('hooks') -and $null -ne $inH['hooks']) {
            foreach ($h in @($inH['hooks'])) {
                if ($have.Add((Get-HookSemanticKey $h))) {
                    [void] $mergedHooks.Add((ConvertTo-OrderedHash $h))
                    $added++
                }
            }
        }
        $targetH['hooks'] = $mergedHooks
        # Replace the group object in place.
        $idx = $result.IndexOf($target)
        $result[$idx] = $targetH
    }

    return [pscustomobject]@{ List = $result; Added = $added }
}

function Remove-DuplicateLifecycleHooksAcrossGroups {
    param($Groups)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $result = New-Object System.Collections.ArrayList
    $removed = 0
    foreach ($group in @($Groups)) {
        $groupHash = ConvertTo-OrderedHash $group
        if (-not $groupHash.Contains('hooks') -or $null -eq $groupHash['hooks']) {
            [void]$result.Add($groupHash)
            continue
        }
        $kept = New-Object System.Collections.ArrayList
        foreach ($hook in @($groupHash['hooks'])) {
            $hookHash = ConvertTo-OrderedHash $hook
            # Lifecycle cross-group dedupe is intentionally command-only.
            # Agent prompts and unknown hook types can have matcher semantics.
            if (-not $hookHash.Contains('command')) {
                [void]$kept.Add($hookHash)
                continue
            }
            if ($seen.Add(('cmd:' + [string]$hookHash['command']))) {
                [void]$kept.Add($hookHash)
            }
            else {
                $removed++
            }
        }
        if ($kept.Count -gt 0) {
            $groupHash['hooks'] = $kept
            [void]$result.Add($groupHash)
        }
    }
    return [pscustomobject]@{ List = $result; Removed = $removed }
}

function Remove-RetiredLifecycleHooks {
    param($Hooks)
    $sessionRemoved = 0
    $stopRemoved = 0

    if ($Hooks.Contains('SessionStart')) {
        $updatedGroups = New-Object System.Collections.ArrayList
        foreach ($group in @($Hooks['SessionStart'])) {
            $groupHash = ConvertTo-OrderedHash $group
            $kept = New-Object System.Collections.ArrayList
            foreach ($hook in @($groupHash['hooks'])) {
                $hookHash = ConvertTo-OrderedHash $hook
                $command = if ($hookHash.Contains('command')) { [string]$hookHash['command'] } else { '' }
                $retiredHydration = $command -match '(?i)(?:^|[\s\\/"''])(?:operator-standing-orders|dreameros-agent-stack-session-start)\.sh(?:["'']|\s|$)'
                $retiredAutoInstall = $command -match '(?i)(?:^|[\s\\/"''])build-boot-pack\.ps1["'']?\s+-Install(?:\s|$)'
                if ($retiredHydration -or $retiredAutoInstall) {
                    $sessionRemoved++
                    continue
                }
                [void]$kept.Add($hookHash)
            }
            if ($kept.Count -gt 0) {
                $groupHash['hooks'] = $kept
                [void]$updatedGroups.Add($groupHash)
            }
        }
        $Hooks['SessionStart'] = $updatedGroups
    }

    $directSwitchPresent = $false
    if ($Hooks.Contains('Stop')) {
        foreach ($group in @($Hooks['Stop'])) {
            foreach ($hook in @((ConvertTo-OrderedHash $group)['hooks'])) {
                $hookHash = ConvertTo-OrderedHash $hook
                $command = if ($hookHash.Contains('command')) { [string]$hookHash['command'] } else { '' }
                if ($command -match '(?i)(?:^|\s)python(?:3|\.exe)?\s+["'']?(?:[^"'']*[\\/])?model-switch-ack\.py(?:["'']|\s|$)') {
                    $directSwitchPresent = $true
                }
            }
        }
    }
    if ($directSwitchPresent) {
        $updatedStopGroups = New-Object System.Collections.ArrayList
        foreach ($group in @($Hooks['Stop'])) {
            $groupHash = ConvertTo-OrderedHash $group
            $kept = New-Object System.Collections.ArrayList
            foreach ($hook in @($groupHash['hooks'])) {
                $hookHash = ConvertTo-OrderedHash $hook
                $command = if ($hookHash.Contains('command')) { [string]$hookHash['command'] } else { '' }
                if ($command -match '(?i)(?:^|[\s\\/"''])model-switch-ack\.sh(?:["'']|\s|$)') {
                    $stopRemoved++
                    continue
                }
                [void]$kept.Add($hookHash)
            }
            if ($kept.Count -gt 0) {
                $groupHash['hooks'] = $kept
                [void]$updatedStopGroups.Add($groupHash)
            }
        }
        $Hooks['Stop'] = $updatedStopGroups
    }
    return [pscustomobject]@{ SessionStart = $sessionRemoved; Stop = $stopRemoved }
}

function Merge-Settings {
    param(
        [Parameter(Mandatory)] $Existing,
        [Parameter(Mandatory)] $Fragment
    )

    $out = $Existing
    $changes = New-Object System.Collections.ArrayList

    if (-not $out.Contains('permissions')) { $out['permissions'] = [ordered]@{} }
    $perm = $out['permissions']
    $fperm = $Fragment['permissions']

    if ($null -ne $fperm) {
        if ($fperm.Contains('defaultMode')) {
            if (-not $perm.Contains('defaultMode')) {
                $perm['defaultMode'] = $fperm['defaultMode']
                [void] $changes.Add("permissions.defaultMode set to $($fperm['defaultMode'])")
            }
            elseif ([string] $perm['defaultMode'] -ne [string] $fperm['defaultMode']) {
                # Never override an explicit operator choice here.
                Add-Warning ("permissions.defaultMode is '" + $perm['defaultMode'] +
                    "' and the DreamerOS default is '" + $fperm['defaultMode'] +
                    "'. Your value was kept.")
            }
        }
        foreach ($listName in @('deny', 'allow')) {
            if (-not $fperm.Contains($listName)) { continue }
            $cur = $null
            if ($perm.Contains($listName)) { $cur = $perm[$listName] }
            $m = Merge-StringList -Existing $cur -Incoming $fperm[$listName]
            $perm[$listName] = $m.List
            if ($m.Added -gt 0) { [void] $changes.Add("permissions.$listName gained $($m.Added) entries") }
        }
    }

    if ($Fragment.Contains('hooks')) {
        if (-not $out.Contains('hooks')) { $out['hooks'] = [ordered]@{} }
        $hooks = $out['hooks']
        $updatedLaunchers = Update-ClaudeHomeBashHookLaunchers -Hooks $hooks -FragmentHooks $Fragment['hooks']
        if ($updatedLaunchers -gt 0) {
            [void]$changes.Add("hooks updated $updatedLaunchers Claude-home Bash launcher(s)")
        }
        foreach ($evt in $Fragment['hooks'].Keys) {
            $cur = $null
            if ($hooks.Contains($evt)) { $cur = $hooks[$evt] }
            $m = Merge-HookEvent -Existing $cur -Incoming @($Fragment['hooks'][$evt])
            $hooks[$evt] = $m.List
            if ($m.Added -gt 0) { [void] $changes.Add("hooks.$evt gained $($m.Added) hooks") }
        }
    }
    $retiredHooks = Remove-RetiredLifecycleHooks -Hooks $hooks
    foreach ($evt in @('SessionStart', 'Stop')) {
        $retiredCount = [int]$retiredHooks.$evt
        if ($retiredCount -gt 0) {
            [void]$changes.Add("hooks.$evt removed $retiredCount retired hook(s)")
        }
        if ($hooks.Contains($evt)) {
            $deduped = Remove-DuplicateLifecycleHooksAcrossGroups -Groups $hooks[$evt]
            $hooks[$evt] = $deduped.List
            if ($deduped.Removed -gt 0) {
                [void]$changes.Add("hooks.$evt removed $($deduped.Removed) duplicate hook(s) across matcher groups")
            }
        }
    }

    # Every other key the operator already had stays untouched. That includes
    # mcpServers, enabledPlugins, env, model, and anything a future Claude
    # Code release adds. The installer never enumerates what it may keep.

    return [pscustomobject]@{ Settings = $out; Changes = $changes }
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "DreamerOS global Claude Code environment installer" -ForegroundColor Green
Write-Host "=================================================="
if ($DryRun) {
    Write-Host "MODE: DRY RUN. Nothing on disk will change." -ForegroundColor Yellow
}
Write-Host "ClaudeHome : $ClaudeHome"
Write-Host "RepoRoot   : $RepoRoot"

if (-not $PSBoundParameters.ContainsKey('PayloadPath') -or [string]::IsNullOrWhiteSpace($PayloadPath)) {
    $PayloadPath = Join-Path $PSScriptRoot 'payload'
}
Write-Host "Payload    : $PayloadPath"

Write-Head 'Preflight'

if (-not (Test-Path -LiteralPath $PayloadPath)) {
    Write-Host "FATAL: payload directory not found at $PayloadPath" -ForegroundColor Red
    Write-Host "Run this script from the folder that contains it, or pass -PayloadPath."
    exit 2
}
Write-Step "payload found"

try {
    $bashLauncher = Resolve-BashLauncher -RequestedPath $BashPath
    $script:BashCommandPrefix = $bashLauncher.CommandPrefix
    if (Test-WindowsHost) {
        Write-Step "Git Bash verified at $($bashLauncher.Executable)"
    }
    else {
        Write-Step "bash verified at $($bashLauncher.Executable)"
    }
}
catch {
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'No Claude files were changed.' -ForegroundColor Red
    exit 2
}

$py = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $py) {
    Add-Warning 'python was not found on PATH. The model phase boundary hook needs it and will stay silent.'
    Write-Step "WARN  python not on PATH"
}
else {
    Write-Step "python found at $($py.Source)"
}

if (-not (Test-Path -LiteralPath $RepoRoot)) {
    Add-Warning "RepoRoot $RepoRoot does not exist yet. Hooks skip repositories they cannot find, so this is safe."
    Write-Step "WARN  RepoRoot missing (safe)"
}

foreach ($d in @($ClaudeHome, (Join-Path $ClaudeHome 'agents'), (Join-Path $ClaudeHome 'hooks'))) {
    if (Test-Path -LiteralPath $d) { continue }
    if ($DryRun) { Write-Step "DRYRUN would create $d"; continue }
    if ($PSCmdlet.ShouldProcess($d, 'Create directory')) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Step "created $d"
    }
}

# ---------------------------------------------------------------------------
# Agents
# ---------------------------------------------------------------------------

Write-Head 'Agents'
$agentSrc = Join-Path $PayloadPath 'agents'
if (Test-Path -LiteralPath $agentSrc) {
    foreach ($f in (Get-ChildItem -LiteralPath $agentSrc -Filter '*.md' -File)) {
        Merge-ManagedAgentFile -Source $f.FullName `
            -Destination (Join-Path $ClaudeHome ('agents\' + $f.Name)) `
            -Label ('agent ' + $f.BaseName)
    }
}
else {
    Add-Failed 'agents' "payload folder missing at $agentSrc"
}

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------

Write-Head 'Hooks'
$hookSrc = Join-Path $PayloadPath 'hooks'
if (Test-Path -LiteralPath $hookSrc) {
    foreach ($f in (Get-ChildItem -LiteralPath $hookSrc -File | Where-Object { $_.Extension -in @('.sh', '.py') })) {
        Install-TemplatedFile -Source $f.FullName `
            -Destination (Join-Path $ClaudeHome ('hooks\' + $f.Name)) `
            -Label ('hook ' + $f.Name) `
            -OverwriteWhenDifferent:$Force
    }
}
else {
    Add-Failed 'hooks' "payload folder missing at $hookSrc"
}

$installerRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$lockstepSource = Join-Path $installerRoot 'gates\gateway_lockstep.py'
if (Test-Path -LiteralPath $lockstepSource -PathType Leaf) {
    Install-TemplatedFile -Source $lockstepSource `
        -Destination (Join-Path $ClaudeHome 'hooks\gateway_lockstep.py') `
        -Label 'hook gateway_lockstep.py' `
        -OverwriteWhenDifferent:$Force
}
else {
    Add-Failed 'hook gateway_lockstep.py' "shared verifier missing at $lockstepSource"
}

# ---------------------------------------------------------------------------
# Skills
# ---------------------------------------------------------------------------

Write-Head 'Skills'
$skillSrc = Join-Path $PayloadPath 'skills'
if (Test-Path -LiteralPath $skillSrc) {
    foreach ($d in (Get-ChildItem -LiteralPath $skillSrc -Directory)) {
        $sf = Join-Path $d.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $sf)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $d.FullName -Recurse -File | Sort-Object FullName)) {
            $relative = $f.FullName.Substring($d.FullName.Length).TrimStart([char[]]@('\', '/'))
            $destination = Join-Path (Join-Path (Join-Path $ClaudeHome 'skills') $d.Name) $relative
            $label = if ($relative -ceq 'SKILL.md') {
                'skill ' + $d.Name
            }
            else {
                'skill ' + $d.Name + '/' + $relative.Replace('\', '/')
            }
            Install-TemplatedFile -Source $f.FullName `
                -Destination $destination `
                -Label $label `
                -OverwriteWhenDifferent:$Force
        }
    }
}
else {
    Add-Skipped 'skills' 'no skills folder in payload'
}

# ---------------------------------------------------------------------------
# Canon file
# ---------------------------------------------------------------------------

Write-Head 'Canon (CLAUDE.md)'
if ($SkipCanon) {
    Add-Skipped 'CLAUDE.md' 'skipped by -SkipCanon'
    Write-Step 'SKIP  CLAUDE.md (-SkipCanon)'
}
else {
    $canonSrc = Join-Path $PayloadPath 'CLAUDE.md'
    if (Test-Path -LiteralPath $canonSrc) {
        # Canon is the one file most likely to hold the operator's own words.
        # It is never overwritten without -Force.
        Install-TemplatedFile -Source $canonSrc `
            -Destination (Join-Path $ClaudeHome 'CLAUDE.md') `
            -Label 'CLAUDE.md' `
            -OverwriteWhenDifferent:$Force
    }
    else {
        Add-Failed 'CLAUDE.md' "payload file missing at $canonSrc"
    }
}

# ---------------------------------------------------------------------------
# settings.json merge. The single most important safety property in this file.
# ---------------------------------------------------------------------------

Write-Head 'settings.json merge'
$settingsPath = Join-Path $ClaudeHome 'settings.json'
$fragPath = Join-Path $PayloadPath 'settings.fragment.json'

try {
    if (-not (Test-Path -LiteralPath $fragPath)) {
        throw "settings fragment missing at $fragPath"
    }

    $fragRaw = Expand-Tokens (Read-TextFile $fragPath)
    $fragment = ConvertTo-OrderedHash (ConvertFrom-Json $fragRaw)
    if ($null -eq $py) {
        $fragment['hooks']['Stop'] = @($fragment['hooks']['Stop'] | Where-Object {
            -not (@($_['hooks']) | Where-Object { [string]$_['command'] -match 'gateway_lockstep\.py' })
        })
        Add-Warning 'Gateway Lockstep Stop registration skipped because the exact Python runtime is unavailable.'
    }
    $renderedBashCommands = Render-FragmentBashCommands -FragmentHooks $fragment['hooks']
    if ($renderedBashCommands -ne 10 -or (Get-CanonicalJson $fragment).Contains('__DREAMEROS_BASH_COMMAND__')) {
        throw 'settings fragment Bash command rendering was incomplete.'
    }

    $existing = [ordered]@{}
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $existing = Read-JsonFile $settingsPath
            Write-Step "read existing settings.json"
        }
        catch {
            # A settings file that does not parse must stop the merge. Writing
            # over it would destroy configuration this installer cannot read.
            throw ("existing settings.json does not parse as JSON, so the merge was refused. " +
                "Fix or move the file, then run again. Parser said: " + $_.Exception.Message)
        }
    }
    else {
        Write-Step "no existing settings.json, a new one will be created"
    }

    $before = Get-CanonicalJson $existing
    $merged = Merge-Settings -Existing $existing -Fragment $fragment
    $after = Get-CanonicalJson $merged.Settings

    if ($before -eq $after) {
        Add-Skipped 'settings.json' 'already carries every DreamerOS entry'
        Write-Step 'SKIP  settings.json (no change needed)'
    }
    else {
        foreach ($c in $merged.Changes) { Write-Step "change: $c" }
        Backup-File $settingsPath | Out-Null
        $json = ConvertTo-Json -InputObject $merged.Settings -Depth 100
        Write-TextFile -Path $settingsPath -Content ($json + "`n")
        $note = ($merged.Changes -join '; ')
        if ([string]::IsNullOrWhiteSpace($note)) { $note = 'merged' }
        Add-Installed 'settings.json' $note
        Write-Step 'MERGE settings.json'
    }
}
catch {
    Add-Failed 'settings.json' $_.Exception.Message
    Write-Host "  FAIL  settings.json : $($_.Exception.Message)" -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host "SUMMARY" -ForegroundColor Green
Write-Host "=================================================="
if ($DryRun) { Write-Host "DRY RUN. Nothing on disk changed." -ForegroundColor Yellow }

Write-Host ""
Write-Host ("INSTALLED ({0})" -f $script:Installed.Count) -ForegroundColor Green
if ($script:Installed.Count -eq 0) { Write-Host "  none" }
foreach ($i in $script:Installed) { Write-Host ("  {0}  [{1}]" -f $i.Item, $i.Note) }

Write-Host ""
Write-Host ("SKIPPED, already present ({0})" -f $script:Skipped.Count) -ForegroundColor Yellow
if ($script:Skipped.Count -eq 0) { Write-Host "  none" }
foreach ($i in $script:Skipped) { Write-Host ("  {0}  [{1}]" -f $i.Item, $i.Note) }

Write-Host ""
Write-Host ("FAILED ({0})" -f $script:Failed.Count) -ForegroundColor Red
if ($script:Failed.Count -eq 0) { Write-Host "  none" }
foreach ($i in $script:Failed) { Write-Host ("  {0}  [{1}]" -f $i.Item, $i.Note) }

if ($script:Warnings.Count -gt 0) {
    Write-Host ""
    Write-Host ("WARNINGS ({0})" -f $script:Warnings.Count) -ForegroundColor Yellow
    foreach ($w in $script:Warnings) { Write-Host "  $w" }
}

Write-Host ""
if (-not $DryRun -and $script:Failed.Count -eq 0) {
    Write-Host "Backups, when anything changed, are under:" -ForegroundColor Cyan
    Write-Host ("  " + (Join-Path $ClaudeHome ('backups\dreameros-install-' + $script:Stamp)))
    Write-Host ""
    Write-Host "Next step: set DREAMEROS_MCP_TOKEN in your user environment, then"
    Write-Host "start a new Claude Code session. This installer never handles tokens."
}

if ($script:Failed.Count -gt 0) {
    Write-Host "Install finished with failures. Exit code 1." -ForegroundColor Red
    exit 1
}
Write-Host "Install finished. Exit code 0." -ForegroundColor Green
exit 0
