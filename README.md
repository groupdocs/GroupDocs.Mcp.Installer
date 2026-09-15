# GroupDocs MCP — one-command installer

Set up any subset of the GroupDocs MCP servers on a developer machine from a
single config file — or a guided wizard. Registers them into your AI client(s)
and/or emits a `docker-compose.yml`. Cross-platform (PowerShell 5.1 and 7+).

```powershell
./install-groupdocs-mcp.ps1 -Interactive     # first run: wizard asks everything (incl. post-install verification), saves the config
./verify-groupdocs-mcp.ps1                   # any time later: re-verify every installed product
```

Fresh machine? [`setup/`](setup/) has one-shot prerequisite bootstrappers per OS
(macOS / Linux / Windows — PowerShell, Docker or the .NET 10 SDK, native deps).
Ready-made configurations for common setups live in [`samples/`](samples/).

## Files

| File | Purpose |
|---|---|
| `manifest.json` | Source-of-truth catalog, **per platform**: which platforms exist, their channels and naming patterns (image, package, MCP Registry name), and which products each one ships. Adding a product or a platform is a manifest entry, not code. |
| `groupdocs-mcp.config.json` | **Your settings** — platform, products, channel, clients, shared paths, license / metered, verify cases. Written by the wizard or edited by hand. |
| `install-groupdocs-mcp.ps1` | Installer / uninstaller / wizard. Reads the two files above, writes client configs / compose. |
| `verify-groupdocs-mcp.ps1` | Post-install smoke tests. Reads the **same** config; runs the MCP handshake, license check, and a document call per server. |
| `uninstall-groupdocs-mcp.ps1` | Configurable removal (defaults: every server, every client, every platform). |
| `lib/platform.ps1` | Shared platform / naming / MCP Registry / metered helpers, dot-sourced by the three scripts. |

## Platforms

A **platform** is the runtime hosting the servers. Choose it with `"platform"` in the
config, `-Platform` on the command line, or the wizard's first question.

| Platform | Key | Status | Channels |
|---|---|---|---|
| .NET | `net` | **available — the default** | `docker`, `nuget` |
| Java | `java` | planned | — |
| Python | `python` | planned | — |
| Node.js | `node` | planned | — |

Planned platforms are listed so the choice is visible, and refused until they ship: their
image, package, and registry names are permanent once published and are deliberately not
guessed at. A config written before platforms existed (no `"platform"` key) means `net`,
exactly as before.

## Shared settings (one place for all products)

`storagePath`, `outputPath`, and `licensePath` in `groupdocs-mcp.config.json`
apply to **every** product — set them once. The installer maps them per channel:
Docker mounts `storagePath → /data`, the license dir → `/license:ro`; NuGet
passes them as `GROUPDOCS_MCP_*` env vars. Missing storage/output folders are
created (only after every validation has passed, so a refused install leaves
nothing behind); a missing license file produces a warning (servers fall back to
evaluation mode — an empty `licensePath` is always safe). The verify script
reuses the same values, so a working install verifies with no extra setup.

## Licensing: license file or metered

| Mode | Configure | How it reaches the server |
|---|---|---|
| Evaluation | nothing | — (output may carry evaluation limits) |
| License file | `"licensePath": "C:/lic/GroupDocs.Total.lic"` | docker: mounted read-only at `/license`; nuget: `GROUPDOCS_LICENSE_PATH` |
| **Metered** (pay-per-use) | `"metered": true` (or `-Metered`) **and** `GROUPDOCS_METERED_PUBLIC_KEY` + `GROUPDOCS_METERED_PRIVATE_KEY` in your environment | docker: forwarded by **name** (`-e GROUPDOCS_METERED_PUBLIC_KEY`); nuget: inherited from the AI client |

**The installer never stores metered keys.** The config file records only `true`/`false`;
the wizard does not ask for the keys (typing a private key into a prompt leaves it in
terminal scrollback); client configs and `docker-compose.yml` reference the variables by name
and never contain a value. The installer reports whether each key is `set (N chars)` or
`not set` — never any characters of it.

- Set the variables where your AI client starts: user/system environment on Windows and
  Linux. **macOS apps launched from Finder do not inherit shell exports** — use
  `launchctl setenv`, or start the client from a terminal.
- If both metered keys and a `licensePath` are configured, servers use **metered** and
  ignore the file; the installer warns.
- Metered mode reports usage to GroupDocs servers, so it needs outbound connectivity.
- Verification under metered licensing makes real document calls, and those consume a small
  amount of credit.

## Quick start

