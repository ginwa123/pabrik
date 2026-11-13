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
# It also installs `rg-pabrik-<triple>` as `$BINDIR/rg-pabrik`: the bundled
# ripgrep the `search` tool spawns, so no `apt install ripgrep` / `brew install
# ripgrep` is needed. The name is deliberately not `rg` -- that would replace a
# ripgrep the user installed, and `--system` writes to /usr/local/bin. The
# runtime finds the bundle beside `pabrik`; a real `rg` on PATH still works, and
# PABRIK_RG_BIN overrides both.
#
# The object store is opt-in. `pabrik-fs-<triple>` is the rustfs binary that
# holds document bodies, and it is 277 MB on Linux / 235 MB on macOS against
# 9.5 MB for pabrik itself, so a default install leaves it out and document
# bodies stay in the filesystem store. `--with-fs` (or PABRIK_WITH_FS=1)
# installs it as `$BINDIR/pabrik-fs`: the backend then starts it on a free
# loopback port and stops it on shutdown, so there is no service to configure
# and the process shows up as `pabrik-fs` in a task manager. A triple upstream
# has no build for (x86_64 macOS), so that cell keeps the filesystem store.
#
# Env overrides:
#   PABRIK_VERSION   release tag, default "ci-latest"
#   PABRIK_REPO      "owner/repo", default "ginwa123/pabrik"
#   PABRIK_BINDIR    install dir, default auto ($HOME/.local/bin or /usr/local/bin)
#   PABRIK_BASE_URL  full base URL for the release assets (default
#                    https://github.com/$PABRIK_REPO/releases/download/$PABRIK_VERSION).
#                    Tests point it at a local file:// staging dir.
#   PABRIK_WITH_FS=1  also install the bundled object store (`pabrik-fs`);
#                    same as --with-fs. Default: not installed.
#   PABRIK_SKIP_DESKTOP_ENTRY=1  skip the Linux .desktop launcher fetch
#                    (hermetic/offline installs and tests).
#   PABRIK_NO_MODIFY_PATH=1  print the export line instead of appending
#                    it to ~/.bashrc / ~/.zshrc (CI, tests).
#   PABRIK_DRY_RUN=1 print resolved asset URLs and exit (no download, no install)
#
# Flags: --help | --version TAG | --dir DIR | --system | --no-desktop | --with-fs | --uninstall
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
WITH_FS="${PABRIK_WITH_FS:-0}"
case "$WITH_FS" in
    1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]) WITH_FS=1 ;;
    *) WITH_FS=0 ;;
esac

usage() {
    sed -n '1,/^$/p' "$0" | sed 's/^# \{0,1\}//' || true
    echo "Usage: install.sh [--dir DIR] [--system] [--no-desktop] [--with-fs] [--version TAG] [--uninstall]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --version) TAG="${2:?--version needs a tag}"; shift 2 ;;
        --dir) BINDIR="${2:?--dir needs a directory}"; shift 2 ;;
        --system) SYSTEM=1; shift ;;
        --no-desktop) WITH_DESKTOP=0; shift ;;
        --with-fs) WITH_FS=1; shift ;;
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
    echo "repo=${REPO} tag=${TAG} triple=${TRIPLE} bindir=${BINDIR} with_fs=${WITH_FS}"
    echo "${BASE_URL}/pabrik-${TRIPLE}"
    echo "${BASE_URL}/pabrik-desktop-${TRIPLE}"
    echo "${BASE_URL}/pabrik-html-${TRIPLE}.tar.gz"
    echo "${BASE_URL}/rg-pabrik-${TRIPLE}"
    if [[ "$WITH_FS" -eq 1 ]]; then
        echo "${BASE_URL}/pabrik-fs-${TRIPLE}"
    fi
    exit 0
fi

if [[ "$UNINSTALL" -eq 1 ]]; then
    rm -f "$BIN_PABRIK" "$BIN_DESKTOP"
    rm -f "${BINDIR}/rg-pabrik"
    rm -f "${BINDIR}/pabrik-fs"
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

# `https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>` →
# `<owner>/<repo> <tag> <asset>`. Prints nothing for any other URL.
release_parts() {
    local url="$1" rest
    case "$url" in
        https://github.com/*/releases/download/*) ;;
        *) return 1 ;;
    esac
    rest="${url#https://github.com/}"
    local repo="${rest%%/releases/download/*}"
    rest="${rest#*/releases/download/}"
    local tag="${rest%%/*}"
    local asset="${rest#*/}"
    [[ -n "$repo" && -n "$tag" && -n "$asset" && "$asset" != "$rest" ]] || return 1
    echo "$repo $tag $asset"
}

