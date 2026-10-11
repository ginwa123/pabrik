#!/usr/bin/env bash
# install.sh — one-line installer for Pabrik (Linux + macOS).
#
#   curl -fsSL https://raw.githubusercontent.com/ginwa123/pabrik/main/install.sh | bash
#   wget -qO- https://raw.githubusercontent.com/ginwa123/pabrik/main/install.sh | bash
#
# Downloads the prebuilt pabrik + pabrik-desktop binaries from the rolling
# `ci-latest` GitHub release and installs them to $HOME/.local/bin
# (no sudo) or /usr/local/bin with --system.
#
# Env overrides:
#   PABRIK_VERSION   release tag, default "ci-latest"
#   PABRIK_REPO      "owner/repo", default "ginwa123/pabrik"
#   PABRIK_BINDIR    install dir, default auto ($HOME/.local/bin or /usr/local/bin)
#   PABRIK_BASE_URL  full base URL for the release assets (default
#                    https://github.com/$PABRIK_REPO/releases/download/$PABRIK_VERSION).
#                    Tests point it at a local file:// staging dir.
#   PABRIK_SKIP_DESKTOP_ENTRY=1  skip the Linux .desktop launcher fetch
#                    (hermetic/offline installs and tests).
#   PABRIK_DRY_RUN=1 print resolved asset URLs and exit (no download, no install)
#
# Flags: --help | --version TAG | --dir DIR | --system | --no-desktop | --uninstall
#
# Windows users: this script does not run on Windows. In PowerShell run:
#   irm https://raw.githubusercontent.com/ginwa123/pabrik/main/install.ps1 | iex

set -euo pipefail

REPO="${PABRIK_REPO:-ginwa123/pabrik}"
TAG="${PABRIK_VERSION:-ci-latest}"
BINDIR="${PABRIK_BINDIR:-}"
SYSTEM=0
WITH_DESKTOP=1
UNINSTALL=0

usage() {
    sed -n '1,/^$/p' "$0" | sed 's/^# \{0,1\}//' || true
    echo "Usage: install.sh [--dir DIR] [--system] [--no-desktop] [--version TAG] [--uninstall]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --version) TAG="${2:?--version needs a tag}"; shift 2 ;;
        --dir) BINDIR="${2:?--dir needs a directory}"; shift 2 ;;
        --system) SYSTEM=1; shift ;;
        --no-desktop) WITH_DESKTOP=0; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        *) echo "Unknown flag: $1 (see --help)" >&2; exit 1 ;;
    esac
done

resolve_triple() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    case "$os" in
        Linux)
            case "$arch" in
                x86_64|amd64) echo "x86_64-linux-gnu" ;;
                *) echo "unsupported: Linux/$arch has no prebuilt binary (only x86_64). Build from source: git clone https://github.com/${REPO}.git && cd pabrik && zig build" >&2; return 1 ;;
            esac
            ;;
        Darwin)
            case "$arch" in
                arm64|aarch64) echo "aarch64-macos" ;;
                *) echo "unsupported: macOS/$arch has no prebuilt binary (only Apple Silicon arm64). Build from source or use Rosetta." >&2; return 1 ;;
            esac
            ;;
        MINGW*|MSYS*|CYGWIN*)
            echo "unsupported: this script does not run on Windows. In PowerShell run: irm https://raw.githubusercontent.com/${REPO}/main/install.ps1 | iex" >&2
            return 1
            ;;
        *)
            echo "unsupported OS: $os ($arch)." >&2
            return 1
            ;;
    esac
}

TRIPLE="$(resolve_triple)"
BASE_URL="${PABRIK_BASE_URL:-https://github.com/${REPO}/releases/download/${TAG}}"

if [[ -z "$BINDIR" ]]; then
    if [[ "$SYSTEM" -eq 1 ]]; then
        BINDIR="/usr/local/bin"
    else
        BINDIR="$HOME/.local/bin"
    fi
fi

BIN_PABRIK="${BINDIR}/pabrik"
BIN_DESKTOP="${BINDIR}/pabrik-desktop"

