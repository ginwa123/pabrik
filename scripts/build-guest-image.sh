#!/usr/bin/env bash
# Assemble the guest rootfs image from Fedora minimal, plus `pabrik-vm-agent`
# as /init, the in-guest network forwarder, and (optionally) the probe fixture.
#
# Nothing here compiles Zig. `zig build vm` produces the binaries and this script
# refuses to invent its own command line for them, so the image hash transitively
# pins the agent's source the same way it pins the Fedora bytes.
#
# Two pins, and they are different in kind:
#   * the ROOTFS is a hash-pinned Fedora release artifact (guest-image.manifest);
#   * the PACKAGE SET is the explicit list below, and the image records what
#     dnf actually installed in /etc/pabrik-image-rpms. Per-rpm hash pinning is
#     the follow-up: Fedora release packages are immutable, repository indexes
#     are not.
# Everything else runs inside a rootless builder container: dnf needs to chroot
# for scriptlets, and the image must record 0:0 ownership.
#
# Usage: scripts/build-guest-image.sh --out IMG [--tier base|dev]
#                                     [--agent BIN] [--probe BIN] [--netd BIN]
#                                     [--size SIZE]
#                                     [--payload DIR] [--zig-cache DIR] [--cache DIR]
#                                     [--in-container] [--selftest]

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
manifest="$repo_root/scripts/guest-image.manifest"
out=""
tier="base"
agent_bin=""
bootstrap_bin=""
probe_bin=""
probe_given=0
netd_bin=""
netd_given=0
payload=""
zig_cache=""

# The uid and gid the guest agent runs a workload as (src/vm_agent/main.zig,
# `default_uid`). /workspace is that workload's $HOME and the directory whose
# contents persist, so a root build has to hand it over (plan §28).
guest_uid=1000
guest_gid=1000
size=""
cache="${PABRIK_VM_CACHE:-$HOME/.cache/pabrik-vm}"
in_container=0
# The builder is Fedora minimal too: one distribution end to end, so a package
# name means the same thing to the build as it does inside the guest.
builder_image="registry.fedoraproject.org/fedora-minimal:44@sha256:863d92bd4419f079bddf6a6cbdd6b3a1428568f72c6e242a215d5102502af0c9"
builder_packages="bash tar gzip xz e2fsprogs"
# The Fedora release the guest and the builder both track. A release that has
# gone EOL is archived: its package trees answer 404 and dnf retries dead URLs
# until the build gives up, which is why this follows a served release.
fedora_release="44"
# Fedora's metalink is the default source of mirrors. When a network cannot
# reach mirrors.fedoraproject.org, or the metalink answers for a release that
# has moved, `PABRIK_DNF_REPO_BASE` points dnf straight at a mirror root:
# `PABRIK_DNF_REPO_BASE=https://dl.fedoraproject.org/pub/fedora/linux`.
dnf_repo_args=()
if [ -n "${PABRIK_DNF_REPO_BASE:-}" ]; then
  dnf_repo_args=(--disablerepo='*'
    "--repofrompath=pabrel,${PABRIK_DNF_REPO_BASE}/releases/${fedora_release}/Everything/x86_64/os/"
    "--repofrompath=pabupd,${PABRIK_DNF_REPO_BASE}/updates/${fedora_release}/Everything/x86_64/")
fi

# What every tier gets: a shell, git (a workspace IS a checkout), TLS trust, and
# the handful of tools a workload and the smoke test reach for.
base_rpms=(git-core ca-certificates curl nmap-ncat procps-ng iproute tar gzip which)
# What only the dev tier adds: a toolchain, the package manager's friends.
dev_rpms=(gcc gcc-c++ make python3 nodejs npm vim-enhanced)
# A Fedora release archive is ~50 MB and the mirrors are not always fast, so the
# download gets a long leash; the hash check is what makes it trustworthy.
fetch_timeout=900

say() { printf '[guest-image] %s\n' "$*"; }
fail() { printf '[guest-image] FAIL %s\n' "$*" >&2; exit 1; }

