<#
.SYNOPSIS
  Install the DreamerOS policy layer for Claude Code as a machine-wide
  managed settings file.

.DESCRIPTION
  Why: on 2026-09-16 a single wrong-typed value made Claude Code skip the whole
  user settings file (~/.claude/settings.json). Every hook, the deny list and
  the env block were off, with no visible error in the Desktop app. Managed
  settings load above every user and project file, apply to the terminal, the
  IDE extensions, the Desktop app's Code tab and Agent SDK sessions, and a user
  edit cannot remove them.

  What it writes (Windows):
    C:\Program Files\ClaudeCode\managed-settings.json
    C:\Program Files\ClaudeCode\dreameros\hooks\validate_claude_settings.py
    C:\Program Files\ClaudeCode\dreameros\hooks\gate_live_canon.py
    C:\Program Files\ClaudeCode\dreameros\claude-code-settings.schema.json

  Policy contents:
    - permissions.deny: the DreamerOS deny list (payload/settings.fragment.json)
    - SessionStart hooks: the settings validator and the live-canon check

  It never overwrites an existing managed file blindly. It merges: deny rules
  are unioned and each DreamerOS hook is added once. It backs up the old file,
  validates the new one with the validator BEFORE and AFTER writing, and
  restores the backup if the post-write check fails.

.PARAMETER DryRun
  Build and validate the policy, print it, and write nothing. Does not need
  administrator rights.

.PARAMETER PythonPath
  Absolute path to python.exe for the hook commands. Default: the first python
  on PATH, resolved to an absolute path.

.PARAMETER TargetDir
  Override the managed directory (tests only).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File dreameros-policy-setup.ps1 -DryRun
  Start-Process powershell -Verb RunAs -ArgumentList '-ExecutionPolicy Bypass -File "<path>\dreameros-policy-setup.ps1"'
#>
[CmdletBinding()]
param(
    [switch] $DryRun,
    [string] $PythonPath,
    [string] $TargetDir = 'C:\Program Files\ClaudeCode',
    # Tests only: apply the ACL lock to a non-default -TargetDir.
    [switch] $LockForTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Payload  = Join-Path $Here 'payload'
$Fragment = Join-Path $Payload 'settings.fragment.json'
$SrcHooks = Join-Path $Payload 'hooks'
$SrcSchema = Join-Path $Payload 'dreameros\claude-code-settings.schema.json'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Say([string] $m) { Write-Host "[dreameros-policy] $m" }

# 1. Python
if (-not $PythonPath) {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $cmd) { throw 'python not found on PATH. Pass -PythonPath.' }
    $PythonPath = $cmd.Source
}
if (-not (Test-Path -LiteralPath $PythonPath)) { throw "PythonPath not found: $PythonPath" }
$ver = & $PythonPath -c "import sys;print(sys.version_info[0])"
if ($ver -ne '3') { throw "PythonPath is not Python 3: $PythonPath" }
Say "python: $PythonPath"

# 2. Admin check (a real install writes under Program Files)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$defaultTarget = ($TargetDir -eq 'C:\Program Files\ClaudeCode')
if (-not $DryRun -and $defaultTarget -and -not $isAdmin) {
    throw 'Run this from an elevated PowerShell (Run as administrator), or use -DryRun.'
}

$HookDir    = Join-Path $TargetDir 'dreameros\hooks'
$SchemaDest = Join-Path $TargetDir 'dreameros\claude-code-settings.schema.json'
$ManagedFile = Join-Path $TargetDir 'managed-settings.json'

