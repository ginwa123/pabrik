#!/usr/bin/env python3
"""Probe a Firecracker guest agent over hybrid vsock.

Firecracker's vsock is host-initiated through a unix socket: the host connects
to the VM's `uds_path` and announces the guest port with `CONNECT <port>\\n`
before any framed traffic flows. Frame = 4-byte big-endian length + payload.

Usage: vm-vsock-hello.py <uds_path> [port]
Exit 0 = hello answered and the guest acknowledged shutdown.
"""

import json
import socket
import struct
import sys

MAX_FRAME = 4096


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise SystemExit("connection closed mid-frame")
        buf += chunk
    return buf


def send_frame(sock, payload):
    sock.sendall(struct.pack(">I", len(payload)) + payload)


def recv_frame(sock):
    (length,) = struct.unpack(">I", read_exact(sock, 4))
    if length == 0 or length > MAX_FRAME:
        raise SystemExit("bad frame length: %d" % length)
    return json.loads(read_exact(sock, length).decode())


def main(argv):
    uds = argv[1]
    port = argv[2] if len(argv) > 2 else "5000"

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(10)
    sock.connect(uds)
    sock.sendall(("CONNECT %s\n" % port).encode())

    # The muxer answers the CONNECT with one `OK <port>` line before frames.
    handshake = b""
    while not handshake.endswith(b"\n"):
        byte = sock.recv(1)
        if not byte:
            raise SystemExit("muxer closed during the CONNECT handshake")
        handshake += byte
    if not handshake.startswith(b"OK"):
        raise SystemExit("muxer refused the CONNECT: %r" % handshake)

    send_frame(sock, b'{"type":"hello"}')
    hello = recv_frame(sock)
    if hello.get("type") != "hello":
        raise SystemExit("unexpected hello reply: %r" % (hello,))
    print("[vm-smoke] hello reply: %s" % json.dumps(hello))

    send_frame(sock, b'{"type":"shutdown"}')
    bye = recv_frame(sock)
    if bye.get("type") != "bye":
        raise SystemExit("unexpected shutdown reply: %r" % (bye,))
    print("[vm-smoke] shutdown reply: %s" % json.dumps(bye))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    raise SystemExit(main(sys.argv))
