[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ServerAddr,
    [int]$ServerPort = 7000,
    [string]$Token,
    [switch]$Start
)

$ErrorActionPreference = 'Stop'
if ($ServerPort -lt 1 -or $ServerPort -gt 65535) { throw 'ServerPort must be between 1 and 65535.' }
if ($ServerAddr -match "[\r\n]" -or $Token -match "[\r\n]") { throw 'Values cannot contain newlines.' }

function Escape-Toml([string]$Value) {
    $Value.Replace('\', '\\').Replace('"', '\"')
}

$dir = Split-Path -Parent $PSCommandPath
$config = Join-Path $dir 'frpc.toml'
$content = @(
    'serverAddr = "' + (Escape-Toml $ServerAddr) + '"',
    'serverPort = ' + $ServerPort
)
if ($Token) {
    $content += 'auth.method = "token"'
    $content += 'auth.token = "' + (Escape-Toml $Token) + '"'
}
[IO.File]::WriteAllLines($config, [string[]]$content, [Text.UTF8Encoding]::new($false))

& (Join-Path $dir 'frpc.exe') verify -c $config
if ($LASTEXITCODE -ne 0) { throw 'frpc configuration validation failed.' }

& sc.exe config frp-agent 'start=' 'auto' | Out-Null
& sc.exe failure frp-agent 'reset=' '86400' 'actions=' 'restart/5000/restart/15000/restart/30000' | Out-Null
if ($Start) { Start-Service frp-agent }
