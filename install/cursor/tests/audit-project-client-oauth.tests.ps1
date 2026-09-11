$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Script = Join-Path $RepoRoot 'install\cursor\audit-project-client-oauth.ps1'
$TempRoot = Join-Path $env:TEMP ('dreameros-oauth-audit-' + [guid]::NewGuid().ToString('N'))
$Repo = Join-Path $TempRoot 'repo'
$Utf8 = New-Object Text.UTF8Encoding($false)
$Cases = 0
$PowerShellExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
function Assert-True([bool]$Value, [string]$Message) { $script:Cases++; if (-not $Value) { throw "ASSERTION FAILED: $Message" } }
New-Item -ItemType Directory -Path $Repo -Force | Out-Null
& git -C $Repo init -b main --quiet
& git -C $Repo config user.email fixture@example.invalid
& git -C $Repo config user.name DreamerOS
[IO.File]::WriteAllText((Join-Path $Repo '.mcp.json'), '{"mcpServers":{"dreameros":{"type":"streamable-http","url":"https://mcp.dreameros.app/mcp"},"other":{"type":"stdio","command":"env"}}}', $Utf8)
New-Item -ItemType Directory -Path (Join-Path $Repo '.cursor') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $Repo '.cursor\mcp.json'), '{"mcpServers":{"dreameros-platform":{"url":"https://mcp.dreameros.app/mcp","headers":{"Authorization":"redacted"}}}}', $Utf8)
New-Item -ItemType Directory -Path (Join-Path $Repo '.codex') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $Repo '.codex\config.toml'), @'
[mcp_servers.dreameros]
url = "https://mcp.dreameros.app/mcp"

[mcp_servers.dreameros.tools.dreameros_session_package]
output_token_limit = 30000
'@, $Utf8)
& git -C $Repo add .
& git -C $Repo commit -m fixture --quiet
$output = @(& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $Script -EstateRoots $TempRoot)
Assert-True (($output -join "`n") -match 'venue=CLAUDE state=REGISTERED_OAUTH_UNVERIFIED') 'Claude scoped registration missing'
Assert-True (($output -join "`n") -match 'venue=CURSOR state=STATIC_AUTH_DEPENDENCY') 'Cursor scoped static auth dependency missing'
Assert-True (($output -join "`n") -match 'venue=CODEX state=REGISTERED_OAUTH_UNVERIFIED') 'Codex output token limit was not accepted'
Assert-True (($output -join "`n") -match 'PROJECT_OAUTH_SUMMARY ABSENT=0 REGISTERED_OAUTH_UNVERIFIED=2 STATIC_AUTH_DEPENDENCY=1 ENDPOINT_DRIFT=0 INVALID=0') 'OAuth summary mismatch'
Assert-True (($output -join [Environment]::NewLine) -match 'PROJECT_OAUTH_SHADOW venue=CLAUDE state=UNVERIFIED_LIVE') 'Claude shadow record missing'
Assert-True (($output -join [Environment]::NewLine) -match 'PROJECT_OAUTH_SHADOW venue=CURSOR state=UNVERIFIED_LIVE') 'Cursor shadow record missing'
Assert-True (($output -join [Environment]::NewLine) -match 'PROJECT_OAUTH_SHADOW venue=CODEX state=UNVERIFIED_LIVE') 'Codex shadow record missing'
function Invoke-OAuthScenario([string]$Name, [string]$Claude = '', [string]$Cursor = '', [string]$Codex = '') {
    $estate = Join-Path $TempRoot $Name
    $repo = Join-Path $estate 'repo'
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    & git -C $repo init -b main --quiet
    & git -C $repo config user.email fixture@example.invalid
    & git -C $repo config user.name DreamerOS
    if ($Claude) { [IO.File]::WriteAllText((Join-Path $repo '.mcp.json'), $Claude, $Utf8) }
    if ($Cursor) { New-Item -ItemType Directory -Path (Join-Path $repo '.cursor') -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $repo '.cursor\mcp.json'), $Cursor, $Utf8) }
    if ($Codex) { New-Item -ItemType Directory -Path (Join-Path $repo '.codex') -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $repo '.codex\config.toml'), $Codex, $Utf8) }
    & git -C $repo add .; & git -C $repo commit -m fixture --quiet
    return @(& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $Script -EstateRoots $estate)
}

