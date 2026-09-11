[CmdletBinding()]
param([string[]]$EstateRoots)

$ErrorActionPreference = 'Stop'
$ExpectedUrl = 'https://mcp.dreameros.app/mcp'
if (-not $EstateRoots -or $EstateRoots.Count -eq 0) { throw 'Provide estate roots. This inventory never writes.' }

function Assert-SafePath([string]$Path, [string]$Root) {
    $full = [IO.Path]::GetFullPath($Path); $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not $full.StartsWith(($base + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw "Path escaped estate root: $full" }
    $cursor = if (Test-Path -LiteralPath $full) { $full } else { Split-Path -Parent $full }
    while ($cursor -and $cursor.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Path crosses reparse point: $cursor" }
        if ($cursor -eq $base) { break }; $cursor = Split-Path -Parent $cursor
    }
}

function Skip-StrictJsonWhitespace([string]$Raw, [ref]$Index) {
    while ($Index.Value -lt $Raw.Length -and " `t`r`n".IndexOf($Raw[$Index.Value]) -ge 0) { $Index.Value++ }
}

function Test-StrictJsonDigit([char]$Value) {
    $code = [int][char]$Value
    return $code -ge 48 -and $code -le 57
}

function Read-StrictJsonString([string]$Raw, [ref]$Index) {
    if ($Index.Value -ge $Raw.Length -or $Raw[$Index.Value] -ne '"') { throw 'Expected JSON string.' }
    $Index.Value++
    $builder = New-Object Text.StringBuilder
    while ($Index.Value -lt $Raw.Length) {
        $character = $Raw[$Index.Value]
        if ($character -eq '"') { $Index.Value++; return $builder.ToString() }
        if ($character -eq '\') {
            $Index.Value++
            if ($Index.Value -ge $Raw.Length) { throw 'Unterminated JSON escape.' }
            $escape = $Raw[$Index.Value]
            switch ($escape) {
                '"' { [void]$builder.Append('"') }
                '\' { [void]$builder.Append('\') }
                '/' { [void]$builder.Append('/') }
                'b' { [void]$builder.Append([char]8) }
                'f' { [void]$builder.Append([char]12) }
                'n' { [void]$builder.Append("`n") }
                'r' { [void]$builder.Append("`r") }
                't' { [void]$builder.Append("`t") }
                'u' {
                    if ($Index.Value + 4 -ge $Raw.Length) { throw 'Incomplete JSON unicode escape.' }
                    $hex = $Raw.Substring($Index.Value + 1, 4)
                    if ($hex -notmatch '^[0-9A-Fa-f]{4}$') { throw 'Invalid JSON unicode escape.' }
                    [void]$builder.Append([char][Convert]::ToInt32($hex, 16))
                    $Index.Value += 4
                }
                default { throw 'Invalid JSON escape.' }
            }
        } elseif ([int][char]$character -lt 32) {
            throw 'Unescaped control character in JSON string.'
        } else {
            [void]$builder.Append($character)
        }
        $Index.Value++
    }
    throw 'Unterminated JSON string.'
}

function Read-StrictJsonNumber([string]$Raw, [ref]$Index) {
    $length = $Raw.Length
    if ($Raw[$Index.Value] -eq '-') { $Index.Value++ }
    if ($Index.Value -ge $length) { throw 'Incomplete JSON number.' }
    if ($Raw[$Index.Value] -eq '0') {
        $Index.Value++
    } elseif ($Raw[$Index.Value] -ge '1' -and $Raw[$Index.Value] -le '9') {
        while ($Index.Value -lt $length -and (Test-StrictJsonDigit $Raw[$Index.Value])) { $Index.Value++ }
    } else {
        throw 'Invalid JSON number.'
    }
    if ($Index.Value -lt $length -and $Raw[$Index.Value] -eq '.') {
        $Index.Value++
        if ($Index.Value -ge $length -or -not (Test-StrictJsonDigit $Raw[$Index.Value])) { throw 'Invalid JSON fraction.' }
        while ($Index.Value -lt $length -and (Test-StrictJsonDigit $Raw[$Index.Value])) { $Index.Value++ }
    }
    if ($Index.Value -lt $length -and ($Raw[$Index.Value] -eq 'e' -or $Raw[$Index.Value] -eq 'E')) {
        $Index.Value++
        if ($Index.Value -lt $length -and ($Raw[$Index.Value] -eq '+' -or $Raw[$Index.Value] -eq '-')) { $Index.Value++ }
        if ($Index.Value -ge $length -or -not (Test-StrictJsonDigit $Raw[$Index.Value])) { throw 'Invalid JSON exponent.' }
        while ($Index.Value -lt $length -and (Test-StrictJsonDigit $Raw[$Index.Value])) { $Index.Value++ }
    }
}

function Read-StrictJsonValue([string]$Raw, [ref]$Index) {
    Skip-StrictJsonWhitespace $Raw $Index
    if ($Index.Value -ge $Raw.Length) { throw 'Missing JSON value.' }
    $character = $Raw[$Index.Value]
    if ($character -eq '"') { [void](Read-StrictJsonString $Raw $Index); return }
    if ($character -eq '{') {
        $Index.Value++
        Skip-StrictJsonWhitespace $Raw $Index
        $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        if ($Index.Value -lt $Raw.Length -and $Raw[$Index.Value] -eq '}') { $Index.Value++; return }
        while ($true) {
            Skip-StrictJsonWhitespace $Raw $Index
            $key = Read-StrictJsonString $Raw $Index
            if (-not $keys.Add($key)) { throw "Duplicate JSON object key: $key" }
            Skip-StrictJsonWhitespace $Raw $Index
            if ($Index.Value -ge $Raw.Length -or $Raw[$Index.Value] -ne ':') { throw 'Missing JSON object colon.' }
            $Index.Value++
            [void](Read-StrictJsonValue $Raw $Index)
            Skip-StrictJsonWhitespace $Raw $Index
            if ($Index.Value -ge $Raw.Length) { throw 'Unterminated JSON object.' }
            if ($Raw[$Index.Value] -eq '}') { $Index.Value++; return }
            if ($Raw[$Index.Value] -ne ',') { throw 'Missing JSON object comma.' }
            $Index.Value++
        }
    }
    if ($character -eq '[') {
        $Index.Value++
        Skip-StrictJsonWhitespace $Raw $Index
        if ($Index.Value -lt $Raw.Length -and $Raw[$Index.Value] -eq ']') { $Index.Value++; return }
        while ($true) {
            [void](Read-StrictJsonValue $Raw $Index)
            Skip-StrictJsonWhitespace $Raw $Index
            if ($Index.Value -ge $Raw.Length) { throw 'Unterminated JSON array.' }
            if ($Raw[$Index.Value] -eq ']') { $Index.Value++; return }
            if ($Raw[$Index.Value] -ne ',') { throw 'Missing JSON array comma.' }
            $Index.Value++
        }
    }
    if ($Raw.Substring($Index.Value).StartsWith('true')) { $Index.Value += 4; return }
    if ($Raw.Substring($Index.Value).StartsWith('false')) { $Index.Value += 5; return }
    if ($Raw.Substring($Index.Value).StartsWith('null')) { $Index.Value += 4; return }
    if ($character -eq '-' -or (Test-StrictJsonDigit $character)) { Read-StrictJsonNumber $Raw $Index; return }
    throw 'Invalid JSON value.'
}

function Test-StrictJson([string]$Raw) {
    try {
        $index = 0
        [void](Read-StrictJsonValue $Raw ([ref]$index))
        Skip-StrictJsonWhitespace $Raw ([ref]$index)
        return $index -eq $Raw.Length
    } catch {
        return $false
    }
}

function Get-JsonPropertyValue($Object, [string]$Name) {
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $property = $Object.PSObject.Properties[$Name]
        if ($property) { return $property.Value }
    }
    return $null
}