```powershell
# 1. Wizard (or edit groupdocs-mcp.config.json by hand):
./install-groupdocs-mcp.ps1 -Interactive
# 2. Preview without touching anything:
./install-groupdocs-mcp.ps1 -DryRun
# 3. Apply, warm caches, and verify the setup in one go:
./install-groupdocs-mcp.ps1 -Verify
# 4. Restart your AI client.
```

## Config file

```jsonc
{
  "platform":    "net",             // net (default) | java, python, node - planned
  "channel":     "docker",          // per platform - net: docker | nuget
  "registry":    "ghcr",            // ghcr | dockerhub  (docker channel only)
  "clients":     ["claude-desktop", "vscode"],
  "version":     "latest",          // "latest" or a pin e.g. "26.9.0" - checked against the MCP Registry
  "storagePath": "C:/docs",         // shared documents folder (created if missing)
  "outputPath":  "",                // optional separate output folder
  "licensePath": "",                // optional path to a .lic file ("" = evaluation mode)
  "metered":     false,             // true = forward GROUPDOCS_METERED_* keys from the environment
  "products":    ["metadata", "conversion", "comparison"]
}
```

- `products` is **always an explicit list**. Use `"all"` to expand to every
  individual product on the chosen platform (Total is excluded — it is the bundle
  equivalent). List `"total"` alone to get the all-in-one server.
- Any CLI switch overrides the config file:
  `-Platform`, `-Channel`, `-Registry`, `-Products`, `-Clients`, `-Version`, `-Metered`.

## Versions and the MCP Registry