# Fedora minimal is ~128 MiB of rootfs before a single package is added, against
# Alpine's ~8 MiB, so the base image is 1 GiB: the old 128 MiB would not hold the
# rootfs, and a workspace disk is a copy of this file.
default_size() {
  case "$1" in
    dev) printf '2048M\n' ;;
    *) printf '1024M\n' ;;
  esac
}

# The bind mounts the container hop needs, one argument per line. A payload
# outside the repo gets its own read-only mount; one inside it is already
# covered, and docker refuses a duplicate mount point.
container_mounts() { # <repo_root> <cache> <out_dir> [<payload>]
  printf '%s\n' -v "$1:$1:ro" -v "$2:$2" -v "$3:$3"
  case "${4:-}" in
    "" | "$1" | "$1"/*) return 0 ;;
  esac
  printf '%s\n' -v "$4:$4:ro"
}

# A payload that is not a directory would silently ship no fixtures, and the
# benchmark that reads them would be measuring an empty rootfs instead.
payload_dir() { # <path> -> the path, or a build stop
  if [ -n "$1" ] && [ ! -d "$1" ]; then
    printf 'payload: %s is not a directory\n' "$1" >&2
    return 1
  fi
  [ -z "$1" ] || printf '%s\n' "$1"
}

# The manifest, as a plan: one `role hash url` line per artifact that this tier
# needs. Every rejection here is a build stop, never a warning.
manifest_plan() { # <manifest> <tier>
  local file="$1" want="$2" hash url role rest found=0
  while read -r hash url role rest; do
    case "$hash" in ""|\#*) continue ;; esac
    if [ "${#hash}" -ne 64 ] || [ -n "${hash//[0-9a-f]/}" ]; then
      printf 'manifest: %s has no 64-char lowercase sha256\n' "${url:-?}" >&2
      return 1
    fi
    if [ -z "${url:-}" ]; then
      printf 'manifest: %s has no URL\n' "$hash" >&2
      return 1
    fi
    if [ -n "${rest:-}" ]; then
      printf 'manifest: %s carries more than the role column\n' "$url" >&2
      return 1
    fi
    role="${role:-rootfs}"
    case "$role" in
      rootfs)
        case "$url" in
          *.tar | *.tar.gz | *.tar.xz | *.tgz) ;;
          *)
            printf 'manifest: the rootfs role takes an archive, and %s is not one\n' "$url" >&2
            return 1
            ;;
        esac
        ;;
      all | dev)
        printf 'manifest: packages are listed in this script now, not here (%s)\n' "$url" >&2
        return 1
        ;;
      *)
        printf 'manifest: unknown role %s for %s\n' "$role" "$url" >&2
        return 1
        ;;
    esac
    printf '%s %s %s\n' "$role" "$hash" "$url"
    found=$((found + 1))
  done <"$file"
  if [ "$found" -eq 0 ]; then
    printf 'manifest: %s listed no artifacts for tier %s\n' "$file" "$want" >&2
    return 1
  fi
}

# The packages this tier installs, one name per line. Every tier gets the base
# set; the dev tier adds its own.
tier_rpms() { # <tier>
  printf '%s\n' "${base_rpms[@]}"
  [ "$1" = dev ] && printf '%s\n' "${dev_rpms[@]}"
  return 0
}

# Whether the host can do the install itself: only a Fedora host has dnf, and the
# install must run as root anyway (chroot for scriptlets, 0:0 ownership), so a
# container hop is the normal path, not the exception.
host_can_install() { command -v dnf >/dev/null 2>&1 && [ "$(id -u)" = 0 ]; }


run_selftest() {
  local tmp ok=0 bad=0 h1 h2 u1 u2
  tmp="$(mktemp -d)"
  h1="2e405ab2b84155c32887f07ed1b259b342acda7547272607c1d18eb7cd1af961"
  h2="0e626fa97cf937fda7bba4ed4dde8e2f2dbb5083ac34e02180cec0c4eba9351b"
  u1="https://example.invalid/fedora-minimal.oci.tar.xz"
  u2="https://example.invalid/thing.rpm"
  printf '%s  %s\n' "$h1" "$u1" >"$tmp/good"
  printf '%s  %s\n' "${h1:0:63}" "$u1" >"$tmp/short"
  printf '%s  %s\n' "$(printf '%s' "$h1" | tr 'a-f' 'A-F')" "$u1" >"$tmp/upper"
  printf '%s  %s  weird\n' "$h1" "$u1" >"$tmp/role"
  printf '%s  %s  all\n' "$h2" "$u2" >"$tmp/all-rpm"
  printf '%s  %s  dev\n' "$h2" "$u2" >"$tmp/dev-rpm"
  printf '%s  %s\n' "$h1" "https://example.invalid/thing.rpm" >"$tmp/not-archive"
  printf '%s  %s  rootfs  extra\n' "$h1" "$u1" >"$tmp/columns"
  printf '# only a comment\n' >"$tmp/empty"
  printf '%s  \n' "$h1" >"$tmp/no-url"

  check() { # <what> <expected> <actual>
    if [ "$2" = "$3" ]; then
      ok=$((ok + 1))
      printf '  ok   %s\n' "$1"
    else
      bad=$((bad + 1))
      printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"
    fi
  }
  rejects() { # <what> <manifest> <tier>
    if manifest_plan "$2" "$3" >/dev/null 2>&1; then
      bad=$((bad + 1))
      printf '  FAIL %s was accepted\n' "$1"
    else
      ok=$((ok + 1))
      printf '  ok   %s is refused\n' "$1"
    fi
  }
  refuses_path() { # <what> <path>
    if payload_dir "$2" >/dev/null 2>&1; then
      bad=$((bad + 1))
      printf '  FAIL %s was accepted\n' "$1"
    else
      ok=$((ok + 1))
      printf '  ok   %s is refused\n' "$1"
    fi
  }
  check "the rootfs archive is what the manifest plans" \
    "rootfs $h1 $u1" "$(manifest_plan "$tmp/good" base)"
  check "the same plan for the dev tier: the archive, nothing else" \
    "rootfs $h1 $u1" "$(manifest_plan "$tmp/good" dev)"
  rejects "a 63-char checksum" "$tmp/short" base
  rejects "an uppercase checksum" "$tmp/upper" base
  rejects "an unknown role" "$tmp/role" base
  rejects "an all package in the manifest" "$tmp/all-rpm" base
  rejects "a dev package in the manifest" "$tmp/dev-rpm" dev
  rejects "a rootfs that is not an archive" "$tmp/not-archive" base
  rejects "a fourth column" "$tmp/columns" base
  rejects "a comment-only manifest" "$tmp/empty" dev
  rejects "an entry with no URL" "$tmp/no-url" base
  check "the base image default size" "1024M" "$(default_size base)"
  check "the dev image default size" "2048M" "$(default_size dev)"

  mkdir -p "$tmp/payload"
  printf 'x\n' >"$tmp/not-a-dir"
  check "no payload is not a payload" "" "$(payload_dir "")"
  check "a payload directory is passed through" "$tmp/payload" "$(payload_dir "$tmp/payload")"
  refuses_path "a payload that is a file" "$tmp/not-a-dir"
  refuses_path "a payload that does not exist" "$tmp/nope"

  check "the container hop mounts the repo, the cache and the output directory" \
    "-v /r:/r:ro -v /c:/c -v /o:/o" \
    "$(container_mounts /r /c /o | tr '\n' ' ' | sed 's/ $//')"
  check "a payload outside the repo is mounted read-only as well" \
    "-v /r:/r:ro -v /c:/c -v /o:/o -v /p:/p:ro" \
    "$(container_mounts /r /c /o /p | tr '\n' ' ' | sed 's/ $//')"
  check "a payload inside the repo is not mounted twice" \
    "-v /r:/r:ro -v /c:/c -v /o:/o" \
    "$(container_mounts /r /c /o /r/payload | tr '\n' ' ' | sed 's/ $//')"

  check "the committed manifest pins exactly one rootfs archive" "1" \
    "$(manifest_plan "$manifest" base | grep -c '^rootfs ')"
  check "the pinned rootfs is a Fedora release archive" "1" \
    "$(manifest_plan "$manifest" base | grep -c 'fedora.*\.oci\.tar\.xz$')"
  check "the base set carries git" "1" "$(tier_rpms base | grep -cx 'git-core')"
  check "the base set carries TLS trust" "1" "$(tier_rpms base | grep -cx 'ca-certificates')"
  check "the dev tier is the base set plus its own" "1" \
    "$([ "$(tier_rpms dev | wc -l)" -gt "$(tier_rpms base | wc -l)" ] && echo 1 || echo 0)"

  rm -rf "$tmp"
  printf '[guest-image] selftest: %d ok, %d failed\n' "$ok" "$bad"
  [ "$bad" -eq 0 ] || exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --tier) tier="$2"; shift 2 ;;
    --agent) agent_bin="$2"; shift 2 ;;
    --bootstrap) bootstrap_bin="$2"; shift 2 ;;
    --probe) probe_bin="$2"; probe_given=1; shift 2 ;;
    --netd) netd_bin="$2"; netd_given=1; shift 2 ;;
    --payload) payload="$2"; shift 2 ;;
    --zig-cache) zig_cache="$2"; shift 2 ;;
    --size) size="$2"; shift 2 ;;
    --cache) cache="$2"; shift 2 ;;
    --in-container) in_container=1; shift ;;
    --selftest) run_selftest; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$tier" in base|dev) ;; *) fail "--tier must be base or dev, not $tier" ;; esac
[ -n "$size" ] || size="$(default_size "$tier")"

# The container hop keeps the caller's absolute paths, because its own working
# directory is not ours: a relative --probe would name nothing inside it.
abs() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$PWD" "$1" ;; esac; }
[ -z "$agent_bin" ] || agent_bin="$(abs "$agent_bin")"
[ -z "$bootstrap_bin" ] || bootstrap_bin="$(abs "$bootstrap_bin")"
[ -z "$probe_bin" ] || probe_bin="$(abs "$probe_bin")"
[ -z "$netd_bin" ] || netd_bin="$(abs "$netd_bin")"
[ -z "$out" ] || out="$(abs "$out")"
[ -z "$payload" ] || payload="$(abs "$payload")"
[ -z "$zig_cache" ] || zig_cache="$(abs "$zig_cache")"
[ -n "$out" ] || fail "--out IMG is required"

# The container hop is about capability: dnf has to run as root (chroot for
# scriptlets, 0:0 ownership inside the image), and this distribution's package
# manager is the builder's, not the host's.
needs_builder=0
if [ "${#base_rpms[@]}" -gt 0 ] && ! host_can_install; then
  needs_builder=1
fi
if [ "$(id -u)" != 0 ] && { [ "$in_container" = 1 ] || [ "$needs_builder" = 1 ]; }; then
  engine="${PABRIK_CONTAINER_ENGINE:-}"
  if [ -z "$engine" ]; then
    if docker info >/dev/null 2>&1; then
      engine=docker
    elif podman info >/dev/null 2>&1; then
      engine=podman
    else
      fail "--in-container needs docker or podman, and neither answers"
    fi
  fi
  out_dir="$(cd "$(dirname "$out")" && pwd)"
  mkdir -p "$cache" "$out_dir"
  say "re-running as root in $builder_image ($engine)"
  args=(--out "$out" --tier "$tier" --size "$size" --cache "$cache")
  [ -z "$agent_bin" ] || args+=(--agent "$agent_bin")
  [ -z "$probe_bin" ] || args+=(--probe "$probe_bin")
  [ -z "$netd_bin" ] || args+=(--netd "$netd_bin")
  [ -z "$payload" ] || args+=(--payload "$payload")
  [ -z "$zig_cache" ] || args+=(--zig-cache "$zig_cache")
  quoted=""
  for a in "${args[@]}"; do quoted+=" $(printf '%q' "$a")"; done
  mounts=()
  while IFS= read -r mount; do mounts+=("$mount"); done \
    < <(container_mounts "$repo_root" "$cache" "$out_dir" "$payload")
  # Keep dnf's downloads between builds: a Fedora package set is ~100 MB, and
  # re-downloading it on every attempt is the slowest part of this script.
  mkdir -p "$cache/dnf"
  mounts+=(-v "$cache/dnf:/var/cache/dnf")
  if [ -n "$zig_cache" ]; then mounts+=(-v "$zig_cache:$zig_cache:ro"); fi
  exec "$engine" run --rm "${mounts[@]}" \
    "$builder_image" \
    sh -euc "dnf -q -y install $builder_packages >/dev/null && exec bash $self_path$quoted"
fi

[ -n "$out" ] || fail "--out IMG is required"
[ -n "$agent_bin" ] || agent_bin="$repo_root/zig-out/bin/pabrik-vm-agent"
[ -n "$bootstrap_bin" ] || bootstrap_bin="$repo_root/zig-out/bin/pabrik-vm-bootstrap"
[ -n "$probe_bin" ] || probe_bin="$repo_root/zig-out/bin/pabrik-probe"
[ -n "$netd_bin" ] || netd_bin="$repo_root/zig-out/bin/pabrik-vm-netd"
[ "$netd_given" = 0 ] || [ -f "$netd_bin" ] || fail "no forwarder at $netd_bin"
[ "$probe_given" = 0 ] || [ -f "$probe_bin" ] || fail "no probe fixture at $probe_bin"

command -v mkfs.ext4 >/dev/null || fail "mkfs.ext4 missing (e2fsprogs)"
command -v e2fsck >/dev/null || fail "e2fsck missing (e2fsprogs)"
command -v sha256sum >/dev/null || fail "sha256sum missing"
command -v curl >/dev/null || command -v wget >/dev/null || fail "curl or wget missing"
[ -f "$agent_bin" ] || fail "no agent at $agent_bin - run 'zig build vm' first"
[ -f "$bootstrap_bin" ] || fail "no bootstrap at $bootstrap_bin - run 'zig build vm' first"
if ! host_can_install; then
  fail "installing packages needs dnf and root inside the builder: run with --in-container"
fi

payload="$(payload_dir "$payload")" || fail "the payload above is not usable"
plan="$(manifest_plan "$manifest" "$tier")" || fail "the manifest above is not usable for tier $tier"

work="$(dirname "$out")/rootfs"
rm -rf "$work"
mkdir -p "$work" "$cache" "$(dirname "$out")"

# A Fedora release artifact is an OCI image archive, not a rootfs tarball:
# index.json names the image manifest, and that manifest's one layer IS the
# rootfs. Unpacking it here (as root) is also what records 0:0 ownership.
unpack_oci() { # <archive> <dest>
  local archive="$1" dest="$2" tmp manifest blob layer magic rc
  tmp="$(mktemp -d)" || return 1
  if ! tar -xf "$archive" -C "$tmp" 2>/dev/null; then
    rm -rf "$tmp"
    return 1
  fi
  manifest="$(sed -n 's/.*"digest":"\(sha256:[0-9a-f]\{64\}\)".*/\1/p' "$tmp/index.json" 2>/dev/null | head -1)"
  blob="$tmp/blobs/sha256/${manifest#sha256:}"
  if [ -z "$manifest" ] || [ ! -f "$blob" ]; then
    rm -rf "$tmp"
    return 1
  fi
  # Exactly two digests in the manifest: the config and the one layer. Any other
  # shape is an image this script has not been taught, so it refuses rather than
  # unpacking half a rootfs.
  if [ "$(grep -o '"digest":"sha256:[0-9a-f]\{64\}"' "$blob" | wc -l)" -ne 2 ]; then
    rm -rf "$tmp"
    return 1
  fi
  layer="$tmp/blobs/sha256/$(sed -n 's/.*"digest":"\(sha256:[0-9a-f]\{64\}\)".*/\1/p' "$blob" | tail -1 | sed 's/^sha256://')"
  if [ ! -f "$layer" ]; then
    rm -rf "$tmp"
    return 1
  fi
  magic="$(head -c2 "$layer" | od -An -tx1 | tr -d ' \n')"
  case "$magic" in
    1f8b) tar -xzf "$layer" -C "$dest" ;;
    *) tar -xf "$layer" -C "$dest" ;;
  esac
  rc=$?
  rm -rf "$tmp"
  return $rc
}

