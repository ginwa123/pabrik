#!/usr/bin/env bash
# Assert what a guest image actually ships, by reading the image itself — no
# root, no loop mount, no VM. This is the outside view `build-guest-image.sh`
# cannot take of its own output, and the one CI can run on a hosted runner.
#
# The checks that matter are ownership (a rootless build leaves the whole base
# owned by the builder's uid, so a guest workload could rewrite /bin/busybox)
# and presence (the tier's own binaries really are in the sealed disk).
#
# Usage: scripts/check-guest-image.sh --image IMG [--tier base|dev]
#                                     [--require PATH] [--selftest]

set -euo pipefail

image=""
tier="base"
extra=()
selftest=0

say() { printf '[check-image] %s\n' "$*"; }
fail() { printf '[check-image] FAIL %s\n' "$*" >&2; exit 1; }

# `debugfs stat` prints `Type: symlink`, `Mode:  0777` and `User:     0   Group:     0`
# on three lines. Parsed here rather than read ad hoc at each call site, because
# this is the shape an e2fsprogs upgrade would change.
parse_stat() { # stdin: debugfs stat output -> `type mode owner`
  awk '
    /^Inode:/ { type = $4; mode = $6 }
    /^User:/ { owner = $2 ":" $4 }
    END { if (type == "" || mode == "") exit 1; print type, mode, owner }
  '
}

read_stat() { # <path> -> sets stat_type, stat_mode, stat_owner
  local dump fields
  dump="$(debugfs -R "stat $1" "$image" 2>&1)" || fail "debugfs could not read $1"
  case "$dump" in *"File not found"*) fail "$1 is not in the image" ;; esac
  if ! fields="$(printf '%s\n' "$dump" | parse_stat)"; then
    fail "could not read $1's inode fields from: $dump"
  fi
  read -r stat_type stat_mode stat_owner <<<"$fields"
}

expect() { # <path> <type> <owner>
  read_stat "$1"
  [ "$stat_type" = "$2" ] || fail "$1 is a $stat_type, expected a $2"
  [ "$stat_owner" = "$3" ] || fail "$1 is owned by $stat_owner, expected $3"
  say "ok  $1 $stat_type $stat_mode $stat_owner"
}

expect_owned() { # <path> <owner> — exists and is the owner's, whatever its type
  read_stat "$1"
  [ "$stat_owner" = "$2" ] || fail "$1 is owned by $stat_owner, expected $2"
  say "ok  $1 $stat_type $stat_mode $stat_owner"
}

run_selftest() {
  local ok=0 bad=0 regular symlink
  regular="$(printf 'Inode: 18   Type: regular    Mode:  0755   Flags: 0x80000\nUser:     0   Group:     0   Project:     0   Size: 804616\n' | parse_stat)"
  symlink="$(printf 'Inode: 83   Type: symlink    Mode:  0777   Flags: 0x0\nUser:     0   Group:     0   Project:     0   Size: 12\n' | parse_stat)"

  check() { # <what> <expected> <actual>
    if [ "$2" = "$3" ]; then
      ok=$((ok + 1))
      printf '  ok   %s\n' "$1"
    else
      bad=$((bad + 1))
      printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"
    fi
  }
  check "a root-owned regular file reads as regular 0755 0:0" "regular 0755 0:0" "$regular"
  check "a fast symlink reads as symlink 0777 0:0" "symlink 0777 0:0" "$symlink"
  if printf 'debugfs 1.47.4 (6-Mar-2025)\n' | parse_stat >/dev/null 2>&1; then
    bad=$((bad + 1)); printf '  FAIL an output with no inode fields was accepted\n'
  else
    ok=$((ok + 1)); printf '  ok   an output with no inode fields is refused\n'
  fi
  printf '[check-image] selftest: %d ok, %d failed\n' "$ok" "$bad"
  [ "$bad" -eq 0 ] || exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --image) image="$2"; shift 2 ;;
    --tier) tier="$2"; shift 2 ;;
    --require) extra+=("$2"); shift 2 ;;
    --selftest) selftest=1; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done

if [ "$selftest" = 1 ]; then
  run_selftest
  exit 0
fi

case "$tier" in base|dev) ;; *) fail "--tier must be base or dev, not $tier" ;; esac
[ -n "$image" ] || fail "--image IMG is required"
[ -f "$image" ] || fail "no image at $image"
command -v debugfs >/dev/null || fail "debugfs missing (e2fsprogs)"

# Every path the guest boots through, plus the tier's own payload. The dev
# payload may be a binary or a symlink to one, so only ownership is asserted.
payload=()
if [ "$tier" = dev ]; then
  payload+=(/usr/bin/git /usr/bin/node /usr/bin/python3 /usr/bin/cargo /usr/bin/zig)
fi
# The in-guest network forwarder is the guest's only way out of the VM.
payload+=(/usr/bin/pabrik-vm-netd)
payload+=("${extra[@]:-}")

say "image $image sha256=$(sha256sum "$image" | cut -d' ' -f1)"
say "tier  $tier"
expect /init regular 0:0
[ "$stat_mode" = 0755 ] || fail "/init is mode $stat_mode, and the kernel needs 0755"
expect /bin/busybox regular 0:0
expect /bin/sh symlink 0:0
# A root build that never hands the tenant's own directory over leaves it 0:0.
expect /workspace directory 1000:1000

for path in "${payload[@]}"; do
  [ -n "$path" ] || continue
  expect_owned "$path" 0:0
done

say "OK $image is a $tier image, owned by root, with every required path present"
