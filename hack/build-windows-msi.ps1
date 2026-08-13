[CmdletBinding()]
param(
    [ValidateSet('amd64', 'arm64')]
    [string]$Architecture = 'amd64',
    [string]$Version = '0.71.0',
    [string]$InputDirectory
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$stage = Join-Path $root ('.msi-stage\windows-' + $Architecture)
$zip = Join-Path $root ('dist\agent\frp-agent_windows_' + $Architecture + '.zip')
$output = Join-Path $root ('dist\agent\frp-agent_windows_' + $Architecture + '.msi')
$wix = Get-Command wix.exe,wix -ErrorAction SilentlyContinue | Select-Object -First 1
$packagePlatform = if ($Architecture -eq 'amd64') { 'x64' } else { 'arm64' }

if (-not $wix) { throw 'WiX CLI is required. Install with: winget install --id WiXToolset.WiXCLI --exact' }
if (-not $InputDirectory -and -not (Test-Path -LiteralPath $zip)) { throw "Windows package not found: $zip" }

Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
    if ($InputDirectory) {
        foreach ($file in @('frpc.exe', 'frpc-service.exe')) {
            $source = Join-Path $InputDirectory $file
            if (-not (Test-Path -LiteralPath $source)) { throw "Required binary not found: $source" }
            Copy-Item -LiteralPath $source -Destination (Join-Path $stage $file)
        }
    } else {
        Expand-Archive -LiteralPath $zip -DestinationPath $stage
    }
    Copy-Item -LiteralPath (Join-Path $root 'install\frpc.windows.toml.example') -Destination (Join-Path $stage 'frpc.toml')
    Copy-Item -LiteralPath (Join-Path $root 'install\windows-msi\configure.ps1') -Destination (Join-Path $stage 'configure.ps1')
    & $wix.Source build (Join-Path $root 'install\windows-msi\Package.wxs') "-dSourceDir=$stage" "-dProductVersion=$Version" "-dPackagePlatform=$packagePlatform" "-o$output"
    if ($LASTEXITCODE -ne 0) { throw 'WiX build failed.' }
    Get-Item -LiteralPath $output | Select-Object FullName,Length,LastWriteTime
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