# ─── fetch, verify, then act on the role ─────────────────────────────────
while read -r role hash url; do
  [ -n "$role" ] || continue
  file="$cache/$(basename "$url")"
  if [ ! -f "$file" ]; then
    say "fetching $(basename "$url")"
    if command -v curl >/dev/null; then
      curl -fsSL --max-time "$fetch_timeout" -o "$file.part" "$url" || fail "download failed: $url"
    else
      wget -q -T "$fetch_timeout" -O "$file.part" "$url" || fail "download failed: $url"
    fi
    mv "$file.part" "$file"
  fi
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  [ "$actual" = "$hash" ] || fail "sha256 mismatch for $(basename "$url"): manifest=$hash actual=$actual"
  say "verified $(basename "$url") sha256=${hash:0:16}"
  case "$(basename "$url")" in
    *.oci.tar.xz | *.oci.tar) unpack_oci "$file" "$work" ;;
    *) tar -xf "$file" -C "$work" ;;
  esac || fail "extracting $(basename "$url") failed"
done <<<"$plan"

# Fedora's /bin is a symlink into /usr/bin, so the assertion is about the shell
# the agent's tty and every `exec /bin/sh` resolve to, not a busybox path.
[ -x "$work/usr/bin/bash" ] || fail "the extracted rootfs has no /usr/bin/bash"
[ -e "$work/usr/bin/dnf" ] || fail "the extracted rootfs has no dnf, so no packages can be added"

