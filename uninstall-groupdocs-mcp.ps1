<#
.SYNOPSIS
  Configurable removal of GroupDocs MCP servers from AI clients. By default it
  sweeps EVERY known client and removes EVERY known GroupDocs server - so a
  bare run fully cleans a machine regardless of what any config file says.
  Works cross-platform on PowerShell 5.1 and 7+.

.DESCRIPTION
  Reads the product catalog (manifest.json) to know every GroupDocs server
  name, then removes the selected subset from the selected clients:

    file-based clients - the entry is deleted from the client's JSON config;
                         other (non-GroupDocs) servers are preserved and a
                         timestamped .bak is written before every change.
    CLI-based clients  - claude-code / codex are cleared via their own CLIs
                         (claude mcp remove / codex mcp remove); skipped with
                         a warning when the CLI is not on PATH.

  Unlike the installer's -Uninstall (which only touches the clients listed in
  groupdocs-mcp.config.json), this script defaults to ALL clients - catching
  entries left behind after the config changed.

.EXAMPLE
  ./uninstall-groupdocs-mcp.ps1 -DryRun                  # preview a full sweep
  ./uninstall-groupdocs-mcp.ps1                          # remove every GroupDocs server from every client
  ./uninstall-groupdocs-mcp.ps1 -Products metadata,conversion
  ./uninstall-groupdocs-mcp.ps1 -Clients claude-desktop,cursor
  ./uninstall-groupdocs-mcp.ps1 -RemoveImages -PurgeNugetCache -RemoveCompose
#>
[CmdletBinding()]
param(
  [string]   $Manifest = (Join-Path $PSScriptRoot 'manifest.json'),
  [string[]] $Products = @('all'),
  [string[]] $Clients  = @('all'),
  [ValidateSet('ghcr','dockerhub')]
  [string]   $Registry = 'ghcr',
  [string]   $Version  = 'latest',
  [switch]   $RemoveImages,
  [switch]   $RemoveCompose,
  [switch]   $PurgeNugetCache,
  [switch]   $DryRun
)

$ErrorActionPreference = 'Stop'

$FILE_CLIENTS = @('claude-desktop','vscode','vscode-workspace','vs2022','cursor','windsurf','cline')
$CLI_CLIENTS  = @('claude-code','codex')

