# AGENTS.md — Guide for AI coding agents

Brief orientation for AI coding agents (Claude Code, Copilot, Cursor, Aider, Codex)
working in this repository.

## What this repo is

A **cross-platform PowerShell installer/verifier** for the GroupDocs MCP server family
(12 products). It registers servers into AI clients (Claude Desktop, Claude Code,
VS Code, VS 2022, Cursor, Windsurf, Cline, Codex CLI), verifies them over a real MCP
JSON-RPC stdio session, and removes them cleanly. No build step — plain `.ps1` scripts.

"Cross-platform" has two meanings here — keep them apart:

- **Client OS** — Windows / macOS / Linux, where the scripts run.
- **MCP platform** — the runtime hosting the servers: `net` (available, default); `java`,
  `python`, `node` (planned). Selected with `-Platform` / `"platform"`.

## Files

```
manifest.json                 <- catalog, schema 2: platforms (channels, naming patterns, package runner) + products
lib/platform.ps1              <- shared pure functions: platform resolution, naming, MCP Registry, metered presence
groupdocs-mcp.config.json     <- default user config (platform, products, channel, clients, shared paths, metered)
install-groupdocs-mcp.ps1     <- installer + wizard (-Interactive) + prewarm + post-install verify (-Verify)
verify-groupdocs-mcp.ps1      <- MCP handshake / license / auto / toolcall verification over stdio
uninstall-groupdocs-mcp.ps1   <- configurable removal (defaults: ALL products, ALL clients, ALL platforms)
changelog/                    <- one MD file per change (see changelog/README.md)
samples/                      <- ready-to-run config examples per client/channel (dry-run validated)
setup/                        <- per-OS prerequisite bootstrappers (macos.sh, linux.sh, windows.ps1)
```

## Hard-won rules — read before editing

1. **PowerShell 5.1 AND 7+ must both work.** No ternary (`?:`), no `??`, no `?.`,
   no `-AsHashtable`. Test parse on 5.1 semantics. And the reverse trap: never name a
   variable or parameter `$IsWindows` / `$IsLinux` / `$IsMacOS` — harmless on 5.1, a
   read-only automatic variable on 7+ that throws on assignment. PSScriptAnalyzer's
   `PSAvoidAssignmentToAutomaticVariable` catches it; testing on 5.1 alone never will.
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
11. `Quote-Arg` triggers a PSUseApprovedVerbs warning — accepted; do not churn the name.
12. **Never hardcode a platform name.** Image names, package ids, the package runner
    (`dnx`), registry names, and the channel list all come from `manifest.json` through
    `lib/platform.ps1`. Grep for `-net-mcp`, `'dnx'`, `nugetBlocked` in the three scripts
    should find nothing. `-Platform` and `-Channel` are validated at runtime against the
    manifest — do not reintroduce `ValidateSet` on them.
13. **Metered keys are never written or printed.** No value in the config file, a client
    config, `docker-compose.yml`, a wizard prompt, or console output. Docker forwards them
    by name (`-e GROUPDOCS_METERED_PUBLIC_KEY`); package-channel servers inherit the
    client's environment. Report presence only via `Get-SecretPresence` (`set (N chars)`).
14. **No filesystem mutation before validation completes.** Platform, channel, product,
    blocked-package and Registry checks all run before storage/output folders are created
    or any client config is written.
15. **CI refusal checks match the message, not just "it threw".** A bare `catch` passes on
    a typo'd script path; every refusal assertion in `ci.yml` checks the expected text.
16. `lib/platform.ps1` holds **pure functions only** (inputs in, value out; no writes, no
    script-scope state). Anything that touches the user's machine stays in the scripts.

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
- **`get_license_status`** ships in GroupDocs.Mcp.Core 26.9.0 on every server: JSON
  `{ mode, licensed, source, consumption, server, engine, note }`, `mode` one of
  `evaluation` / `licensed` / `metered`. Pre-26.9.0 servers lack it — report `n/a`, never fail.
- Metered licensing = `GROUPDOCS_METERED_PUBLIC_KEY` + `GROUPDOCS_METERED_PRIVATE_KEY`;
  metered wins over `GROUPDOCS_LICENSE_PATH` when both are set.
- `.NET` naming: `ghcr.io/groupdocs-<slug>/<slug>-net-mcp`, `groupdocs/<slug>-net-mcp`,
  NuGet `GroupDocs.<Product>.Mcp`. Future platforms: `<slug>-java-mcp`, `-python-mcp`,
  `-node-mcp` (decision D2).
- MCP Registry names: today `io.github.groupdocs-<slug>/groupdocs-<slug>-mcp`; .NET entries
  move to `…-mcp-net` and later platforms get `…-mcp-java` etc. (decision D1). The manifest
  lists both candidates, new name first — do not remove the old one until every product has
  the new entry.
- Products do **not** share a version: Total can trail the family. A single `-Version`
  pin is checked per product against the Registry.
- GroupDocs.Metadata does not support `.txt` — `get_document_info` on it fails with an engine
  error. Use `.pdf` / `.docx` for verification samples (CI generates a minimal PDF).
- A **cold dnx cache** can make a client's first in-pipe launch of a large package fail
  before the download completes — that is why prewarm launches each package once with
  stdin closed (server reads EOF, exits 0).

## Adding a platform

Manifest only, when the platform actually ships: set `platforms.<key>.status` to
`available`, fill `channels`, `defaultChannel`, `naming` (server, ghcr, dockerhub, package,
mcpRegistry), and `packageRunner` (channel, command, windowsCommand, args with `{ref}`, ref
`{package}` / `{version}` templates, prerequisite); add `<key>` to each product's
`platforms`. Then add a dry-run for it to `ci.yml` and a `setup/` prerequisite path.
**Server keys must not collide with `net`'s** (`groupdocs-<slug>`) — pick a suffixed pattern,
or two platforms of one product cannot be registered side by side.

## What NOT to change

- Existing `manifest.json` fields (`products.<key>.nuget / server / nugetBlocked /
  displayName`) — downstream automation reads them. Schema 2 only *added* `platforms`,
  `defaultPlatform`, and per-product `platforms` / `overrides`; CI checks that the net
  naming patterns reproduce the legacy fields exactly.
- Schema-1 manifests (no `platforms`) must keep working — `Get-PlatformCatalog` synthesizes `net`.
- The `.bak`-before-write and merge-not-overwrite behavior of client configs.
- Exit-code contract: `0` all verified / installer success, `1` any failure (CI relies on
  it), `2` verify had nothing to verify.
