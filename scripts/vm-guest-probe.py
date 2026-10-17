#!/usr/bin/env python3
"""Drive the guest agent's protocol from the host, over hybrid vsock.

Firecracker's vsock is host-initiated through the unix socket at the VM's
`uds_path`: connect, send `CONNECT <port>\\n`, read one `OK <port>\\n` line, then
frames (4-byte big-endian length + payload). Getting that handshake order wrong
makes the first frame read look like a corrupt length.

Usage: vm-guest-probe.py <uds_path> [port]
Exit 0 = every assertion held.
"""

import base64
import json
import socket
import struct
import sys

MAX_FRAME = 64 * 1024


class Client:
    def __init__(self, uds, port):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(20)
        self.sock.connect(uds)
        self.sock.sendall(("CONNECT %s\n" % port).encode())
        self.handshake = self._read_line()

    def _read_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise SystemExit("connection closed mid-frame")
            buf += chunk
        return buf

    def _read_line(self):
        line = b""
        while not line.endswith(b"\n"):
            byte = self.sock.recv(1)
            if not byte:
                raise SystemExit("connection closed during the handshake")
            line += byte
        return line.decode().strip()

    def send(self, payload):
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.sock.sendall(struct.pack(">I", len(body)) + body)

    def recv(self):
        (length,) = struct.unpack(">I", self._read_exact(4))
        if length == 0 or length > MAX_FRAME:
            raise SystemExit("bad frame length: %d" % length)
        return json.loads(self._read_exact(length).decode())

    def request(self, frame):
        """Send one request and collect every reply up to exec.exit/timeout."""
        self.send(frame)
        chunks = {b"stdout": [], b"stderr": []}
        timed_out = False
        while True:
            msg = self.recv()
            kind = msg.get("type")
            if kind in ("exec.stdout", "exec.stderr"):
                chunks[kind.split(".", 1)[1].encode()].append(base64.b64decode(msg["data_b64"]))
                continue
            if kind == "exec.timeout":
                timed_out = True
                continue
            if kind == "exec.exit":
                return (
                    b"".join(chunks[b"stdout"]),
                    b"".join(chunks[b"stderr"]),
                    msg,
                    timed_out,
                )
            raise SystemExit("unexpected frame: %r" % (msg,))


def check(label, condition, detail=""):
    if condition:
        print("[vm-smoke] ok  %s" % label)
        return
    raise SystemExit("[vm-smoke] FAIL %s %s" % (label, detail))


def main(argv):
    client = Client(argv[1], argv[2] if len(argv) > 2 else "5000")
    check("vsock muxer handshake", client.handshake.startswith("OK"), client.handshake)

    client.send({"type": "hello"})
    hello = client.recv()
    check("hello frame", hello.get("agent") == "pabrik-vm-agent", repr(hello))

    out, err, exit_frame, _ = client.request(
        {"type": "exec", "id": 1, "argv": ["/bin/probe", "echo", "hello", "from", "the", "guest"]}
    )
    check("exec stdout round-trip", out == b"hello from the guest\n", repr(out))
    check("exec exit code 0", exit_frame.get("code") == 0 and not err, repr(exit_frame))

    out, _, exit_frame, _ = client.request({"type": "exec", "id": 2, "argv": ["/bin/probe", "id"]})
    check("commands run as a non-root uid", out.startswith(b"uid=1000 "), repr(out))

    out, _, exit_frame, _ = client.request(
        {"type": "exec", "id": 3, "argv": ["/bin/probe", "write", "/workspace/hello.txt", "persisted"]}
    )
    check("guest writes a file", exit_frame.get("code") == 0 and b"wrote" in out, repr(out))

    out, err, exit_frame, _ = client.request({"type": "exec", "id": 4, "argv": ["/bin/probe", "fail", "7"]})
    check("non-zero exit and stderr", exit_frame.get("code") == 7 and b"failing" in err, repr((exit_frame, err)))

    _, _, exit_frame, timed_out = client.request(
        {"type": "exec", "id": 5, "argv": ["/bin/probe", "sleep", "30000"], "timeout_ms": 500}
    )
    check("timeout kills the command", timed_out and exit_frame.get("timed_out") is True, repr(exit_frame))

    out, _, exit_frame, _ = client.request(
        {
            "type": "exec",
            "id": 6,
            "argv": ["/bin/probe", "echo", "x" * 4096],
            "max_output_bytes": 64,
        }
    )
    check(
        "output budget truncates instead of flooding",
        exit_frame.get("truncated") is True and exit_frame.get("bytes", 0) <= 64,
        repr(exit_frame),
    )

    client.send({"type": "shutdown"})
    bye = client.recv()
    check("shutdown ack", bye.get("type") == "bye", repr(bye))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    raise SystemExit(main(sys.argv))
