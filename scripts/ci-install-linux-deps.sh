#!/usr/bin/env bash
# scripts/ci-install-linux-deps.sh
#
# Installs the Linux system packages `zig build` needs on a GitHub-hosted
# `ubuntu-24.04` runner. Shared by all three Linux jobs in
# .github/workflows/ci.yml (backend's Ubuntu cell, functional-test,
# functional-test-ui) — they are separate jobs on separate VMs, so each one
# has to call this itself.
#
# Why a script rather than an inline step: the package list used to be
# copy-pasted into three places, and when it was wrong it was wrong in all
# three at once. One file, one list.
#
# Two install helpers, because they answer different questions:
#   apt_install <pkg>...  every one of these must exist; fail loudly if not
#   apt_any <alt>...      install the FIRST of these that exists (for
#                         packages Debian renamed between releases)
#
# The `t64` names are the Ubuntu 24.04 "64-bit time_t" transition:
# libasound2 -> libasound2t64, libcups2 -> libcups2t64, libatk1.0-0 ->
# libatk1.0-0t64. This step probes for a real install candidate rather
# than trusting a name, so it keeps working if the image is bumped to a
# distro that uses the old names again.

set -euo pipefail

# The GitHub-hosted runners reach the Ubuntu archive through an Azure mirror that
# intermittently fails to resolve — "Temporary failure resolving
# 'azure.archive.ubuntu.com'" — which turned every Linux job red for a reason no
# diff could fix. `Acquire::Retries` covers a flaky fetch; the loop below covers a
# flaky `update`, which is a separate invocation with its own DNS lookup.
APT_OPTS=(-o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

apt_update() {
    local attempt
    for attempt in 1 2 3; do
        if sudo apt-get "${APT_OPTS[@]}" update; then
            return 0
        fi
        echo "apt-get update failed (attempt ${attempt}/3); retrying in $((attempt * 10))s" >&2
        sleep $((attempt * 10))
    done
    echo "x apt-get update failed after 3 attempts — the Ubuntu mirror is unreachable" >&2
    return 1
}

# Exit 0 only when apt has an actual installable candidate. `apt-cache
# show` is NOT used as the probe: its exit code for an unknown package has
# varied across apt releases, which turns a missing package into either a
# silent skip or a confusing "E: Unable to locate package" on a real one.
#
# `grep -c`, NOT `grep -q`, and that is load-bearing under `set -o
# pipefail`: `grep -q` exits on the first match and closes the pipe, so
# apt-cache dies on SIGPIPE and the pipeline reports failure even though
# grep matched. Every package then looks unavailable and this script
# installs nothing while still exiting 0 on the failure path. `grep -c`
# consumes all input, so no SIGPIPE. It still exits 1 on zero matches,
# which is the signal we want.
pkg_available() {
    apt-cache policy "$1" 2>/dev/null | grep -c '^  Candidate:' >/dev/null
}

apt_install() {
    local missing=()
    local pkg
    for pkg in "$@"; do
        pkg_available "$pkg" || missing+=("$pkg")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "x not available on this image: ${missing[*]}" >&2
        return 1
    fi
    sudo apt-get "${APT_OPTS[@]}" install -y "$@"
}

apt_any() {
    local pkg
    for pkg in "$@"; do
        if pkg_available "$pkg"; then
            sudo apt-get "${APT_OPTS[@]}" install -y "$pkg"
            return 0
        fi
    done
    echo "x none of these packages exist on this image: $*" >&2
    return 1
}

apt_update

# C toolchain + the libraries the `databases` and `kabelweb` packages link
# unconditionally on Linux: -lpq, -lcurl, -lssl/-lcrypto, -lsqlite3.
# libcurl4-openssl-dev rather than libcurl4-gnutls-dev: the build probes
# openssl/ssl.h and prefers an OpenSSL-backed libcurl so one TLS stack
# serves the whole binary.
apt_install build-essential pkg-config unzip ripgrep \
            libssl-dev libcurl4-openssl-dev libsqlite3-dev libpq-dev

# pabrik-desktop's GTK webview. Zig resolves the hyphenated names
# (webkit2gtk-4.1 / gtk-3 / soup-3.0) through pkg-config, so these are
# only linkable when the matching .pc files are installed.
apt_install libgtk-3-dev libsoup-3.0-dev
apt_any libwebkit2gtk-4.1-dev

# Playwright's headless Chromium launch deps. Arch's single `mesa` package
# splits into libgl1 (libGL.so.1) + libegl1 (libEGL.so.1) + libgbm1
# (DRM buffers) on Debian/Ubuntu, and Chromium's compositor needs the
# first two — installing only libgbm1 leaves it failing to dlopen.
apt_install libnss3 libnspr4 libxkbcommon0 libdrm2 libxcomposite1 \
            libxdamage1 libxfixes3 libxrandr2 libgl1 libegl1 libgbm1 \
            libpango-1.0-0 libcairo2 at-spi2-core libatk-bridge2.0-0
apt_any libasound2t64 libasound2
apt_any libcups2t64 libcups2

# Assert what the build is about to look for, so an under-install fails
# HERE with a package-level message instead of deep inside a zig link
# error. `apt-cache policy` also confirms a dependency actually resolved
# to something installable.
rc=0
for pc in sqlite3 openssl libpq libcurl webkit2gtk-4.1; do
    if pkg-config --exists "$pc" 2>/dev/null; then
        echo "  ok pkg-config $pc ($(pkg-config --modversion "$pc" 2>/dev/null || echo '?'))"
    else
        echo "x pkg-config cannot resolve '$pc' after install" >&2
        rc=1
    fi
done
command -v rg >/dev/null 2>&1 || { echo "x ripgrep ('rg') not on PATH — search.zig spawns it" >&2; rc=1; }
if [ "$rc" -ne 0 ]; then
    echo "x system dependency install is incomplete — see the failures above" >&2
    exit 1
fi

echo "ok system dependencies installed"
