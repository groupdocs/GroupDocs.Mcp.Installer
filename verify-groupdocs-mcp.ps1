<#
.SYNOPSIS
  Post-install verification for GroupDocs MCP servers. Reads the SAME
  groupdocs-mcp.config.json as the installer and smoke-tests each configured
  product over stdio (docker or dnx).

.DESCRIPTION
  Two levels, set by "verify.level" in the config (or -Level):

    handshake  (default) - the universal test. Spawns each server, performs the
                 MCP JSON-RPC handshake (initialize -> tools/list) and asserts
                 the server starts and returns >=1 tool. Works for every
                 product and both channels; needs no sample file.

    toolcall   - handshake, then invokes one real tool per product using the
                 case defined in "verify.cases" against "verify.sampleFile"
                 (which must exist under storagePath). Confirms the engine and
                 license path actually process a document.

  TIP: run the installer with -Prewarm first so image pulls don't count against
  the per-server timeout.

.EXAMPLE
  ./verify-groupdocs-mcp.ps1
  ./verify-groupdocs-mcp.ps1 -Level toolcall -TimeoutSec 180
#>
[CmdletBinding()]
param(
  [string] $Config   = (Join-Path $PSScriptRoot 'groupdocs-mcp.config.json'),
  [string] $Manifest = (Join-Path $PSScriptRoot 'manifest.json'),
  [ValidateSet('handshake','toolcall')]
  [string] $Level,
  [ValidateSet('docker','nuget')]
  [string] $Channel,
  [ValidateSet('ghcr','dockerhub')]
  [string] $Registry,
  [string] $Version,
  [string[]] $Products,
  [int]    $TimeoutSec = 120
)

