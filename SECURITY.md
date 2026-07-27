# Security Policy

## Supported versions

Only the **latest tagged release** (and `main`) receives security fixes.

## What this tool does on your machine

Be aware before running — the installer is deliberately powerful:

- **Writes AI-client configuration files** (Claude Desktop, VS Code, Cursor, Windsurf,
  Cline, VS 2022) — always merge-not-overwrite, with a timestamped `.bak` first.
- **Executes local tooling**: `docker pull` / `docker run`, `dnx` (which downloads and
  runs the published GroupDocs MCP packages from NuGet.org), and the `claude` / `codex`
  CLIs when those clients are selected.
- Servers it registers process documents **locally**; the only network access at
  install time is pulling images (ghcr.io / docker.io) and packages (nuget.org).
- No telemetry is collected by these scripts.

Review with `-DryRun` first; it prints every write and command without executing them.

## Reporting a vulnerability

Please **do not** open a public issue for security reports.

- Use GitHub's [private vulnerability reporting](https://github.com/groupdocs/GroupDocs.Mcp.Installer/security/advisories/new), or
- report through the [GroupDocs support forum](https://forum.groupdocs.com/) marking the topic private.

Include OS, PowerShell version (`$PSVersionTable`), the command you ran, and the
config file (redact license paths). Expect an acknowledgement within **5 business days**.

## Scope notes

- Vulnerabilities in the GroupDocs MCP **servers** belong in the per-product repos
  (`groupdocs-<product>/GroupDocs.<Product>.Mcp`); in the underlying engines, report
  here or on the forum and they will be routed.
- The scripts assume a trusted single-user machine; they are not hardened for running
  with untrusted config files from third parties (a config chooses what gets executed).
