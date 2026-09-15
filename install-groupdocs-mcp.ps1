<#
.SYNOPSIS
  Config-driven installer that registers GroupDocs MCP servers into one or more
  AI clients (Claude Desktop, Claude Code, VS Code / Copilot, Visual Studio 2022,
  Cursor, Windsurf, Cline, Codex CLI) and/or emits a docker-compose.yml.
  Works cross-platform on PowerShell 5.1 and 7+.

.DESCRIPTION
  Reads a JSON config (which products, which channel, which clients) plus the
  product catalog in manifest.json, then generates the correct MCP server
  entries and merges them into each client's config file (or registers via the
  client's own CLI where that is the native path: Claude Code, Codex).
  Optionally pulls Docker images / warms the dnx package cache up front
  (-Prewarm) and writes a docker-compose.yml (-EmitCompose).

  Run with -Interactive (or with no config file present) for a guided wizard
  that asks for platform, products, channel, clients, and shared paths, then
  saves the config for next time.

  Platform = the runtime hosting the servers. .NET ("net") is the only one
  available today and the default; Java, Python and Node.js are listed in
  manifest.json as planned and refused until they ship. Channels are defined
  per platform in the manifest. For "net":
    docker  - self-contained, native deps bundled (recommended cross-platform)
    nuget   - dnx auto-pull; needs .NET 10 SDK (+ libgdiplus on Linux/macOS)

  A pinned -Version is checked against the MCP Registry before anything is
  written, so a product that was never published at that version is skipped
  with a reason instead of failing at first launch inside the AI client.

  -Metered forwards GROUPDOCS_METERED_PUBLIC_KEY / GROUPDOCS_METERED_PRIVATE_KEY
  from the environment. The keys are never written to any file.

.EXAMPLE
  ./install-groupdocs-mcp.ps1 -Interactive
  ./install-groupdocs-mcp.ps1 -DryRun
  ./install-groupdocs-mcp.ps1 -Config my.config.json -Prewarm
  ./install-groupdocs-mcp.ps1 -Channel nuget -Products metadata,conversion -Clients vscode
  ./install-groupdocs-mcp.ps1 -Platform net -Version 26.9.0 -Metered -Verify
  ./install-groupdocs-mcp.ps1 -EmitCompose -DryRun
