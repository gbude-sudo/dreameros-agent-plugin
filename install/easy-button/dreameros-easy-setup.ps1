# dreameros-easy-setup.ps1
# The DreamerOS easy button for Windows, v0.
#
# WHAT THIS IS
#   One script a customer runs once. It probes the machine for AI coding
#   tools, then writes the DreamerOS binding into each tool it finds, in
#   that tool's own native format. The customer edits nothing.
#
#   The estate script (bootpack/build-boot-pack.ps1) UPDATES an operator
#   machine that already has every file. This script PROVISIONS a customer
#   machine that has none of them. That is the whole difference: where the
#   estate script prints SKIP on a missing file, this one creates it.
#
# WHAT IT WRITES, per tool, all shapes taken from vendor docs or measured
# on a live install on 2026-08-26 (see install/easy-button/README.md for
# the source table):
#   Claude Code   ~/.claude/CLAUDE.md          block merge, created if absent
#   Codex CLI     ~/.codex/AGENTS.md           block merge, created if absent
#                 ~/.codex/config.toml         [mcp_servers.dreameros] append
#   Cursor        ~/.cursor/rules/dreameros.mdc  full write
#                 ~/.cursor/mcp.json           mcpServers.dreameros merge
#   VS Code       %APPDATA%/Code/User/mcp.json servers.dreameros merge
#   Antigravity   ~/.gemini/GEMINI.md          block merge, created if absent
#
#   Claude Code MCP registration goes through `claude mcp add` when the CLI
#   is on PATH, never by editing ~/.claude.json. That file is Claude Code's
#   live state and a bad write there breaks the tool this script serves.
#
# WHAT IT NEVER DOES
#   - It never writes a secret. The MCP entries reference the environment
#     variable DREAMEROS_MCP_TOKEN by NAME. The customer pastes the value
#     once, into their own environment, at the end. An installer that
#     handles token values is an installer that leaks them.
#   - It never deletes or truncates. Every existing file it must change is
#     backed up beside itself first, and block merges replace only the
#     marked DreamerOS block.
#   - It never symlinks. A CLAUDE.md symlink needs Administrator rights or
#     Developer Mode on Windows, per Anthropic's own memory doc.
#
# CONTENT
#   The instruction payload is fetched live from the public manifest at
#   install time, so a customer always gets the current boot contract:
#     GET https://mcp.dreameros.app/api/v1/agent/manifest
#       -> boot_contract.instruction_text
#   Measured 2026-08-26: HTTP 200, instruction_text 1367 chars. When the
#   fetch fails the embedded fallback below is used and the report says so.
#
# USAGE
#   .\dreameros-easy-setup.ps1                     do it
#   .\dreameros-easy-setup.ps1 -DryRun             show the plan, write nothing
#   .\dreameros-easy-setup.ps1 -HomeOverride <dir> operate on a fake home (tests)
#
# ASCII only. No em dashes. Spaced hyphens only.

[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$HomeOverride = ''
)

$ErrorActionPreference = 'Stop'

$Home_ = if ($HomeOverride) { $HomeOverride } else { $env:USERPROFILE }
$AppData_ = if ($HomeOverride) { Join-Path $HomeOverride 'AppData\Roaming' } else { $env:APPDATA }

$ManifestUrl = 'https://mcp.dreameros.app/api/v1/agent/manifest'
$McpUrl      = 'https://mcp.dreameros.app/mcp'
$TokenEnv    = 'DREAMEROS_MCP_TOKEN'
$Marker      = 'DREAMEROS-BOOT'
# The END marker carries NO version on purpose. The estate installer's
# versioned END marker cannot match a block written under an older version,
# so a version bump there appends a duplicate block instead of replacing.
$Begin = "<!-- BEGIN $Marker - written by dreameros-easy-setup, safe to delete as one block -->"
$End   = "<!-- END $Marker -->"

