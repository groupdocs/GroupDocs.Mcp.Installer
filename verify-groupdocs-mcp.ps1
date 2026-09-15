<#
.SYNOPSIS
  Post-install verification for GroupDocs MCP servers. Reads the SAME
  groupdocs-mcp.config.json as the installer and smoke-tests each configured
  product over stdio (docker or dnx).

.DESCRIPTION
  Three levels, set by "verify.level" in the config (or -Level):

    auto       (default) - zero-config verification. Performs the MCP handshake
                 (initialize -> tools/list); then, if the server exposes an
                 info tool (get_document_info, or get_view_info for Viewer) AND
                 a sample document is available, invokes it against that
                 document. The sample is "verify.sampleFile" when set and
                 present - otherwise the FIRST document found in storagePath.
                 No sample / no info tool degrades gracefully to handshake-only.

    handshake  - the universal minimum. Spawns each server, asserts it starts
                 and returns >=1 tool. Needs no sample file.

    toolcall   - handshake, then invokes exactly the case defined per product
                 in "verify.cases" against "verify.sampleFile". Strict: a
                 product without a case is reported as 'no-case'.

  An explicit "verify.cases" entry always wins over the auto pick.

  License check (auto and toolcall levels): servers built on GroupDocs.Mcp.Core
  26.9.0+ expose get_license_status. It is called on every such server - it needs
  no sample and changes nothing - and its mode (evaluation / licensed / metered)
  and the server version are reported. When metered licensing is expected
  ("metered": true, or -Metered) a server that did NOT engage metered fails, with
  the server's own reason (keys rejected, only one key set, ...). Older servers
  without the tool report 'n/a' and are not failed for it.

  TIP: run the installer with -Prewarm first so image pulls don't count against
  the per-server timeout (or just use the installer's -Verify, which prewarms).

.EXAMPLE
  ./verify-groupdocs-mcp.ps1
  ./verify-groupdocs-mcp.ps1 -Level toolcall -TimeoutSec 180
  ./verify-groupdocs-mcp.ps1 -Products metadata -Channel nuget -Metered
#>
[CmdletBinding()]
param(
  [string] $Config   = (Join-Path $PSScriptRoot 'groupdocs-mcp.config.json'),
  [string] $Manifest = (Join-Path $PSScriptRoot 'manifest.json'),
  [ValidateSet('auto','handshake','toolcall')]
  [string] $Level,
  # Platform and channel are validated against manifest.json at runtime.
  [string] $Platform,
  [string] $Channel,
  [ValidateSet('ghcr','dockerhub')]
  [string] $Registry,
  [string] $Version,
  [string[]] $Products,
  [switch] $Metered,
  [int]    $TimeoutSec = 120
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/platform.ps1')
function Write-Info ($m) { Write-Host "  $m" }
function Write-Pass ($m) { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Write-Fail ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Head ($m) { Write-Host "`n== $m ==" -ForegroundColor Cyan }
function Get-Json ($p) { if (-not (Test-Path $p)) { throw "File not found: $p" }; Get-Content -Raw -LiteralPath $p | ConvertFrom-Json }

$mani = Get-Json $Manifest
$cfg  = Get-Json $Config

$platformKey = if ($Platform) { $Platform.ToLower() } elseif ($cfg.PSObject.Properties.Name -contains 'platform' -and $cfg.platform) { "$($cfg.platform)".ToLower() } else { Get-DefaultPlatform $mani }
$platformDef = Resolve-Platform $mani $platformKey
$packageChannel = Get-PackageChannel $platformDef
$defaultChannel = if ($platformDef.defaultChannel) { "$($platformDef.defaultChannel)" } else { "$(@($platformDef.channels)[0])" }
$channel     = if ($Channel)  { $Channel.ToLower() }  elseif ($cfg.channel)  { "$($cfg.channel)".ToLower() }  else { $defaultChannel }
Assert-PlatformChannel $platformKey $platformDef $channel
$expectMetered = if ($PSBoundParameters.ContainsKey('Metered')) { [bool]$Metered } else { ($cfg.PSObject.Properties.Name -contains 'metered') -and [bool]$cfg.metered }
$registry    = if ($Registry) { $Registry.ToLower() } elseif ($cfg.registry) { "$($cfg.registry)".ToLower() } else { 'ghcr' }
$version     = if ($Version)  { $Version }            elseif ($cfg.version)  { "$($cfg.version)" }            else { 'latest' }
$storagePath = if ($cfg.storagePath) { "$($cfg.storagePath)" }        else { (Get-Location).Path }
$outputPath  = if ($cfg.outputPath)  { "$($cfg.outputPath)" }         else { '' }
$licensePath = if ($cfg.licensePath) { "$($cfg.licensePath)" }        else { '' }
$verifyCfg   = $cfg.verify
$level       = if ($Level) { $Level } elseif ($verifyCfg -and $verifyCfg.level) { "$($verifyCfg.level)" } else { 'auto' }

# --- Sample document resolution (auto level) --------------------------------
# Preference: verify.sampleFile when set AND present under storagePath;
# otherwise the first document found in storagePath (common formats).
$DOC_EXTS = @('.docx','.doc','.pdf','.xlsx','.xls','.pptx','.ppt','.rtf','.odt','.txt','.html','.htm','.png','.jpg','.jpeg','.tiff','.eml','.msg','.epub')
function Get-SampleFile {
  if ($verifyCfg -and $verifyCfg.sampleFile) {
    $cand = Join-Path $storagePath "$($verifyCfg.sampleFile)"
    if (Test-Path $cand) { return "$($verifyCfg.sampleFile)" }
  }
  if (Test-Path $storagePath) {
    $f = Get-ChildItem -LiteralPath $storagePath -File -ErrorAction SilentlyContinue |
         Where-Object { $DOC_EXTS -contains $_.Extension.ToLower() } |
         Select-Object -First 1
    if ($f) { return $f.Name }
  }
  return $null
}
$sampleName = Get-SampleFile
if ($level -eq 'auto') {
  if ($sampleName) { Write-Info "sample document: $sampleName (from $storagePath)" }
  else { Write-Info "no sample document found in $storagePath - auto level will do handshake-only" }
}

$allKeys = @($mani.products.PSObject.Properties.Name)
$requested = if ($Products) { $Products } else { @($cfg.products) }
$resolved = New-Object System.Collections.Generic.List[string]
foreach ($p in $requested) {
  $k = "$p".ToLower().Trim()
  if ($k -eq 'all') { foreach ($a in $allKeys) { if ($a -ne 'total' -and (Test-ProductOnPlatform $mani $platformKey $a) -and -not $resolved.Contains($a)) { $resolved.Add($a) } } }
  elseif ($allKeys -contains $k) {
    if (-not (Test-ProductOnPlatform $mani $platformKey $k)) { Write-Info "'$k' is not available on platform '$platformKey' - skipped." }
    elseif (-not $resolved.Contains($k)) { $resolved.Add($k) }
  }
}
if ($channel -eq $packageChannel) {
  foreach ($k in @($resolved)) {
    if (Test-PackageBlocked $mani $platformKey $k) {
      Write-Info "'$k' is not published to $channel ($($platformDef.packageRunner.sizeLimitNote)) - skipped (use -Channel docker)."
      [void]$resolved.Remove($k)
    }
  }
}
# Never report success when nothing was actually verified - an empty run must be
# loud, not a green exit code (a CI job wired to this would pass while testing nothing).
if ($resolved.Count -eq 0) {
  Write-Fail "no products to verify - every requested product was unknown, unavailable on '$platformKey', or blocked on the $channel channel."
  exit 2
}

Write-Head "GroupDocs MCP verify"
Write-Info "platform=$platformKey  channel=$channel  level=$level  timeout=${TimeoutSec}s"
Write-Info "products: $($resolved -join ', ')"
if ($expectMetered) {
  Write-Info "metered licensing expected - $((Get-MeteredVariableNames | ForEach-Object { "$_ $(Get-SecretPresence $_)" }) -join '; ')"
}

# Prerequisite preflight - fail fast (exit 2 = nothing verified) instead of
# reporting a per-product failure for a runtime that simply is not there.
if ($channel -eq 'docker') {
  $dockerOk = $false
  if (Get-Command docker -ErrorAction SilentlyContinue) {
    & docker version --format '{{.Server.Version}}' 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $dockerOk = $true }
  }
  if (-not $dockerOk) {
    Write-Fail "docker daemon not reachable - start Docker Desktop / dockerd (setup/<os> script installs it)."
    exit 2
  }
} else {
  $dnxProbe = Get-PackageRunnerCommand $mani $platformKey ($PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows)
  if (-not (Get-Command $dnxProbe -ErrorAction SilentlyContinue)) {
    Write-Fail "'$dnxProbe' not found - the $channel channel needs the $($platformDef.packageRunner.prerequisite) (setup/<os> script installs it)."
    exit 2
  }
}

# --- Build the launch command for one product ------------------------------
# Mirrors the entry the installer writes, so what passes here is what the AI
# client will run - including forwarding metered keys by name on docker.
function Get-Launch ($key) {
  if ($channel -eq 'docker') {
    $img = Get-ImageRef $mani $platformKey $key $registry $version
    $a = [System.Collections.Generic.List[string]]::new()
    @('run','--rm','-i') | ForEach-Object { $a.Add($_) }
    $a.Add('-v'); $a.Add("$(ConvertTo-DockerHostPath $storagePath)`:/data")
    $a.Add('-e'); $a.Add('GROUPDOCS_MCP_STORAGE_PATH=/data')
    if ($outputPath -ne '') { $a.Add('-v'); $a.Add("$(ConvertTo-DockerHostPath $outputPath)`:/data/output"); $a.Add('-e'); $a.Add('GROUPDOCS_MCP_OUTPUT_PATH=/data/output') }
    if ($licensePath -ne '') { $a.Add('-v'); $a.Add("$(ConvertTo-DockerHostPath (Split-Path -Parent $licensePath))`:/license:ro"); $a.Add('-e'); $a.Add("GROUPDOCS_LICENSE_PATH=/license/$(Split-Path -Leaf $licensePath)") }
    if ($expectMetered) { foreach ($n in Get-MeteredVariableNames) { $a.Add('-e'); $a.Add($n) } }
    $a.Add($img)
    return @{ file = 'docker'; args = @($a) }
  } else {
    # Windows: 'dnx' is a cmd shim - Process.Start needs the FULL PATH to dnx.cmd
    # (bare name breaks the shim's internal %~dp0dotnet.exe resolution).
    $dnxName = Get-PackageRunnerCommand $mani $platformKey ($PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows)
    $found = Get-Command $dnxName -ErrorAction SilentlyContinue
    $dnx = if ($found) { $found.Source } else { $dnxName }
    $e = [ordered]@{ GROUPDOCS_MCP_STORAGE_PATH = $storagePath }
    if ($outputPath  -ne '') { $e.GROUPDOCS_MCP_OUTPUT_PATH = $outputPath }
    if ($licensePath -ne '') { $e.GROUPDOCS_LICENSE_PATH    = $licensePath }
    # Metered keys are inherited from this process's environment, as they are
    # from the AI client's - nothing to add.
    return @{ file = $dnx; args = @(Get-PackageRunnerArgs $mani $platformKey $key $version); env = $e }
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
function Invoke-McpSession ($launch, $requestPairs, $timeoutMs, $OnToolsList) {
  # $requestPairs: array of @{ line = <json>; waitId = <int or $null> }
  # $OnToolsList (optional): scriptblock invoked with the tools/list response
  # (waitId 2) that may RETURN additional pairs to send in the same session -
  # this lets 'auto' level decide the tool call after seeing the tool list.
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

  $queue = New-Object System.Collections.Generic.List[object]
  foreach ($p in $requestPairs) { $queue.Add($p) }
  $qi = 0
  while ($qi -lt $queue.Count) {
    $pair = $queue[$qi]; $qi++
    $proc.StandardInput.Write($pair.line + "`n")   # \n framing (WriteLine would send \r\n)
    $proc.StandardInput.Flush()
    if ($null -eq $pair.waitId) { continue }        # notification - nothing to wait for
    $got = $null
    while ($null -eq $got) {
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
      if ($o.PSObject.Properties.Name -contains 'id' -and $o.id -eq $pair.waitId) { $got = $o }
    }
    if ($timedOut) { break }
    if ($got -and $pair.waitId -eq 2 -and $OnToolsList) {
      $extra = & $OnToolsList $got
      if ($extra) { foreach ($e in @($extra)) { $queue.Add($e) } }
    }
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

$LICENSE_TOOL = 'get_license_status'

$results = @()
foreach ($k in $resolved) {
  $server = Get-ProductName $mani $platformKey $k 'server'
  Write-Head "verify: $server ($k)"
  $launch = Get-Launch $k
  Write-Info "$($launch.file) $((($launch.args) -join ' '))"

  $pairs = @(
    @{ line = $INIT;   waitId = 1 },
    @{ line = $INITED; waitId = $null },
    @{ line = $LIST;   waitId = 2 }
  )
  # Explicit case (used by 'toolcall' always; wins over the auto pick on 'auto').
  $caseTool = $null
  if ($level -ne 'handshake' -and $verifyCfg -and $verifyCfg.cases -and ($verifyCfg.cases.PSObject.Properties.Name -contains $k)) {
    $case = $verifyCfg.cases.$k
    $caseTool = $case.tool
    $caseArgs = $case.args | ConvertTo-Json -Depth 8 -Compress
    $pairs += @{ line = ('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"' + $caseTool + '","arguments":' + $caseArgs + '}}'); waitId = 3 }
  }

  # After tools/list arrives, decide the follow-up calls from what the server
  # actually exposes:
  #  - get_license_status (id 4) on auto/toolcall levels - sample-free, read-only.
  #  - auto pick (id 3): the server's info tool against the discovered sample
  #    document. get_document_info is near-universal; Viewer exposes
  #    get_view_info instead. Both take Mcp.Core's FileInput shape.
  $script:autoTool = $null
  $script:licenseAsked = $false
  $script:wantAutoPick = ($level -eq 'auto' -and -not $caseTool -and $sampleName)
  $onList = $null
  if ($level -ne 'handshake') {
    $onList = {
      param($listResp)
      $tnames = @($listResp.result.tools | ForEach-Object { $_.name })
      $extra = @()
      if ($script:wantAutoPick) {
        $pick = $null
        if     ($tnames -contains 'get_document_info') { $pick = 'get_document_info' }
        elseif ($tnames -contains 'get_view_info')     { $pick = 'get_view_info' }
        if ($pick) {
          $script:autoTool = $pick
          $fileArg = ('{"file":{"filePath":"' + $script:sampleName + '"}}')
          $extra += @{ line = ('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"' + $pick + '","arguments":' + $fileArg + '}}'); waitId = 3 }
        }
      }
      if ($tnames -contains $script:LICENSE_TOOL) {
        $script:licenseAsked = $true
        $extra += @{ line = ('{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"' + $script:LICENSE_TOOL + '","arguments":{}}}'); waitId = 4 }
      }
      if ($extra.Count -eq 0) { return $null }
      return $extra
    }
  }

  $sess = Invoke-McpSession $launch $pairs ($TimeoutSec * 1000) $onList

  # initialize result - the server's own name/version, i.e. what 'latest' really resolved to
  $initResp = $sess.objects | Where-Object { $_.id -eq 1 } | Select-Object -First 1
  $serverVersion = if ($initResp -and $initResp.result -and $initResp.result.serverInfo) { "$($initResp.result.serverInfo.version)" } else { '?' }

  # tools/list result
  $listResp = $sess.objects | Where-Object { $_.id -eq 2 } | Select-Object -First 1
  if (-not $listResp -or -not $listResp.result -or -not $listResp.result.tools) {
    Write-Fail "handshake: no tools/list response. stderr tail: $((($sess.stderr -split "`n") | Select-Object -Last 3) -join ' | ')"
    $results += [pscustomobject]@{ product = $k; server = $server; version = $serverVersion; handshake = $false; tools = 0; toolcall = 'n/a'; license = 'n/a' }
    continue
  }
  $tools = @($listResp.result.tools)
  $names = ($tools | ForEach-Object { $_.name }) -join ', '
  Write-Pass "handshake: $serverVersion, $($tools.Count) tool(s) -> $names"

  # License mode. The payload is JSON text: { mode, licensed, source, consumption, note, ... }.
  $licStatus = 'n/a'
  if ($level -ne 'handshake') {
    if (-not $script:licenseAsked) {
      if ($expectMetered) { Write-Info "license: server predates $LICENSE_TOOL (Mcp.Core < 26.9.0) - metered cannot be confirmed" }
    } else {
      $licResp = $sess.objects | Where-Object { $_.id -eq 4 } | Select-Object -First 1
      $lic = $null
      if ($licResp -and $licResp.result -and $licResp.result.content) {
        try { $lic = ((@($licResp.result.content) | ForEach-Object { $_.text }) -join '') | ConvertFrom-Json } catch { $lic = $null }
      }
      if (-not $lic) {
        $licStatus = 'fail'
        Write-Fail "license: no readable $LICENSE_TOOL response"
      } else {
        $mode = "$($lic.mode)"
        $noteText = if ($lic.PSObject.Properties.Name -contains 'note' -and $lic.note) { " - $($lic.note)" } else { '' }
        if ($expectMetered -and $mode -ne 'metered') {
          $licStatus = 'fail'
          Write-Fail "license: expected metered, server is running '$mode'$noteText"
        } else {
          $licStatus = $mode
          $usage = ''
          if ($mode -eq 'metered' -and $lic.consumption) {
            $usage = if ($lic.consumption.error) { " (consumption unavailable: $($lic.consumption.error))" } else { " (credit $($lic.consumption.credit))" }
          }
          Write-Pass "license: $mode$usage"
          if ($mode -eq 'evaluation' -and $noteText) { Write-Info "license note$noteText" }
        }
      }
    }
  }

  $tcStatus = 'skipped'
  $ranTool = if ($caseTool) { $caseTool } else { $script:autoTool }
  if ($level -eq 'toolcall' -and -not $caseTool) {
    $tcStatus = 'no-case'; Write-Info "toolcall: no case defined for '$k' in verify.cases - skipped"
  } elseif ($level -eq 'auto' -and -not $ranTool) {
    if (-not $sampleName) { $tcStatus = 'no-sample'; Write-Info "toolcall: no sample document in $storagePath - handshake only" }
    else { $tcStatus = 'no-info-tool'; Write-Info "toolcall: '$k' exposes no get_document_info / get_view_info - handshake only" }
  } elseif ($ranTool) {
    $onFile = if ($caseTool) { '' } else { " on '$sampleName'" }
    $callResp = $sess.objects | Where-Object { $_.id -eq 3 } | Select-Object -First 1
    $callText = ''
    if ($callResp -and $callResp.result -and $callResp.result.content) {
      $callText = (@($callResp.result.content) | ForEach-Object { $_.text }) -join ' '
    }
    $protocolOk = ($callResp -and $callResp.result -and -not $callResp.result.isError -and -not $callResp.error)
    # GroupDocs MCP servers follow an errors-as-text contract: engine failures come
    # back as a NORMAL result whose text starts with "<Operation> failed for '<file>'"
    # (isError stays unset). The protocol check alone would false-PASS a broken
    # engine - inspect the text too. Also catch the evaluation-mode cap message.
    $textLooksFailed = ($callText -match "(?m)^[^\r\n]{0,80} failed for '") -or ($callText -like 'Could not *')
    if ($protocolOk -and -not $textLooksFailed) {
      $tcStatus = 'pass'; Write-Pass "toolcall '$ranTool'$onFile : ok"
    } else {
      $tcStatus = 'fail'
      $err = if ($callResp.error) { $callResp.error.message } elseif ($callText) { $callText } else { 'no response' }
      if ("$err".Length -gt 300) { $err = "$err".Substring(0, 300) + '...' }
      Write-Fail "toolcall '$ranTool'$onFile : $err"
    }
  }
  $results += [pscustomobject]@{ product = $k; server = $server; version = $serverVersion; handshake = $true; tools = $tools.Count; toolcall = $tcStatus; license = $licStatus }
}

Write-Head "Summary"
$results | Format-Table -AutoSize | Out-String | Write-Host
$hsFail  = @($results | Where-Object { -not $_.handshake }).Count
$tcFail  = @($results | Where-Object { $_.toolcall -eq 'fail' }).Count
$licFail = @($results | Where-Object { $_.license -eq 'fail' }).Count
if ($hsFail -eq 0 -and $tcFail -eq 0 -and $licFail -eq 0) { Write-Pass "all $($results.Count) product(s) verified"; exit 0 }
Write-Fail "$hsFail handshake failure(s), $tcFail toolcall failure(s), $licFail license failure(s)"
exit 1
