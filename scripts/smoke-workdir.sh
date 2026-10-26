#!/usr/bin/env bash
# Shared by the VM smokes: remove a work dir that holds an extracted guest rootfs.
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