function Get-JsonState([string]$Path, [string]$Server, [string]$Root) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'ABSENT' }
    Assert-SafePath $Path $Root
    try {
        $raw = [IO.File]::ReadAllText($Path)
        if (-not (Test-StrictJson $raw)) { return 'INVALID' }
        $json = $raw | ConvertFrom-Json
    } catch { return 'INVALID' }
    $servers = Get-JsonPropertyValue $json 'mcpServers'
    if ($null -eq $servers) { return 'ABSENT' }
    if ($servers -isnot [System.Management.Automation.PSCustomObject]) { return 'INVALID' }
    $properties = @($servers.PSObject.Properties)
    $target = $servers.PSObject.Properties[$Server]
    $entry = if ($target) { $target.Value } else { $null }
    $canonicalAliases = @($properties | Where-Object {
        $_.Name -cne $Server -and (Get-JsonPropertyValue $_.Value 'url') -ceq $ExpectedUrl
    })
    $hasStaticAuth = ($null -ne $entry -and (Test-CredentialShape $entry)) -or
        (@($canonicalAliases | Where-Object { Test-CredentialShape $_.Value }).Count -gt 0)
    if ($hasStaticAuth) { return 'STATIC_AUTH_DEPENDENCY' }
    if ($canonicalAliases.Count -gt 0) { return 'INVALID' }
    if ($null -eq $entry) { return 'ABSENT' }
    if ($entry -isnot [System.Management.Automation.PSCustomObject]) { return 'INVALID' }
    if ((Get-JsonPropertyValue $entry 'url') -cne $ExpectedUrl) { return 'ENDPOINT_DRIFT' }
    if ($Server -eq 'dreameros') {
        $type = Get-JsonPropertyValue $entry 'type'
        if ($type -cnotin @('http', 'streamable-http')) { return 'INVALID' }
    }
    if ($Server -eq 'dreameros-platform' -and ($entry.PSObject.Properties.Name -contains 'type')) { return 'INVALID' }
    return 'REGISTERED_OAUTH_UNVERIFIED'
}