Before writing anything, the installer makes **one** request to the
[MCP Registry](https://registry.modelcontextprotocol.io/v0/servers?search=groupdocs) for every
GroupDocs entry, and uses it two ways:

- **`"version": "latest"`** — prints the version each product currently resolves to, e.g.
  `metadata (26.9.0), total (26.7.3)`.
- **A pinned version** — products are not guaranteed to share one. A product never published
  at the pin is **skipped with the reason** (`'total' was never published at 26.9.0 (latest
  26.7.3)`) instead of writing an entry that fails at first launch inside the AI client. If
  nothing is left, the install stops.

The Registry is the one index that covers every product, including the Docker-only ones that
have no NuGet package. Registry names come from `manifest.json` and may list several
candidates: .NET entries are moving to `…-mcp-net` (and later platforms to `…-mcp-java`, …), and
until the new name exists the current one still answers — no installer release needed for
the rename.

Offline or behind a proxy? An unreachable Registry is a warning, not a stop. `-SkipRegistryCheck`
skips the lookup entirely.

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

## Channels (.NET platform)

Channels are defined per platform in `manifest.json`. For `net`:

| | `docker` | `nuget` |
|---|---|---|
| Prereqs | Docker only | .NET 10 SDK (+ `libgdiplus`/`libfontconfig1` on Linux/macOS) |
| Native deps | bundled in image | you install them |
| Total / Parser | ✅ supported | ⛔ NuGet-blocked (>250 MB) — auto-skipped |
| Entry written | `docker run … <image>` | `dnx <pkg> --yes` + env |
| Metered keys | `-e NAME` pass-through | inherited from the client |

Docker is the recommended default (self-contained, verified green across the
publish matrix). NuGet is convenient for .NET devs and per-product subsets.

## Switches

| Switch | Effect |
|---|---|
| `-Interactive` | Guided wizard; saves answers to the config file. Also auto-runs when no config exists. |
| `-Platform <key>` | Runtime platform (`net` by default). Planned platforms are refused with the list of available ones. |
| `-Metered` | Use metered licensing: forward `GROUPDOCS_METERED_PUBLIC_KEY` / `_PRIVATE_KEY` from the environment. Keys are never written anywhere. |
| `-SkipRegistryCheck` | Skip the MCP Registry lookup (air-gapped machines). Pinned versions are then not checked. |
| `-SkipPreflight` | Skip the prerequisite preflight. By default the installer verifies the channel's runtime (docker daemon reachable / .NET 10 SDK + `dnx` present) **before touching anything**; on failure it prints the exact `setup/<os>` command (and the wizard offers to run it). Dry-runs warn and continue. |
| `-Verify` | After installing: warm caches, then run the verifier against the same products/channel (auto level). Exit code = verification result. The wizard offers this as its last question. |
| `-DryRun` | Print everything, write nothing. Always preview first. |
| `-Prewarm` | docker: `docker pull` each image. nuget: download **and first-launch** each package with stdin closed (server reads EOF and exits cleanly) — prevents the cold-cache failure where a client's first in-pipe launch of a large package dies before the download finishes. |
| `-EmitCompose` | Also write a `docker-compose.yml` in the current dir (docker channel). |
| `-Config <path>` | Use a different config file. |

## Uninstall / remove

`uninstall-groupdocs-mcp.ps1` is the configurable removal tool. Its defaults
are deliberately the "clean this machine" case: **every known GroupDocs server,
from every known client** — regardless of what the config file says, so it also
catches entries left behind after the config changed.

```powershell
./uninstall-groupdocs-mcp.ps1 -DryRun                     # preview a full sweep
./uninstall-groupdocs-mcp.ps1                             # remove ALL GroupDocs servers from ALL clients
./uninstall-groupdocs-mcp.ps1 -Products metadata,conversion   # only these products
./uninstall-groupdocs-mcp.ps1 -Clients claude-desktop,cursor  # only these clients
./uninstall-groupdocs-mcp.ps1 -RemoveImages               # also docker rmi the images
./uninstall-groupdocs-mcp.ps1 -PurgeNugetCache            # also delete the cached NuGet packages (dnx re-downloads)
./uninstall-groupdocs-mcp.ps1 -RemoveCompose              # also delete ./docker-compose.yml
```

- `-Products` / `-Clients` accept `all` (the default) or comma-separated subsets.
- `-Platform` defaults to `all` available platforms, so servers registered for any platform are found.
- Non-GroupDocs servers in the same config files are left untouched, and every
  modified file gets a timestamped `.bak` backup first.
- CLI clients are cleared via `claude mcp remove` / `codex mcp remove` (skipped
  with a warning if the CLI is not on PATH).
- `-RemoveImages` honours `-Registry` / `-Version` for the tag to delete.

`./install-groupdocs-mcp.ps1 -Uninstall` still works — it forwards to the same
script, scoped to the clients listed in your config file.

## Verify installed products

```powershell
./install-groupdocs-mcp.ps1 -Verify              # install + prewarm + verify in one command
./verify-groupdocs-mcp.ps1                       # auto level (default) - zero config needed
./verify-groupdocs-mcp.ps1 -Level handshake      # minimum: server starts + lists tools
./verify-groupdocs-mcp.ps1 -Level toolcall       # strict: only explicit verify.cases
```

| Level | What it proves | Needs setup? |
|---|---|---|
| `auto` (default) | Handshake, the **license check** (below) **plus**, when possible, a real document check: after `tools/list` the verifier picks the server's info tool (`get_document_info`, or `get_view_info` for Viewer) and calls it against **the first document found in `storagePath`** (or `verify.sampleFile` when set). No document / no info tool → degrades gracefully, still passing. | No — drop any supported document (e.g. `.pdf`, `.docx`) into your storage folder for the deeper check |
| `handshake` | Server **starts** (image pulls/runs or `dnx` resolves) and returns its tool list via `initialize` → `tools/list`. Universal across all products + both channels. | No |
| `toolcall` | Handshake, the license check, **plus** exactly the `tools/call` defined per product in `verify.cases` against `verify.sampleFile`. Products without a case report `no-case`. | Yes |

**License check** (`auto` and `toolcall`). Servers on GroupDocs.Mcp.Core 26.9.0+ expose
`get_license_status`. The verifier calls it on every such server — it needs no document and
changes nothing — and the summary gains `version` (what `latest` actually resolved to) and
`license` (`evaluation` / `licensed` / `metered`) columns. When metered is expected
(`"metered": true` or `-Metered`), a server that did **not** engage metered **fails**, with the
server's own reason:

```
[FAIL] license: expected metered, server is running 'evaluation' - Metered keys were supplied
       but the engine rejected them (InvalidOperationException: Authentication failed.)
```

Servers older than 26.9.0 lack the tool; they report `n/a` and are not failed for it.

Use a document format the product supports: an unsupported one (for example `.txt` with
Metadata) fails the document check with the engine's error, as it should.

Explicit `verify.cases` entries always win over the auto pick — use them to
exercise a specific tool or argument shape:

```jsonc
"verify": {
  "level": "auto",                   // auto | handshake | toolcall
  "sampleFile": "sample.docx",       // optional - otherwise first document in storagePath
  "cases": {                         // optional per-product overrides
    "metadata":   { "tool": "get_document_info", "args": { "file": { "filePath": "sample.docx" } } },
    "conversion": { "tool": "get_document_info", "args": { "file": { "filePath": "sample.docx" } } }
  }
}
```

Exit code is `0` when all products pass, `1` on any handshake, toolcall, or license failure,
`2` when nothing could be verified — so it drops straight into CI. Tool args use Mcp.Core's
`FileInput` shape: `{ "file": { "filePath": "<name>" } }`.

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
- **MCP Registry** (`io.github.groupdocs-*/…`) — the version index the installer checks
  pins against and reports `latest` from. It is not the install source: entries are still
  built from `manifest.json`, so a Registry outage never blocks an install.
