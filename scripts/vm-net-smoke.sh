#!/usr/bin/env bash
# P4 network smoke — the guest's forwarder, the host's egress + resolver proxy
# and the preview tunnel, against a live microVM.
#
# Needs /dev/kvm (Firecracker) and e2fsprogs. No tap, no root, no iptables.
#
# Proves WITHOUT any internet access:
#   1. netd starts in the guest, brings `lo` up, writes /etc/resolv.conf and
#      listens on 127.0.0.1:3128 / 127.0.0.1:53
#   2. a guest dial to 127.0.0.1:8081 (the control plane's port) is refused by
#      the HOST's egress proxy, and the audit log says why
#   3. a guest dial to a host the workspace did not declare is refused too
#   4. the guest resolver gets a real answer over vsock (SERVFAIL still proves
#      the tunnel; a name that resolves to an internal address is REFUSED)
#   5. the preview tunnel: proxy.exchange over the daemon's socket → the guest's
#      `port.forward` → a TCP server inside the guest
# With internet it additionally does a public GET and a real lookup.
#
# Env: FC_BIN, GUEST_KERNEL, PABRIK_VM_WORKDIR

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fc_bin="${FC_BIN:-$HOME/firecracker-demo/firecracker}"
guest_kernel="${GUEST_KERNEL:-$HOME/firecracker-demo/vmlinux-6.18.51}"
work="${PABRIK_VM_WORKDIR:-${TMPDIR:-/tmp}/pabrik-vm-net-smoke}"
vms="$work/vms"
sock="$work/vmd.sock"
ws="demo"
image="$work/base.ext4"
vmd="$repo_root/zig-out/bin/pabrik-vmd"
daemon_pid=""

say() { printf '\n==> %s\n' "$*"; }
ok() { printf '    ok: %s\n' "$*"; }
fail() {
  printf '\nFAIL %s\n' "$*" >&2
  printf 'daemon log:   %s\n' "$work/vmd.log" >&2
  printf 'serial log:   %s\n' "$vms/workspaces/$ws/serial.log" >&2
  exit 1
}

cleanup() {
  if [ -n "$daemon_pid" ]; then
    PABRIK_VM_DIR="$vms" "$vmd" stop --socket "$sock" --workspace-id "$ws" >/dev/null 2>&1 || true
    kill "$daemon_pid" >/dev/null 2>&1 || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

[ -c /dev/kvm ] || fail "/dev/kvm is missing: Firecracker needs it"
[ -x "$fc_bin" ] || fail "no firecracker at $fc_bin (set FC_BIN)"
[ -f "$guest_kernel" ] || fail "no kernel at $guest_kernel (set GUEST_KERNEL)"
rm -rf "$work"
mkdir -p "$work"

say "build the VM trio and the daemon"
(cd "$repo_root" && zig build vm -Doptimize=ReleaseSmall)
(cd "$repo_root" && zig build vmd -Doptimize=ReleaseSafe)
[ -x "$repo_root/zig-out/bin/pabrik-vm-netd" ] || fail "zig build vm did not produce pabrik-vm-netd"
[ -x "$vmd" ] || fail "zig build vmd did not produce $vmd"

say "guest image (base tier, rootless)"
"$repo_root/scripts/build-guest-image.sh" --out "$image" --size 128M >/dev/null
# The image must carry the forwarder, or the guest has no way out at all.
debugfs -R 'stat /usr/bin/pabrik-vm-netd' "$image" 2>/dev/null | grep -q 'Type: regular' \
  || fail "the image has no /usr/bin/pabrik-vm-netd"
ok "image ships /usr/bin/pabrik-vm-netd"

say "start pabrik-vmd (it binds the two guest-initiated vsock sockets)"
PABRIK_VM_DIR="$vms" "$vmd" serve --socket "$sock" --base-image "$image" \
  --kernel "$guest_kernel" --fc "$fc_bin" --sweep-interval-ms 1000 \
  >>"$work/vmd.log" 2>&1 &
daemon_pid=$!
for _ in $(seq 1 100); do
  [ -S "$sock" ] && break
  sleep 0.05
done
[ -S "$sock" ] || fail "the daemon never created $sock"

exec_in() {
  PABRIK_VM_DIR="$vms" "$vmd" exec --socket "$sock" --workspace-id "$ws" \
    --timeout-ms 60000 -- "$@"
}

say "boot the workspace and check what netd set up"
out="$(exec_in /bin/sh -c 'id -u; cat /etc/resolv.conf; busybox --list | grep -c .' 2>/dev/null)"
printf '%s\n' "$out" | sed 's/^/    /'
printf '%s\n' "$out" | head -1 | grep -qx 1000 || fail "the guest workload is not uid 1000"
printf '%s\n' "$out" | grep -q '^nameserver 127.0.0.1$' || fail "netd did not write /etc/resolv.conf"

serial="$vms/workspaces/$ws/serial.log"
for want in 'netd started' 'lo up' 'proxy listening on 127.0.0.1:3128' 'dns listening on 127.0.0.1:53'; do
  grep -q "$want" "$serial" || fail "the guest serial log never said '$want'"
done
ok "netd started, loopback up, proxy and resolver listening"

flags="$(exec_in /bin/sh -c 'cat /sys/class/net/lo/flags 2>/dev/null || echo none' 2>/dev/null | tail -1 || true)"
case "$flags" in
  0x9|0x1009) ok "guest loopback is UP (flags=$flags)" ;;
  *) fail "guest loopback flags are '$flags', expected 0x9 (UP|LOOPBACK)" ;;
