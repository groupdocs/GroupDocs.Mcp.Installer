# AGENTS.md — Guide for AI coding agents

Brief orientation for AI coding agents (Claude Code, Copilot, Cursor, Aider, Codex)
working in this repository.

## What this repo is

A **cross-platform PowerShell installer/verifier** for the GroupDocs MCP server family
(12 products). It registers servers into AI clients (Claude Desktop, Claude Code,
VS Code, VS 2022, Cursor, Windsurf, Cline, Codex CLI), verifies them over a real MCP
JSON-RPC stdio session, and removes them cleanly. No build step — plain `.ps1` scripts.

## Files

```
manifest.json                 <- source-of-truth product catalog (nuget id, image slug, server name, nugetBlocked)
groupdocs-mcp.config.json     <- sample user config (products, channel, clients, shared paths, verify overrides)
install-groupdocs-mcp.ps1     <- installer + wizard (-Interactive) + prewarm + post-install verify (-Verify)
verify-groupdocs-mcp.ps1      <- MCP handshake / auto / toolcall verification over stdio
uninstall-groupdocs-mcp.ps1   <- configurable removal (defaults: ALL products from ALL clients)
changelog/                    <- one MD file per change (see changelog/README.md)
samples/                      <- ready-to-run config examples per client/channel (dry-run validated)
setup/                        <- per-OS prerequisite bootstrappers (macos.sh, linux.sh, windows.ps1)
```

## Hard-won rules — read before editing

1. **PowerShell 5.1 AND 7+ must both work.** No ternary (`?:`), no `??`, no `?.`,
   no `-AsHashtable`. Test parse on 5.1 semantics.
2. **Scripts must be pure ASCII.** PS 5.1 reads BOM-less files as ANSI — an em dash
   inside a double-quoted string becomes a stray quote and breaks the parser.
3. **Write client JSON as UTF-8 WITHOUT BOM** (`Write-TextNoBom`), never
   `Set-Content -Encoding UTF8` (PS 5.1 adds a BOM that some client parsers reject).
4. **`dnx` must be launched by FULL PATH** (`(Get-Command dnx.cmd).Source` on Windows):
   the shim's internal `%~dp0dotnet.exe` breaks when started by bare name from
   `Process.Start`.
5. **MCP stdio sessions must be sequenced** (send `initialize`, wait for its id, then
   `notifications/initialized`, then `tools/list`, …). Writing everything and closing
   stdin races the server's EOF shutdown against its handlers — it exits before
   answering. Drain stderr asynchronously (anonymous-pipe deadlock otherwise).
6. **PS 5.1 quirk:** `@{ key = @($listOfPSObjects) }` throws "Argument types do not
   match" when the `List[object]` holds PSCustomObjects — use `.ToArray()`.
7. **`-Clients @()` must stay meaningful** (compose-only flow): parameter override
   uses `$PSBoundParameters.ContainsKey('Clients')`, not truthiness.
8. **Never let a test touch real client configs.** Use the cwd-scoped clients
   (`vs2022`, `vscode-workspace`) inside a scratch directory, or `-DryRun`.
   The file merge is destructive-adjacent even with backups.
9. **Tool args use Mcp.Core's `FileInput` shape:** `{"file":{"filePath":"<name>"}}` —
   not `{"file_path": ...}`.
10. **The client-target map exists in BOTH install and uninstall scripts** — change
    them together (extraction into a shared module is on the backlog).
11. `Quote-Arg` / `Normalize-HostPath` trigger PSUseApprovedVerbs warnings — accepted;
    do not churn names without updating both scripts and CI expectations.

## How to test changes

```powershell
# parse both editions' syntax:
$t=$null;$e=$null; [System.Management.Automation.Language.Parser]::ParseFile('install-groupdocs-mcp.ps1',[ref]$t,[ref]$e); $e

# always preview first:
./install-groupdocs-mcp.ps1 -DryRun
./uninstall-groupdocs-mcp.ps1 -DryRun

# sandboxed real write (cwd-scoped client, scratch dir):
mkdir /tmp/sand; cd /tmp/sand
& <repo>/install-groupdocs-mcp.ps1 -Channel docker -Products metadata -Clients vs2022

# real end-to-end (downloads a package; smallest fast path):
./verify-groupdocs-mcp.ps1 -Products metadata -Channel nuget -TimeoutSec 180
```

## Product facts the code depends on

- Parser and Total are `nugetBlocked` (packed tool > NuGet.org's 250 MB limit) —
  Docker/GHCR only. The installer must refuse them on the nuget channel.
- `get_document_info` exists on most products; Viewer exposes `get_view_info` instead;
  a few products expose neither — `auto` verification degrades to handshake-only.
- Image naming: `ghcr.io/groupdocs-<slug>/<slug>-net-mcp` and `groupdocs/<slug>-net-mcp`.
- A **cold dnx cache** can make a client's first in-pipe launch of a large package fail
  before the download completes — that is why prewarm launches each package once with
  stdin closed (server reads EOF, exits 0).

## What NOT to change

- `manifest.json` keys/shape — the scripts and downstream automation read it.
- The `.bak`-before-write and merge-not-overwrite behavior of client configs.
- Exit-code contract: `0` all verified / installer success, `1` any failure (CI relies on it).