$zero = Invoke-OAuthScenario 'zero'
Assert-True (($zero -join [Environment]::NewLine) -match 'PROJECT_OAUTH_ONRAMP_STATUS=BLOCKED_NO_REGISTERED_DREAMEROS_ENTRY') 'zero registered status missing'
$unrelated = Invoke-OAuthScenario 'unrelated' '{"mcpServers":{"other":{"type":"stdio","command":"env"}}}'
Assert-True (($unrelated -join [Environment]::NewLine) -match 'venue=CLAUDE state=ABSENT') 'unrelated server did not remain absent'
$claudeHttp = Invoke-OAuthScenario 'claude-http' '{"mcpServers":{"dreameros":{"type":"http","url":"https://mcp.dreameros.app/mcp"}}}'
Assert-True (($claudeHttp -join [Environment]::NewLine) -match 'venue=CLAUDE state=REGISTERED_OAUTH_UNVERIFIED') 'Claude http transport was not accepted'
$drift = Invoke-OAuthScenario 'drift' '{"mcpServers":{"dreameros":{"type":"streamable-http","url":"https://wrong.invalid/mcp"}}}'
Assert-True (($drift -join [Environment]::NewLine) -match 'venue=CLAUDE state=ENDPOINT_DRIFT action=SURGICAL_MERGE_DREAMEROS_ENTRY') 'endpoint drift action missing'
$duplicate = Invoke-OAuthScenario 'duplicate' '{"mcpServers":{"dreameros":{"type":"streamable-http","url":"https://mcp.dreameros.app/mcp"},"dreameros":{"type":"streamable-http","url":"https://mcp.dreameros.app/mcp"}}}'
Assert-True (($duplicate -join [Environment]::NewLine) -match 'venue=CLAUDE state=INVALID action=REPLACE_DREAMEROS_ENTRY') 'duplicate JSON state missing'
$nestedDuplicate = Invoke-OAuthScenario 'nested-duplicate' '{"mcpServers":{"dreameros":{"type":"streamable-http","url":"https://mcp.dreameros.app/mcp","metadata":{"child":{"key":1,"key":2}}}}}'
Assert-True (($nestedDuplicate -join [Environment]::NewLine) -match 'venue=CLAUDE state=INVALID') 'nested JSON duplicate key was not rejected'
$aliasCollision = Invoke-OAuthScenario 'alias-collision' '' '{"mcpServers":{"dreameros-platform":{"url":"https://mcp.dreameros.app/mcp"},"dreameros":{"url":"https://mcp.dreameros.app/mcp"}}}'
Assert-True (($aliasCollision -join [Environment]::NewLine) -match 'venue=CURSOR state=INVALID action=REPLACE_DREAMEROS_ENTRY') 'same-endpoint Cursor alias collision missing'
$aliasStatic = Invoke-OAuthScenario 'alias-static' '' '{"mcpServers":{"dreameros-platform":{"url":"https://mcp.dreameros.app/mcp"},"dreameros":{"url":"https://mcp.dreameros.app/mcp","headersHelper":{"x":"ALIAS_SECRET_1234567890"}}}}'
Assert-True (($aliasStatic -join [Environment]::NewLine) -match 'venue=CURSOR state=STATIC_AUTH_DEPENDENCY') 'same-endpoint static alias was not classified as static auth'
Assert-True (-not (($aliasStatic -join [Environment]::NewLine).Contains('ALIAS_SECRET_1234567890'))) 'same-endpoint static alias leaked a value'
$staticBeforeShape = Invoke-OAuthScenario 'static-before-shape' '{"mcpServers":{"dreameros":{"type":"stdio","url":"https://mcp.dreameros.app/mcp","headers":{"x":"STATIC_BEFORE_SHAPE_1234567890"}}}}'
Assert-True (($staticBeforeShape -join [Environment]::NewLine) -match 'venue=CLAUDE state=STATIC_AUTH_DEPENDENCY') 'JSON static auth was masked by a malformed transport type'
Assert-True (-not (($staticBeforeShape -join [Environment]::NewLine).Contains('STATIC_BEFORE_SHAPE_1234567890'))) 'JSON static-before-shape value leaked'
$credentialNames = @('headers','headersHelper','auth','oauth','clientId','clientSecret','authorization','bearer','token','api_key','env')
foreach ($name in $credentialNames) {
    $sentinel = 'VALUE_' + $name + '_1234567890'
    $json = '{"mcpServers":{"dreameros":{"type":"streamable-http","url":"https://mcp.dreameros.app/mcp","' + $name + '":{"x":"' + $sentinel + '"}}}}'
    $result = Invoke-OAuthScenario ('credential-' + $name) $json
    $text = $result -join [Environment]::NewLine
    Assert-True ($text -match 'venue=CLAUDE state=STATIC_AUTH_DEPENDENCY action=REPLACE_DREAMEROS_ENTRY') ('credential alias failed: ' + $name)
    Assert-True (-not $text.Contains($sentinel)) ('credential leaked: ' + $name)
}
$legacyAuth = Invoke-OAuthScenario 'legacy-auth' '' '' "[mcp_servers.dreameros]`nurl = https://mcp.dreameros.app/mcp`nbearer_token_env_var = DO_NOT_PRINT_1234567890"
Assert-True (($legacyAuth -join [Environment]::NewLine) -match 'venue=CODEX state=STATIC_AUTH_DEPENDENCY') 'legacy TOML static auth was masked'
Assert-True (-not (($legacyAuth -join [Environment]::NewLine).Contains('DO_NOT_PRINT_1234567890')) ) 'legacy TOML value leaked'
$missingTool = Invoke-OAuthScenario 'missing-tool' '' '' "[mcp_servers.dreameros]`nurl = https://mcp.dreameros.app/mcp"
Assert-True (($missingTool -join [Environment]::NewLine) -match 'venue=CODEX state=INVALID') 'missing nested limit missing'
$wrongLimit = Invoke-OAuthScenario 'wrong-limit' '' '' "[mcp_servers.dreameros]`nurl = https://mcp.dreameros.app/mcp`n[mcp_servers.dreameros.tools.dreameros_session_package]`noutput_token_limit = 12"
Assert-True (($wrongLimit -join [Environment]::NewLine) -match 'venue=CODEX state=INVALID') 'wrong nested limit missing'
$unquoted = Invoke-OAuthScenario 'unquoted-url' '' '' "[mcp_servers.dreameros]`nurl = https://mcp.dreameros.app/mcp`n[mcp_servers.dreameros.tools.dreameros_session_package]`noutput_token_limit = 30000"
Assert-True (($unquoted -join [Environment]::NewLine) -match 'venue=CODEX state=INVALID') 'unquoted TOML URL missing'
$duplicateEntry = Invoke-OAuthScenario 'duplicate-entry' '{"mcpServers":{"dreameros":{"type":"streamable-http","url":"https://mcp.dreameros.app/mcp","url":"https://mcp.dreameros.app/mcp"}}}'
Assert-True (($duplicateEntry -join [Environment]::NewLine) -match 'venue=CLAUDE state=INVALID') 'duplicate target entry key missing'
$duplicateToml = Invoke-OAuthScenario 'duplicate-toml' '' '' "[mcp_servers.dreameros]`nurl = `"https://mcp.dreameros.app/mcp`"`n[mcp_servers.dreameros.tools.dreameros_session_package]`noutput_token_limit = 30000`n[mcp_servers.dreameros.tools.dreameros_session_package]`noutput_token_limit = 30000"
Assert-True (($duplicateToml -join [Environment]::NewLine) -match 'venue=CODEX state=INVALID') 'duplicate TOML section missing'
$duplicateTomlKey = Invoke-OAuthScenario 'duplicate-toml-key' '' '' "[mcp_servers.dreameros]`nurl = `"https://mcp.dreameros.app/mcp`"`n[mcp_servers.dreameros.tools.dreameros_session_package]`noutput_token_limit = 30000`noutput_token_limit = 30000"
Assert-True (($duplicateTomlKey -join [Environment]::NewLine) -match 'venue=CODEX state=INVALID') 'duplicate TOML key missing'
$partial = Invoke-OAuthScenario 'partial' '{"mcpServers":{"dreameros":{"type":"streamable-http","url":"https://mcp.dreameros.app/mcp"}}}' '' ''
Assert-True (($partial -join [Environment]::NewLine) -match 'PROJECT_OAUTH_ONRAMP_STATUS=PARTIAL_REGISTERED_WITH_GAPS') 'partial registered aggregate missing'
$allRegistered = Invoke-OAuthScenario 'all-registered' '{"mcpServers":{"dreameros":{"type":"streamable-http","url":"https://mcp.dreameros.app/mcp"}}}' '{"mcpServers":{"dreameros-platform":{"url":"https://mcp.dreameros.app/mcp"}}}' "[mcp_servers.dreameros]`nurl = `"https://mcp.dreameros.app/mcp`"`n[mcp_servers.dreameros.tools.dreameros_session_package]`noutput_token_limit = 30000"
Assert-True (($allRegistered -join [Environment]::NewLine) -match 'PROJECT_OAUTH_ONRAMP_STATUS=REGISTERED_NOT_CONNECTED') 'all registered aggregate missing'
Write-Output ((@{status='pass';assertions=$Cases} | ConvertTo-Json -Compress))
