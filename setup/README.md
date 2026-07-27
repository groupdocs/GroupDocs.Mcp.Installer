# setup/ — per-OS prerequisite bootstrap

The installer itself is PowerShell — but on macOS and Linux, PowerShell is usually the
*first missing prerequisite*. These scripts close that chicken-and-egg gap: run the one
for your OS first, then use `install-groupdocs-mcp.ps1` normally.

| OS | Script | Run |
|---|---|---|
| macOS | `macos.sh` | `bash setup/macos.sh [--channel docker\|nuget\|both] [--check]` |
| Linux (Debian/Ubuntu) | `linux.sh` | `bash setup/linux.sh [--channel docker\|nuget\|both] [--check]` |
| Windows | `windows.ps1` | `powershell -ExecutionPolicy Bypass -File setup\windows.ps1 [-Channel docker\|nuget\|both] [-Check]` |

All three are **idempotent** (already-installed items are detected and skipped),
**channel-aware** (install only what your chosen delivery channel needs), and support a
**check-only mode** that reports status without installing anything. Each ends with a
status summary and the next command to run.

## What gets installed, per channel

| Component | docker channel | nuget channel | Why |
|---|:--:|:--:|---|
| PowerShell 7 (`pwsh`) | macOS/Linux | macOS/Linux | Runs the installer (Windows already has PowerShell 5.1, which works too) |
| Docker (Desktop / engine) | ✅ | — | Runs the self-contained server images (multi-arch: amd64 + arm64) |
| .NET 10 SDK (`dotnet` + `dnx`) | — | ✅ | `dnx` launches the NuGet-published servers |
| libgdiplus (+ fontconfig, MS core fonts on Linux) | — | ✅ (macOS/Linux) | Native graphics deps some engines need when running outside Docker |

**Recommendation:** `docker` on macOS and Linux (native deps are baked into the
images; nothing else to maintain). `nuget` is great on Windows and for the lighter
products anywhere.

## What the scripts deliberately do NOT do

- No silent installs of package managers: if Homebrew (macOS) or winget (Windows) is
  missing, the script prints the official install command and stops — installing a
  package manager is your call.
- No `curl | sh`: Linux Docker install uses the distro package (`docker.io` on
  Debian/Ubuntu); other distros get pointed at the official docs instead of guessed at.
- No elevation surprises: Linux commands that need root use explicit visible `sudo`;
  Windows/winget prompts UAC per package as usual.

## Typical first run on a fresh machine

```bash
# macOS
git clone https://github.com/groupdocs/GroupDocs.Mcp.Installer.git
cd GroupDocs.Mcp.Installer
bash setup/macos.sh --channel docker
pwsh ./install-groupdocs-mcp.ps1 -Interactive
```

```powershell
# Windows
git clone https://github.com/groupdocs/GroupDocs.Mcp.Installer.git
cd GroupDocs.Mcp.Installer
powershell -ExecutionPolicy Bypass -File setup\windows.ps1 -Channel nuget
./install-groupdocs-mcp.ps1 -Interactive
```

Notes:
- macOS Docker Desktop must be **launched once manually** after install (first-run
  dialog); the script reminds you.
- Linux: after being added to the `docker` group, **log out/in** (or `newgrp docker`)
  before the docker channel works without sudo.
- `--check` (or `-Check`) is safe anywhere, including CI.