function Test-CredentialShape($Value) {
    if ($null -eq $Value) { return $false }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -match '(?i)^(headers|headersHelper|authorization|bearer|token|api[_-]?key|env|auth|oauth|clientId|clientSecret)$') { return $true }
            if (Test-CredentialShape $property.Value) { return $true }
        }
    } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { if (Test-CredentialShape $item) { return $true } }
    }
    return $false
}

function Get-TomlState([string]$Path, [string]$Root) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'ABSENT' }
    Assert-SafePath $Path $Root
    try { $lines = [IO.File]::ReadAllLines($Path) } catch { return 'INVALID' }
    $rootRows = @(); $toolRows = @(); $active = ''; $rootCount = 0; $toolCount = 0
    foreach ($line in $lines) {
        if ($line -match '^\s*\[(?<name>[^\]]+)\]\s*$') {
            $active = $Matches.name.Trim()
            if ($active -eq 'mcp_servers.dreameros') { $rootCount++ }
            if ($active -eq 'mcp_servers.dreameros.tools.dreameros_session_package') { $toolCount++ }
            continue
        }
        if ($line -match '^\s*[^#\s].*=') {
            if ($active -eq 'mcp_servers.dreameros') { $rootRows += $line }
            if ($active -eq 'mcp_servers.dreameros.tools.dreameros_session_package') { $toolRows += $line }
        }
    }
    $keys = @($rootRows | ForEach-Object { ($_ -split '=',2)[0].Trim() })
    $toolKeys = @($toolRows | ForEach-Object { ($_ -split '=',2)[0].Trim() })
    if ($rootCount -eq 0 -and $toolCount -eq 0) { return 'ABSENT' }
    if (($keys + $toolKeys) | Where-Object { $_ -ne 'output_token_limit' -and $_ -match '(?i)authorization|bearer|token|api[_-]?key|env|auth|oauth|clientId|clientSecret' }) { return 'STATIC_AUTH_DEPENDENCY' }
    if ($rootCount -ne 1 -or $toolCount -ne 1) { return 'INVALID' }
    if ($keys.Count -ne @($keys | Sort-Object -Unique).Count -or $toolKeys.Count -ne @($toolKeys | Sort-Object -Unique).Count) { return 'INVALID' }
    if ((@($keys | Where-Object { $_ -ne 'url' })).Count -gt 0 -or (@($toolKeys | Where-Object { $_ -ne 'output_token_limit' })).Count -gt 0) { return 'INVALID' }
    $urlRow = @($rootRows | Where-Object { $_ -match '^\s*url\s*=' }); if ($urlRow.Count -ne 1) { return 'INVALID' }
    if ((($urlRow[0] -split '=',2)[1]).Trim() -ne ('"' + $ExpectedUrl + '"')) { return 'INVALID' }
    $limitRow = @($toolRows | Where-Object { $_ -match '^\s*output_token_limit\s*=' }); if ($limitRow.Count -ne 1 -or (($limitRow[0] -split '=',2)[1]).Trim() -ne '30000') { return 'INVALID' }
    return 'REGISTERED_OAUTH_UNVERIFIED'
}

