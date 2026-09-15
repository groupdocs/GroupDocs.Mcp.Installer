# Sample configurations

Ready-to-run configs for common setups. Use any of them directly:

```powershell
# preview what it would do:
./install-groupdocs-mcp.ps1 -Config samples/<name>.config.json -DryRun
# apply + warm caches + verify:
./install-groupdocs-mcp.ps1 -Config samples/<name>.config.json -Verify
```

Copy one next to the scripts as `groupdocs-mcp.config.json` to make it your default,
then adjust `storagePath` / `outputPath` / `licensePath` to your folders.
Windows paths work with forward or backslashes (`D:/Storage/Documents`).

| Sample | Client(s) | Products | Channel | Shows |
|---|---|---|---|---|
| `claude-desktop.all-products.docker` | Claude Desktop | all 12 (individual) | docker | The "give me everything" setup |
| `claude-code.parser.docker` | Claude Code (CLI) | Parser | docker | Docker-only product + full path setup: separate output folder and a license file (all three `GROUPDOCS_*` settings mapped into the container) |
| `vscode.metadata-conversion-comparison.nuget` | VS Code / Copilot (user-level) | Metadata, Conversion, Comparison | nuget | Lightweight `dnx` trio for .NET devs — no Docker needed |
| `cursor.conversion.docker` | Cursor | Conversion | docker | Single-product minimal setup |
| `codex.metadata.nuget` | Codex CLI | Metadata | nuget | CLI-registered client (`codex mcp add`) |
| `windsurf-cline.total.docker` | Windsurf + Cline | Total bundle | docker | One server exposing every Total tool, two clients at once |
| `compose-only.all-products.docker` | *(none)* | all 12 | docker | No client registration — pair with `-EmitCompose` to run the fleet via `docker compose` |
| `team-workspace.vs2022-vscode.nuget` | VS Code workspace + VS 2022 | Metadata, Conversion | nuget | Committable, per-repo config: run from your solution root; writes `./.vscode/mcp.json` + `./.mcp.json` |
| `claude.metered.pinned.docker` | Claude Desktop + Claude Code | Conversion, Comparison, Signature | docker | **Metered licensing** + a **pinned version**: keys forwarded from your environment by name (never written), pin checked against the MCP Registry before install |

Notes:

- Every sample sets `"platform": "net"` — .NET, the only platform available today and the
  default when the key is absent.
- **Parser and Total are docker-only** (the packed tool exceeds NuGet.org's 250 MB
  limit) — the installer refuses them on the nuget channel with an explanation.
- `licensePath: ""` runs in **evaluation mode** (safe); point it at your
  `.lic` file to lift the limits. Any GroupDocs license file name works
  (e.g. `GroupDocs.Total.lic`, `Conholdate.Total.lic`).
- `"metered": true` needs `GROUPDOCS_METERED_PUBLIC_KEY` and `GROUPDOCS_METERED_PRIVATE_KEY`
  set where the AI client starts; the installer reports whether each is set, never its value.
- A pinned `version` is checked per product: a product never published at that version is
  skipped with the reason (products do not all share one version).
- Claude Code and Codex are registered through their own CLIs — those must be on
  `PATH` in the shell running the installer, or the client is skipped with a warning
  (the equivalent one-liner is printed by `-DryRun`).
- After any install, `./verify-groupdocs-mcp.ps1` re-checks every configured product;
  drop a document into your storage folder to get the deeper `get_document_info` check.