esac

egress_log="$vms/workspaces/$ws/egress.log"
say "the workspace declares one destination"
printf 'example.com 80\n' >"$vms/workspaces/$ws/egress.allow"

say "a dial to the control plane's own port is refused by the host"
exec_in /bin/sh -c \
  'http_proxy=http://127.0.0.1:3128 wget -q -O- -T 5 http://127.0.0.1:8081/health 2>&1 || echo refused' \
  >"$work/probe-cp.txt" 2>&1 || true
cat "$work/probe-cp.txt" | sed 's/^/    /'
grep -qi 'refused\|403\|forbidden' "$work/probe-cp.txt" || fail "the dial to 127.0.0.1:8081 was not refused"
grep -q 'outcome=host listener' "$egress_log" || fail "the audit log has no 'host listener' refusal"
ok "refused by policy, and the audit log agrees"

say "a dial to an undeclared host is refused before any resolution"
exec_in /bin/sh -c \
  'http_proxy=http://127.0.0.1:3128 wget -q -O- -T 5 http://not.declared.example/ 2>&1 || echo refused' \
  >"$work/probe-undeclared.txt" 2>&1 || true
grep -q 'outcome=not declared' "$egress_log" || fail "the undeclared host was not refused"
ok "refused as undeclared"

say "the guest hands the egress proxy to the workload, with no env of its own"
out="$(exec_in /bin/sh -c 'printf "%s\n" "$http_proxy" "$https_proxy" "$no_proxy"' 2>/dev/null)"
printf '%s\n' "$out" | sed 's/^/    /'
printf '%s\n' "$out" | grep -qx 'http://127.0.0.1:3128' \
  || fail "the workload's own env has no http_proxy, so nothing can use the tunnel"
login_out="$(exec_in /bin/sh -l -c 'printf "%s" "$https_proxy"' 2>/dev/null | tail -1)"
[ "$login_out" = "http://127.0.0.1:3128" ] \
  || fail "a login shell did not source /etc/profile.d/pabrik-egress.sh (got '$login_out')"
exec_in /bin/sh -c 'git --version' >"$work/probe-git.txt" 2>&1 \
  || fail "the image has no git: a workspace could not clone anything"
head -1 "$work/probe-git.txt" | sed 's/^/    /'
ok "exec env, the login-shell profile and git are all in the base tier"

say "a declared host is resolved on the host and dialled"
host_has_net=0
curl -sS -m 5 -o /dev/null http://example.com/ >/dev/null 2>&1 && host_has_net=1
if [ "$host_has_net" = 1 ]; then
  # No `http_proxy=` on this command line: the guest has to supply it.
  exec_in /bin/sh -c 'wget -q -O- -T 15 http://example.com/ 2>&1 | head -c 200' \
    >"$work/probe-public.txt" 2>&1 || true
  head -c 200 "$work/probe-public.txt" | sed 's/^/    /'
  grep -q 'outcome=allowed' "$egress_log" || fail "the public GET was not allowed"
  grep -qi '<html\|<!doctype\|example' "$work/probe-public.txt" || fail "the public GET returned nothing"
  ok "public GET with no manual env: the guest supplied the proxy"

  say "a CONNECT that pipelines its request gets an answer (TLS starts this way)"
  # A TLS client may send CONNECT and its ClientHello in one write; anything
  # that arrived with the head has to reach the tunnel or the handshake hangs
  # with a 200 and no reply. Port 80 exercises the same path with plain HTTP.
  exec_in /bin/sh -c \
    'printf "CONNECT example.com:80 HTTP/1.1\r\nHost: example.com\r\n\r\nGET / HTTP/1.0\r\nHost: example.com\r\n\r\n" | timeout 20 nc 127.0.0.1 3128 | head -c 900' \
    >"$work/probe-pipelined-connect.txt" 2>&1 || true
  tr -d '\r' <"$work/probe-pipelined-connect.txt" | grep -E 'Connection Established|title' | head -3 | sed 's/^/    /'
  grep -q 'Connection Established' "$work/probe-pipelined-connect.txt" \
    || fail "the pipelined CONNECT was not established"
  # The body is the proof: it can only arrive if the pipelined request reached
  # the origin, which is exactly what used to be dropped.
  grep -qi 'Example Domain' "$work/probe-pipelined-connect.txt" \
    || fail "the request pipelined behind CONNECT never reached the origin"
