#!/usr/bin/env bash
# Assemble the guest rootfs image: pinned artifacts from guest-image.manifest,
# plus `pabrik-vm-agent` as /init, the in-guest network forwarder, and
# (optionally) the protocol probe fixture.
#
# Nothing here compiles Zig. `zig build vm` produces the two binaries and this
# script refuses to invent its own command line for them, so the image hash
# transitively pins the agent's source the same way it pins the Alpine bytes.
#
# Ownership: restoring root ownership needs root, so a shippable image is built
# with `--in-container`, which re-runs this script inside a pinned Alpine image.
# Rootless it still builds, but the whole base lands owned by the calling uid and
# the script says so.
#
# Usage: scripts/build-guest-image.sh --out IMG [--tier base|dev]
#                                     [--agent BIN] [--probe BIN] [--netd BIN]
#                                     [--size SIZE]
#                                     [--payload DIR] [--cache DIR]
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

# The uid and gid the guest agent runs a workload as (src/vm_agent/main.zig,
# `default_uid`). /workspace is that workload's $HOME and the directory whose
# contents persist, so a root build has to hand it over (plan §28).
guest_uid=1000
guest_gid=1000
size=""
cache="${PABRIK_VM_CACHE:-$HOME/.cache/pabrik-vm}"
in_container=0
builder_image="docker.io/library/alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6"
builder_packages="bash=5.3.9-r1 e2fsprogs=1.47.4-r0"
fetch_timeout=300

say() { printf '[guest-image] %s\n' "$*"; }
fail() { printf '[guest-image] FAIL %s\n' "$*" >&2; exit 1; }

default_size() {
  case "$1" in
    dev) printf '2048M\n' ;;
    *) printf '128M\n' ;;
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
      rootfs) ;;
      dev)
        case "$want" in dev) ;; *) continue ;; esac
        case "$url" in
          *.apk) ;;
          *)
            printf 'manifest: the dev role is for apk packages, and %s is not one\n' "$url" >&2
            return 1
            ;;
        esac
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

