# Contributing

Thanks for improving the GroupDocs MCP installer.

## Ground rules (hard-won — see AGENTS.md for the full list)

1. **Windows PowerShell 5.1 AND PowerShell 7+ must both work.** No `?:`, `??`, `?.`,
   `-AsHashtable`. CI parses and dry-runs on Windows, Linux, and macOS.
2. **Scripts stay pure ASCII** (PS 5.1 misreads BOM-less Unicode) and client JSON is
   written **UTF-8 without BOM** via `Write-TextNoBom`.
3. **Never let a test touch real client configs.** Use `-DryRun`, or the cwd-scoped
   clients (`vs2022`, `vscode-workspace`) inside a scratch directory.
4. The client-target map lives in **both** `install-` and `uninstall-` scripts —
   change them together.
5. `manifest.json` is the single source of truth for products **and platforms** — a new
   product or a newly shipping platform is a manifest entry, not code. Never hardcode an
   image name, package id, runner command, or channel list in a script.
6. **Metered keys are never written or printed** — not to configs, compose files, prompts,
   or logs. Report presence only (`set (N chars)`).

## Test before you PR

```powershell
./install-groupdocs-mcp.ps1 -DryRun                     # docker channel preview
./install-groupdocs-mcp.ps1 -Channel nuget -DryRun      # nuget channel preview
./uninstall-groupdocs-mcp.ps1 -DryRun                   # removal preview
./install-groupdocs-mcp.ps1 -Platform java -DryRun      # must refuse: planned platform
# real end-to-end against a published package (downloads once, then cached);
# put a .pdf or .docx in the storage folder for the document check:
./verify-groupdocs-mcp.ps1 -Products metadata -Channel nuget -TimeoutSec 180
./verify-groupdocs-mcp.ps1 -Products metadata -Channel nuget -Metered   # with metered keys in your env
```

## Pull request expectations

- One logical change per PR; conventional-commit style title (`fix:`, `feat:`, `docs:`, `ci:`).
- **Changelog entry required** for behaviour changes: `changelog/NNN-<slug>.md`
  (format in `changelog/README.md`).
- Update `README.md` **and** `AGENTS.md` when flags, clients, or file layouts change.
- Keep the exit-code contract: `0` success / all verified, `1` any failure.

## Releases

CalVer tags (`YY.M.N`) on `main`; the tag description lists the changelog entries
included. No build artifacts — the tag is the release.

## Reporting bugs / requesting features

Use the [issue templates](https://github.com/groupdocs/GroupDocs.Mcp.Installer/issues/new/choose).
Security reports: see [SECURITY.md](SECURITY.md) — never as public issues.
