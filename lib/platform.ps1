<#
.SYNOPSIS
  Platform, naming, licensing and MCP Registry helpers shared by the install,
  verify and uninstall scripts. Dot-source it; it defines functions only.

.DESCRIPTION
  Everything that differs per MCP *platform* (the runtime hosting the server:
  .NET today; Java, Python, Node.js planned) is data in manifest.json, read
  through these functions - so adding a platform is a manifest entry, not code.

  Pure functions: inputs in, values out. No script-scope state, no writes.
  Must stay PowerShell 5.1 compatible and pure ASCII (see AGENTS.md).
#>

$script:METERED_PUBLIC_VAR  = 'GROUPDOCS_METERED_PUBLIC_KEY'
$script:METERED_PRIVATE_VAR = 'GROUPDOCS_METERED_PRIVATE_KEY'
$script:REGISTRY_BASE       = 'https://registry.modelcontextprotocol.io/v0/servers'
$script:REGISTRY_META_KEY   = 'io.modelcontextprotocol.registry/official'

# --- Platform catalog ---------------------------------------------------------

# A manifest written before platforms existed (schema 1) has only .NET data in
# its product fields. Synthesize the net platform from those so an older
# -Manifest keeps working unchanged.
function Get-PlatformCatalog ($mani) {
  if ($mani.PSObject.Properties.Name -contains 'platforms') { return $mani.platforms }
  return [pscustomobject]@{
    net = [pscustomobject]@{
      displayName    = '.NET'
      status         = 'available'
      channels       = @('docker', 'nuget')
      defaultChannel = 'docker'
      naming         = [pscustomobject]@{
        server      = 'groupdocs-<slug>'
        ghcr        = 'ghcr.io/groupdocs-<slug>/<slug>-net-mcp'
        dockerhub   = 'groupdocs/<slug>-net-mcp'
        package     = 'GroupDocs.<Product>.Mcp'
        mcpRegistry = @('io.github.groupdocs-<slug>/groupdocs-<slug>-mcp')
      }
      packageRunner  = [pscustomobject]@{
        channel = 'nuget'; command = 'dnx'; windowsCommand = 'dnx.cmd'
        args = @('{ref}', '--yes'); ref = '{package}@{version}'; refLatest = '{package}'
        prerequisite = '.NET 10 SDK'
      }
    }
  }
}

function Get-DefaultPlatform ($mani) {
  if ($mani.PSObject.Properties.Name -contains 'defaultPlatform' -and $mani.defaultPlatform) {
    return "$($mani.defaultPlatform)".ToLower()
  }
  return 'net'
}

function Get-AvailablePlatformKeys ($mani) {
  $cat = Get-PlatformCatalog $mani
  return @($cat.PSObject.Properties | Where-Object { "$($_.Value.status)" -eq 'available' } | ForEach-Object { $_.Name })
}

# Returns the platform definition, or throws with the reason and the choices.
# A planned platform is refused rather than half-installed: its image, package
# and registry names are not decided yet (see manifest note), so any entry we
# wrote would point at an artifact that does not exist.
function Resolve-Platform ($mani, [string]$requested) {
  $cat = Get-PlatformCatalog $mani
  $key = "$requested".Trim().ToLower()
  if ($key -eq '') { $key = Get-DefaultPlatform $mani }
  $available = (Get-AvailablePlatformKeys $mani) -join ', '
  if (-not ($cat.PSObject.Properties.Name -contains $key)) {
    throw "Unknown platform '$requested'. Available: $available."
  }
  $def = $cat.$key
  if ("$($def.status)" -ne 'available') {
    throw "Platform '$key' ($($def.displayName)) is $($def.status), not yet installable. Available: $available."
  }
  return $def
}

function Assert-PlatformChannel ($platformKey, $platformDef, [string]$channel) {
  $valid = @($platformDef.channels)
  if ($valid -notcontains $channel) {
    throw "Channel '$channel' is not available on platform '$platformKey'. Use one of: $($valid -join ', ')."
  }
}

function Get-PackageChannel ($platformDef) {
  if ($platformDef.packageRunner) { return "$($platformDef.packageRunner.channel)" }
  return $null
}

# --- Product availability and naming -----------------------------------------

function Get-ProductPlatforms ($mani, $key) {
  $p = $mani.products.$key
  if ($p.PSObject.Properties.Name -contains 'platforms') { return @($p.platforms) }
  return @('net')   # schema 1: every product was .NET-only
}

function Test-ProductOnPlatform ($mani, $platformKey, $key) {
  return (Get-ProductPlatforms $mani $key) -contains $platformKey
}

