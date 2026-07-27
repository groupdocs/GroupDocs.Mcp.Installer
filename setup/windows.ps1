<#
.SYNOPSIS
  Prerequisite bootstrap for the GroupDocs MCP installer - Windows.

.DESCRIPTION
  Installs (idempotently, via winget):
    docker channel : Docker Desktop
    nuget channel  : .NET 10 SDK (includes dnx; GDI+ is built into Windows)
    optionally     : PowerShell 7 (nice to have - the installer also runs on
                     the built-in Windows PowerShell 5.1)

  -Check reports status without installing anything.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File setup\windows.ps1 -Channel nuget
  powershell -ExecutionPolicy Bypass -File setup\windows.ps1 -Channel docker -Check
#>
[CmdletBinding()]
param(
  [ValidateSet('docker','nuget','both')]
  [string] $Channel = 'docker',
  [switch] $IncludePwsh7,
  [switch] $Check
)

$ErrorActionPreference = 'Stop'
function Write-Ok   ($m) { Write-Host "  [OK]      $m" -ForegroundColor Green }
function Write-Miss ($m) { Write-Host "  [MISSING] $m" -ForegroundColor Yellow }
function Write-Act  ($m) { Write-Host "  [INSTALL] $m" -ForegroundColor Cyan }
function Test-Cmd ([string]$n) { [bool](Get-Command $n -ErrorAction SilentlyContinue) }

Write-Host "== GroupDocs MCP prerequisites - Windows (channel: $Channel) ==" -ForegroundColor Cyan
Write-Ok "PowerShell $($PSVersionTable.PSVersion) (5.1+ is enough to run the installer)"

$winget = Test-Cmd 'winget'
if (-not $winget) {
  Write-Miss "winget - required to install the items below."
  Write-Host "            Install 'App Installer' from the Microsoft Store, then re-run."
  if (-not $Check) { exit 1 }
} else {
  Write-Ok "winget $((winget --version) 2>$null)"
}

$failed = $false
function Install-WingetPackage ([string]$id, [string]$label) {
  Write-Act "$label (winget install --id $id)"
  winget install --id $id --exact --accept-source-agreements --accept-package-agreements
  if ($LASTEXITCODE -ne 0) { Write-Miss "$label - winget exited $LASTEXITCODE"; $script:failed = $true }
}

# --- Optional PowerShell 7 ---------------------------------------------------
if ($IncludePwsh7) {
  if (Test-Cmd 'pwsh') { Write-Ok "PowerShell 7 ($((pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')))" }
  elseif ($Check)      { Write-Miss "PowerShell 7  ->  winget install --id Microsoft.PowerShell" }
  else                 { Install-WingetPackage 'Microsoft.PowerShell' 'PowerShell 7' }
}

# --- Docker channel ----------------------------------------------------------
if ($Channel -in @('docker','both')) {
  if (Test-Cmd 'docker') {
    $daemon = $null
    try { $daemon = docker version --format '{{.Server.Version}}' 2>$null } catch {}
    if ($daemon) { Write-Ok "Docker (daemon running, $daemon)" }
    else { Write-Ok "Docker CLI present - but the daemon is NOT running. Start Docker Desktop." }
  } elseif ($Check) {
    Write-Miss "Docker Desktop  ->  winget install --id Docker.DockerDesktop"
  } else {
    Install-WingetPackage 'Docker.DockerDesktop' 'Docker Desktop'
    Write-Host "            NOTE: start Docker Desktop once to finish its first-run setup (WSL2 backend)."
  }
}

# --- NuGet channel -----------------------------------------------------------
if ($Channel -in @('nuget','both')) {
  $sdk10 = $false
  if (Test-Cmd 'dotnet') {
    try { $sdk10 = [bool]((dotnet --list-sdks 2>$null) | Where-Object { $_ -match '^10\.' }) } catch {}
  }
  if ($sdk10) { Write-Ok ".NET 10 SDK ($(((dotnet --list-sdks) | Where-Object { $_ -match '^10\.' } | Select-Object -First 1).Split(' ')[0]))" }
  elseif ($Check) { Write-Miss ".NET 10 SDK  ->  winget install --id Microsoft.DotNet.SDK.10" }
  else { Install-WingetPackage 'Microsoft.DotNet.SDK.10' '.NET 10 SDK' }
  # GDI+ is built into Windows - no native graphics deps needed here.
}

Write-Host "== Summary ==" -ForegroundColor Cyan
if ($Channel -ne 'nuget') {
  if (Test-Cmd 'docker') { Write-Ok "docker : $((Get-Command docker).Source)" } else { Write-Miss 'docker' }
}
if ($Channel -ne 'docker') {
  if (Test-Cmd 'dotnet') { Write-Ok "dotnet : $((Get-Command dotnet).Source)" } else { Write-Miss 'dotnet' }
  if ((Test-Cmd 'dnx.cmd') -or (Test-Cmd 'dnx')) { Write-Ok "dnx    : present" }
  else { Write-Host "  [NOTE]    dnx ships inside the .NET 10 SDK; open a NEW terminal if it is not found yet." }
}

if ($failed) { Write-Host "Some installs failed - review the output above."; exit 1 }
Write-Host ""
Write-Host "Next:  ./install-groupdocs-mcp.ps1 -Interactive"