# The release asset id for <repo> <tag> <asset>, or nothing. The
# `releases/download` redirect answers 504 for large assets often enough that
# the installer needs a second path; the API asset endpoint 302s to a working
# signed URL. The API returns pretty-printed JSON with `"url"` before
# `"name"` inside each asset object, which is what the awk state machine
# relies on.
release_asset_id() {
    local repo="$1" tag="$2" asset="$3"
    have_cmd curl || return 1
    local auth=()
    # CI sets GITHUB_TOKEN; unauthenticated API calls are capped at 60/hour
    # per IP, which a shared runner IP can already have spent.
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi
    # `${auth[@]+...}`: macOS ships bash 3.2, where an empty array under
    # `set -u` is an unbound-variable error.
    curl -fsSL --connect-timeout 20 --max-time 60 \
        -H "Accept: application/vnd.github+json" ${auth[@]+"${auth[@]}"} \
        "https://api.github.com/repos/${repo}/releases/tags/${tag}" 2>/dev/null |
        awk -v want="\"name\": \"${asset}\"" '
            /"url": "https:\/\/api\.github\.com\/repos\/.*\/releases\/assets\// {
                id = $0
                sub(/.*assets\//, "", id)
                sub(/".*/, "", id)
            }
            $0 ~ want { print id; exit }
        '
}

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
    # The release CDN 504s often enough that a second path is worth it: ask
    # the API for the asset id and fetch it from there.
    if [[ "$rc" -ne 0 ]]; then
        local parts repo tag asset id
        if parts="$(release_parts "$url")"; then
            read -r repo tag asset <<<"$parts"
            if id="$(release_asset_id "$repo" "$tag" "$asset")" && [[ -n "$id" ]]; then
                echo "  retrying ${name} through the API asset endpoint ..."
                rc=0
                if [[ -t 2 ]]; then
                    curl -fSL --progress-bar --connect-timeout 20 --max-time 900 \
                        --retry 3 -H "Accept: application/octet-stream" \
                        -o "$dest" "https://api.github.com/repos/${repo}/releases/assets/${id}" || rc=$?
                else
                    curl -fsSL --connect-timeout 20 --max-time 900 \
                        --retry 3 -H "Accept: application/octet-stream" \
                        -o "$dest" "https://api.github.com/repos/${repo}/releases/assets/${id}" || rc=$?
                fi
            fi
        fi
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

# ripgrep, beside the pabrik binary, so `search` works on a machine that has
# no rg of its own. It ships as `rg-pabrik`, NOT `rg`: with --system the
# destination is /usr/local/bin, and a file called `rg` there would replace a
# ripgrep the user installed deliberately. The runtime resolver looks for
# exactly this name first and falls back to a real `rg` on PATH.
# Best-effort: a release published before the asset existed still installs a
# working pabrik, and the warning names what is missing.
install_bundled_rg() {
    if ! download "${BASE_URL}/rg-pabrik-${TRIPLE}" "${TMPDIR}/rg-pabrik" 2>/dev/null; then
        echo "warning: no bundled ripgrep asset for ${TRIPLE} -- the search tool needs rg on PATH" >&2
        return 0
    fi
    install -m 0755 "${TMPDIR}/rg-pabrik" "${BINDIR}/rg-pabrik"
    echo "Installed the bundled ripgrep into ${BINDIR}/rg-pabrik."
}

# The object store, beside the pabrik binary, and only when the user asked for
# it: the rustfs binary is 277 MB, so the default install stays small and keeps
# document bodies in the filesystem store. `--with-fs` / PABRIK_WITH_FS=1 turns
# the rustfs runtime on by putting it where the resolver looks first. The name
# is `pabrik-fs`, not `rustfs`, so a task manager shows `pabrik-fs` and a
# `--system` install never shadows a rustfs the user installed.
# Best-effort: a triple upstream has no build for (x86_64 macOS) or a release
# published before the asset existed still installs a working pabrik, which
# then keeps the filesystem store.
install_bundled_rustfs() {
    if [[ "$WITH_FS" -ne 1 ]]; then
        return 0
    fi
    if ! download "${BASE_URL}/pabrik-fs-${TRIPLE}" "${TMPDIR}/pabrik-fs" 2>/dev/null; then
        echo "warning: no bundled object store asset for ${TRIPLE} -- documents stay in the filesystem store" >&2
        return 0
    fi
    install -m 0755 "${TMPDIR}/pabrik-fs" "${BINDIR}/pabrik-fs"
    echo "Installed the bundled object store into ${BINDIR}/pabrik-fs."
}

# Which storage runtime the install leaves behind, so the user learns the
# alternative without reading the header.
report_object_store() {
    if [[ "$WITH_FS" -eq 1 ]]; then
        echo "Object store: ${BINDIR}/pabrik-fs (rustfs runtime)."
    else
        echo "Object store: not installed -- document bodies use the filesystem store."
        echo "  Re-run with --with-fs to add the rustfs runtime."
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
        # Same reasoning for rg: an install that predates the bundled
        # ripgrep has an up-to-date binary and still no `search`.
        install_bundled_rg
        # And for the object store: an install that asked for it with
        # --with-fs gets it even when the binaries already match.
        install_bundled_rustfs
        report_object_store
        exit 0
    fi
fi

install -m 0755 "${TMPDIR}/pabrik" "$BIN_PABRIK"
if [[ "$WITH_DESKTOP" -eq 1 ]]; then
    install -m 0755 "${TMPDIR}/pabrik-desktop" "$BIN_DESKTOP"
fi
install_bundled_rg
install_bundled_rustfs
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
report_object_store
echo "Run 'pabrik --help' to start. Desktop GUI: 'pabrik-desktop'."