rpms="$(tier_rpms "$tier")"
say "installing the $tier package set with dnf --installroot"
printf '%s\n' "$rpms" | sed 's/^/    /'
# shellcheck disable=SC2086  # deliberate word list
# Parallel downloads: a package set this size on one connection is the slowest
# thing this script does, and dnf's default of 3 leaves the mirror idle.
if ! dnf -q -y --installroot="$work" --releasever="$fedora_release" \
    --setopt=install_weak_deps=False --setopt=max_parallel_downloads=10 \
    "${dnf_repo_args[@]}" install $rpms >"$work.dnf.log" 2>&1; then
  tail -25 "$work.dnf.log" >&2
  fail "dnf could not install the package set"
fi
say "dnf installed $(rpm --root "$work" -qa | wc -l) packages in total"
# Provenance: what this image actually holds. The rootfs is hash-pinned; the
# packages are this list resolved against Fedora 41 on the day of the build.
rpm --root "$work" -qa --qf '%{name}-%{version}-%{release}.%{arch}\n' | sort \
  >"$work/etc/pabrik-image-rpms"

# ─── our own side ────────────────────────────────────────────────────────
# /init is the BOOTSTRAP: it asks the host for the current agent and execs
# it, so a workspace's disk never carries the agent (src/vm_agent/bootstrap.zig).
# The agent itself stays on the disk as /init.agent — the bootstrap's fallback
# when the host does not answer.
cp "$bootstrap_bin" "$work/init"
chmod +x "$work/init"
cp "$agent_bin" "$work/init.agent"
chmod +x "$work/init.agent"
if [ -f "$netd_bin" ]; then
  mkdir -p "$work/usr/bin"
  cp "$netd_bin" "$work/usr/bin/pabrik-vm-netd"
  chmod +x "$work/usr/bin/pabrik-vm-netd"