# Embedded fallback: used only when the live manifest cannot be fetched.
$FallbackContract = @"
<dreameros_boot_contract version="1.0.0" source="embedded-fallback">
- Models generate. DreamerOS verifies intent and integrity. The human decides.
- Use the local computer, repository files, Git, tests, and builds as the execution plane whenever possible.
- Use DreamerOS as the authority for current context, intent, routing, continuity, and receipts.
- At fresh start, resume, or compaction: load the DreamerOS session package first, then context and state, then relevant recall before substantive DreamerOS work.
- If DreamerOS is unavailable, report BLOCKED for gateway-dependent work, continue local work as STANDALONE, and never fabricate connection, hydration, synchronization, or receipts.
- Before completion: inspect local Git and diffs, run proportional checks, publish a concise handoff to DreamerOS memory when available, and read it back.
- Do not call work DONE unless a real customer path is verified end to end.
</dreameros_boot_contract>
"@

$Report = New-Object System.Collections.Generic.List[object]
function Note([string]$Tool, [string]$Target, [string]$Action) {
    $Report.Add([pscustomobject]@{ Tool = $Tool; Target = $Target; Action = $Action })
    $color = switch -Regex ($Action) {
        '^PROVISIONED|^HEALED|^REGISTERED' { 'Green' }
        '^ALIGNED'                          { 'DarkGreen' }
        '^WOULD '                           { 'Cyan' }
        '^NOT DETECTED'                     { 'DarkGray' }
        default                             { 'Yellow' }
    }
    Write-Host ("  {0,-12} {1,-52} {2}" -f $Tool, $Target, $Action) -ForegroundColor $color
}

