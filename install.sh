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
#   PABRIK_NO_MODIFY_PATH=1  print the export line instead of appending
#                    it to ~/.bashrc / ~/.zshrc (CI, tests).
#   PABRIK_DRY_RUN=1 print resolved asset URLs and exit (no download, no install)
#
# Flags: --help | --version TAG | --dir DIR | --system | --no-desktop | --uninstall
#
# Webapp cache: EVERY run refreshes the shipped UI a bare `pabrik` serves
# (`$BINDIR/html`) from the `pabrik-html-<triple>.tar.gz` release asset --
# including a re-run whose binaries already match, because the UI is a
# separate asset that a release can republish without touching the binaries.
# A real install (binaries differ) and --uninstall additionally clear the
# desktop app's runtime UI cache -- `$HOME/.local/share/pabrik/desktop-webapp`
# on Linux (`$XDG_DATA_HOME`) and `$HOME/Library/Application Support/pabrik/
# desktop-webapp` on macOS. It holds one `<hash>` dir per build plus a
# `current` symlink, and nothing else ever prunes it, so the next launch
# re-extracts the assets of the build just installed.
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

# Where the desktop app caches the UI it materialises from its embedded
# assets: `<data home>/pabrik/desktop-webapp`, one dir per content hash plus
# a `current` symlink (src/apps/desktop_app/extraction.zig). Platform split
# matches persistentBaseDir() there.
webapp_cache_dir() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo "$HOME/Library/Application Support/pabrik/desktop-webapp"
    else
        echo "${XDG_DATA_HOME:-$HOME/.local/share}/pabrik/desktop-webapp"
    fi
}

# Drop that cache so the next launch re-extracts the assets belonging to the
# build we just installed -- old hash dirs are never pruned otherwise. Only
# the desktop-webapp subdir is removed: its siblings `data/` and `tls/` hold
# the user's database and certificates.
clear_webapp_cache() {
    local dir
    dir="$(webapp_cache_dir)"
    if [[ -d "$dir" ]]; then
        rm -rf "$dir"
        echo "Cleared the webapp cache ($dir)."
    fi
}

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
    echo "${BASE_URL}/pabrik-html-${TRIPLE}.tar.gz"
    exit 0
fi

if [[ "$UNINSTALL" -eq 1 ]]; then
    rm -f "$BIN_PABRIK" "$BIN_DESKTOP"
    rm -rf "${BINDIR}/html"
    rm -f "$HOME/.local/share/applications/pabrik.desktop" "$HOME/.local/share/applications/pabrik-browser.desktop"
    if [[ "$SYSTEM" -eq 1 ]]; then
        rm -f /usr/share/applications/pabrik.desktop /usr/share/applications/pabrik-browser.desktop
    fi
    clear_webapp_cache
    echo "Uninstalled pabrik from ${BINDIR}."
    exit 0
fi

have_cmd() { command -v "$1" >/dev/null 2>&1; }

download() {
    local url="$1" dest="$2"
    local name rc
    name="$(basename "$url")"
    rc=0
    echo "Downloading $name ..."
    if have_cmd curl; then
        # Timeouts so a stalled connection fails instead of hanging
        # forever; a progress bar on interactive terminals so a ~130 MB
        # binary does not look frozen, silence otherwise (CI logs).
        if [[ -t 2 ]]; then
            curl -fSL --progress-bar --connect-timeout 20 --max-time 900 \
                --retry 3 -o "$dest" "$url" || rc=$?
        else
            curl -fsSL --connect-timeout 20 --max-time 900 \
                --retry 3 -o "$dest" "$url" || rc=$?
        fi
    elif have_cmd wget; then
        # --tries=3: wget defaults to 20 retries, which reads as a hang
        # on a dead mirror. --timeout bounds connect/read stalls.
        if [[ -t 2 ]]; then
            wget --timeout=20 --tries=3 --show-progress -O "$dest" "$url" || rc=$?
        else
            wget --timeout=20 --tries=3 -qO "$dest" "$url" || rc=$?
        fi
    else
        echo "Need curl or wget to download ${url}" >&2
        return 1
    fi
    # Propagate fetch failures: callers gate on our exit status (e.g.
    # the shipped-UI download is best-effort). The size echo below must
    # not mask it, so return early here.
    if [[ "$rc" -ne 0 ]]; then return "$rc"; fi
    # Confirm movement: the byte count proves the download landed.
    local size
    size="$(du -h "$dest" 2>/dev/null | cut -f1)" || size="?"
    echo "  -> $name ($size)"
    return 0
}

