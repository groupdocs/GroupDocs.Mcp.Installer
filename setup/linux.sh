#!/usr/bin/env bash
# Prerequisite bootstrap for the GroupDocs MCP installer - Linux (Debian/Ubuntu).
#
#   bash setup/linux.sh [--channel docker|nuget|both] [--check]
#
# Installs (idempotently, apt + packages.microsoft.com):
#   always : PowerShell 7 (pwsh) - runs the installer scripts
#   docker : docker engine (docker.io) + adds you to the 'docker' group
#   nuget  : .NET 10 SDK (dnx) + libgdiplus, libfontconfig1, MS core fonts
#
# Non-apt distros (Fedora, Arch, ...): the script detects this and prints the
# official doc links instead of guessing package names.
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

echo "== GroupDocs MCP prerequisites - Linux (channel: $CHANNEL) =="

if ! have apt-get; then
  echo "  This script automates Debian/Ubuntu (apt). For your distro, install manually:"
  echo "    PowerShell : https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux"
  echo "    Docker     : https://docs.docker.com/engine/install/"
  echo "    .NET 10 SDK: https://learn.microsoft.com/dotnet/core/install/linux"
  echo "    nuget channel extras: libgdiplus libfontconfig1 + MS core fonts"
  exit 1
fi

# Microsoft package repo provides both pwsh and the .NET SDK on Debian/Ubuntu.
ensure_ms_repo() {
  if [[ -f /etc/apt/sources.list.d/microsoft-prod.list ]]; then return 0; fi
  act "Microsoft package repository (packages.microsoft.com)"
  . /etc/os-release
  local deb="packages-microsoft-prod.deb"
  local url="https://packages.microsoft.com/config/${ID}/${VERSION_ID}/${deb}"
  local tmp; tmp="$(mktemp -d)"
  if ! curl -fsSL "$url" -o "$tmp/$deb"; then
    echo "            Could not fetch $url - see https://learn.microsoft.com/linux/packages"
    return 1
  fi
  sudo dpkg -i "$tmp/$deb" && sudo apt-get update -qq
}

FAILED=0

# --- PowerShell (always) -----------------------------------------------------
if have pwsh; then
  ok "PowerShell $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || echo '?')"
elif [[ $CHECK -eq 1 ]]; then
  miss "PowerShell 7 (pwsh)  ->  Microsoft repo + 'sudo apt-get install -y powershell'"
else
  ensure_ms_repo || FAILED=1
  act "PowerShell 7 (sudo apt-get install -y powershell)"
  sudo apt-get install -y powershell || FAILED=1
fi

# --- Docker channel ----------------------------------------------------------
if [[ "$CHANNEL" == "docker" || "$CHANNEL" == "both" ]]; then
  if have docker; then
    if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
      ok "Docker (daemon reachable, $(docker version --format '{{.Server.Version}}'))"
    else
      ok "Docker CLI present - daemon not reachable for this user (group membership? service running?)"
    fi
  elif [[ $CHECK -eq 1 ]]; then
    miss "Docker  ->  sudo apt-get install -y docker.io  (or Docker CE per docs.docker.com)"
  else
    act "Docker engine (sudo apt-get install -y docker.io)"
    sudo apt-get update -qq && sudo apt-get install -y docker.io || FAILED=1
    if getent group docker >/dev/null 2>&1 && ! id -nG "$USER" | grep -qw docker; then
      act "adding $USER to the 'docker' group (takes effect after re-login / 'newgrp docker')"
      sudo usermod -aG docker "$USER" || true
    fi
    sudo systemctl enable --now docker >/dev/null 2>&1 || true
  fi
fi

# --- NuGet channel -----------------------------------------------------------
if [[ "$CHANNEL" == "nuget" || "$CHANNEL" == "both" ]]; then
  if have dotnet && dotnet --list-sdks 2>/dev/null | grep -q '^10\.'; then
    ok ".NET 10 SDK ($(dotnet --list-sdks | grep '^10\.' | head -1 | awk '{print $1}'))"
  elif [[ $CHECK -eq 1 ]]; then
    miss ".NET 10 SDK  ->  Microsoft repo + 'sudo apt-get install -y dotnet-sdk-10.0'"
  else
    ensure_ms_repo || FAILED=1
    act ".NET 10 SDK (sudo apt-get install -y dotnet-sdk-10.0)"
    sudo apt-get install -y dotnet-sdk-10.0 || FAILED=1
  fi

  # Native deps some engines need outside Docker; ttf-mscorefonts needs an EULA accept.
  if dpkg -s libgdiplus >/dev/null 2>&1 && dpkg -s libfontconfig1 >/dev/null 2>&1; then
    ok "libgdiplus + libfontconfig1"
  elif [[ $CHECK -eq 1 ]]; then
    miss "libgdiplus/libfontconfig1/ttf-mscorefonts-installer  ->  sudo apt-get install -y ..."
  else
    act "native graphics deps (libgdiplus libfontconfig1 ttf-mscorefonts-installer)"
    echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | sudo debconf-set-selections
    sudo apt-get install -y --no-install-recommends libgdiplus libfontconfig1 ttf-mscorefonts-installer || FAILED=1
  fi
fi

echo "== Summary =="
have pwsh   && ok "pwsh   : $(command -v pwsh)"   || miss "pwsh"
if [[ "$CHANNEL" != "nuget" ]]; then have docker && ok "docker : $(command -v docker)" || miss "docker"; fi
if [[ "$CHANNEL" != "docker" ]]; then
  have dotnet && ok "dotnet : $(command -v dotnet)" || miss "dotnet"
  have dnx    && ok "dnx    : $(command -v dnx)"    || echo "  [NOTE]    dnx ships inside the .NET 10 SDK; open a new shell if it is not found yet."
fi

if [[ $FAILED -eq 1 ]]; then
  echo "Some installs failed - review the output above."
  exit 1
fi
echo
echo "Next:  pwsh ./install-groupdocs-mcp.ps1 -Interactive"
[[ "$CHANNEL" != "nuget" ]] && echo "       (docker group changes need a re-login or 'newgrp docker' first)"
exit 0
