---
id: 001
date: 2026-07-27
type: feature
---

# Initial toolkit: installer, wizard, verifier, uninstaller

## What changed

- **install-groupdocs-mcp.ps1** — config-driven installer for all 12 GroupDocs MCP
  servers. Guided wizard (`-Interactive`, auto-runs when no config exists); 9 client
  targets (Claude Desktop, Claude Code via `claude` CLI, VS Code user-level +
  workspace, Visual Studio 2022, Cursor, Windsurf, Cline, Codex via `codex` CLI);
  docker and nuget channels with shared storage/output/license settings; real cache
  prewarm (docker pull / dnx first-launch with stdin closed); docker-compose emission;
  post-install verification chaining (`-Verify`); NuGet-blocked products (Parser,
  Total — >250 MB) refused on the nuget channel with actionable guidance.
- **verify-groupdocs-mcp.ps1** — verification over a real, properly sequenced MCP
  JSON-RPC stdio session. Default `auto` level: handshake (initialize → tools/list),
  then the server's info tool (`get_document_info` / `get_view_info`) against the
  first document found in the storage folder; graceful degradation when no sample or
  info tool exists. `handshake` and strict `toolcall` levels; CI-friendly exit codes.
- **uninstall-groupdocs-mcp.ps1** — configurable removal; defaults sweep every known
  GroupDocs server from every known client; `-Products`/`-Clients` subsets;
  `-RemoveImages`, `-PurgeNugetCache`, `-RemoveCompose`.
- Safety rails everywhere: `-DryRun`, timestamped `.bak` before each client-config
  write, merge-not-overwrite (other MCP servers preserved), UTF-8 no-BOM output,
  cross-platform PowerShell 5.1 / 7+.

## Why

Installing N products into M clients by hand means N×M config edits and no proof any
of it works. One config (or wizard) drives install, verification against the live
published artifacts, and clean removal.

## Migration / impact

New toolkit — nothing to migrate. Verified end-to-end on Windows against published
packages: nuget channel (Signature 26.7.2, handshake 8 tools + document toolcall) and
docker channel (Parser 6 tools, Total 38 tools, document toolcall through containers).
