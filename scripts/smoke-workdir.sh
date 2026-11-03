#!/usr/bin/env bash
# Shared by the VM smokes: remove a work dir that holds an extracted guest rootfs,
# and keep the guest image cache out of that work dir.
#
# WHY A PLAIN `rm -rf` IS NOT ENOUGH
# ----------------------------------
# `build-guest-image.sh` unpacks the guest rootfs with `tar -xf` and never
# rewrites the modes afterwards, so the staging tree keeps the container image's
# own permissions — on Fedora `/usr/bin`, `/usr/lib`, `/usr/lib64` and
# `/usr/sbin` are 0555. Unlinking an entry needs WRITE on its PARENT directory,
# so `rm -rf` over that tree fails with `Permission denied` even though every
# file in it belongs to the runner user.
#
# Every smoke runs under `set -euo pipefail`, so one such failure turns a green
# test into a red job — and the tree that refused to go stays behind, so the
# NEXT run dies in its own pre-run wipe before it asserts anything. That is
# exactly what happened to `ci-vm-smoke` from 2026-10-25 on: the guest image
# became Fedora in #1045, and every run since has been red in the wipe rather
# than in a test.
#
# `chmod -R u+rwX` re-opens the directories we own, after which the same
# `rm -rf` succeeds. The plain `rm -rf` stays first: it is the fast path, and it
# is the only one that runs when the tree was never read-only.
pabrik_wipe_workdir() {
  local dir="${1:?pabrik_wipe_workdir needs a directory}"
  [ -e "$dir" ] || return 0
  if rm -rf "$dir" 2>/dev/null; then
    return 0
  fi
  chmod -R u+rwX "$dir" 2>/dev/null || true
  rm -rf "$dir"
}

# Where `build-guest-image.sh` keeps the pinned rootfs, the rpms and the assembled
# images (the same default it derives itself). A smoke resolves this BEFORE it
# replaces HOME: the replacement HOME exists to keep pabrik's config and database
# out of the run, and a cache derived from it is a cache inside the throwaway work
# dir — every run then re-downloads the Fedora rootfs and the whole package set,
# which is minutes of the runner's bandwidth for bytes already on its disk.
pabrik_vm_cache_root() {
  printf '%s\n' "${PABRIK_VM_CACHE:-$HOME/.cache/pabrik-vm}"
}

# Assemble the guest image and report the cache decision this run took. The build
# prints `cache hit|miss` itself, and the two --saas smokes used to hide it behind
# `tail -1` and `/dev/null`, so no CI log could say whether a job had downloaded
# Fedora or reused the image it already had.
pabrik_build_guest_image() { # <repo root> <out image>
  local repo="${1:?pabrik_build_guest_image needs the repo root}"
  local out="${2:?pabrik_build_guest_image needs an output image}"
  local log state
  log="$(dirname "$out")/guest-image.log"
  "$repo/scripts/build-guest-image.sh" --out "$out" >"$log" 2>&1 || {
    tail -n 25 "$log" >&2
    return 1
  }
  state="$(grep -m1 -oE 'cache (hit|miss)' "$log" || true)"
  printf '%s at %s\n' "${state:-image cache disabled}" "$(pabrik_vm_cache_root)"
}