# Shipped UI (serves /app): the server auto-discovers "${BINDIR}/html"
# (same portable layout as zig-out/bin/html in a checkout), so a bare
# `pabrik` opens the app with no --static-dir flag. Best-effort: a missing
# tar binary or a release without the asset degrades to API-only, never
# fails the install.
#
# Called on EVERY run, the up-to-date path included: the UI ships as its own
# asset and a release can republish it without touching the binaries, so
# skipping it there left an existing install showing the previous release's
# UI (observed live: fresh binaries from Oct 18 next to an Oct 11 tarball).
install_shipped_ui() {
    if ! have_cmd tar; then
        echo "warning: tar not found -- skipping shipped UI (serves API-only)" >&2
        return 0
    fi
    if ! download "${BASE_URL}/pabrik-html-${TRIPLE}.tar.gz" "${TMPDIR}/html.tar.gz" 2>/dev/null; then
        echo "warning: no shipped UI asset for ${TRIPLE} -- keeping any existing ${BINDIR}/html" >&2
        return 0
    fi
    rm -rf "${BINDIR}/html"
    if tar -xzf "${TMPDIR}/html.tar.gz" -C "${BINDIR}"; then
        echo "Installed the shipped UI into ${BINDIR}/html."
    else
        echo "warning: could not extract the shipped UI (serves API-only)" >&2
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

# Update detection: byte-compare the downloads against an existing
# install (the binaries carry no --version flag, so content is the
# version). Identical → already up to date, exit before touching
# anything. Differing (or missing) → install + report the update.
# `cmp -s` is POSIX-adjacent everywhere this script runs (coreutils,
# macOS file_cmds, Git Bash); without it, fall through to installing.
HAD_EXISTING=0
if [[ -f "$BIN_PABRIK" ]]; then HAD_EXISTING=1; fi
if have_cmd cmp && [[ -f "$BIN_PABRIK" ]]; then
    up_to_date=1
    cmp -s "${TMPDIR}/pabrik" "$BIN_PABRIK" || up_to_date=0
    if [[ "$WITH_DESKTOP" -eq 1 ]]; then
        [[ -f "$BIN_DESKTOP" ]] || up_to_date=0
        if [[ "$up_to_date" -eq 1 ]]; then
            cmp -s "${TMPDIR}/pabrik-desktop" "$BIN_DESKTOP" || up_to_date=0
        fi
    fi
    if [[ "$up_to_date" -eq 1 ]]; then
        echo "pabrik is already up to date (${TAG})."
        # Refresh the shipped UI anyway: it is a separate asset, and a
        # release can republish it while the binaries stay byte-identical.
        install_shipped_ui
        exit 0
    fi
fi

install -m 0755 "${TMPDIR}/pabrik" "$BIN_PABRIK"
if [[ "$WITH_DESKTOP" -eq 1 ]]; then
    install -m 0755 "${TMPDIR}/pabrik-desktop" "$BIN_DESKTOP"
fi
if [[ "$HAD_EXISTING" -eq 1 ]]; then
    echo "Updated existing installation to ${TAG}."
fi

# The binaries (and therefore the embedded UI) changed: drop the desktop's
# webapp cache so the next launch re-extracts the assets of THIS build
# instead of reusing a stale copy next to it.
clear_webapp_cache

# Shipped UI for a bare `pabrik` (see install_shipped_ui).
install_shipped_ui

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

# Add BINDIR to the user's PATH for future shells by appending an export
# line to ~/.bashrc / ~/.zshrc (whichever files already exist). A piped
# `curl | bash` runs in a child process and cannot change the parent
# shell's PATH, so rc files are the only automatic route — the current
# shell still needs `source ~/.bashrc` (or a new terminal), printed below.
# Idempotent via the marker comment (re-running never duplicates the line).
# Skipped with --system (/usr/local/bin is already on PATH), when BINDIR
# is already on PATH, or with PABRIK_NO_MODIFY_PATH=1 (CI, tests).
ensure_path() {
    case ":$PATH:" in
        *":${BINDIR}:") return 0 ;;
    esac
    local line
    if [[ "$BINDIR" == "$HOME"/* ]]; then
        line="export PATH=\"\$HOME/${BINDIR#"$HOME"/}:\$PATH\""
    else
        line="export PATH=\"${BINDIR}:\$PATH\""
    fi
    if [[ "$SYSTEM" -eq 1 || "${PABRIK_NO_MODIFY_PATH:-0}" -eq 1 ]]; then
        echo "Add ${BINDIR} to your PATH, e.g.:"
        echo "  $line"
        return 0
    fi
    local marker="# Added by pabrik installer"
    local touched=0
    local rc
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [[ -f "$rc" ]]; then
            if ! grep -qF "$marker" "$rc" 2>/dev/null; then
                printf '%s\n%s\n' "$marker" "$line" >> "$rc"
            fi
            touched=1
        fi
    done
    if [[ "$touched" -eq 1 ]]; then
        echo "Added ${BINDIR} to your PATH in your shell rc file."
        echo "Restart your terminal or run: $line"
    else
        echo "Add ${BINDIR} to your PATH, e.g.:"
        echo "  $line"
    fi
}

ensure_path

echo "Installed: ${BIN_PABRIK}"
[[ "$WITH_DESKTOP" -eq 1 ]] && echo "Installed: ${BIN_DESKTOP}"
echo "Run 'pabrik --help' to start. Desktop GUI: 'pabrik-desktop'."
