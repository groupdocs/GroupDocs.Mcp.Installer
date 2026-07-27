# GroupDocs MCP — one-command installer

Set up any subset of the GroupDocs MCP servers on a developer machine from a
single config file — or a guided wizard. Registers them into your AI client(s)
and/or emits a `docker-compose.yml`. Cross-platform (PowerShell 5.1 and 7+).

```powershell
./install-groupdocs-mcp.ps1 -Interactive     # first run: wizard asks everything, saves the config
./verify-groupdocs-mcp.ps1                   # then: MCP handshake smoke test per product
```

## Files

| File | Purpose |
|---|---|
| `manifest.json` | Source-of-truth catalog: product → NuGet id, Docker image, server name. Update when products are added. |
| `groupdocs-mcp.config.json` | **Your settings** — products, channel, clients, shared paths, license, verify cases. Written by the wizard or edited by hand. |
| `install-groupdocs-mcp.ps1` | Installer / uninstaller / wizard. Reads the two files above, writes client configs / compose. |
| `verify-groupdocs-mcp.ps1` | Post-install smoke tests. Reads the **same** config; runs the MCP handshake per server. |

## Shared settings (one place for all products)

`storagePath`, `outputPath`, and `licensePath` in `groupdocs-mcp.config.json`
apply to **every** product — set them once. The installer maps them per channel:
Docker mounts `storagePath → /data`, the license dir → `/license:ro`; NuGet
passes them as `GROUPDOCS_MCP_*` env vars. Missing storage/output folders are
created; a missing license file produces a warning (servers fall back to
evaluation mode — an empty `licensePath` is always safe). The verify script
reuses the same values, so a working install verifies with no extra setup.

## Quick start

```powershell
# 1. Wizard (or edit groupdocs-mcp.config.json by hand):
./install-groupdocs-mcp.ps1 -Interactive
# 2. Preview without touching anything:
./install-groupdocs-mcp.ps1 -DryRun
# 3. Apply (+ warm caches so the first agent call is instant):
./install-groupdocs-mcp.ps1 -Prewarm
# 4. Restart your AI client, then smoke-test:
./verify-groupdocs-mcp.ps1
```

## Config file

```jsonc
{
  "channel":     "docker",          // docker | nuget
  "registry":    "ghcr",            // ghcr | dockerhub  (docker channel only)
  "clients":     ["claude-desktop", "vscode"],
  "version":     "latest",          // "latest" or a pin e.g. "26.7.2"
  "storagePath": "C:/docs",         // shared documents folder (created if missing)
  "outputPath":  "",                // optional separate output folder
  "licensePath": "",                // optional path to a .lic file ("" = evaluation mode)
  "products":    ["metadata", "conversion", "comparison"]
}
```

- `products` is **always an explicit list**. Use `"all"` to expand to every
  individual product (Total is excluded — it is the bundle equivalent). List
  `"total"` alone to get the all-in-one server.
- Any CLI switch overrides the config file:
  `-Channel`, `-Registry`, `-Products`, `-Clients`, `-Version`.

## Clients

| Client id | How it's registered | Where |
|---|---|---|
| `claude-desktop` | file merge | `%APPDATA%\Claude\claude_desktop_config.json` (Win) / `~/Library/Application Support/Claude/…` (mac) / `~/.config/Claude/…` (Linux) — root `mcpServers` |
| `claude-code` | **`claude` CLI** (`claude mcp add --scope user`) | Claude Code user scope |
| `vscode` | file merge | VS Code **user-level** `mcp.json` (`%APPDATA%\Code\User\mcp.json` etc.) — root `servers`; applies to every workspace |
| `vscode-workspace` | file merge | `./.vscode/mcp.json` (current directory) — root `servers` |
| `vs2022` | file merge | `./.mcp.json` in the current directory (put it in your **solution root**) — root `servers` |
| `cursor` | file merge | `~/.cursor/mcp.json` — root `mcpServers` |
| `windsurf` | file merge | `~/.codeium/windsurf/mcp_config.json` — root `mcpServers` |
| `cline` | file merge | VS Code globalStorage `…/saoudrizwan.claude-dev/settings/cline_mcp_settings.json` — root `mcpServers` |
| `codex` | **`codex` CLI** (`codex mcp add`) | Codex CLI config |

CLI-registered clients (`claude-code`, `codex`) need their CLI on `PATH`; if it
is missing, that client is skipped with a warning and the rest proceed.
JetBrains Rider has no stable config-file/CLI surface — register there manually
(Settings → Tools → AI Assistant → MCP) using any generated entry as reference.