#>
[CmdletBinding()]
param(
  [string]   $Config    = (Join-Path $PSScriptRoot 'groupdocs-mcp.config.json'),
  [string]   $Manifest  = (Join-Path $PSScriptRoot 'manifest.json'),
  # Platform and channel are validated against manifest.json at runtime rather
  # than with ValidateSet: a new platform (and its channels) is a manifest entry.
  [string]   $Platform,
  [string]   $Channel,
  [ValidateSet('ghcr','dockerhub')]
  [string]   $Registry,
  [string[]] $Products,
  [string[]] $Clients,
  [string]   $Version,
  [switch]   $Metered,
  [switch]   $Interactive,
  [switch]   $SkipPreflight,
  [switch]   $SkipRegistryCheck,
  [switch]   $Verify,
  [switch]   $Prewarm,
  [switch]   $EmitCompose,
  [switch]   $Uninstall,
  [switch]   $RemoveImages,
  [switch]   $RemoveCompose,
  [switch]   $DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/platform.ps1')

$KNOWN_CLIENTS = @('claude-desktop','claude-code','vscode','vscode-workspace','vs2022','cursor','windsurf','cline','codex')

function Write-Info  ($m) { Write-Host "  $m" }
function Write-Ok    ($m) { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn2 ($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Head  ($m) { Write-Host "`n== $m ==" -ForegroundColor Cyan }

function Get-Json ($path) {
  if (-not (Test-Path $path)) { throw "File not found: $path" }
  return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
}

# UTF-8 WITHOUT BOM on every PowerShell version - PS 5.1's `-Encoding UTF8`
# writes a BOM, which some client JSON parsers reject.
function Write-TextNoBom ($path, [string]$content) {
  [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-IsWindows {
  if ($PSVersionTable.PSVersion.Major -ge 6) { return $IsWindows }
  return $true   # Windows PowerShell 5.1 only runs on Windows
}
function Test-IsMac {
  if ($PSVersionTable.PSVersion.Major -ge 6) { return $IsMacOS }
  return $false
}

function Test-CommandExists ([string]$name) {
  return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

# --- Load catalog ------------------------------------------------------------
$mani = Get-Json $Manifest
$allKeys = @($mani.products.PSObject.Properties.Name)

# --- Interactive wizard ------------------------------------------------------
function Invoke-Wizard {
  Write-Head "GroupDocs MCP setup wizard"
  Write-Host "  Press Enter to accept the [default] shown for each question.`n"

  # Platform first: it decides which products and channels exist.
  $catalog  = Get-PlatformCatalog $mani
  $defaultPf = Get-DefaultPlatform $mani
  $pfLines = @($catalog.PSObject.Properties | ForEach-Object {
    $tag = if ("$($_.Value.status)" -eq 'available') { '' } else { " ($($_.Value.status) - not installable yet)" }
    "$($_.Name) = $($_.Value.displayName)$tag"
  })
  Write-Host "  Platforms: $($pfLines -join '; ')"
  $pfDef = $null
  while (-not $pfDef) {
    $pfAns = Read-Host "  Which platform? [$defaultPf]"
    if ([string]::IsNullOrWhiteSpace($pfAns)) { $pfAns = $defaultPf }
    try { $pfDef = Resolve-Platform $mani $pfAns } catch { Write-Warn2 $_.Exception.Message }
  }
  $pfKey = $pfAns.Trim().ToLower()

  $pfProducts = @($allKeys | Where-Object { Test-ProductOnPlatform $mani $pfKey $_ } | Sort-Object)
  Write-Host "  Products: $($pfProducts -join ', ')"
  Write-Host "  ('all' = every individual product; 'total' alone = the all-in-one bundle)"
  $pAns = Read-Host "  Which products? (comma-separated) [all]"
  if ([string]::IsNullOrWhiteSpace($pAns)) { $pAns = 'all' }

  $pkgChannel = Get-PackageChannel $pfDef
  $prereq = if ($pfDef.packageRunner) { $pfDef.packageRunner.prerequisite } else { '' }
  $chDefault = if ($pfDef.defaultChannel) { "$($pfDef.defaultChannel)" } else { @($pfDef.channels)[0] }
  $chHelp = @($pfDef.channels | ForEach-Object {
    if ($_ -eq 'docker') { 'docker (self-contained, recommended)' }
    elseif ($_ -eq $pkgChannel) { "$_ ($($pfDef.packageRunner.command), needs $prereq)" }
    else { "$_" }
  }) -join ' or '
  $cAns = $null
  while (-not $cAns) {
    $cAns = Read-Host "  Channel - $chHelp [$chDefault]"
    if ([string]::IsNullOrWhiteSpace($cAns)) { $cAns = $chDefault }
    if (@($pfDef.channels) -notcontains $cAns.Trim().ToLower()) { Write-Warn2 "Choose one of: $($pfDef.channels -join ', ')"; $cAns = $null }
  }

  $rAns = 'ghcr'
  if ($cAns.Trim().ToLower() -eq 'docker') {
    $rAns = Read-Host "  Registry - ghcr or dockerhub [ghcr]"
    if ([string]::IsNullOrWhiteSpace($rAns)) { $rAns = 'ghcr' }
  }

  Write-Host "  Clients: $($KNOWN_CLIENTS -join ', ')"
  $clAns = Read-Host "  Which clients to register into? (comma-separated) [claude-desktop]"
  if ([string]::IsNullOrWhiteSpace($clAns)) { $clAns = 'claude-desktop' }

  $sAns = Read-Host "  Documents storage folder (inputs + outputs) [$((Get-Location).Path)]"
  if ([string]::IsNullOrWhiteSpace($sAns)) { $sAns = (Get-Location).Path }

  $oAns = Read-Host "  Separate output folder (Enter = same as storage)"
  $lAns = Read-Host "  Path to GroupDocs license .lic file (Enter = none)"

  # Metered keys are NOT asked for: typing a private key into a prompt puts it in
  # terminal scrollback, and saving it would put it in this config file. Only the
  # choice is recorded; the keys stay in the environment.
  Write-Host "  Metered (pay-per-use) licensing reads $((Get-MeteredVariableNames) -join ' and ') from your environment."
  foreach ($n in Get-MeteredVariableNames) { Write-Host "    $n : $(Get-SecretPresence $n)" }
  $mDefault = if ((Get-MeteredConfigState) -eq 'complete') { 'Y/n' } else { 'y/N' }
  $mAns = Read-Host "  Use metered licensing? [$mDefault]"
  $useMetered = if ([string]::IsNullOrWhiteSpace($mAns)) { $mDefault -eq 'Y/n' } else { "$mAns".Trim().ToLower() -in @('y','yes') }

  $vAns = Read-Host "  Version pin, e.g. 26.9.0 (Enter = latest)"
  if ([string]::IsNullOrWhiteSpace($vAns)) { $vAns = 'latest' }

  $verAns = Read-Host "  Run post-install verification when done? (spawns each server, checks its tools and license mode, and - if a document exists in the storage folder - runs get_document_info on it) [Y/n]"
  if ("$verAns".Trim().ToLower() -notin @('n','no')) { $script:WizardWantsVerify = $true }

  $doc = [ordered]@{
    platform    = $pfKey
    channel     = $cAns.Trim().ToLower()
    registry    = $rAns.Trim().ToLower()
    clients     = @($clAns -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    version     = $vAns.Trim()
    storagePath = $sAns.Trim()
    outputPath  = "$oAns".Trim()
    licensePath = "$lAns".Trim()
    metered     = [bool]$useMetered
    products    = @($pAns -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
  }
  $json = ($doc | ConvertTo-Json -Depth 6)
  Write-Host "`n  Saving config -> $Config"
  Write-TextNoBom $Config $json
  Write-Ok "config saved; re-run with -DryRun any time to preview"
  return (Get-Json $Config)
}

# --- Load config (wizard if requested or missing) ----------------------------
$cfg = $null
if ($Interactive -or -not (Test-Path $Config)) {
  if (-not (Test-Path $Config)) { Write-Warn2 "No config at $Config - starting the wizard." }
  $cfg = Invoke-Wizard
} else {
  $cfg = Get-Json $Config
}

# CLI overrides win over config file. -Clients uses ContainsKey so an EXPLICIT
# empty array (-Clients @(), the compose-only flow) overrides too - a bare
# truthiness check treats @() as "not passed" and silently falls back to the
# config's clients.
if ($Platform) { $cfg | Add-Member platform $Platform -Force }
if ($Channel)  { $cfg | Add-Member channel  $Channel  -Force }
if ($Registry) { $cfg | Add-Member registry $Registry -Force }
if ($Version)  { $cfg | Add-Member version  $Version  -Force }
if ($Products) { $cfg | Add-Member products $Products -Force }
if ($PSBoundParameters.ContainsKey('Metered')) { $cfg | Add-Member metered ([bool]$Metered) -Force }
if ($PSBoundParameters.ContainsKey('Clients')) { $cfg | Add-Member clients $Clients -Force }

# Platform before channel: the platform decides which channels are valid, and a
# config that predates platforms (no "platform" key) means .NET, as it always did.
$platformKey = if ($cfg.PSObject.Properties.Name -contains 'platform' -and $cfg.platform) { "$($cfg.platform)".ToLower() } else { Get-DefaultPlatform $mani }
$platformDef = Resolve-Platform $mani $platformKey
$packageChannel = Get-PackageChannel $platformDef
$defaultChannel = if ($platformDef.defaultChannel) { "$($platformDef.defaultChannel)" } else { "$(@($platformDef.channels)[0])" }

$channel     = if ($cfg.channel)     { "$($cfg.channel)".ToLower() } else { $defaultChannel }
Assert-PlatformChannel $platformKey $platformDef $channel
$registry    = if ($cfg.registry)    { "$($cfg.registry)".ToLower() } else { 'ghcr' }
$version     = if ($cfg.version)      { "$($cfg.version)" }            else { 'latest' }
$storagePath = if ($cfg.storagePath) { "$($cfg.storagePath)" }        else { (Get-Location).Path }
$outputPath  = if ($cfg.outputPath)  { "$($cfg.outputPath)" }         else { '' }
$licensePath = if ($cfg.licensePath) { "$($cfg.licensePath)" }        else { '' }
$useMetered  = ($cfg.PSObject.Properties.Name -contains 'metered') -and [bool]$cfg.metered
$clients     = @($cfg.clients)
$requested   = @($cfg.products)

Write-Head "GroupDocs MCP installer"
Write-Info "platform=$platformKey ($($platformDef.displayName))  channel=$channel  registry=$registry  version=$version"
if ($outputPath -ne '') { Write-Info "storage=$storagePath  output=$outputPath" }
else                    { Write-Info "storage=$storagePath  output=(same as storage)" }
$licenseDesc = if ($useMetered -and $licensePath -ne '') { "metered (license file ignored: $licensePath)" }
               elseif ($useMetered)                     { 'metered (keys from environment)' }
               elseif ($licensePath -ne '')             { "file $licensePath" }
               else                                     { '(evaluation mode)' }
Write-Info "license=$licenseDesc"

# --- Prerequisite preflight (same checks as setup/<os> --check) --------------
# Runs BEFORE any filesystem mutation: a config that points at a missing runtime
# would otherwise fail at first launch inside the AI client, which is the worst
# place to discover it. -SkipPreflight bypasses; -DryRun warns and continues.
function Get-SetupCommand {
  if (Test-IsWindows) { return "powershell -ExecutionPolicy Bypass -File setup\windows.ps1 -Channel $channel" }
  if (Test-IsMac)     { return "bash setup/macos.sh --channel $channel" }
  return "bash setup/linux.sh --channel $channel"
}
function Test-Prerequisites {
  $problems = @()
  if ($channel -eq 'docker') {
    if (-not (Test-CommandExists 'docker')) {
      $problems += "docker CLI not found on PATH"
    } else {
      & docker version --format '{{.Server.Version}}' 2>$null | Out-Null
      if ($LASTEXITCODE -ne 0) { $problems += "docker daemon not reachable (is Docker Desktop / dockerd running?)" }
    }
  } else {
    $runnerName = Get-PackageRunnerCommand $mani $platformKey (Test-IsWindows)
    if (-not (Test-CommandExists $runnerName)) { $problems += "'$runnerName' not found - the $channel channel needs the $($platformDef.packageRunner.prerequisite)" }
  }
  return @($problems)
}
if (-not $SkipPreflight) {
  $missingPrereqs = Test-Prerequisites
  if ($missingPrereqs.Count -gt 0) {
    foreach ($m in $missingPrereqs) { Write-Warn2 $m }
    $setupCmd = Get-SetupCommand
    if ($Interactive -and -not $DryRun) {
      $ans = Read-Host "  Run the prerequisite setup now? ($setupCmd) [Y/n]"
      if ("$ans".Trim().ToLower() -notin @('n','no')) {
        $setupScript = if (Test-IsWindows) { Join-Path $PSScriptRoot 'setup/windows.ps1' }
                       elseif (Test-IsMac) { Join-Path $PSScriptRoot 'setup/macos.sh' }
                       else                { Join-Path $PSScriptRoot 'setup/linux.sh' }
        if (Test-IsWindows) { & powershell -ExecutionPolicy Bypass -File $setupScript -Channel $channel }
        else                { & bash $setupScript --channel $channel }
        $missingPrereqs = Test-Prerequisites
      }
    }
    if ($missingPrereqs.Count -gt 0) {
      if ($DryRun) { Write-Warn2 "(dry-run) continuing despite missing prerequisites - fix with:  $setupCmd" }
      else { throw "Missing prerequisites for the '$channel' channel. Fix with:  $setupCmd  (or re-run with -SkipPreflight)" }
    }
  } else {
    Write-Info "prerequisites OK ($channel channel)"
  }
}

# Fail early on obviously wrong shared paths (placeholder or missing license file).
if ($licensePath -ne '' -and -not (Test-Path $licensePath)) {
  Write-Warn2 "license file not found at '$licensePath' - servers will run in evaluation mode until it exists."
}

# Metered: report presence only - never a value. Missing keys do not block the
# install (the keys can be set afterwards, before the client restarts), but the
# user must hear now that the server would otherwise run in evaluation mode.
if ($useMetered) {
  foreach ($n in Get-MeteredVariableNames) { Write-Info "$n : $(Get-SecretPresence $n)" }
  switch (Get-MeteredConfigState) {
    'missing' { Write-Warn2 "metered is on but neither key is set in this environment - servers will run in evaluation mode until both are set where the AI client starts." }
    'partial' { Write-Warn2 "metered is on but only one key is set - metered licensing needs BOTH; servers will ignore a half-configured pair." }
  }
  if ($licensePath -ne '') { Write-Warn2 "both metered keys and licensePath are configured - servers use metered licensing and ignore the license file." }
}

# --- Resolve product list --------------------------------------------------
$resolved = New-Object System.Collections.Generic.List[string]
foreach ($p in $requested) {
  $k = "$p".ToLower().Trim()
  if ($k -eq 'all') {
    # "all" = every individual product; Total is the bundle equivalent, so skip it here.
    foreach ($a in $allKeys) {
      if ($a -ne 'total' -and (Test-ProductOnPlatform $mani $platformKey $a) -and -not $resolved.Contains($a)) { $resolved.Add($a) }
    }
  } elseif ($allKeys -contains $k) {
    if (-not (Test-ProductOnPlatform $mani $platformKey $k)) {
      Write-Warn2 "'$k' is not available on platform '$platformKey' - skipped. Available on: $((Get-ProductPlatforms $mani $k) -join ', ')"
    } elseif (-not $resolved.Contains($k)) { $resolved.Add($k) }
  } else {
    Write-Warn2 "Unknown product '$p' - skipped. Known: $($allKeys -join ', ')"
  }
}
if ($resolved.Count -eq 0) { throw "No valid products resolved from config. Nothing to do." }
if ($resolved.Contains('total') -and $resolved.Count -gt 1) {
  Write-Warn2 "'total' bundles every product; the individual servers you also listed are redundant (duplicate tools)."
}

# The package channel can't serve bundles over the package registry's size limit.
if ($channel -eq $packageChannel) {
  foreach ($k in @($resolved)) {
    if (Test-PackageBlocked $mani $platformKey $k) {
      Write-Warn2 "'$k' is not published to $channel ($($platformDef.packageRunner.sizeLimitNote)) - use -Channel docker for it. Skipping on $channel."
      [void]$resolved.Remove($k)
    }
  }
  if ($resolved.Count -eq 0) {
    throw "All requested products are $channel-blocked - nothing left to install on the $channel channel. Re-run with -Channel docker."
  }
}

# --- MCP Registry check ------------------------------------------------------
# The registry is the one version index that covers every product, including the
# docker-first ones with no NuGet package. A pinned version is checked here,
# BEFORE any write: products were never guaranteed to share a version (Total can
# trail the rest), and a pin that does not exist for one product used to surface
# only at first launch inside the AI client. Offline is a warning, not a stop.
$registryInfo = @{}
if (-not $SkipRegistryCheck) {
  $regIndex = Get-RegistryIndex
  if (-not $regIndex.ok) {
    Write-Warn2 "MCP Registry unreachable ($($regIndex.error)) - versions not checked. Use -SkipRegistryCheck to skip this lookup offline."
  } else {
    foreach ($k in @($resolved)) {
      $info = Get-RegistryProductInfo $mani $platformKey $k $regIndex
      $registryInfo[$k] = $info
      if (-not $info.found) {
        Write-Warn2 "'$k' has no MCP Registry entry ($($info.name)) - version not checked."
        continue
      }
      if (-not (Test-IsLatestVersion $version) -and @($info.versions) -notcontains $version.Trim()) {
        Write-Warn2 "'$k' was never published at $version (latest $($info.latest)) - skipped. Pin a published version or use 'latest'."
        [void]$resolved.Remove($k)
      }
    }
    if ($resolved.Count -eq 0) { throw "No requested product is published at version $version. Nothing to do." }
  }
}

$productLines = @($resolved | ForEach-Object {
  if ($registryInfo.ContainsKey($_) -and $registryInfo[$_].found) { "$_ ($($registryInfo[$_].latest))" } else { $_ }
})
if (-not (Test-IsLatestVersion $version)) { Write-Info "products @ ${version}: $($resolved -join ', ')" }
elseif ($registryInfo.Count -gt 0)        { Write-Info "products (latest per MCP Registry): $($productLines -join ', ')" }
else                                      { Write-Info "products (latest, not checked): $($resolved -join ', ')" }

# Folders are created only now, after every validation that can abort the run -
# a refused install must not leave a freshly created folder behind (backlog 1b.1).
if (-not (Test-Path $storagePath)) {
  if ($DryRun) { Write-Info "(dry-run) storage folder '$storagePath' does not exist - would create it" }
  else { New-Item -ItemType Directory -Force -Path $storagePath | Out-Null; Write-Ok "created storage folder $storagePath" }
}
if ($outputPath -ne '' -and -not (Test-Path $outputPath)) {
  if ($DryRun) { Write-Info "(dry-run) output folder '$outputPath' does not exist - would create it" }
  else { New-Item -ItemType Directory -Force -Path $outputPath | Out-Null; Write-Ok "created output folder $outputPath" }
}

# --- Build one MCP server entry -------------------------------------------
function New-DockerEntry ($key) {
  $image = Get-ImageRef $mani $platformKey $key $registry $version
  $sp = ConvertTo-DockerHostPath $storagePath
  $dargs = [System.Collections.Generic.List[string]]::new()
  @('run','--rm','-i') | ForEach-Object { $dargs.Add($_) }
  $dargs.Add('-v'); $dargs.Add("$sp`:/data")
  $dargs.Add('-e'); $dargs.Add('GROUPDOCS_MCP_STORAGE_PATH=/data')
  if ($outputPath -ne '') {
    $op = ConvertTo-DockerHostPath $outputPath
    $dargs.Add('-v'); $dargs.Add("$op`:/data/output")
    $dargs.Add('-e'); $dargs.Add('GROUPDOCS_MCP_OUTPUT_PATH=/data/output')
  }
  if ($licensePath -ne '') {
    $licDir  = ConvertTo-DockerHostPath (Split-Path -Parent $licensePath)
    $licName = Split-Path -Leaf   $licensePath
    $dargs.Add('-v'); $dargs.Add("$licDir`:/license:ro")
    $dargs.Add('-e'); $dargs.Add("GROUPDOCS_LICENSE_PATH=/license/$licName")
  }
  if ($useMetered) {
    # `-e NAME` with no value copies NAME from the process launching docker - the
    # AI client. The key itself is never written into the client config.
    foreach ($n in Get-MeteredVariableNames) { $dargs.Add('-e'); $dargs.Add($n) }
  }
  $dargs.Add($image)
  return [ordered]@{ command = 'docker'; args = @($dargs) }
}

# Package channel (nuget/dnx on net). Metered keys need no entry here: a stdio
# server inherits its client's environment, so writing them would only create a
# second, literal copy of a secret in a plain-text config file.
function New-PackageEntry ($key) {
  $env = [ordered]@{ GROUPDOCS_MCP_STORAGE_PATH = $storagePath }
  if ($outputPath  -ne '') { $env.GROUPDOCS_MCP_OUTPUT_PATH = $outputPath }
  if ($licensePath -ne '') { $env.GROUPDOCS_LICENSE_PATH    = $licensePath }
  $cmd = "$($platformDef.packageRunner.command)"
  return [ordered]@{ command = $cmd; args = @(Get-PackageRunnerArgs $mani $platformKey $key $version); env = $env }
}

$entries = [ordered]@{}
foreach ($k in $resolved) {
  $name = Get-ProductName $mani $platformKey $k 'server'
  $entries[$name] = if ($channel -eq 'docker') { New-DockerEntry $k } else { New-PackageEntry $k }
}

# --- Client config targets -------------------------------------------------
# File-based clients get a target (path + root key). CLI-based clients
# (claude-code, codex) register through the client's own command instead -
# that is their supported path and avoids guessing at internal file formats.
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
      # VS Code user-level MCP config (applies to every workspace).
      $base = if (Test-IsWindows) { Join-Path $env:APPDATA 'Code/User' }
              elseif (Test-IsMac) { Join-Path $HOME 'Library/Application Support/Code/User' }
              else                { Join-Path $HOME '.config/Code/User' }
      return @{ path = (Join-Path $base 'mcp.json'); root = 'servers' }
    }
    'vscode-workspace' { return @{ path = (Join-Path (Get-Location) '.vscode/mcp.json'); root = 'servers' } }
    'vs2022'           { return @{ path = (Join-Path (Get-Location) '.mcp.json'); root = 'servers' } }
    default   { throw "Unknown client '$client'. Use: $($KNOWN_CLIENTS -join ', ')." }
  }
}
function Test-CliClient ($client) { return @('claude-code','codex') -contains $client.ToLower() }

function Merge-IntoClient ($target, $entries) {
  $path = $target.path; $root = $target.root
  $dir  = Split-Path -Parent $path
  if (-not (Test-Path $dir)) {
    if ($DryRun) { Write-Info "(dry-run) would create $dir" } else { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  }
  $doc = if (Test-Path $path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } else { [pscustomobject]@{} }
  if (-not ($doc.PSObject.Properties.Name -contains $root)) {
    $doc | Add-Member -NotePropertyName $root -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  foreach ($name in $entries.Keys) {
    $doc.$root | Add-Member -NotePropertyName $name -NotePropertyValue $entries[$name] -Force
  }
  $json = $doc | ConvertTo-Json -Depth 12
  if ($DryRun) {
    Write-Info "(dry-run) would write $path :"
    $json -split "`n" | ForEach-Object { Write-Host "      $_" }
    return
  }
  if (Test-Path $path) {
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $path -Destination "$path.$stamp.bak"
    Write-Info "backed up existing -> $path.$stamp.bak"
  }
  Write-TextNoBom $path $json
  Write-Ok "$path  ($($entries.Count) server(s))"
}

# --- CLI-based clients (claude-code, codex) ---------------------------------
function Register-ViaCli ($client, $entries) {
  $cli = if ($client -eq 'claude-code') { 'claude' } else { 'codex' }
  $cliPresent = Test-CommandExists $cli
  if (-not $cliPresent) {
    if (-not $DryRun) {
      Write-Warn2 "'$cli' CLI not found on PATH - skipping client '$client'. Install it, or run the command below in a shell where '$cli' works."
    } else {
      Write-Warn2 "'$cli' CLI not found on PATH here - showing the command it would run:"
    }
  }
  foreach ($name in $entries.Keys) {
    $e = $entries[$name]
    $cliArgs = [System.Collections.Generic.List[string]]::new()
    if ($client -eq 'claude-code') {
      @('mcp','add','--scope','user') | ForEach-Object { $cliArgs.Add($_) }
      if ($e.Contains('env')) { foreach ($kv in $e.env.GetEnumerator()) { $cliArgs.Add('-e'); $cliArgs.Add("$($kv.Key)=$($kv.Value)") } }
      $cliArgs.Add($name)
    } else {
      @('mcp','add') | ForEach-Object { $cliArgs.Add($_) }
      if ($e.Contains('env')) { foreach ($kv in $e.env.GetEnumerator()) { $cliArgs.Add('--env'); $cliArgs.Add("$($kv.Key)=$($kv.Value)") } }
      $cliArgs.Add($name)
    }
    $cliArgs.Add('--'); $cliArgs.Add($e.command)
    foreach ($a in $e.args) { $cliArgs.Add($a) }
    # Always SHOW the exact command (dry-run, or CLI missing) so users can copy it
    # into a shell where the client CLI is available.
    if ($DryRun -or -not $cliPresent) { Write-Info "$cli $($cliArgs -join ' ')"; continue }
    & $cli @cliArgs
    if ($LASTEXITCODE -eq 0) { Write-Ok "$cli registered '$name'" }
    else { Write-Warn2 "$cli exited $LASTEXITCODE registering '$name' - check the output above." }
  }
}

if ($Uninstall) {
  # Delegate to the dedicated removal script (single implementation). Scope note:
  # the installer's -Uninstall clears the clients listed in the CONFIG; run
  # uninstall-groupdocs-mcp.ps1 directly (defaults: all products, ALL clients)
  # to sweep entries left behind after the config changed.
  $un = Join-Path $PSScriptRoot 'uninstall-groupdocs-mcp.ps1'
  $unArgs = @{ Manifest = $Manifest; Platform = $platformKey; Products = @('all'); Clients = @($clients); Registry = $registry; Version = $version }
  if ($RemoveImages)  { $unArgs.RemoveImages  = $true }
  if ($RemoveCompose) { $unArgs.RemoveCompose = $true }
  if ($DryRun)        { $unArgs.DryRun        = $true }
  & $un @unArgs
  return
}

Write-Head "Registering into clients"
foreach ($c in $clients) {
  if (Test-CliClient $c) { Write-Info "client '$c' (via CLI)"; Register-ViaCli $c $entries; continue }
  $t = Get-ClientTarget $c
  Write-Info "client '$c' -> $($t.path)"
  Merge-IntoClient $t $entries
}

# --- docker-compose.yml ----------------------------------------------------
function Write-Compose {
  $lines = [System.Collections.Generic.List[string]]::new()
  $lines.Add('services:')
  foreach ($k in $resolved) {
    $name  = Get-ProductName $mani $platformKey $k 'server'
    $image = Get-ImageRef $mani $platformKey $k $registry $version
    $sp = ConvertTo-DockerHostPath $storagePath
    $lines.Add("  $name`:")
    $lines.Add("    image: $image")
    $lines.Add('    volumes:')
    $lines.Add("      - `"$sp`:/data`"")
    if ($outputPath  -ne '') { $lines.Add("      - `"$(ConvertTo-DockerHostPath $outputPath)`:/data/output`"") }
    if ($licensePath -ne '') { $lines.Add("      - `"$(ConvertTo-DockerHostPath (Split-Path -Parent $licensePath))`:/license:ro`"") }
    $lines.Add('    environment:')
    $lines.Add('      GROUPDOCS_MCP_STORAGE_PATH: /data')
    if ($outputPath  -ne '') { $lines.Add('      GROUPDOCS_MCP_OUTPUT_PATH: /data/output') }
    if ($licensePath -ne '') { $lines.Add("      GROUPDOCS_LICENSE_PATH: /license/$(Split-Path -Leaf $licensePath)") }
    # A key with no value is taken from the shell running `docker compose` - the
    # compose file never holds the secret.
    if ($useMetered) { foreach ($n in Get-MeteredVariableNames) { $lines.Add("      ${n}:") } }
    $lines.Add('    stdin_open: true')
    $lines.Add('    tty: true')
    $lines.Add('    restart: unless-stopped')
  }
  $out = Join-Path (Get-Location) 'docker-compose.yml'
  if ($DryRun) { Write-Info "(dry-run) would write $out"; return }
  Write-TextNoBom $out (($lines -join "`n") + "`n")
  Write-Ok "docker-compose.yml written -> $out"
}

if ($EmitCompose) {
  if ($channel -ne 'docker') { Write-Warn2 "-EmitCompose ignored: compose requires channel=docker." }
  else { Write-Head "docker-compose.yml"; Write-Compose }
}

# --- Prewarm ---------------------------------------------------------------
# docker: pull each image. nuget: download + first-launch each package by
# spawning the server with CLOSED stdin - a stdio MCP server reads EOF and
# exits cleanly (exit 0), leaving the dnx cache warm. This matters: a COLD
# dnx cache can make a client's first in-pipe launch of a large package fail
# before the download completes (observed org-wide; worst on the 161 MB
# Signature package).
if ($Prewarm) {
  Write-Head "Prewarming ($channel)"
  foreach ($k in $resolved) {
    if ($channel -eq 'docker') {
      $image = Get-ImageRef $mani $platformKey $k $registry $version
      Write-Info "docker pull $image"
      if (-not $DryRun) { & docker pull $image }
    } else {
      $runArgs = Get-PackageRunnerArgs $mani $platformKey $k $version
      Write-Info "$($platformDef.packageRunner.command) $($runArgs -join ' ')  (download + first launch, stdin closed)"
      if ($DryRun) { continue }
      # Full path is required: dnx.cmd's internal %~dp0dotnet.exe resolves against
      # the wrong directory when the shim is started by bare name from Process.Start.
      $dnxName = Get-PackageRunnerCommand $mani $platformKey (Test-IsWindows)
      $dnxCmd  = (Get-Command $dnxName -ErrorAction SilentlyContinue).Source
      if (-not $dnxCmd) { Write-Warn2 "'$dnxName' not found on PATH - install the $($platformDef.packageRunner.prerequisite). Skipping prewarm."; continue }
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName  = $dnxCmd
      $psi.Arguments = ($runArgs -join ' ')
      $psi.RedirectStandardInput  = $true
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError  = $true
      $psi.UseShellExecute = $false
      try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Close()          # EOF -> server exits after startup
        $null = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(300000)) { try { $proc.Kill() } catch {}; Write-Warn2 "'$k' prewarm timed out (5 min) - killed." }
        elseif ($proc.ExitCode -eq 0) { Write-Ok "'$k' cache warm (clean first launch)" }
        else {
          $tail = (($errTask.Result -split "`n") | Select-Object -Last 3) -join ' | '
          Write-Warn2 "'$k' prewarm exit $($proc.ExitCode): $tail"
        }
      } catch {
        Write-Warn2 "'$k' prewarm failed to start '$dnxCmd': $($_.Exception.Message)"
      }
    }
  }
}

Write-Head "Done"
Write-Info "Restart your AI client to pick up the new servers."

# --- Post-install verification (-Verify, or chosen in the wizard) -----------
# Chains to verify-groupdocs-mcp.ps1 with the SAME effective settings. Caches
# are warmed first (docker pull / dnx first-launch) so pulls don't eat the
# verifier's per-server timeout. 'auto' level: handshake + get_document_info
# against the first document found in the storage folder, when one exists.
if (($Verify -or $script:WizardWantsVerify) -and -not $DryRun) {
  if (-not $Prewarm) {
    Write-Head "Prewarming before verification"
    foreach ($k in $resolved) {
      if ($channel -eq 'docker') {
        $image = Get-ImageRef $mani $platformKey $k $registry $version
        Write-Info "docker pull $image"
        & docker pull $image | Out-Null
      }
      # package channel: the -Prewarm block above is the thorough warm; for
      # verification the verifier's own launch downloads on demand within its
      # timeout - acceptable when the package is already cached, which -Prewarm
      # guarantees. Warm here too:
      else {
        $runArgs2 = Get-PackageRunnerArgs $mani $platformKey $k $version
        $dnxName2 = Get-PackageRunnerCommand $mani $platformKey (Test-IsWindows)
        $dnxCmd2  = (Get-Command $dnxName2 -ErrorAction SilentlyContinue).Source
        if ($dnxCmd2) {
          Write-Info "$($platformDef.packageRunner.command) $($runArgs2 -join ' ') (cache warm)"
          $psi2 = New-Object System.Diagnostics.ProcessStartInfo
          $psi2.FileName = $dnxCmd2; $psi2.Arguments = ($runArgs2 -join ' ')
          $psi2.RedirectStandardInput = $true; $psi2.RedirectStandardOutput = $true; $psi2.RedirectStandardError = $true
          $psi2.UseShellExecute = $false
          try {
            $p2 = [System.Diagnostics.Process]::Start($psi2)
            $p2.StandardInput.Close()
            $null = $p2.StandardOutput.ReadToEndAsync(); $null = $p2.StandardError.ReadToEndAsync()
            if (-not $p2.WaitForExit(300000)) { try { $p2.Kill() } catch {} }
          } catch {}
        }
      }
    }
  }
  Write-Head "Post-install verification"
  $vs = Join-Path $PSScriptRoot 'verify-groupdocs-mcp.ps1'
  $vsArgs = @{ Config = $Config; Manifest = $Manifest; Platform = $platformKey; Channel = $channel; Registry = $registry; Version = $version; Products = @($resolved); TimeoutSec = 180 }
  if ($useMetered) { $vsArgs.Metered = $true }
  & $vs @vsArgs
  exit $LASTEXITCODE
}
Write-Info "Next: ./verify-groupdocs-mcp.ps1  (auto level: handshake + license mode + get_document_info on the first document in your storage folder)"