$ErrorActionPreference = 'Stop'
function Write-Info ($m) { Write-Host "  $m" }
function Write-Pass ($m) { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Write-Fail ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Head ($m) { Write-Host "`n== $m ==" -ForegroundColor Cyan }
function Get-Json ($p) { if (-not (Test-Path $p)) { throw "File not found: $p" }; Get-Content -Raw -LiteralPath $p | ConvertFrom-Json }

$mani = Get-Json $Manifest
$cfg  = Get-Json $Config

$channel     = if ($Channel)  { $Channel.ToLower() }  elseif ($cfg.channel)  { "$($cfg.channel)".ToLower() }  else { 'docker' }
$registry    = if ($Registry) { $Registry.ToLower() } elseif ($cfg.registry) { "$($cfg.registry)".ToLower() } else { 'ghcr' }
$version     = if ($Version)  { $Version }            elseif ($cfg.version)  { "$($cfg.version)" }            else { 'latest' }
$storagePath = if ($cfg.storagePath) { "$($cfg.storagePath)" }        else { (Get-Location).Path }
$outputPath  = if ($cfg.outputPath)  { "$($cfg.outputPath)" }         else { '' }
$licensePath = if ($cfg.licensePath) { "$($cfg.licensePath)" }        else { '' }
$verifyCfg   = $cfg.verify
$level       = if ($Level) { $Level } elseif ($verifyCfg -and $verifyCfg.level) { "$($verifyCfg.level)" } else { 'handshake' }

$allKeys = @($mani.products.PSObject.Properties.Name)
$requested = if ($Products) { $Products } else { @($cfg.products) }
$resolved = New-Object System.Collections.Generic.List[string]
foreach ($p in $requested) {
  $k = "$p".ToLower().Trim()
  if ($k -eq 'all') { foreach ($a in $allKeys) { if ($a -ne 'total' -and -not $resolved.Contains($a)) { $resolved.Add($a) } } }
  elseif ($allKeys -contains $k) { if (-not $resolved.Contains($k)) { $resolved.Add($k) } }
}
if ($channel -eq 'nuget') { foreach ($k in @($resolved)) { if ($mani.products.$k.nugetBlocked) { [void]$resolved.Remove($k) } } }

Write-Head "GroupDocs MCP verify"
Write-Info "channel=$channel  level=$level  timeout=${TimeoutSec}s"
Write-Info "products: $($resolved -join ', ')"

# --- Build the launch command for one product ------------------------------
function Get-Launch ($key) {
  $tag = if ($version -eq 'latest') { 'latest' } else { $version }
  if ($channel -eq 'docker') {
    $img = if ($registry -eq 'dockerhub') { "groupdocs/$key-net-mcp:$tag" } else { "ghcr.io/groupdocs-$key/$key-net-mcp:$tag" }
    $a = [System.Collections.Generic.List[string]]::new()
    @('run','--rm','-i') | ForEach-Object { $a.Add($_) }
    $a.Add('-v'); $a.Add("$storagePath`:/data")
    $a.Add('-e'); $a.Add('GROUPDOCS_MCP_STORAGE_PATH=/data')
    if ($outputPath -ne '') { $a.Add('-v'); $a.Add("$outputPath`:/data/output"); $a.Add('-e'); $a.Add('GROUPDOCS_MCP_OUTPUT_PATH=/data/output') }
    if ($licensePath -ne '') { $a.Add('-v'); $a.Add("$(Split-Path -Parent $licensePath)`:/license:ro"); $a.Add('-e'); $a.Add("GROUPDOCS_LICENSE_PATH=/license/$(Split-Path -Leaf $licensePath)") }
    $a.Add($img)
    return @{ file = 'docker'; args = @($a) }
  } else {
    $pkg = $mani.products.$key.nuget
    $ref = if ($version -eq 'latest') { $pkg } else { "$pkg@$version" }
    # Windows: 'dnx' is a cmd shim - Process.Start needs the FULL PATH to dnx.cmd
    # (bare name breaks the shim's internal %~dp0dotnet.exe resolution).
    $dnxName = if ($PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows) { 'dnx.cmd' } else { 'dnx' }
    $found = Get-Command $dnxName -ErrorAction SilentlyContinue
    $dnx = if ($found) { $found.Source } else { $dnxName }
    $e = [ordered]@{ GROUPDOCS_MCP_STORAGE_PATH = $storagePath }
    if ($outputPath  -ne '') { $e.GROUPDOCS_MCP_OUTPUT_PATH = $outputPath }
    if ($licensePath -ne '') { $e.GROUPDOCS_LICENSE_PATH    = $licensePath }
    return @{ file = $dnx; args = @($ref, '--yes'); env = $e }
  }
}

function Quote-Arg ($a) { if ("$a" -match '[\s"]') { '"' + ("$a" -replace '"','\"') + '"' } else { "$a" } }

# --- Run a JSON-RPC session over stdio and return the parsed response objects -
# The session is properly SEQUENCED: send a request, read stdout line-by-line
# until its response id arrives, then send the next. (Writing everything and
# closing stdin up front races the server's shutdown against its handlers -
# the server sees EOF and exits cleanly before answering.) stderr is drained
# asynchronously the whole time to avoid the anonymous-pipe deadlock, and every
# read respects the overall timeout so a hung server can't block forever.
function Invoke-McpSession ($launch, $requestPairs, $timeoutMs) {
  # $requestPairs: array of @{ line = <json>; waitId = <int or $null> }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = $launch.file
  $psi.Arguments = (($launch.args | ForEach-Object { Quote-Arg $_ }) -join ' ')
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute = $false
  if ($launch.env) { foreach ($kv in $launch.env.GetEnumerator()) { $psi.EnvironmentVariables[$kv.Key] = "$($kv.Value)" } }
  $proc = [System.Diagnostics.Process]::Start($psi)
  $errTask = $proc.StandardError.ReadToEndAsync()
  $objs = New-Object System.Collections.Generic.List[object]
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $timedOut = $false

  foreach ($pair in $requestPairs) {
    $proc.StandardInput.Write($pair.line + "`n")   # \n framing (WriteLine would send \r\n)
    $proc.StandardInput.Flush()
    if ($null -eq $pair.waitId) { continue }        # notification - nothing to wait for
    $got = $false
    while (-not $got) {
      $remaining = $timeoutMs - $sw.ElapsedMilliseconds
      if ($remaining -le 0) { $timedOut = $true; break }
      $lineTask = $proc.StandardOutput.ReadLineAsync()
      if (-not $lineTask.Wait([int]$remaining)) { $timedOut = $true; break }
      $l = $lineTask.Result
      if ($null -eq $l) { break }                   # EOF - server exited early
      $t = $l.Trim()
      if (-not $t.StartsWith('{')) { continue }
      try { $o = $t | ConvertFrom-Json } catch { continue }
      $objs.Add($o)
      if ($o.PSObject.Properties.Name -contains 'id' -and $o.id -eq $pair.waitId) { $got = $true }
    }
    if ($timedOut) { break }
  }

  try { $proc.StandardInput.Close() } catch {}      # EOF -> clean shutdown
  if (-not $proc.WaitForExit(10000)) { try { $proc.Kill() } catch {} }
  $stderr = $errTask.Result
  # NOTE: .ToArray(), not @($objs) - on PS 5.1 a List[object] of PSCustomObjects
  # wrapped with @() inside a hashtable literal throws 'Argument types do not match'.
  return @{ objects = $objs.ToArray(); stderr = $stderr; timedOut = $timedOut }
}

$INIT = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"gd-installer-verify","version":"1.0"}}}'
$INITED = '{"jsonrpc":"2.0","method":"notifications/initialized"}'
$LIST = '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

