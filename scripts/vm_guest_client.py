#!/usr/bin/env python3
"""The guest agent's protocol from the host side: the vsock muxer handshake,
then length-prefixed frames (4-byte big-endian length + JSON payload).

Firecracker's vsock is host-initiated through the unix socket at the VM's
`uds_path`: connect, send `CONNECT <port>\\n`, read one `OK <port>\\n` line.
Getting that order wrong makes the first frame read look like a corrupt length.

Used as a library by `vm-guest-probe.py` (the smoke's assertions) and
`vm-guest-bench.py` (the timed workloads). Selftest: no socket, no VM.
"""

import base64
import json
import socket
import struct
import sys

MAX_FRAME = 64 * 1024
DEFAULT_PORT = "5000"
CONNECT_TIMEOUT = 20.0


class WireError(RuntimeError):
    """The peer went away, or said something the protocol does not allow."""


class SocketWire:
    """A real socket, behind the two calls the protocol needs."""

    def __init__(self, sock):
        self._sock = sock

    def recv(self, n):
        try:
            chunk = self._sock.recv(n)
        except TimeoutError:
            raise WireError("the peer said nothing for %ss" % self._sock.gettimeout()) from None
        if not chunk:
            raise WireError("connection closed")
        return chunk

    def sendall(self, data):
        self._sock.sendall(data)


def connect(uds, port=DEFAULT_PORT, timeout=CONNECT_TIMEOUT):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(uds)
    return Client(SocketWire(sock), port)


class Client:
    """One conversation: the muxer handshake, then frames.

    `wire` is anything with `recv(n)` -> at most n bytes and `sendall(data)`,
    which is what makes the framing testable without a VM underneath it.
    """

    def __init__(self, wire, port=DEFAULT_PORT):
        self.wire = wire
        self.port = port
        self.handshake = self._handshake()

    def _handshake(self):
        self.wire.sendall(("CONNECT %s\n" % self.port).encode())
        return self._read_line()

    def _read_line(self):
        line = b""
        while not line.endswith(b"\n"):
            line += self.wire.recv(1)
        return line.decode().strip()

    def _read_exact(self, n):
        buf = b""
        while len(buf) < n:
            buf += self.wire.recv(n - len(buf))
        return buf

    def send(self, payload):
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.wire.sendall(struct.pack(">I", len(body)) + body)

    def recv(self):
        (length,) = struct.unpack(">I", self._read_exact(4))
        if length == 0 or length > MAX_FRAME:
            raise WireError("bad frame length: %d" % length)
        return json.loads(self._read_exact(length).decode())

    def request(self, frame):
        """Send one request; collect its output until `exec.exit`.

        Returns (stdout, stderr, exit_frame, timed_out) — the shape every
        caller of the protocol wants, so the frame loop lives in one place.
        """
        self.send(frame)
        chunks = {b"stdout": [], b"stderr": []}
        timed_out = False
        while True:
            msg = self.recv()
            kind = msg.get("type")
            if kind in ("exec.stdout", "exec.stderr"):
                stream = kind.split(".", 1)[1].encode()
                chunks[stream].append(base64.b64decode(msg["data_b64"]))
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
            raise WireError("unexpected frame: %r" % (msg,))


def frame(payload):
    """The wire form of one frame. The tests assert against this, not against
    the client's own encoder, so an accidental format change is a red test."""
    body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
    return struct.pack(">I", len(body)) + body