function Get-ProductOverride ($mani, $platformKey, $key, $kind) {
  $p = $mani.products.$key
  if (-not ($p.PSObject.Properties.Name -contains 'overrides')) { return $null }
  if (-not ($p.overrides.PSObject.Properties.Name -contains $platformKey)) { return $null }
  $o = $p.overrides.$platformKey
  if ($o.PSObject.Properties.Name -contains $kind) { return $o.$kind }
  return $null
}

function Expand-NamePattern ([string]$pattern, $mani, $key) {
  $display = "$($mani.products.$key.displayName)"
  $product = if ($display -match '^GroupDocs\.(.+)$') { $Matches[1] } else { $display }
  return ($pattern -replace '<slug>', $key -replace '<Product>', $product)
}

# Name resolution order: explicit per-product override, then the platform's
# naming pattern. kind = server | ghcr | dockerhub | package
function Get-ProductName ($mani, $platformKey, $key, [string]$kind) {
  $ov = Get-ProductOverride $mani $platformKey $key $kind
  if ($null -ne $ov -and "$ov" -ne '') { return "$ov" }
  $def = (Get-PlatformCatalog $mani).$platformKey
  $pattern = $def.naming.$kind
  if (-not $pattern) { throw "Platform '$platformKey' has no naming pattern for '$kind'." }
  return (Expand-NamePattern "$pattern" $mani $key)
}

# Oversized packages cannot be published to the platform package registry
# (NuGet.org caps packages at 250 MB). Schema 1 recorded this as nugetBlocked.
function Test-PackageBlocked ($mani, $platformKey, $key) {
  $ov = Get-ProductOverride $mani $platformKey $key 'packageBlocked'
  if ($null -ne $ov) { return [bool]$ov }
  if ($platformKey -eq 'net') { return [bool]$mani.products.$key.nugetBlocked }
  return $false
}

function Test-IsLatestVersion ([string]$version) {
  return ([string]::IsNullOrWhiteSpace($version) -or $version.Trim().ToLower() -eq 'latest')
}

function Get-ImageRef ($mani, $platformKey, $key, [string]$registry, [string]$version) {
  $kind = if ($registry -eq 'dockerhub') { 'dockerhub' } else { 'ghcr' }
  $tag  = if (Test-IsLatestVersion $version) { 'latest' } else { $version.Trim() }
  return "$(Get-ProductName $mani $platformKey $key $kind):$tag"
}

function Get-PackageRef ($mani, $platformKey, $key, [string]$version) {
  $runner = (Get-PlatformCatalog $mani).$platformKey.packageRunner
  $pkg = Get-ProductName $mani $platformKey $key 'package'
  $tpl = if (Test-IsLatestVersion $version) { "$($runner.refLatest)" } else { "$($runner.ref)" }
  return ($tpl -replace '\{package\}', $pkg -replace '\{version\}', "$version".Trim())
}

# The package runner's command name for this OS - on Windows, dnx is a .cmd
# shim that Process.Start can only launch by full path (see AGENTS.md rule 4).
# NOT named $isWindows: that is a read-only automatic variable on PowerShell 6+,
# and binding a parameter to it throws - PS 5.1 alone would never show this.
function Get-PackageRunnerCommand ($mani, $platformKey, [bool]$onWindows) {
  $runner = (Get-PlatformCatalog $mani).$platformKey.packageRunner
  if ($onWindows -and $runner.windowsCommand) { return "$($runner.windowsCommand)" }
  return "$($runner.command)"
}

function Get-PackageRunnerArgs ($mani, $platformKey, $key, [string]$version) {
  $runner = (Get-PlatformCatalog $mani).$platformKey.packageRunner
  $ref = Get-PackageRef $mani $platformKey $key $version
  return @($runner.args | ForEach-Object { "$_" -replace '\{ref\}', $ref })
}

# Docker -v needs forward slashes; configs on Windows often carry backslashes.
function ConvertTo-DockerHostPath ([string]$p) { return ($p -replace '\\', '/') }

# --- Metered licensing -----------------------------------------------------------
#
# Keys are never written anywhere by these scripts - not to the config file, not
# to a client config, not to the console. The docker channel forwards them by
# NAME (`-e VAR` with no value copies it from the launching process), and a
# package-channel server inherits its client's environment directly.

function Get-MeteredVariableNames { return @($script:METERED_PUBLIC_VAR, $script:METERED_PRIVATE_VAR) }

# Presence only - length, never characters. Enough to catch "not set" and the
# classic truncated-paste, useless to anyone reading the output.
function Get-SecretPresence ([string]$name) {
  $v = [Environment]::GetEnvironmentVariable($name)
  if ([string]::IsNullOrWhiteSpace($v)) { return 'not set' }
  return "set ($($v.Trim().Length) chars)"
}