$results = @()
foreach ($k in $resolved) {
  $server = $mani.products.$k.server
  Write-Head "verify: $server ($k)"
  $launch = Get-Launch $k
  Write-Info "$($launch.file) $((($launch.args) -join ' '))"

  $pairs = @(
    @{ line = $INIT;   waitId = 1 },
    @{ line = $INITED; waitId = $null },
    @{ line = $LIST;   waitId = 2 }
  )
  $caseTool = $null
  if ($level -eq 'toolcall' -and $verifyCfg -and $verifyCfg.cases -and ($verifyCfg.cases.PSObject.Properties.Name -contains $k)) {
    $case = $verifyCfg.cases.$k
    $caseTool = $case.tool
    $caseArgs = $case.args | ConvertTo-Json -Depth 8 -Compress
    $pairs += @{ line = ('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"' + $caseTool + '","arguments":' + $caseArgs + '}}'); waitId = 3 }
  }

  $sess = Invoke-McpSession $launch $pairs ($TimeoutSec * 1000)

  # tools/list result
  $listResp = $sess.objects | Where-Object { $_.id -eq 2 } | Select-Object -First 1
  if (-not $listResp -or -not $listResp.result -or -not $listResp.result.tools) {
    Write-Fail "handshake: no tools/list response. stderr tail: $((($sess.stderr -split "`n") | Select-Object -Last 3) -join ' | ')"
    $results += [pscustomobject]@{ product = $k; server = $server; handshake = $false; tools = 0; toolcall = 'n/a' }
    continue
  }
  $tools = @($listResp.result.tools)
  $names = ($tools | ForEach-Object { $_.name }) -join ', '
  Write-Pass "handshake: $($tools.Count) tool(s) -> $names"

  $tcStatus = 'skipped'
  if ($level -eq 'toolcall') {
    if (-not $caseTool) {
      $tcStatus = 'no-case'; Write-Info "toolcall: no case defined for '$k' in verify.cases - skipped"
    } else {
      $callResp = $sess.objects | Where-Object { $_.id -eq 3 } | Select-Object -First 1
      if ($callResp -and $callResp.result -and -not $callResp.result.isError -and -not $callResp.error) {
        $tcStatus = 'pass'; Write-Pass "toolcall '$caseTool': ok"
      } else {
        $tcStatus = 'fail'
        $err = if ($callResp.error) { $callResp.error.message } elseif ($callResp.result) { ($callResp.result.content | ForEach-Object { $_.text }) -join ' ' } else { 'no response' }
        Write-Fail "toolcall '$caseTool': $err"
      }
    }
  }
  $results += [pscustomobject]@{ product = $k; server = $server; handshake = $true; tools = $tools.Count; toolcall = $tcStatus }
}

Write-Head "Summary"
$results | Format-Table -AutoSize | Out-String | Write-Host
$hsFail = @($results | Where-Object { -not $_.handshake }).Count
$tcFail = @($results | Where-Object { $_.toolcall -eq 'fail' }).Count
if ($hsFail -eq 0 -and $tcFail -eq 0) { Write-Pass "all $($results.Count) product(s) verified"; exit 0 }
Write-Fail "$hsFail handshake failure(s), $tcFail toolcall failure(s)"
exit 1