$counts = @{}
foreach ($root in ($EstateRoots | Sort-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    $root = [IO.Path]::GetFullPath($root)
    $repos = @(); if (Test-Path -LiteralPath (Join-Path $root '.git')) { $repos += $root }
    $repos += Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and (Test-Path -LiteralPath (Join-Path $_.FullName '.git')) } | ForEach-Object FullName
    foreach ($repo in ($repos | Sort-Object -Unique)) {
        $items = @(
            @{ Venue='CLAUDE'; Path=(Join-Path $repo '.mcp.json'); State=(Get-JsonState (Join-Path $repo '.mcp.json') 'dreameros' $repo); Template='bootpack/out/project-oauth/claude.mcp.json' },
            @{ Venue='CURSOR'; Path=(Join-Path $repo '.cursor/mcp.json'); State=(Get-JsonState (Join-Path $repo '.cursor/mcp.json') 'dreameros-platform' $repo); Template='bootpack/out/project-oauth/cursor.mcp.json' },
            @{ Venue='CODEX'; Path=(Join-Path $repo '.codex/config.toml'); State=(Get-TomlState (Join-Path $repo '.codex/config.toml') $repo); Template='bootpack/out/project-oauth/codex.config.toml' }
        )
        foreach ($item in $items) {
            if (-not $counts.ContainsKey($item.State)) { $counts[$item.State] = 0 }; $counts[$item.State]++
            $action = if ($item.State -eq 'ABSENT') { 'ADD_DREAMEROS_ENTRY' } elseif ($item.State -eq 'REGISTERED_OAUTH_UNVERIFIED') { 'NONE' } elseif ($item.State -eq 'ENDPOINT_DRIFT') { 'SURGICAL_MERGE_DREAMEROS_ENTRY' } else { 'REPLACE_DREAMEROS_ENTRY' }
            Write-Output ("PROJECT_OAUTH_INVENTORY venue={0} state={1} action={2} template={3} path={4}" -f $item.Venue,$item.State,$action,$item.Template,$item.Path)
        }
    }
}
$summary = @('ABSENT','REGISTERED_OAUTH_UNVERIFIED','STATIC_AUTH_DEPENDENCY','ENDPOINT_DRIFT','INVALID') | ForEach-Object { "$_=$(if ($counts.ContainsKey($_)) { $counts[$_] } else { 0 })" }
Write-Output ('PROJECT_OAUTH_SUMMARY ' + ($summary -join ' '))
${registered} = if ($counts.ContainsKey('REGISTERED_OAUTH_UNVERIFIED')) { $counts['REGISTERED_OAUTH_UNVERIFIED'] } else { 0 }
${total} = @($counts.Values | Measure-Object -Sum).Sum
if ($registered -gt 0 -and $registered -eq $total) {
    Write-Output 'PROJECT_OAUTH_ONRAMP_STATUS=REGISTERED_NOT_CONNECTED client OAuth approval is required before connection proof.'
} elseif ($registered -gt 0) {
    Write-Output 'PROJECT_OAUTH_ONRAMP_STATUS=PARTIAL_REGISTERED_WITH_GAPS'
} else {
    Write-Output 'PROJECT_OAUTH_ONRAMP_STATUS=BLOCKED_NO_REGISTERED_DREAMEROS_ENTRY'
}
Write-Output 'PROJECT_OAUTH_SHADOW venue=CLAUDE state=UNVERIFIED_LIVE action=VERIFY_EFFECTIVE_PRECEDENCE'
Write-Output 'PROJECT_OAUTH_SHADOW venue=CURSOR state=UNVERIFIED_LIVE action=VERIFY_EFFECTIVE_PRECEDENCE'
Write-Output 'PROJECT_OAUTH_SHADOW venue=CODEX state=UNVERIFIED_LIVE action=VERIFY_EFFECTIVE_PRECEDENCE'