function Get-MeteredConfigState {
  $pub = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($script:METERED_PUBLIC_VAR))
  $prv = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($script:METERED_PRIVATE_VAR))
  if ($pub -and $prv) { return 'complete' }
  if ($pub -or $prv)  { return 'partial' }
  return 'missing'
}

# --- MCP Registry ------------------------------------------------------------------

# One paged query for every GroupDocs entry, not one per product: a fleet install
# should cost one round trip, and an offline machine should fail once, fast.
# Returns @{ ok; error; entries } - never throws.
# 45 s per attempt with one retry. 20 s was observed to time out on a GitHub ubuntu
# runner (2026-09-15) while a request seconds earlier had succeeded: the registry's
# search response time varies, and a single slow response should not cost a check.
function Get-RegistryIndex ([string]$search = 'groupdocs', [int]$timeoutSec = 45, [int]$attempts = 2) {
  try {
    # PS 5.1 on older .NET defaults to TLS 1.0, which the registry rejects.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  } catch {}
  $lastError = $null
  for ($attempt = 1; $attempt -le $attempts; $attempt++) {
    # Restart paging from scratch on a retry - a half-read index is worse than none.
    $entries = New-Object System.Collections.Generic.List[object]
    $cursor = $null
    try {
      for ($page = 0; $page -lt 10; $page++) {
        $url = "$($script:REGISTRY_BASE)?search=$([uri]::EscapeDataString($search))&limit=100"
        if ($cursor) { $url += "&cursor=$([uri]::EscapeDataString($cursor))" }
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec $timeoutSec -UseBasicParsing -ErrorAction Stop
        foreach ($e in @($resp.servers)) { $entries.Add($e) }
        $cursor = $null
        if ($resp.metadata -and ($resp.metadata.PSObject.Properties.Name -contains 'nextCursor')) { $cursor = $resp.metadata.nextCursor }
        if (-not $cursor) { break }
      }
      return @{ ok = $true; error = $null; entries = $entries.ToArray() }
    } catch {
      $lastError = $_.Exception.Message
      if ($attempt -lt $attempts) { Start-Sleep -Seconds 2 }
    }
  }
  return @{ ok = $false; error = "$lastError (after $attempts attempts)"; entries = @() }
}

function ConvertTo-VersionKey ([string]$v) {
  $parts = @("$v" -split '[.\-+]' | ForEach-Object { $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 } })
  while ($parts.Count -lt 4) { $parts += 0 }
  return ('{0:D6}.{1:D6}.{2:D6}.{3:D6}' -f $parts[0], $parts[1], $parts[2], $parts[3])
}

# Registry facts for one product on one platform:
#   @{ name; latest; versions; status; found }
# The platform may list several candidate registry names, most preferred first.
# That is how a rename is absorbed without an installer release: decision D1
# moves .NET entries to "...-mcp-net", and until those exist the current name
# still answers. Active entries beat deprecated ones.
function Get-RegistryProductInfo ($mani, $platformKey, $key, $index) {
  $def = (Get-PlatformCatalog $mani).$platformKey
  $candidates = @($def.naming.mcpRegistry | ForEach-Object { Expand-NamePattern "$_" $mani $key })
  foreach ($name in $candidates) {
    $matching = @($index.entries | Where-Object { $_.server.name -eq $name })
    if ($matching.Count -eq 0) { continue }
    $active = @($matching | Where-Object {
      $m = $_._meta
      -not ($m -and ($m.PSObject.Properties.Name -contains $script:REGISTRY_META_KEY) -and "$($m.$($script:REGISTRY_META_KEY).status)" -eq 'deprecated')
    })
    $pool = if ($active.Count -gt 0) { $active } else { $matching }
    $versions = @($pool | ForEach-Object { "$($_.server.version)" } | Sort-Object -Unique { ConvertTo-VersionKey $_ })
    $flagged = @($pool | Where-Object {
      $m = $_._meta
      $m -and ($m.PSObject.Properties.Name -contains $script:REGISTRY_META_KEY) -and $m.$($script:REGISTRY_META_KEY).isLatest
    } | ForEach-Object { "$($_.server.version)" })
    $latest = if ($flagged.Count -gt 0) { $flagged[0] } else { $versions[-1] }
    return @{
      name = $name; latest = $latest; versions = $versions; found = $true
      status = if ($active.Count -gt 0) { 'active' } else { 'deprecated' }
    }
  }
  return @{ name = $candidates[0]; latest = $null; versions = @(); found = $false; status = 'missing' }
}