File merges preserve other servers in the file and create a timestamped
`.bak` backup before every write. All JSON is written UTF-8 **without BOM**.

## Channels

| | `docker` | `nuget` |
|---|---|---|
| Prereqs | Docker only | .NET 10 SDK (+ `libgdiplus`/`libfontconfig1` on Linux/macOS) |
| Native deps | bundled in image | you install them |
| Total / Parser | ✅ supported | ⛔ NuGet-blocked (>250 MB) — auto-skipped |
| Entry written | `docker run … <image>` | `dnx <pkg> --yes` + env |

Docker is the recommended default (self-contained, verified green across the
publish matrix). NuGet is convenient for .NET devs and per-product subsets.

## Switches

| Switch | Effect |
|---|---|
| `-Interactive` | Guided wizard; saves answers to the config file. Also auto-runs when no config exists. |
| `-DryRun` | Print everything, write nothing. Always preview first. |
| `-Prewarm` | docker: `docker pull` each image. nuget: download **and first-launch** each package with stdin closed (server reads EOF and exits cleanly) — prevents the cold-cache failure where a client's first in-pipe launch of a large package dies before the download finishes. |
| `-EmitCompose` | Also write a `docker-compose.yml` in the current dir (docker channel). |
| `-Config <path>` | Use a different config file. |

## Uninstall / clear everything

```powershell
./install-groupdocs-mcp.ps1 -Uninstall -DryRun            # preview
./install-groupdocs-mcp.ps1 -Uninstall                    # remove every GroupDocs server from the configured clients
./install-groupdocs-mcp.ps1 -Uninstall -RemoveCompose     # also delete ./docker-compose.yml
./install-groupdocs-mcp.ps1 -Uninstall -RemoveImages      # also docker rmi the pulled images
```

Uninstall removes **all known GroupDocs servers** (from `manifest.json`) — not
just the currently-configured subset — so it fully clears prior installs.
Non-GroupDocs servers in the same config file are left untouched, and the file
is backed up before every change. CLI clients are cleared via
`claude mcp remove` / `codex mcp remove`.

## Verify installed products

```powershell
./install-groupdocs-mcp.ps1 -Prewarm             # warm caches first (recommended)
./verify-groupdocs-mcp.ps1                       # handshake level (default)
./verify-groupdocs-mcp.ps1 -Level toolcall       # also invoke one real tool per product
```

| Level | What it proves | Needs a sample file? |
|---|---|---|
| `handshake` (default) | Server **starts** (image pulls/runs or `dnx` resolves) and returns its tool list via `initialize` → `tools/list`. Universal across all products + both channels. | No |
| `toolcall` | Handshake **plus** one real `tools/call` per product from `verify.cases`, against `verify.sampleFile` under `storagePath`. Confirms the engine + license actually process a document. | Yes |

The test prompts are **config-driven** — edit `verify.cases` to adjust:

```jsonc
"verify": {
  "level": "handshake",              // or "toolcall"
  "sampleFile": "sample.docx",       // must live under storagePath
  "cases": {
    "metadata":   { "tool": "get_document_info", "args": { "file": { "filePath": "sample.docx" } } },
    "conversion": { "tool": "get_document_info", "args": { "file": { "filePath": "sample.docx" } } }
  }
}
```

Exit code is `0` when all products pass, `1` otherwise — so it drops straight
into CI. `get_document_info` is the best cross-product smoke tool: it is
lightweight (no output file) and exists on most engines; products without it
fall back to handshake-only.

## docker-compose alternative

For a Docker-only shop, skip client registration and just:

```powershell
./install-groupdocs-mcp.ps1 -EmitCompose -Clients @()   # writes docker-compose.yml
docker compose up
```

## Delivery-channel notes (why this design)

- **NuGet (`dnx`)** — zero pre-install, auto-pulls; needs .NET 10 SDK and native
  graphics libs on Linux/macOS. Total/Parser exceed NuGet's 250 MB cap.
- **Docker (GHCR / Docker Hub)** — self-contained, native deps bundled; the
  "just works" cross-platform path and the primary channel here.
- **GitHub Copilot / VS Code / Cursor / Windsurf / Cline** — *clients*
  (registration targets), not runtimes; they still run dnx or docker underneath.
- **MCP Registry** (`io.github.groupdocs-*/…`) — a discovery/verification index,
  not yet a bulk installer.
