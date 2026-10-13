#!/usr/bin/env bash
# packaging/macos/install-pabrik-app.sh
#
# User-local macOS install: assembles Pabrik.app (no admin, no /Applications).
# Both binaries ship together because the desktop auto-spawns the pabrik
# service sitting next to itself (Contents/MacOS/pabrik); a lone
# pabrik-desktop cannot start its backend.
#
# Also assembles Pabrik Browser.app: same binaries, but the bundle
# executable is a small `pabrik-browser` shim that execs
# `pabrik-desktop --browser`, so a double-click opens the attached
# pabrik URL in the default browser tab instead of a webview window.
#
# Usage:
#   packaging/macos/install-pabrik-app.sh <sourcedir> [destappdir] [browserappdir]
#
#   <sourcedir>   dir holding `pabrik-desktop` + `pabrik`
#                 (e.g. zig-out/bin from `zig build pabrik-desktop`).
#   [destappdir]  destination bundle, default ~/Applications/Pabrik.app.
#                 CI passes a staging dir (bin-stage-*/Pabrik.app) instead.
#   [browserappdir] destination browser bundle,
#                 default ~/Applications/Pabrik Browser.app.
#
# Post-assembly the script clears the quarantine xattr and applies an
# ad-hoc signature (both best-effort) so a first double-click doesn't
# bounce on Gatekeeper for locally-built binaries.
#
# App icon: packaging/macos/Pabrik.icns (the brand "P" mark, see
# packaging/icons/README.md) is copied into Contents/Resources when
# present, matching the CFBundleIconFile entry in Info.plist.
# Missing icns is a warning, not a failure — the bundle still indexes
# in Spotlight/Launchpad by name.
#
# Idempotent: re-running overwrites the previous bundle.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <sourcedir> [destappdir]" >&2
    exit 1
fi

SRC_DIR="$1"
DEST_APP="${2:-$HOME/Applications/Pabrik.app}"
DEST_BROWSER_APP="${3:-$HOME/Applications/Pabrik Browser.app}"

for bin in pabrik-desktop pabrik; do
    if [[ ! -f "${SRC_DIR}/${bin}" ]]; then
        echo "Required file missing: ${SRC_DIR}/${bin} -- run 'zig build pabrik-desktop' first." >&2
        exit 1
    fi
done

# Resolve Info.plist next to this script so the script works from any cwd
# (repo checkout) and from a release-zip layout (script beside Info.plist).
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
PLIST_SRC="${SCRIPT_DIR}/Info.plist"
if [[ ! -f "${PLIST_SRC}" ]]; then
    echo "Info.plist missing next to script: ${PLIST_SRC}" >&2
    exit 1
fi

rm -rf "${DEST_APP}"
mkdir -p "${DEST_APP}/Contents/MacOS" "${DEST_APP}/Contents/Resources"

cp "${SRC_DIR}/pabrik-desktop" "${DEST_APP}/Contents/MacOS/pabrik-desktop"
cp "${SRC_DIR}/pabrik"         "${DEST_APP}/Contents/MacOS/pabrik"
chmod +x "${DEST_APP}/Contents/MacOS/pabrik-desktop" "${DEST_APP}/Contents/MacOS/pabrik"
cp "${PLIST_SRC}" "${DEST_APP}/Contents/Info.plist"
if [[ -f "${SCRIPT_DIR}/Pabrik.icns" ]]; then
    cp "${SCRIPT_DIR}/Pabrik.icns" "${DEST_APP}/Contents/Resources/Pabrik.icns"
else
    echo "warning: Pabrik.icns missing next to script (app ships without a custom icon)" >&2
fi

# Gatekeeper friendliness for locally-built binaries (best-effort: missing
# tools or hardened runtimes must not fail the install).
xattr -dr com.apple.quarantine "${DEST_APP}" 2>/dev/null || true
codesign --force --deep -s - "${DEST_APP}" 2>/dev/null || true

echo "Installed Pabrik.app -> ${DEST_APP}"
echo "Spotlight/Launchpad will index it as 'Pabrik' (reindex can take ~1 min on first install)."

# Pabrik Browser.app: same payload plus a `pabrik-browser` shim that
# forwards to `pabrik-desktop --browser`. The browser plist points
# CFBundleExecutable at the shim so Launchpad shows a distinct
# "Pabrik Browser" entry that opens a default-browser tab.
PLIST_BROWSER_SRC="${SCRIPT_DIR}/Info.browser.plist"
if [[ -f "${PLIST_BROWSER_SRC}" ]]; then
    rm -rf "${DEST_BROWSER_APP}"
    mkdir -p "${DEST_BROWSER_APP}/Contents/MacOS" "${DEST_BROWSER_APP}/Contents/Resources"
    cp "${SRC_DIR}/pabrik-desktop" "${DEST_BROWSER_APP}/Contents/MacOS/pabrik-desktop"
    cp "${SRC_DIR}/pabrik"         "${DEST_BROWSER_APP}/Contents/MacOS/pabrik"
    chmod +x "${DEST_BROWSER_APP}/Contents/MacOS/pabrik-desktop" "${DEST_BROWSER_APP}/Contents/MacOS/pabrik"
    cat > "${DEST_BROWSER_APP}/Contents/MacOS/pabrik-browser" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
HERE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
exec "${HERE}/pabrik-desktop" --browser "$@"
SHIM
    chmod +x "${DEST_BROWSER_APP}/Contents/MacOS/pabrik-browser"
    cp "${PLIST_BROWSER_SRC}" "${DEST_BROWSER_APP}/Contents/Info.plist"
    if [[ -f "${SCRIPT_DIR}/Pabrik.icns" ]]; then
        cp "${SCRIPT_DIR}/Pabrik.icns" "${DEST_BROWSER_APP}/Contents/Resources/Pabrik.icns"
    fi
    xattr -dr com.apple.quarantine "${DEST_BROWSER_APP}" 2>/dev/null || true
    codesign --force --deep -s - "${DEST_BROWSER_APP}" 2>/dev/null || true
    echo "Installed Pabrik Browser.app -> ${DEST_BROWSER_APP}"
else
    echo "Info.browser.plist missing next to script: ${PLIST_BROWSER_SRC} (skipping browser bundle)" >&2
fi