run_selftest() {
  local tmp ok=0 bad=0 h1 h2 u1 u2
  tmp="$(mktemp -d)"
  h1="c5ca053cfe1d85c5b96dff8b9bc57045f7f184a30ffb6b65776409ca90388677"
  h2="0e626fa97cf937fda7bba4ed4dde8e2f2dbb5083ac34e02180cec0c4eba9351b"
  u1="https://example.invalid/base.tar.gz"
  u2="https://example.invalid/thing.apk"
  printf '%s  %s\n%s  %s  dev\n' "$h1" "$u1" "$h2" "$u2" >"$tmp/good"
  printf '%s  %s\n' "${h1:0:63}" "$u1" >"$tmp/short"
  printf '%s  %s\n' "$(printf '%s' "$h1" | tr 'a-f' 'A-F')" "$u1" >"$tmp/upper"
  printf '%s  %s  weird\n' "$h1" "$u1" >"$tmp/role"
  printf '%s  %s  dev\n' "$h1" "$u1" >"$tmp/dev-tar"
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
  check "the base tier takes the extracted rootfs artifact" \
    "rootfs $h1 $u1" "$(manifest_plan "$tmp/good" base)"
  check "the dev tier adds the pinned package" \
    "$(printf 'rootfs %s %s\ndev %s %s' "$h1" "$u1" "$h2" "$u2")" \
    "$(manifest_plan "$tmp/good" dev)"
  rejects "a 63-char checksum" "$tmp/short" base
  rejects "an uppercase checksum" "$tmp/upper" base
  rejects "an unknown role" "$tmp/role" base
  rejects "a dev entry that is not an apk" "$tmp/dev-tar" dev
  rejects "a fourth column" "$tmp/columns" base
  rejects "a comment-only manifest" "$tmp/empty" dev
  rejects "an entry with no URL" "$tmp/no-url" base
  check "the base image default size" "128M" "$(default_size base)"
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

  check "the committed manifest pins exactly one extracted base" "1" \
    "$(manifest_plan "$manifest" dev | grep -c '^rootfs ')"
  check "every committed dev entry is an apk package" "0" \
    "$(manifest_plan "$manifest" dev | awk '$1 == "dev" && $3 !~ /\.apk$/ { n++ } END { print n + 0 }')"
  check "the committed dev set carries git nodejs python3 rust and zig" "5" \
    "$(manifest_plan "$manifest" dev | awk '$1 == "dev" { print $3 }' \
      | grep -cE '/(git|nodejs|python3|rust|zig)-[0-9]')"

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
[ -n "$out" ] || fail "--out IMG is required"

if [ "$in_container" = 1 ] && [ "$(id -u)" != 0 ]; then
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
  quoted=""
  for a in "${args[@]}"; do quoted+=" $(printf '%q' "$a")"; done
  mounts=()
  while IFS= read -r mount; do mounts+=("$mount"); done \
    < <(container_mounts "$repo_root" "$cache" "$out_dir" "$payload")
  exec "$engine" run --rm "${mounts[@]}" \
    "$builder_image" \
    sh -euc "apk add --no-cache $builder_packages >/dev/null && exec bash $self_path$quoted"
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
if [ "$tier" = dev ]; then
  command -v apk >/dev/null || fail "the dev tier installs its packages with apk-tools; run with --in-container"
  [ "$(id -u)" = 0 ] || fail "the dev tier needs root to set package ownership in the rootfs; run with --in-container"
fi

payload="$(payload_dir "$payload")" || fail "the payload above is not usable"
plan="$(manifest_plan "$manifest" "$tier")" || fail "the manifest above is not usable for tier $tier"

work="$(dirname "$out")/rootfs"
rm -rf "$work"
mkdir -p "$work" "$cache" "$(dirname "$out")"

# ─── fetch, verify, then act on the role ─────────────────────────────────
packages=()
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
  case "$role" in
    dev)
      say "verified $(basename "$url") sha256=${hash:0:16} (dev package)"
      packages+=("$file")
      ;;
    rootfs)
      say "verified $(basename "$url") sha256=${hash:0:16}"
      extract=(-xzf "$file" -C "$work")
      [ "$(id -u)" = 0 ] || extract+=(--no-same-owner)
      tar "${extract[@]}" || fail "extracting $(basename "$url") failed"
      ;;
  esac
done <<<"$plan"

# /bin/sh is an ABSOLUTE symlink to /bin/busybox, so a host-side -x on it
# follows the HOST path and lies. Check the real file instead.
[ -f "$work/bin/busybox" ] || fail "the extracted rootfs has no /bin/busybox"

if [ "${#packages[@]}" -gt 0 ]; then
  say "installing ${#packages[@]} pinned packages with apk add --root"
  # No repository at all, so these FILES are the only source apk may pick from,
  # and `--force-non-repository` is apk's own way of being told "install them
  # anyway". Alpine's signature still verifies against the builder's keyring.
  apk add --root "$work" --repositories-file /dev/null --no-network --force-non-repository \
    "${packages[@]}" || fail "apk could not install the pinned package set"
fi

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
  [ "$(stat -c '%u:%g' "$work/bin/busybox")" = "0:0" ] \
    || fail "a root build must own the base as 0:0, and /bin/busybox is $(stat -c '%u:%g' "$work/bin/busybox")"
  chown "$guest_uid:$guest_gid" "$work/workspace"
  [ "$(stat -c '%u:%g' "$work/workspace")" = "$guest_uid:$guest_gid" ] \
    || fail "a root build must own /workspace as $guest_uid:$guest_gid, and it is $(stat -c '%u:%g' "$work/workspace")"
  [ "$(stat -c '%u:%g' "$work/init")" = "0:0" ] \
    || fail "a root build must own /init as 0:0"
  say "base owned by 0:0, as a shippable image requires"
else
  say "WARNING /workspace will be owned by uid $(id -u), and the guest workload is uid $guest_uid"
  say "WARNING built unprivileged: base files are owned by uid $(id -u), so a"
  say "WARNING uid-$(id -u) workload inside the guest can rewrite the base. Use --in-container."
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