function HookCmd([string] $script, [string] $arg = '') {
    $p = (Join-Path $HookDir $script).Replace('\', '/')
    $py = $PythonPath.Replace('\', '/')
    $c = "`"$py`" `"$p`""
    if ($arg) { $c = "$c $arg" }
    return $c
}

# 3. Build the policy
$frag = Get-Content -LiteralPath $Fragment -Raw -Encoding UTF8 | ConvertFrom-Json
$deny = @($frag.permissions.deny)

$existing = $null
if (Test-Path -LiteralPath $ManagedFile) {
    $existing = Get-Content -LiteralPath $ManagedFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Say "existing managed file found; merging"
}

$policy = [ordered]@{}
if ($existing) {
    foreach ($p in $existing.PSObject.Properties) { $policy[$p.Name] = $p.Value }
}

# deny: union, order kept
$perm = [ordered]@{}
if ($policy.Contains('permissions') -and $policy['permissions']) {
    foreach ($p in $policy['permissions'].PSObject.Properties) { $perm[$p.Name] = $p.Value }
}
$oldDeny = @()
if ($perm.Contains('deny') -and $perm['deny']) { $oldDeny = @($perm['deny']) }
$merged = New-Object System.Collections.Generic.List[string]
foreach ($r in @($oldDeny + $deny)) { if (-not $merged.Contains([string]$r)) { $merged.Add([string]$r) } }
$perm['deny'] = $merged.ToArray()
$policy['permissions'] = $perm

# hooks: add each DreamerOS SessionStart hook once
$wanted = @(
    @{ type = 'command'; command = (HookCmd 'validate_claude_settings.py' '--hook'); timeout = 30 },
    @{ type = 'command'; command = (HookCmd 'gate_live_canon.py'); timeout = 60 }
)
$hooks = [ordered]@{}
if ($policy.Contains('hooks') -and $policy['hooks']) {
    foreach ($p in $policy['hooks'].PSObject.Properties) { $hooks[$p.Name] = @($p.Value) }
}
$ss = @()
if ($hooks.Contains('SessionStart')) { $ss = @($hooks['SessionStart']) }
$present = @()
foreach ($g in $ss) { foreach ($h in @($g.hooks)) { $present += [string]$h.command } }
foreach ($w in $wanted) {
    if ($present -notcontains $w.command) { $ss += [ordered]@{ hooks = @($w) } }
}
$hooks['SessionStart'] = $ss
$policy['hooks'] = $hooks

$json = ($policy | ConvertTo-Json -Depth 20)

# 4. Validate BEFORE writing, with the validator from the payload
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("dreameros-managed-" + [guid]::NewGuid().ToString('N') + '.json')
[IO.File]::WriteAllText($tmp, $json, $Utf8)
& $PythonPath (Join-Path $SrcHooks 'validate_claude_settings.py') $tmp
$pre = $LASTEXITCODE
if ($pre -ne 0) { Remove-Item -LiteralPath $tmp; throw "policy failed validation (exit $pre); nothing written" }
Say 'policy validated before write'

if ($DryRun) {
    Write-Host $json
    Remove-Item -LiteralPath $tmp
    Say 'DRY RUN: nothing written'
    exit 0
}

# 5. Write hooks, schema, then the policy, with a backup
New-Item -ItemType Directory -Force -Path $HookDir | Out-Null
Copy-Item -LiteralPath (Join-Path $SrcHooks 'validate_claude_settings.py') -Destination $HookDir -Force
Copy-Item -LiteralPath (Join-Path $SrcHooks 'gate_live_canon.py') -Destination $HookDir -Force
Copy-Item -LiteralPath $SrcSchema -Destination $SchemaDest -Force

$backup = $null
if (Test-Path -LiteralPath $ManagedFile) {
    $backup = "$ManagedFile.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $ManagedFile -Destination $backup -Force
    Say "backup: $backup"
}
Move-Item -LiteralPath $tmp -Destination $ManagedFile -Force

# 6. Validate AFTER writing, from the installed copy; roll back on failure
& $PythonPath (Join-Path $HookDir 'validate_claude_settings.py') $ManagedFile
if ($LASTEXITCODE -ne 0) {
    if ($backup) { Copy-Item -LiteralPath $backup -Destination $ManagedFile -Force; Say 'ROLLED BACK to backup' }
    else { Remove-Item -LiteralPath $ManagedFile -Force; Say 'ROLLED BACK: removed new file' }
    throw 'post-write validation failed'
}
# 7. Lock the managed directory. C:\Program Files grants CREATOR OWNER full
# control, so the account that ran this elevated installer otherwise owns the
# policy and can edit it without elevation (measured 2026-09-16: the user and
# CodexSandboxUsers had write access). Only SYSTEM and Administrators may
# write; Users may read and run the hooks.
#
# How, and why in this order (2026-09-16 lesson): set the explicit grants on
# the DIRECTORY only, then /reset the children so every file inherits them.
# The first version ran /inheritance:r /grant:r (OI)(CI) with /T: on files the
# (OI)(CI) grants do not apply, so every file was left with NO access entries
# and nobody, Claude Code included, could read the policy.
if ($defaultTarget -or $LockForTest) {
    # Build the directory ACL from nothing: exactly three entries, inheritance
    # off. icacls /grant:r only replaces the named accounts and would keep any
    # other explicit entry (for example OWNER RIGHTS full control).
    $sec = New-Object System.Security.AccessControl.DirectorySecurity
    $sec.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $prop = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($pair in @(
        @('S-1-5-18', 'FullControl'),
        @('S-1-5-32-544', 'FullControl'),
        @('S-1-5-32-545', 'ReadAndExecute')
    )) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($pair[0])
        $rights = [System.Security.AccessControl.FileSystemRights]$pair[1]
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $rights, $inherit, $prop, $allow)))
    }
    (New-Object System.IO.DirectoryInfo($TargetDir)).SetAccessControl($sec)
    $out = & icacls (Join-Path $TargetDir '*') /reset /T /C 2>&1
    if ($LASTEXITCODE -ne 0) { throw "could not propagate the lock under $TargetDir : $out" }

    foreach ($f in @($ManagedFile, (Join-Path $HookDir 'gate_live_canon.py'))) {
        $lines = @(& icacls $f 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "cannot read the ACL of $f after locking: $($lines -join ' ')" }
        $text = $lines -join "`n"
        if ($text -notmatch 'Users:\(I\)\(RX\)') { throw "Users cannot read $f after locking: $text" }
        $bad = $lines | Where-Object {
            $_ -match ':\(' -and $_ -notmatch 'SYSTEM|Administrators' -and $_ -match '\((F|M|W)\)|\(M,|,W\)|\(W,'
        }
        if ($bad) { throw "$f is still writable by a non-admin: $($bad -join '; ')" }
    }
    Say 'locked: only SYSTEM and Administrators can change the policy; Users can read it'
}

# .NET hash: Get-FileHash is missing when Windows PowerShell 5.1 is started
# from PowerShell 7 (module path mismatch, seen on GitHub runners 2026-09-16).
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $bytes = [IO.File]::ReadAllBytes($ManagedFile)
    $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLower()
} finally { $sha.Dispose() }
Say "installed: $ManagedFile"
Say "sha256: $hash"
Say 'Next: open a NEW Claude Code session. /status should list "Enterprise managed settings (file)",'
Say 'and the session should start with a "DreamerOS boot:" line.'
if ($backup) { Say "Undo: Copy-Item '$backup' '$ManagedFile' -Force" }
else { Say "Undo: Remove-Item '$ManagedFile'" }