function Write-Info  ($m) { Write-Host "  $m" }
function Write-Ok    ($m) { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn2 ($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Head  ($m) { Write-Host "`n== $m ==" -ForegroundColor Cyan }

function Test-IsWindows {
  if ($PSVersionTable.PSVersion.Major -ge 6) { return $IsWindows }
  return $true
}
function Test-IsMac {
  if ($PSVersionTable.PSVersion.Major -ge 6) { return $IsMacOS }
  return $false
}
function Test-CommandExists ([string]$name) {
  return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}
function Write-TextNoBom ($path, [string]$content) {
  [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

# --- Catalog + selections ----------------------------------------------------
if (-not (Test-Path $Manifest)) { throw "File not found: $Manifest" }
$mani = Get-Content -Raw -LiteralPath $Manifest | ConvertFrom-Json
$allKeys = @($mani.products.PSObject.Properties.Name)

$prodKeys = New-Object System.Collections.Generic.List[string]
foreach ($p in $Products) {
  $k = "$p".ToLower().Trim()
  if ($k -eq 'all') { foreach ($a in $allKeys) { if (-not $prodKeys.Contains($a)) { $prodKeys.Add($a) } } }
  elseif ($allKeys -contains $k) { if (-not $prodKeys.Contains($k)) { $prodKeys.Add($k) } }
  else { Write-Warn2 "Unknown product '$p' - skipped. Known: $($allKeys -join ', ')" }
}
if ($prodKeys.Count -eq 0) { throw "No valid products selected. Nothing to do." }
$serverNames = @($prodKeys | ForEach-Object { $mani.products.$_.server })

$clientList = New-Object System.Collections.Generic.List[string]
foreach ($c in $Clients) {
  $k = "$c".ToLower().Trim()
  if ($k -eq 'all') {
    foreach ($a in ($FILE_CLIENTS + $CLI_CLIENTS)) { if (-not $clientList.Contains($a)) { $clientList.Add($a) } }
  } elseif (($FILE_CLIENTS + $CLI_CLIENTS) -contains $k) {
    if (-not $clientList.Contains($k)) { $clientList.Add($k) }
  } else {
    Write-Warn2 "Unknown client '$c' - skipped. Known: $(($FILE_CLIENTS + $CLI_CLIENTS) -join ', '), all"
  }
}

Write-Head "GroupDocs MCP uninstall"
Write-Info "products: $($prodKeys -join ', ')"
Write-Info "servers : $($serverNames -join ', ')"
Write-Info "clients : $($clientList -join ', ')"
if ($DryRun) { Write-Info "(dry-run - nothing will be changed)" }

# --- Client config targets (same map as the installer) -----------------------
function Get-ClientTarget ($client) {
  switch ($client.ToLower()) {
    'claude-desktop' {
      $p = if (Test-IsWindows) { Join-Path $env:APPDATA 'Claude/claude_desktop_config.json' }
           elseif (Test-IsMac) { Join-Path $HOME 'Library/Application Support/Claude/claude_desktop_config.json' }
           else                { Join-Path $HOME '.config/Claude/claude_desktop_config.json' }
      return @{ path = $p; root = 'mcpServers' }
    }
    'cursor'   { return @{ path = (Join-Path $HOME '.cursor/mcp.json'); root = 'mcpServers' } }
    'windsurf' { return @{ path = (Join-Path $HOME '.codeium/windsurf/mcp_config.json'); root = 'mcpServers' } }
    'cline' {
      $base = if (Test-IsWindows) { Join-Path $env:APPDATA 'Code/User' }
              elseif (Test-IsMac) { Join-Path $HOME 'Library/Application Support/Code/User' }
              else                { Join-Path $HOME '.config/Code/User' }
      return @{ path = (Join-Path $base 'globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json'); root = 'mcpServers' }
    }
    'vscode' {
      $base = if (Test-IsWindows) { Join-Path $env:APPDATA 'Code/User' }
              elseif (Test-IsMac) { Join-Path $HOME 'Library/Application Support/Code/User' }
              else                { Join-Path $HOME '.config/Code/User' }
      return @{ path = (Join-Path $base 'mcp.json'); root = 'servers' }
    }
    'vscode-workspace' { return @{ path = (Join-Path (Get-Location) '.vscode/mcp.json'); root = 'servers' } }
    'vs2022'           { return @{ path = (Join-Path (Get-Location) '.mcp.json'); root = 'servers' } }
  }
}

function Remove-FromClient ($target, $names) {
  $path = $target.path; $root = $target.root
  if (-not (Test-Path $path)) { Write-Info "$path (not present - nothing to remove)"; return 0 }
  $doc = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
  if (-not ($doc.PSObject.Properties.Name -contains $root)) { Write-Info "$path (no '$root' block)"; return 0 }
  $removed = @()
  foreach ($n in $names) {
    if ($doc.$root.PSObject.Properties.Name -contains $n) {
      $doc.$root.PSObject.Properties.Remove($n); $removed += $n
    }
  }
  if ($removed.Count -eq 0) { Write-Info "$path (no matching GroupDocs servers)"; return 0 }
  if ($DryRun) { Write-Info "(dry-run) would remove from $path : $($removed -join ', ')"; return $removed.Count }
  $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
  Copy-Item -LiteralPath $path -Destination "$path.$stamp.bak"
  Write-TextNoBom $path ($doc | ConvertTo-Json -Depth 12)
  Write-Ok "$path  (removed $($removed.Count): $($removed -join ', '); backup .$stamp.bak)"
  return $removed.Count
}

function Remove-ViaCli ($client, $names) {
  $cli = if ($client -eq 'claude-code') { 'claude' } else { 'codex' }
  if (-not (Test-CommandExists $cli)) { Write-Warn2 "'$cli' CLI not found on PATH - skipping '$client'."; return 0 }
  $count = 0
  foreach ($n in $names) {
    $rmArgs = if ($client -eq 'claude-code') { @('mcp','remove','--scope','user',$n) } else { @('mcp','remove',$n) }
    if ($DryRun) { Write-Info "(dry-run) $cli $($rmArgs -join ' ')"; continue }
    & $cli @rmArgs 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Ok "$cli removed '$n'"; $count++ }
  }
  return $count
}

# --- Sweep clients -----------------------------------------------------------
Write-Head "Removing from clients"
$total = 0
foreach ($c in $clientList) {
  if ($CLI_CLIENTS -contains $c) {
    Write-Info "client '$c' (via CLI)"
    $total += (Remove-ViaCli $c $serverNames)
  } else {
    $t = Get-ClientTarget $c
    Write-Info "client '$c' -> $($t.path)"
    $total += (Remove-FromClient $t $serverNames)
  }
}

# --- Optional deeper cleanup -------------------------------------------------
if ($RemoveCompose) {
  $cf = Join-Path (Get-Location) 'docker-compose.yml'
  if (Test-Path $cf) {
    if ($DryRun) { Write-Info "(dry-run) would delete $cf" }
    else { Remove-Item -LiteralPath $cf -Force; Write-Ok "deleted $cf" }
  } else { Write-Info "no docker-compose.yml in $(Get-Location)" }
}

if ($RemoveImages) {
  Write-Head "Removing Docker images"
  if (-not (Test-CommandExists 'docker')) { Write-Warn2 "'docker' not found on PATH - skipping image removal." }
  else {
    $tag = if ([string]::IsNullOrWhiteSpace($Version)) { 'latest' } else { $Version }
    foreach ($k in $prodKeys) {
      $img = if ($Registry -eq 'dockerhub') { "groupdocs/$k-net-mcp:$tag" } else { "ghcr.io/groupdocs-$k/$k-net-mcp:$tag" }
      Write-Info "docker rmi $img"
      if (-not $DryRun) { & docker rmi $img 2>$null | Out-Null }
    }
  }
}

if ($PurgeNugetCache) {
  Write-Head "Purging NuGet package cache (dnx re-downloads on next use)"
  $nugetRoot = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $HOME '.nuget/packages' }
  foreach ($k in $prodKeys) {
    $pkgDir = Join-Path $nugetRoot ($mani.products.$k.nuget.ToLower())
    if (Test-Path $pkgDir) {
      if ($DryRun) { Write-Info "(dry-run) would delete $pkgDir" }
      else { Remove-Item -LiteralPath $pkgDir -Recurse -Force; Write-Ok "purged $pkgDir" }
    } else { Write-Info "not cached: $pkgDir" }
  }
}

Write-Head "Done"
if ($DryRun) { Write-Info "dry-run complete - re-run without -DryRun to apply." }
else {
  Write-Info "removed $total server registration(s). Restart your AI client(s) to drop them."
  Write-Info "Client config backups (.bak) were left next to each modified file."
}