elif [ "$netd_given" = 1 ]; then
  fail "the forwarder was named but is not there: $netd_bin"
else
  say "no forwarder: $netd_bin is absent, so the guest has no egress and no resolver"
fi

if [ -f "$probe_bin" ]; then
  cp "$probe_bin" "$work/bin/pabrik-probe"
  chmod +x "$work/bin/pabrik-probe"
elif [ "$probe_given" = 1 ]; then
  fail "the probe was named but is not there: $probe_bin"
else
  say "no probe fixture: $probe_bin is absent, so /bin/pabrik-probe is not in this image"
fi

if [ -n "$payload" ]; then
  mkdir -p "$work/opt/bench"
  cp -a "$payload/." "$work/opt/bench/"
  say "payload $(find "$work/opt/bench" -mindepth 1 | wc -l) filesystem objects in /opt/bench from $payload"
fi

# A warm Zig package cache. Zig's package fetcher does not read http_proxy (its
# `initDefaultProxies` has no callers in the compiler's own fetch path), so a
# `zig build` in the workspace cannot reach github through the egress tunnel at
# all. Shipping the packages it would fetch makes the build work with no network
# — `ZIG_GLOBAL_CACHE_DIR` points here (see src/vm_agent/main.zig `exec_env`).
if [ -n "$zig_cache" ]; then
  mkdir -p "$work/opt/zig-cache/p"
  if [ -d "$zig_cache/p" ]; then
    cp -f "$zig_cache"/p/*.tar.gz "$work/opt/zig-cache/p/" 2>/dev/null || true
  fi
  say "zig package cache: $(find "$work/opt/zig-cache" -type f | wc -l) archives in /opt/zig-cache"
fi

mkdir -p "$work/workspace" "$work/proc" "$work/sys" "$work/dev" "$work/tmp"

# ─── assemble ────────────────────────────────────────────────────────────
if [ "$(id -u)" = 0 ]; then
  # `cp -a` keeps the payload's owner, which is the caller, so a root build
  # has to hand /opt/bench back to root the same way it asserts the base.
  if [ -n "$payload" ]; then
    chown -R 0:0 "$work/opt/bench"
    [ "$(stat -c '%u:%g' "$work/opt/bench")" = "0:0" ] \
      || fail "a root build must own /opt/bench as 0:0, and it is $(stat -c '%u:%g' "$work/opt/bench")"
  fi
  [ "$(stat -c '%u:%g' "$work/usr/bin/bash")" = "0:0" ] \
    || fail "a root build must own the base as 0:0, and /usr/bin/bash is $(stat -c '%u:%g' "$work/usr/bin/bash")"
  chown "$guest_uid:$guest_gid" "$work/workspace"
  [ "$(stat -c '%u:%g' "$work/workspace")" = "$guest_uid:$guest_gid" ] \
    || fail "a root build must own /workspace as $guest_uid:$guest_gid, and it is $(stat -c '%u:%g' "$work/workspace")"
  [ "$(stat -c '%u:%g' "$work/init")" = "0:0" ] \
    || fail "a root build must own /init as 0:0"
  say "base owned by 0:0, as a shippable image requires"
fi

rm -f "$out"
truncate -s "$size" "$out"
mkfs.ext4 -q -F -L pabrik-guest -d "$work" "$out"
e2fsck -fn "$out" >/dev/null || fail "the assembled image is not clean"

say "tier    $tier"
say "image   $out ($size, sha256=$(sha256sum "$out" | cut -d' ' -f1))"
say "agent   $(stat -c '%s bytes, owner %u:%g' "$work/init"), sha256=$(sha256sum "$work/init" | cut -d' ' -f1)"
say "entries $(find "$work" -mindepth 1 | wc -l) filesystem objects"
say "OK $out ready"