if [[ "${PABRIK_DRY_RUN:-0}" -eq 1 ]]; then
    echo "repo=${REPO} tag=${TAG} triple=${TRIPLE} bindir=${BINDIR}"
    echo "${BASE_URL}/pabrik-${TRIPLE}"
    echo "${BASE_URL}/pabrik-desktop-${TRIPLE}"
    exit 0
fi

if [[ "$UNINSTALL" -eq 1 ]]; then
    rm -f "$BIN_PABRIK" "$BIN_DESKTOP"
    rm -f "$HOME/.local/share/applications/pabrik.desktop" "$HOME/.local/share/applications/pabrik-browser.desktop"
    if [[ "$SYSTEM" -eq 1 ]]; then
        rm -f /usr/share/applications/pabrik.desktop /usr/share/applications/pabrik-browser.desktop
    fi
    echo "Uninstalled pabrik from ${BINDIR}."
    exit 0
fi

have_cmd() { command -v "$1" >/dev/null 2>&1; }

download() {
    local url="$1" dest="$2"
    if have_cmd curl; then
        curl -fsSL --retry 3 -o "$dest" "$url"
    elif have_cmd wget; then
        wget -qO "$dest" "$url"
    else
        echo "Need curl or wget to download ${url}" >&2
        return 1
    fi
}

mkdir -p "$BINDIR"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Installing pabrik (${TRIPLE}, ${TAG}) -> ${BINDIR} ..."
download "${BASE_URL}/pabrik-${TRIPLE}" "${TMPDIR}/pabrik"
if [[ "$WITH_DESKTOP" -eq 1 ]]; then
    download "${BASE_URL}/pabrik-desktop-${TRIPLE}" "${TMPDIR}/pabrik-desktop"
fi

install -m 0755 "${TMPDIR}/pabrik" "$BIN_PABRIK"
if [[ "$WITH_DESKTOP" -eq 1 ]]; then
    install -m 0755 "${TMPDIR}/pabrik-desktop" "$BIN_DESKTOP"
fi

# Linux desktop launchers (best-effort): fetch the .desktop files shipped in
# packaging/linux so Pabrik shows up in GNOME/KDE search. User-local when
# installing to $HOME, system-wide with --system. Skipped entirely with
# PABRIK_SKIP_DESKTOP_ENTRY=1 (hermetic/offline installs and tests).
if [[ "$(uname -s)" == "Linux" && "$WITH_DESKTOP" -eq 1 && "${PABRIK_SKIP_DESKTOP_ENTRY:-0}" != "1" ]]; then
    APPSDIR="$HOME/.local/share/applications"
    [[ "$SYSTEM" -eq 1 ]] && APPSDIR="/usr/share/applications"
    mkdir -p "$APPSDIR" 2>/dev/null || true
    for entry in pabrik pabrik-browser; do
        if download "https://raw.githubusercontent.com/${REPO}/main/packaging/linux/${entry}.desktop" "${TMPDIR}/${entry}.desktop" 2>/dev/null; then
            sed "s|^Exec=.*|Exec=${BIN_DESKTOP}|" "${TMPDIR}/${entry}.desktop" > "${APPSDIR}/${entry}.desktop" || true
        fi
    done
fi

# macOS GUI hint: the .app bundle ships as a separate asset for users who
# want a Spotlight/Launchpad entry instead of bare binaries.
if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "(GUI users: ${BASE_URL}/Pabrik-${TRIPLE}.zip holds Pabrik.app — extract and move it to ~/Applications.)"
fi

if ! "$BIN_PABRIK" --help >/dev/null 2>&1; then
    echo "warning: installed binary failed '--help' check at ${BIN_PABRIK}" >&2
fi

case ":$PATH:" in
    *":${BINDIR}:"*) ;;
    *)
        echo "Add ${BINDIR} to your PATH, e.g.:"
        echo "  export PATH=\"${BINDIR}:\$PATH\""
        ;;
esac

echo "Installed: ${BIN_PABRIK}"
[[ "$WITH_DESKTOP" -eq 1 ]] && echo "Installed: ${BIN_DESKTOP}"
echo "Run 'pabrik --help' to start. Desktop GUI: 'pabrik-desktop'."