function New-Dir([string]$p) { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    # A UTF-8 BOM made a real settings.json unparseable to JSON.parse on
    # 2026-08-26 with thirteen hooks behind it. Never write one.
    New-Dir (Split-Path -Parent $Path)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Backup([string]$Path) {
    if (Test-Path $Path) {
        Copy-Item $Path ($Path + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
}

# --- fetch the live contract --------------------------------------------------
$Contract = $null
$ContractSource = 'live manifest'
try {
    $resp = Invoke-RestMethod -Uri $ManifestUrl -TimeoutSec 5
    $t = $resp.boot_contract.instruction_text
    if ($t -and $t.Length -gt 200) { $Contract = $t }
} catch { }
if (-not $Contract) {
    $Contract = $FallbackContract
    $ContractSource = 'embedded fallback - the live manifest was unreachable'
}

$Block = "$Begin`n$Contract`n$End"

# --- block merge: replace our block, append if absent, create if missing ------
function Install-Block([string]$Tool, [string]$File) {
    if (-not (Test-Path $File)) {
        if ($DryRun) { Note $Tool $File 'WOULD PROVISION (create new file)'; return }
        Write-Utf8NoBom $File ($Block + "`n")
        Note $Tool $File 'PROVISIONED (new file)'
        return
    }
    $cur = Get-Content $File -Raw
    $pattern = [regex]::Escape($Begin.Substring(0, ("<!-- BEGIN $Marker").Length)) + '[\s\S]*?' + [regex]::Escape($End)
    if ($cur -match $pattern) {
        $new = [regex]::Replace($cur, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $Block })
    } else {
        $new = $cur.TrimEnd() + "`n`n" + $Block + "`n"
    }
    if ($new -eq $cur) { Note $Tool $File 'ALIGNED'; return }
    if ($DryRun) { Note $Tool $File 'WOULD HEAL (update block)'; return }
    Backup $File
    Write-Utf8NoBom $File $new
    Note $Tool $File 'HEALED (block updated)'
}

# --- JSON MCP merge, shape differs per tool -----------------------------------
function Install-JsonMcp([string]$Tool, [string]$File, [string]$RootKey, [hashtable]$Entry) {
    $obj = $null
    if (Test-Path $File) {
        try { $obj = Get-Content $File -Raw | ConvertFrom-Json }
        catch { Note $Tool $File 'MERGE NEEDED - the existing file does not parse as JSON. Not touching it.'; return }
    }
    if ($null -eq $obj) { $obj = New-Object psobject }
    if (-not ($obj.PSObject.Properties.Name -contains $RootKey)) {
        $obj | Add-Member -NotePropertyName $RootKey -NotePropertyValue (New-Object psobject)
    }
    $root = $obj.$RootKey
    $entryObj = New-Object psobject
    foreach ($k in ($Entry.Keys | Sort-Object)) { $entryObj | Add-Member -NotePropertyName $k -NotePropertyValue $Entry[$k] }
    if ($root.PSObject.Properties.Name -contains 'dreameros') {
        # Align on CONTENT, never on key presence. Presence-alignment means a
        # later shape fix would never reach an existing install - caught live
        # when a header edit did not heal the fake-home file.
        $curJson = $root.dreameros | ConvertTo-Json -Depth 8
        $newJson = $entryObj | ConvertTo-Json -Depth 8
        if ($curJson -eq $newJson) { Note $Tool $File 'ALIGNED (dreameros server current)'; return }
        if ($DryRun) { Note $Tool $File ("WOULD HEAL {0}.dreameros (shape drifted)" -f $RootKey); return }
        Backup $File
        $root.PSObject.Properties.Remove('dreameros')
        $root | Add-Member -NotePropertyName 'dreameros' -NotePropertyValue $entryObj
        Write-Utf8NoBom $File (($obj | ConvertTo-Json -Depth 8) + "`n")
        Note $Tool $File ("HEALED {0}.dreameros (shape updated)" -f $RootKey)
        return
    }
    if ($DryRun) { Note $Tool $File ("WOULD REGISTER {0}.dreameros" -f $RootKey); return }
    $root | Add-Member -NotePropertyName 'dreameros' -NotePropertyValue $entryObj
    Backup $File
    Write-Utf8NoBom $File (($obj | ConvertTo-Json -Depth 8) + "`n")
    Note $Tool $File ("REGISTERED {0}.dreameros" -f $RootKey)
}

Write-Host ''
Write-Host 'DreamerOS easy setup v0' -ForegroundColor Cyan
Write-Host ("  contract source: {0}" -f $ContractSource)
if ($DryRun) { Write-Host '  DRY RUN - nothing will be written' -ForegroundColor Cyan }
Write-Host ''

# --- Claude Code --------------------------------------------------------------
$claudeHome = Join-Path $Home_ '.claude'
$claudeCli  = Get-Command claude -ErrorAction SilentlyContinue
if ((Test-Path $claudeHome) -or $claudeCli) {
    Install-Block 'Claude Code' (Join-Path $claudeHome 'CLAUDE.md')
    if ($claudeCli -and -not $HomeOverride) {
        # Registration goes through the CLI, never by editing ~/.claude.json.
        $listed = ''
        try { $listed = (& claude mcp list 2>$null) -join "`n" } catch { }
        if ($listed -match 'dreameros') {
            Note 'Claude Code' 'claude mcp (user scope)' 'ALIGNED (dreameros server present)'
        } elseif ($DryRun) {
            Note 'Claude Code' 'claude mcp (user scope)' 'WOULD REGISTER via claude mcp add'
        } else {
            try {
                & claude mcp add --scope user --transport http dreameros $McpUrl --header "Authorization: Bearer `${$TokenEnv}" 2>$null | Out-Null
                Note 'Claude Code' 'claude mcp (user scope)' 'REGISTERED via claude mcp add'
            } catch {
                Note 'Claude Code' 'claude mcp (user scope)' 'MERGE NEEDED - claude mcp add failed. Run it by hand.'
            }
        }
    } elseif ($HomeOverride) {
        Note 'Claude Code' 'claude mcp (user scope)' 'SKIPPED (HomeOverride test mode never calls the real CLI)'
    } else {
        Note 'Claude Code' 'claude mcp (user scope)' 'MERGE NEEDED - claude CLI not on PATH. Install Claude Code, then rerun.'
    }
} else { Note 'Claude Code' $claudeHome 'NOT DETECTED' }

# --- Codex CLI ----------------------------------------------------------------
$codexHome = Join-Path $Home_ '.codex'
$codexCli  = Get-Command codex -ErrorAction SilentlyContinue
if ((Test-Path $codexHome) -or $codexCli) {
    Install-Block 'Codex' (Join-Path $codexHome 'AGENTS.md')
    $toml = Join-Path $codexHome 'config.toml'
    $tomlBody = if (Test-Path $toml) { Get-Content $toml -Raw } else { '' }
    if ($tomlBody -match '(?m)^\[mcp_servers\.dreameros\]') {
        Note 'Codex' $toml 'ALIGNED (dreameros server present)'
    } elseif ($DryRun) {
        Note 'Codex' $toml 'WOULD REGISTER [mcp_servers.dreameros]'
    } else {
        # Appending a new table at end of file is valid TOML as long as the
        # table is not already defined. Checked two lines above.
        $section = "`n[mcp_servers.dreameros]`nurl = `"$McpUrl`"`nbearer_token_env_var = `"$TokenEnv`"`n"
        Backup $toml
        Write-Utf8NoBom $toml (($tomlBody.TrimEnd() + "`n" + $section).TrimStart("`n"))
        Note 'Codex' $toml 'REGISTERED [mcp_servers.dreameros]'
    }
} else { Note 'Codex' $codexHome 'NOT DETECTED' }

# --- Cursor -------------------------------------------------------------------
$cursorHome = Join-Path $Home_ '.cursor'
if (Test-Path $cursorHome) {
    $mdc = Join-Path $cursorHome 'rules\dreameros.mdc'
    $mdcText = "---`ndescription: DreamerOS boot contract. Always applied.`nalwaysApply: true`n---`n`n$Contract`n"
    if ((Test-Path $mdc) -and ((Get-Content $mdc -Raw) -eq $mdcText)) {
        Note 'Cursor' $mdc 'ALIGNED'
    } elseif ($DryRun) {
        Note 'Cursor' $mdc 'WOULD PROVISION rule file'
    } else {
        Backup $mdc
        Write-Utf8NoBom $mdc $mdcText
        Note 'Cursor' $mdc 'PROVISIONED rule file'
    }
    # Cursor reads mcpServers with url + headers. Env reference, never a value.
    Install-JsonMcp 'Cursor' (Join-Path $cursorHome 'mcp.json') 'mcpServers' @{
        url     = $McpUrl
        headers = @{ Authorization = ('Bearer ${env:' + $TokenEnv + '}') }
    }
} else { Note 'Cursor' $cursorHome 'NOT DETECTED' }

# --- VS Code (Copilot MCP) ----------------------------------------------------
$vscodeUser = Join-Path $AppData_ 'Code\User'
if (Test-Path $vscodeUser) {
    # VS Code's key is servers, not mcpServers, and remote entries need type.
    # The header uses VS Code's own env interpolation so no value is written.
    Install-JsonMcp 'VS Code' (Join-Path $vscodeUser 'mcp.json') 'servers' @{
        type    = 'http'
        url     = $McpUrl
        headers = @{ Authorization = ('Bearer ${env:' + $TokenEnv + '}') }
    }
} else { Note 'VS Code' $vscodeUser 'NOT DETECTED' }

# --- Antigravity / Gemini instruction file ------------------------------------
$geminiHome = Join-Path $Home_ '.gemini'
if (Test-Path $geminiHome) {
    Install-Block 'Antigravity' (Join-Path $geminiHome 'GEMINI.md')
} else { Note 'Antigravity' $geminiHome 'NOT DETECTED' }

# --- report -------------------------------------------------------------------
Write-Host ''
$did      = @($Report | Where-Object { $_.Action -match '^(PROVISIONED|HEALED|REGISTERED)' }).Count
$aligned  = @($Report | Where-Object { $_.Action -match '^ALIGNED' }).Count
$manual   = @($Report | Where-Object { $_.Action -match '^MERGE NEEDED' }).Count
$absent   = @($Report | Where-Object { $_.Action -match '^NOT DETECTED' }).Count
Write-Host ("done: {0} written, {1} already aligned, {2} need a hand, {3} tools not on this machine" -f $did, $aligned, $manual, $absent) -ForegroundColor Cyan

if (-not $DryRun) {
    Write-Host ''
    Write-Host 'ONE THING LEFT, and only you can do it:' -ForegroundColor Yellow
    Write-Host ("  set the environment variable {0} to your DreamerOS token." -f $TokenEnv) -ForegroundColor Yellow
    Write-Host ("  PowerShell:  [Environment]::SetEnvironmentVariable('{0}', '<paste token>', 'User')" -f $TokenEnv) -ForegroundColor Yellow
    Write-Host '  Get your token from your DreamerOS account page. This script never touches it.' -ForegroundColor Yellow
}
