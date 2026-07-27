# GroupDocs MCP Installer

Set up any GroupDocs MCP server (Metadata, Conversion, Parser, Signature, Total, … 12 products) in your local AI tool — Claude Desktop, Claude Code, VS Code / Copilot, Visual Studio 2022, Cursor, Windsurf, Cline, Codex CLI — from one config file, a wizard, or a single command line. Then verify it actually works with a real MCP call.

Repo: **https://github.com/groupdocs/GroupDocs.Mcp.Installer**

---

## 0. Prerequisites

One-shot bootstrap per OS (installs PowerShell + Docker or the .NET 10 SDK, only what your channel needs; `--check` = report only):

| OS | Command |
|---|---|
| Windows | `powershell -ExecutionPolicy Bypass -File setup\windows.ps1 -Channel docker` |
| macOS | `bash setup/macos.sh --channel docker` |
| Linux (Debian/Ubuntu) | `bash setup/linux.sh --channel docker` |

You can also skip this: the installer preflights the runtime itself and prints the exact setup command if something is missing.

## 1. Clone

```bash
git clone https://github.com/groupdocs/GroupDocs.Mcp.Installer.git
cd GroupDocs.Mcp.Installer
```

On macOS/Linux run the scripts with `pwsh`; on Windows any PowerShell (5.1 or 7+) works.

## 2. Install — pick your style

**Fully interactive** — wizard asks products, channel, clients, folders, license, then verifies:

```powershell
./install-groupdocs-mcp.ps1 -Interactive
```

**From a sample config** (see [`samples/`](https://github.com/groupdocs/GroupDocs.Mcp.Installer/tree/main/samples) — 8 ready-made setups):

```powershell
./install-groupdocs-mcp.ps1 -Config samples/vscode.metadata-conversion-comparison.nuget.config.json -Verify
```

**Fully from the command line:**

```powershell
./install-groupdocs-mcp.ps1 -Channel nuget -Products metadata,conversion -Clients vscode -Verify
```

**Preview first** (prints everything, changes nothing):

```powershell
./install-groupdocs-mcp.ps1 -DryRun
```

Useful switches: `-Verify` (prewarm caches + run verification after install), `-Prewarm` (docker pull / dnx first-launch so the first agent call is instant), `-EmitCompose` (write `docker-compose.yml`), `-Version 26.7.2` (pin), `-SkipPreflight`.

## 3. Config file

`groupdocs-mcp.config.json` — set shared paths **once**, they apply to every product:

```json
{
  "channel":     "docker",
  "registry":    "ghcr",
  "clients":     ["claude-desktop", "vscode"],
  "version":     "latest",
  "storagePath": "D:/Storage/Documents",
  "outputPath":  "D:/Storage/Output",
  "licensePath": "D:/Storage/Licenses/Conholdate.Total.lic",
  "products":    ["metadata", "conversion", "parser"]
}
```

- `products`: list, or `"all"` (every product; `"total"` alone = the all-in-one bundle, 38 tools).
- `licensePath: ""` = evaluation mode (safe; watermarks/limits apply).
- Any CLI switch overrides the file.

### Channels

| | `docker` (recommended) | `nuget` |
|---|---|---|
| Needs | Docker only | .NET 10 SDK (+ libgdiplus on macOS/Linux) |
| Native deps | in the image (amd64 + arm64) | yours to install (`setup/` does it) |
| Parser / Total | ✅ | ⛔ >250 MB — auto-refused with explanation |

### Clients

`claude-desktop`, `claude-code`*, `vscode` (user-level), `vscode-workspace`, `vs2022`, `cursor`, `windsurf`, `cline`, `codex`*

\* registered via the client's own CLI; if it's not on PATH the exact `claude mcp add …` / `codex mcp add …` command is printed for you to paste elsewhere.

Existing MCP servers in your configs are **never touched**; every modified file gets a timestamped `.bak` first.

## 4. Verify

```powershell
./verify-groupdocs-mcp.ps1                    # auto (default): MCP handshake + get_document_info
                                              # on the first document found in storagePath
./verify-groupdocs-mcp.ps1 -Level handshake   # minimum: server starts + lists tools
./verify-groupdocs-mcp.ps1 -Level toolcall    # strict: explicit verify.cases from config
```

Drop any document into your storage folder to get the deeper engine check. Engine failures returned as text ("… failed for '…'") are detected and reported with the engine's message. Exit codes: `0` all pass · `1` failures · `2` nothing verified — CI-ready.

## 5. Remove

```powershell
./uninstall-groupdocs-mcp.ps1 -DryRun                        # preview
./uninstall-groupdocs-mcp.ps1                                # ALL GroupDocs servers from ALL clients
./uninstall-groupdocs-mcp.ps1 -Products metadata,conversion  # subset of products
./uninstall-groupdocs-mcp.ps1 -Clients claude-desktop,cursor # subset of clients
./uninstall-groupdocs-mcp.ps1 -RemoveImages -PurgeNugetCache # deeper cleanup
```

Defaults sweep everything — including entries left behind after config changes.

## 6. Use it in your IDE

Restart the AI client after install, then just ask:

- *convert a.pdf to docx*
- *remove all metadata from sample.docx*
- *extract all tables from b.pdf*
- *add watermark to sample.pdf*
- *compare v1.docx and v2.docx and summarize the changes*
- *what signatures does contract.pdf contain?*

Files are resolved from your `storagePath`; results land in `outputPath`.

### Bigger workflow: verifying your own SDK examples (.NET / Java / Node.js / Python)

1. Point your examples' output folder at the MCP `storagePath` (or vice versa).
2. Ask the AI to run all your examples, then **verify each produced document against the code snippet** — content, tables, metadata — using the `groupdocs-parser` MCP tools (`extract_text`, `extract_tables`, `extract_metadata`, `get_document_info`).

The agent becomes your document-output test harness.

## 7. Troubleshooting

| Symptom | Fix |
|---|---|
| "docker daemon not reachable" | Start Docker Desktop / `dockerd`; the preflight catches this before anything is written |
| `claude` / `codex` skipped | Their CLI isn't on PATH in that shell — copy the printed one-liner into a shell where it is |
| First tool call is slow / fails once | Cold cache — run `./install-groupdocs-mcp.ps1 -Prewarm` (downloads and first-launches each package/image) |
| Want your old client config back | Restore the `.bak` written next to it |

---

*Try it on your product's documents and share feedback — problems, insights, ideas. That's what improves these tools.*
