#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BaseUrl = $(if ($env:FRP_AGENT_BASE_URL) { $env:FRP_AGENT_BASE_URL } else { '@@PUBLIC_BASE_URL@@' }),
    [string]$ConfigUrl = $env:FRP_AGENT_CONFIG_URL,
    [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'
$serviceName = 'frp-agent'
$installDir = Join-Path $env:ProgramFiles 'frp-agent'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run PowerShell as Administrator.'
}
if ($BaseUrl -eq 'https://github.com/OWNER/REPO/releases/latest/download') {
    throw 'Set -BaseUrl to the public release download URL.'
}
if (-not $BaseUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The package base URL must use HTTPS.'
}
if ($ConfigUrl -and -not $ConfigUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The configuration URL must use HTTPS.'
}
if ($ConfigFile -and -not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    throw "Configuration file not found: $ConfigFile"
}
$existingConfig = Join-Path $installDir 'frpc.toml'
if (-not $ConfigUrl -and -not $ConfigFile -and -not (Test-Path -LiteralPath $existingConfig)) {
    throw 'First install requires -ConfigFile or -ConfigUrl.'
}

switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { $arch = 'amd64' }
    'ARM64' { $arch = 'arm64' }
    default { throw "Unsupported CPU architecture: $env:PROCESSOR_ARCHITECTURE" }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("frp-agent-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    $asset = "frp-agent_windows_$arch.zip"
    $archive = Join-Path $tempDir $asset
    $checksums = Join-Path $tempDir 'checksums.txt'
    Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/$asset" -OutFile $archive
    Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/checksums.txt" -OutFile $checksums

    $checksumLine = Get-Content -LiteralPath $checksums | Where-Object { $_ -match "\s\*?$([regex]::Escape($asset))$" } | Select-Object -First 1
    if (-not $checksumLine) { throw "No checksum found for $asset." }
    $expected = ($checksumLine -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "Checksum verification failed for $asset." }

    $packageDir = Join-Path $tempDir 'package'
    Expand-Archive -LiteralPath $archive -DestinationPath $packageDir
    & (Join-Path $packageDir 'frpc.exe') --version | Out-Null

    $candidateConfig = $existingConfig
    if ($ConfigUrl) {
        $candidateConfig = Join-Path $tempDir 'frpc.toml'
        Invoke-WebRequest -UseBasicParsing -Uri $ConfigUrl -OutFile $candidateConfig
    } elseif ($ConfigFile) {
        $candidateConfig = Join-Path $tempDir 'frpc.toml'
        Copy-Item -LiteralPath $ConfigFile -Destination $candidateConfig
    }
    & (Join-Path $packageDir 'frpc.exe') verify -c $candidateConfig
    if ($LASTEXITCODE -ne 0) { throw 'frpc configuration validation failed.' }

    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($service) {
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
    }
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Copy-Item -Force -LiteralPath (Join-Path $packageDir 'frpc.exe') -Destination $installDir
    Copy-Item -Force -LiteralPath (Join-Path $packageDir 'frpc-service.exe') -Destination $installDir

    if ($ConfigUrl) {
        Copy-Item -Force -LiteralPath $candidateConfig -Destination $existingConfig
    } elseif ($ConfigFile) {
        Copy-Item -Force -LiteralPath $candidateConfig -Destination $existingConfig
    }

    $serviceBinary = '"' + (Join-Path $installDir 'frpc-service.exe') + '"'
    if (-not $service) {
        New-Service -Name $serviceName -BinaryPathName $serviceBinary -DisplayName 'FRP managed client agent' -StartupType Automatic | Out-Null
    } else {
        & sc.exe config $serviceName 'binPath=' $serviceBinary 'start=' 'auto' | Out-Null
    }
    & sc.exe failure $serviceName 'reset=' '86400' 'actions=' 'restart/5000/restart/15000/restart/30000' | Out-Null
    Start-Service -Name $serviceName
    Get-Service -Name $serviceName | Format-Table Status, Name, DisplayName -AutoSize
    Write-Host "frp-agent installed and started (windows/$arch)."
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
