#!/usr/bin/env bash
# Prerequisite bootstrap for the GroupDocs MCP installer - macOS.
#
#   bash setup/macos.sh [--channel docker|nuget|both] [--check]
#
# Installs (idempotently, via Homebrew):
#   always : PowerShell 7 (pwsh) - runs the installer scripts
#   docker : Docker Desktop      - runs the self-contained server images
#   nuget  : .NET 10 SDK (dnx) + mono-libgdiplus (native graphics dep)
#
# --check reports status without installing anything.
set -euo pipefail

CHANNEL="docker"
CHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL="${2:?--channel needs docker|nuget|both}"; shift 2 ;;
    --check)   CHECK=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (use --channel docker|nuget|both, --check)"; exit 2 ;;
  esac
done
case "$CHANNEL" in docker|nuget|both) ;; *) echo "invalid --channel '$CHANNEL'"; exit 2 ;; esac

ok()   { printf '  [OK]      %s\n' "$1"; }
miss() { printf '  [MISSING] %s\n' "$1"; }
act()  { printf '  [INSTALL] %s\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }
brew_has_cask() { brew list --cask "$1" >/dev/null 2>&1; }
brew_has() { brew list "$1" >/dev/null 2>&1; }

echo "== GroupDocs MCP prerequisites - macOS (channel: $CHANNEL) =="

# Homebrew is required to install anything below - but installing a package
# manager is the user's decision, so we only point at the official command.
if ! have brew; then
  miss "Homebrew - required to install the items below."
  echo '            Install it first (official command from https://brew.sh):'
  echo '            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  [[ $CHECK -eq 1 ]] || exit 1
else
  ok "Homebrew $(brew --version | head -1 | awk '{print $2}')"
fi

FAILED=0

# --- PowerShell (always) -----------------------------------------------------
if have pwsh; then
  ok "PowerShell $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || echo '?')"
elif [[ $CHECK -eq 1 ]]; then
  miss "PowerShell 7 (pwsh)  ->  brew install --cask powershell"
else
  act "PowerShell 7 (brew install --cask powershell)"
  brew install --cask powershell || FAILED=1
fi

# --- Docker channel ----------------------------------------------------------
if [[ "$CHANNEL" == "docker" || "$CHANNEL" == "both" ]]; then
  if have docker; then
    if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
      ok "Docker (daemon running, $(docker version --format '{{.Server.Version}}'))"
    else
      ok "Docker CLI present - but the daemon is NOT running. Launch Docker Desktop."
    fi
  elif [[ $CHECK -eq 1 ]]; then
    miss "Docker Desktop  ->  brew install --cask docker"
  else
    act "Docker Desktop (brew install --cask docker)"
    brew install --cask docker || FAILED=1
    echo "            NOTE: launch Docker Desktop once from /Applications to finish its first-run setup."
  fi
fi

# --- NuGet channel -----------------------------------------------------------
if [[ "$CHANNEL" == "nuget" || "$CHANNEL" == "both" ]]; then
  if have dotnet && dotnet --list-sdks 2>/dev/null | grep -q '^10\.'; then
    ok ".NET 10 SDK ($(dotnet --list-sdks | grep '^10\.' | head -1 | awk '{print $1}'))"
  elif [[ $CHECK -eq 1 ]]; then
    miss ".NET 10 SDK  ->  brew install --cask dotnet-sdk"
  else
    act ".NET 10 SDK (brew install --cask dotnet-sdk)"
    brew install --cask dotnet-sdk || FAILED=1
  fi

  if have brew && brew_has mono-libgdiplus; then
    ok "mono-libgdiplus"
  elif [[ $CHECK -eq 1 ]]; then
    miss "mono-libgdiplus  ->  brew install mono-libgdiplus"
  else
    act "mono-libgdiplus (brew install mono-libgdiplus)"
    brew install mono-libgdiplus || FAILED=1
  fi
fi

echo "== Summary =="
have pwsh   && ok "pwsh   : $(command -v pwsh)"   || miss "pwsh"
if [[ "$CHANNEL" != "nuget" ]]; then have docker && ok "docker : $(command -v docker)" || miss "docker"; fi
if [[ "$CHANNEL" != "docker" ]]; then
  have dotnet && ok "dotnet : $(command -v dotnet)" || miss "dotnet"
  have dnx    && ok "dnx    : $(command -v dnx)"    || echo "  [NOTE]    dnx ships inside the .NET 10 SDK; open a new terminal if it is not found yet."
fi

if [[ $FAILED -eq 1 ]]; then
  echo "Some installs failed - review the output above."
  exit 1
fi
echo
echo "Next:  pwsh ./install-groupdocs-mcp.ps1 -Interactive"