def run_selftest():
    """Framing and request-collection behaviours, over a scripted wire.

    The socket is the hidden input here; `ScriptedWire` injects it, so every
    assertion below is same-answer-every-run and needs no VM, no KVM, no root.
    """

    class ScriptedWire:
        """Pre-written replies. `max_chunk` forces the partial reads a real
        socket delivers for free, which is the case `_read_exact` exists for."""

        def __init__(self, inbound=b"", max_chunk=None):
            self.inbound = bytearray(inbound)
            self.sent = bytearray()
            self.max_chunk = max_chunk

        def recv(self, n):
            if not self.inbound:
                raise WireError("the scripted replies ran out")
            if self.max_chunk is not None:
                n = min(n, self.max_chunk)
            chunk = bytes(self.inbound[:n])
            del self.inbound[:n]
            return chunk

        def sendall(self, data):
            self.sent += data

    state = {"ok": 0, "failed": 0}

    def check(label, expected, actual):
        if expected == actual:
            state["ok"] += 1
            print("  ok   %s" % label)
        else:
            state["failed"] += 1
            print("  FAIL %s\n         expected: %r\n         actual:   %r" % (label, expected, actual))

    def refuses(label, call):
        try:
            call()
        except WireError:
            state["ok"] += 1
            print("  ok   %s is refused" % label)
            return
        state["failed"] += 1
        print("  FAIL %s was accepted" % label)

    wire = ScriptedWire(b"OK 5000\n")
    client = Client(wire, "5000")
    check("the handshake is the returned muxer line", "OK 5000", client.handshake)
    check("the port reaches the muxer as CONNECT <port>\\n", b"CONNECT 5000\n", bytes(wire.sent))

    check(
        "a frame arriving one byte at a time reassembles",
        {"type": "hello", "agent": "pabrik-vm-agent"},
        Client(ScriptedWire(b"OK 1\n" + frame({"type": "hello", "agent": "pabrik-vm-agent"}), max_chunk=1), "1").recv(),
    )

    refuses("a zero-length frame", lambda: Client(ScriptedWire(b"OK 1\n" + struct.pack(">I", 0)), "1").recv())
    refuses(
        "a frame past the size budget",
        lambda: Client(ScriptedWire(b"OK 1\n" + struct.pack(">I", MAX_FRAME + 1)), "1").recv(),
    )

    sent = ScriptedWire(b"OK 1\n")
    Client(sent, "1").send({"type": "shutdown"})
    check(
        "a frame carries its own length",
        frame({"type": "shutdown"}),
        bytes(sent.sent)[len(b"CONNECT 1\n"):],
    )

    replies = frame(
        {"type": "exec.stdout", "data_b64": base64.b64encode(b"hello ").decode()}
    ) + frame(
        {"type": "exec.stderr", "data_b64": base64.b64encode(b"warn").decode()}
    ) + frame(
        {"type": "exec.stdout", "data_b64": base64.b64encode(b"world\n").decode()}
    ) + frame(
        {"type": "exec.exit", "code": 7, "timed_out": False}
    )
    client = Client(ScriptedWire(b"OK 1\n" + replies), "1")
    client.send({"type": "exec", "id": 1, "argv": ["true"]})
    check(
        "a request joins its streams and reports the exit code",
        (b"hello world\n", b"warn", {"type": "exec.exit", "code": 7, "timed_out": False}, False),
        client.request({"type": "exec", "id": 2, "argv": ["true"]}),
    )

    timeout_replies = frame({"type": "exec.timeout"}) + frame(
        {"type": "exec.exit", "code": 137, "timed_out": True}
    )
    client = Client(ScriptedWire(b"OK 1\n" + timeout_replies), "1")
    check(
        "a deadline is reported as timed out, not as a plain exit",
        (b"", b"", {"type": "exec.exit", "code": 137, "timed_out": True}, True),
        client.request({"type": "exec", "id": 3, "argv": ["sleep"]}),
    )

    refuses(
        "a frame the exec protocol never sends",
        lambda: Client(ScriptedWire(b"OK 1\n" + frame({"type": "hello"})), "1").request(
            {"type": "exec", "id": 4, "argv": ["true"]}
        ),
    )
    refuses("a peer that closes mid-frame", lambda: Client(ScriptedWire(b"OK 1\n"), "1").recv())

    class SilentSocket:
        """A socket whose read deadline expires: a command that produces no
        output for longer than the deadline must not look like a crash."""

        def recv(self, n):
            raise TimeoutError("timed out")

        def sendall(self, data):
            pass

        def gettimeout(self):
            return 20.0

    refuses("a peer that says nothing before the deadline", lambda: Client(SocketWire(SilentSocket()), "1").recv())

    print("[vm-client] selftest: %d ok, %d failed" % (state["ok"], state["failed"]))
    return state["failed"] == 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        raise SystemExit(0 if run_selftest() else 1)
    raise SystemExit(__doc__)
