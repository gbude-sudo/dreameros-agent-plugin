[CmdletBinding()]
param(
    [switch]$Update,
    [switch]$VerifyOnly,
    [switch]$Uninstall,
    [string]$RestoreBackup,
    [string]$ConfirmAction
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$PluginRoot = Join-Path $env:USERPROFILE '.cursor\plugins'
$LocalRoot = Join-Path $PluginRoot 'local'
$Target = Join-Path $LocalRoot 'dreameros'
$BackupRoot = Join-Path $PluginRoot 'backups'

$Assets = @(
    '.cursor-plugin',
    'bootpack\out\cursor',
    'bootpack\out\evidence',
    'skills',
    'cursor'
)
$LegacyCursorRootFiles = @('plugin.json', 'mcp.json')

function Assert-ChildPath([string]$Path, [string]$Parent, [string]$Label) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escaped its managed parent: $full"
    }
}

function Get-TreeDigest([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Plugin tree does not exist: $Path"
    }
    $lines = @(
        Get-ChildItem -LiteralPath $Path -File -Recurse -Force |
            Where-Object { $_.Extension -ne '.pyc' -and $_.FullName -notmatch '\\__pycache__\\' } |
            Sort-Object FullName |
            ForEach-Object {
                $relative = $_.FullName.Substring($Path.Length).TrimStart('\').Replace('\', '/')
                $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
                "$relative|$hash"
            }
    )
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($lines -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-RestorableTree([string]$Path) {
    foreach ($required in @(
        '.cursor-plugin\plugin.json',
        'cursor\hooks\hooks.json',
        'cursor\hooks\dreameros_cursor_hook.py',
        'cursor\mcp.json'
    )) {
        $candidate = Join-Path $Path $required
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Restore backup is missing required plugin file: $required"
        }
    }
    Get-Content -Raw -LiteralPath (Join-Path $Path '.cursor-plugin\plugin.json') | ConvertFrom-Json | Out-Null
    Get-Content -Raw -LiteralPath (Join-Path $Path 'cursor\hooks\hooks.json') | ConvertFrom-Json | Out-Null
    Get-Content -Raw -LiteralPath (Join-Path $Path 'cursor\mcp.json') | ConvertFrom-Json | Out-Null
    foreach ($legacyManifest in @('plugin.json', 'mcp.json')) {
        $legacyPath = Join-Path $Path $legacyManifest
        if (Test-Path -LiteralPath $legacyPath -PathType Leaf) {
            Get-Content -Raw -LiteralPath $legacyPath | ConvertFrom-Json | Out-Null
        }
    }
}

Assert-ChildPath -Path $Target -Parent $LocalRoot -Label 'Cursor plugin target'
Assert-ChildPath -Path $BackupRoot -Parent $PluginRoot -Label 'Cursor plugin backup root'

$modeFlags = @([bool]$VerifyOnly, [bool]$Uninstall, [bool](-not [string]::IsNullOrWhiteSpace($RestoreBackup)))
$modeCount = @($modeFlags | Where-Object { $_ }).Count
if ($modeCount -gt 1 -or ($Update -and $modeCount -gt 0)) {
    throw 'Choose exactly one operation: install/update, VerifyOnly, Uninstall, or RestoreBackup.'
}

if ($Uninstall) {
    if ($ConfirmAction -cne 'UNINSTALL DREAMEROS CURSOR PLUGIN') {
        throw 'Recoverable uninstall requires -ConfirmAction "UNINSTALL DREAMEROS CURSOR PLUGIN".'
    }
    if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
        throw "Cursor plugin target is not installed: $Target"
    }
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $uninstalled = Join-Path $BackupRoot ('uninstalled-dreameros-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
    Assert-ChildPath -Path $uninstalled -Parent $BackupRoot -Label 'Cursor plugin uninstall backup'
    if (Test-Path -LiteralPath $uninstalled) { throw "Uninstall backup destination exists: $uninstalled" }
    $beforeDigest = Get-TreeDigest $Target
    Move-Item -LiteralPath $Target -Destination $uninstalled
    if ((Test-Path -LiteralPath $Target) -or (Get-TreeDigest $uninstalled) -ne $beforeDigest) {
        throw "Recoverable uninstall verification failed. Inspect $uninstalled and $Target before any retry."
    }
    Write-Output "UNINSTALLED Cursor plugin to recoverable backup $uninstalled digest=$beforeDigest"
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($RestoreBackup)) {
    if ($ConfirmAction -cne 'RESTORE DREAMEROS CURSOR PLUGIN BACKUP') {
        throw 'Restore requires -ConfirmAction "RESTORE DREAMEROS CURSOR PLUGIN BACKUP".'
    }
    if (-not [IO.Path]::IsPathRooted($RestoreBackup)) { throw 'RestoreBackup must be an absolute path.' }
    if (-not (Test-Path -LiteralPath $RestoreBackup -PathType Container)) {
        throw "Restore backup does not exist: $RestoreBackup"
    }
    $restore = (Resolve-Path -LiteralPath $RestoreBackup).Path.TrimEnd('\')
    Assert-ChildPath -Path $restore -Parent $BackupRoot -Label 'Cursor plugin restore backup'
    if (-not [string]::Equals((Split-Path -Parent $restore).TrimEnd('\'), $BackupRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'RestoreBackup must be one direct child of the managed Cursor backup directory.'
    }
    if (Test-Path -LiteralPath $Target) {
        throw "Restore target already exists. Run the recoverable Uninstall operation first: $Target"
    }
    Assert-RestorableTree $restore
    $beforeDigest = Get-TreeDigest $restore
    New-Item -ItemType Directory -Path $LocalRoot -Force | Out-Null
    try {
        Move-Item -LiteralPath $restore -Destination $Target
        Assert-RestorableTree $Target
        if ((Test-Path -LiteralPath $restore) -or (Get-TreeDigest $Target) -ne $beforeDigest) {
            throw 'Restored target digest differs from the selected backup.'
        }
    } catch {
        $reason = $_.Exception.Message
        if ((Test-Path -LiteralPath $Target -PathType Container) -and -not (Test-Path -LiteralPath $restore)) {
            Move-Item -LiteralPath $Target -Destination $restore
        }
        if (-not (Test-Path -LiteralPath $restore -PathType Container) -or (Get-TreeDigest $restore) -ne $beforeDigest) {
            throw "Restore failed and rollback could not verify the original backup: $reason"
        }
        throw "Restore failed; the selected backup was returned to its original path: $reason"
    }
    $legacyRestored = @(@('plugin.json', 'mcp.json') | Where-Object { Test-Path -LiteralPath (Join-Path $Target $_) })
    if ($legacyRestored.Count -gt 0) {
        Write-Output ("RESTORED LEGACY DUAL-MANIFEST Cursor backup; reload will reactivate preserved root manifest(s): {0}" -f ($legacyRestored -join ', '))
    }
    Write-Output "RESTORED Cursor plugin from $RestoreBackup digest=$beforeDigest"
    exit 0
}

function Get-Python {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "The Cursor hook manifest invokes 'python'. Install or expose that exact command before installing; accepting python3 or py here would validate a runtime command Cursor cannot launch."
}

function Assert-Source {
    $manifest = Join-Path $RepoRoot '.cursor-plugin\plugin.json'
    $mcp = Join-Path $RepoRoot 'mcp.json'
    $cursorMcp = Join-Path $RepoRoot 'cursor\mcp.json'
    $hooks = Join-Path $RepoRoot 'cursor\hooks\hooks.json'
    Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json | Out-Null
    Get-Content -Raw -LiteralPath $mcp | ConvertFrom-Json | Out-Null
    Get-Content -Raw -LiteralPath $cursorMcp | ConvertFrom-Json | Out-Null
    Get-Content -Raw -LiteralPath $hooks | ConvertFrom-Json | Out-Null
    if ((Get-Content -Raw -LiteralPath $mcp) -match 'Authorization' -or
        (Get-Content -Raw -LiteralPath $cursorMcp) -match 'Authorization') {
        throw 'Cursor plugin MCP config must not contain an Authorization header.'
    }
    $bootSource = Join-Path $RepoRoot 'bootpack\out\cursor\dreameros-global-plugin-pointer.mdc'
    $bootInstalled = Join-Path $env:USERPROFILE '.cursor\rules\dreameros-boot-canon.mdc'
    if (-not (Test-Path -LiteralPath $bootInstalled)) {
        throw 'Global Cursor plugin pointer is missing. Run bootpack\build-boot-pack.ps1 -Install first.'
    }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $bootSource).Hash -ne
        (Get-FileHash -Algorithm SHA256 -LiteralPath $bootInstalled).Hash) {
        throw 'Global Cursor plugin pointer drifted. Run bootpack\build-boot-pack.ps1 -Install first.'
    }
    $python = Get-Python
    & $python (Join-Path $RepoRoot 'cursor\hooks\dreameros_cursor_hook.py') --self-test
    if ($LASTEXITCODE -ne 0) { throw 'Cursor hook self-test failed.' }
}

function Copy-Asset([string]$Relative) {
    $source = Join-Path $RepoRoot $Relative
    $destination = Join-Path $Target $Relative
    if (Test-Path -LiteralPath $source -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse -Force |
            Where-Object { $_.Extension -ne '.pyc' -and $_.FullName -notmatch '\\__pycache__\\' }) {
            $suffix = $file.FullName.Substring($source.Length).TrimStart('\')
            $installed = Join-Path $destination $suffix
            New-Item -ItemType Directory -Path (Split-Path -Parent $installed) -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $installed -Force
        }
    } else {
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}

function Assert-Installed {
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in $Assets) {
        $source = Join-Path $RepoRoot $relative
        if (Test-Path -LiteralPath $source -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse -Force |
                Where-Object { $_.Extension -ne '.pyc' -and $_.FullName -notmatch '\\__pycache__\\' }) {
                $suffix = $file.FullName.Substring($RepoRoot.Length).TrimStart('\')
                [void]$expected.Add($suffix)
                $installed = Join-Path $Target $suffix
                if (-not (Test-Path -LiteralPath $installed)) { throw "installed file missing: $suffix" }
                if ((Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash -ne
                    (Get-FileHash -Algorithm SHA256 -LiteralPath $installed).Hash) {
                    throw "installed file differs: $suffix"
                }
            }
        } else {
            [void]$expected.Add($relative)
            $installed = Join-Path $Target $relative
            if (-not (Test-Path -LiteralPath $installed)) { throw "installed file missing: $relative" }
            if ((Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -ne
                (Get-FileHash -Algorithm SHA256 -LiteralPath $installed).Hash) {
                throw "installed file differs: $relative"
            }
        }
    }
    foreach ($legacy in $LegacyCursorRootFiles) {
        if (Test-Path -LiteralPath (Join-Path $Target $legacy)) {
            throw "ambiguous Cursor install contains portable root manifest: $legacy"
        }
    }
    $extras = @(
        Get-ChildItem -LiteralPath $Target -File -Recurse -Force |
            ForEach-Object { $_.FullName.Substring($Target.Length).TrimStart('\') } |
            Where-Object { -not $expected.Contains($_) }
    )
    if ($extras.Count -gt 0) {
        throw "installed target contains obsolete or unmanaged files: $($extras -join ', ')"
    }
}

Assert-Source

if ($VerifyOnly) {
    if (-not (Test-Path -LiteralPath $Target)) { throw "Cursor plugin is not installed at $Target" }
    Assert-Installed
    Write-Output "VERIFIED Cursor plugin bytes at $Target"
    exit 0
}

$backup = $null
if (Test-Path -LiteralPath $Target) {
    if (-not $Update) {
        throw "Target exists. Nothing was overwritten. Re-run with -Update to create a backup before updating: $Target"
    }
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $backup = Join-Path $BackupRoot ('dreameros-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
    Assert-ChildPath -Path $backup -Parent $BackupRoot -Label 'Cursor plugin backup'
    if (Test-Path -LiteralPath $backup) { throw "Backup destination already exists: $backup" }
    Move-Item -LiteralPath $Target -Destination $backup
    Write-Output "BACKUP $backup"
}

try {
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    foreach ($asset in $Assets) { Copy-Asset $asset }
    Assert-Installed
} catch {
    if (Test-Path -LiteralPath $Target) {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
        $failed = Join-Path $BackupRoot ('failed-dreameros-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
        Assert-ChildPath -Path $failed -Parent $BackupRoot -Label 'Failed Cursor plugin capture'
        Move-Item -LiteralPath $Target -Destination $failed
        Write-Output "FAILED INSTALL CAPTURE $failed"
    }
    if ($backup -and (Test-Path -LiteralPath $backup)) {
        Move-Item -LiteralPath $backup -Destination $Target
        Write-Output "ROLLBACK restored $Target"
    }
    throw
}

Write-Output "INSTALLED Cursor plugin at $Target"
Write-Output 'NEXT: reload Cursor, confirm dreameros-platform in Customize, then complete DreamerOS OAuth when Cursor asks.'