else
  echo "    (this host has no internet: skipping the public GET)"
fi

say "the guest resolver answers over vsock (or answers SERVFAIL, which is an answer)"
exec_in /bin/sh -c 'nslookup example.com 127.0.0.1 2>&1 | head -5' >"$work/probe-dns.txt" 2>&1 || true
cat "$work/probe-dns.txt" | sed 's/^/    /'
grep -qi 'address\|servfail\|nxdomain\|name:' "$work/probe-dns.txt" \
  || fail "the guest resolver produced no answer at all: $(cat "$work/probe-dns.txt")"
grep -q 'dns=' "$egress_log" || fail "the audit log has no resolver line"
ok "the resolver answered through the host"

say "the preview tunnel: proxy.exchange -> the guest's port.forward -> a guest server"
# A DETACHED job, because the agent's frame loop is serial: a foreground exec
# would hold the one connection every other guest op has to share.
PABRIK_VM_DIR="$vms" "$vmd" spawn --socket "$sock" --workspace-id "$ws" --log-name ncsrv -- \
  /bin/sh -c "while true; do printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 11\r\n\r\nhello there' | nc -l -p 3000; done" \
  >/dev/null 2>&1 || fail "could not start the guest's test server"
sleep 3
printf '3000\n' >"$vms/workspaces/$ws/preview.ports"
python3 - "$sock" "$ws" <<'PY' >"$work/probe-preview.txt" 2>&1 || true
import json, socket, struct, sys

sock_path, workspace = sys.argv[1], sys.argv[2]
request = b"GET / HTTP/1.1\r\nHost: 127.0.0.1:3000\r\nConnection: close\r\n\r\n"
body = json.dumps({
    "type": "proxy.exchange",
    "id": 1,
    "workspace_id": workspace,
    "port": 3000,
    "data_b64": __import__("base64").b64encode(request).decode(),
}).encode()
wire = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
wire.settimeout(60)
wire.connect(sock_path)
wire.sendall(struct.pack(">I", len(body)) + body)
def read_exact(n):
    out = b""
    while len(out) < n:
        chunk = wire.recv(n - len(out))
        if not chunk:
            raise SystemExit("the daemon closed the connection")
        out += chunk
    return out
(length,) = struct.unpack(">I", read_exact(4))
reply = json.loads(read_exact(length).decode())
if reply.get("type") != "proxy.exchange.ok":
    raise SystemExit("daemon refused: %s" % reply)
sys.stdout.buffer.write(__import__("base64").b64decode(reply["data_b64"]))
PY
cat "$work/probe-preview.txt" | head -5 | sed 's/^/    /'
grep -q '200 OK' "$work/probe-preview.txt" || fail "the preview tunnel returned no HTTP response"
grep -qi 'hello there' "$work/probe-preview.txt" || fail "the preview tunnel lost the guest's body"
ok "the guest's dev server answered through the daemon and the guest op"

say "an undeclared preview port is refused before the guest is asked"
printf '5173\n' >"$vms/workspaces/$ws/preview.ports"
python3 - "$sock" "$ws" <<'PY' >"$work/probe-preview-deny.txt" 2>&1 || true
import base64, json, socket, struct, sys

sock_path, workspace = sys.argv[1], sys.argv[2]
body = json.dumps({
    "type": "proxy.exchange",
    "id": 2,
    "workspace_id": workspace,
    "port": 3000,
    "data_b64": base64.b64encode(b"GET / HTTP/1.1\r\n\r\n").decode(),
}).encode()
wire = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
wire.settimeout(60)
wire.connect(sock_path)
wire.sendall(struct.pack(">I", len(body)) + body)
(length,) = struct.unpack(">I", wire.recv(4))
print(wire.recv(length).decode())
PY
cat "$work/probe-preview-deny.txt" | sed 's/^/    /'
grep -q 'port not declared' "$work/probe-preview-deny.txt" || fail "an undeclared port was forwarded anyway"
ok "refused with 'port not declared'"

printf '\nPASS the network smoke: egress, the resolver and the preview tunnel all behave\n'
