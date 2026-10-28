#!/usr/bin/env python3
"""Assert the behaviours the guest agent's protocol owes its callers: `hello`,
`exec` (argv, exit code, the guest's own root uid, timeout, output budget),
`shutdown`. The framing itself lives in `vm_guest_client.py`.

Usage: vm-guest-probe.py <uds_path> [port]
       vm-guest-probe.py <uds_path> -- <argv...>    # run one command and show it
Exit 0 = every assertion held.
"""

import base64
import sys

from vm_guest_client import WireError, connect


def check(label, condition, detail=""):
    if condition:
        print("[vm-smoke] ok  %s" % label)
        return
    raise SystemExit("[vm-smoke] FAIL %s %s" % (label, detail))


def write(client, path, data, **fields):
    """One `fs.write` frame, and the reply to it. The body is bytes on the
    wire, so it is base64 there."""
    frame = {
        "type": "fs.write",
        "id": 20,
        "path": path,
        "data_b64": base64.b64encode(data).decode(),
    }
    frame.update(fields)
    client.send(frame)
    return client.recv()


def read(client, path, offset=0, max_bytes=65536):
    client.send(
        {
            "type": "fs.read",
            "id": 21,
            "path": path,
            "offset": offset,
            "max_bytes": max_bytes,
        }
    )
    msg = client.recv()
    if msg.get("missing"):
        return msg, b""
    return msg, base64.b64decode(msg.get("data_b64", ""))


def read_whole(client, path, max_bytes=32768):
    """Everything in a file, in bounded pieces, until the guest says eof."""
    out = b""
    offset = 0
    while True:
        msg, piece = read(client, path, offset=offset, max_bytes=max_bytes)
        if msg.get("missing"):
            return msg, b""
        out += piece
        if msg.get("eof") or not piece:
            return msg, out
        offset += len(piece)


def walk(client, path="", **fields):
    """A walk, collected until the frame that says `done`. The reply is
    streamed, so one call is many frames."""
    frame = {"type": "fs.walk", "id": 22, "path": path}
    frame.update(fields)
    client.send(frame)
    entries = []
    while True:
        msg = client.recv()
        if msg.get("type") != "fs.walk":
            return msg, None
        entries.extend(msg.get("entries", []))
        if msg.get("done"):
            return msg, entries


def main(argv):
    separator = argv.index("--") if "--" in argv else len(argv)
    client = connect(argv[1], argv[2] if separator > 2 else "5000")
    check("vsock muxer handshake", client.handshake.startswith("OK"), client.handshake)

    if "--" in argv:
        # Debug mode: run one argv in the guest and print what it produced.
        command = argv[argv.index("--") + 1 :]
        out, err, final, timed_out = client.request({"type": "exec", "id": 99, "argv": command})
        sys.stdout.write(out.decode(errors="replace"))
        sys.stderr.write(err.decode(errors="replace"))
        print("[vm-smoke] exit=%s timeout=%s" % (final.get("code"), timed_out))
        return 0

    client.send({"type": "hello"})
    hello = client.recv()
    check("hello frame", hello.get("agent") == "pabrik-vm-agent", repr(hello))

    out, err, exit_frame, _ = client.request(
        {"type": "exec", "id": 1, "argv": ["/bin/pabrik-probe", "echo", "hello", "from", "the", "guest"]}
    )
    check("exec stdout round-trip", out == b"hello from the guest\n", repr(out))
    check("exec exit code 0", exit_frame.get("code") == 0 and not err, repr(exit_frame))

    out, _, exit_frame, _ = client.request({"type": "exec", "id": 2, "argv": ["/bin/pabrik-probe", "id"]})
    check("commands run as the guest's own root", out.startswith(b"uid=0 "), repr(out))

    out, _, exit_frame, _ = client.request(
        {"type": "exec", "id": 3, "argv": ["/bin/pabrik-probe", "write", "/workspace/hello.txt", "persisted"]}
    )
    check("guest writes a file", exit_frame.get("code") == 0 and b"wrote" in out, repr(out))

    out, err, exit_frame, _ = client.request({"type": "exec", "id": 4, "argv": ["/bin/pabrik-probe", "fail", "7"]})
    check("non-zero exit and stderr", exit_frame.get("code") == 7 and b"failing" in err, repr((exit_frame, err)))

    _, _, exit_frame, timed_out = client.request(
        {"type": "exec", "id": 5, "argv": ["/bin/pabrik-probe", "sleep", "30000"], "timeout_ms": 500}
    )
    check("timeout kills the command", timed_out and exit_frame.get("timed_out") is True, repr(exit_frame))

    out, _, exit_frame, _ = client.request(
        {
            "type": "exec",
            "id": 6,
            "argv": ["/bin/pabrik-probe", "echo", "x" * 4096],
            "max_output_bytes": 64,
        }
    )
    check(
        "output budget truncates instead of flooding",
        exit_frame.get("truncated") is True and exit_frame.get("bytes", 0) <= 64,
        repr(exit_frame),
    )

    out, _, exit_frame, _ = client.request(
        {"type": "exec", "id": 10, "argv": ["/bin/sh", "-c", "echo shell-ok"]}
    )
    check("the guest image ships a real shell", out.strip() == b"shell-ok", repr(out))

    out, _, exit_frame, _ = client.request(
        {"type": "exec", "id": 11, "argv": ["/bin/sh", "-c", "echo $((6*7)); id -u"]}
    )
    check(
        "shell expansion and command substitution",
        out == b"42\n0\n",
        repr(out),
    )

    out, _, exit_frame, _ = client.request(
        {"type": "exec", "id": 12, "argv": ["/bin/sh", "-c", "wc -l < /etc/pabrik-image-rpms"]}
    )
    packages = int(out.strip() or b"0")
    check("the image records the packages it ships", packages > 100, repr(out))

    # ── fs.write: the guest creates the file, and its directories ──────
    reply = write(
        client,
        "seam/deep/note.txt",
        b"written by the protocol\n",
        create_dirs=True,
        offset=0,
    )
    check("fs.write creates a file and its directories", reply.get("type") == "fs.write.ok", repr(reply))
    check(
        "fs.write reports the bytes it took",
        reply.get("size") == len(b"written by the protocol\n"),
        repr(reply),
    )

    msg, body = read(client, "seam/deep/note.txt")
    check("fs.read reads back what fs.write wrote", body == b"written by the protocol\n", repr((msg, body)))

    # A frame is 64 KiB and base64 costs 4 bytes per 3, so one write piece is
    # bounded; a bigger body crosses as pieces at their own offsets.
    big = bytes(range(256)) * 160  # 40,960 bytes
    chunk = 32 * 1024
    reply = write(client, "seam/big.bin", big[:chunk], create_dirs=False, offset=0)
    check("fs.write takes one full piece", reply.get("size") == chunk, repr(reply))
    reply = write(client, "seam/big.bin", big[chunk:], create_dirs=False, offset=chunk, truncate=False)
    check("fs.write extends the file at an offset", reply.get("size") == len(big) - chunk, repr(reply))
    msg, body = read_whole(client, "seam/big.bin")
    check("a piecewise write reads back whole", body == big, repr((msg.get("size"), len(body))))

    over = write(client, "seam/over.bin", b"x" * (chunk + 1), create_dirs=False, offset=0)
    check("one piece past the frame ceiling is refused", over.get("type") == "fs.error", repr(over))

    reply = write(client, "../escape.txt", b"nope", create_dirs=True, offset=0)
    check("fs.write refuses a path that leaves the workspace", reply.get("type") == "fs.error", repr(reply))
    reply = write(client, "/etc/passwd", b"nope", offset=0)
    check("fs.write refuses an absolute path", reply.get("type") == "fs.error", repr(reply))
    reply = write(client, "seam/not-base64.txt", b"", offset=0)
    client.send({"type": "fs.write", "id": 23, "path": "seam/bad.txt", "data_b64": "not base64!"})
    reply = client.recv()
    check("fs.write refuses a body that is not base64", reply.get("type") == "fs.error", repr(reply))

    # A missing parent is the caller's mistake unless it asked for the dirs.
    reply = client.request(
        {"type": "exec", "id": 30, "argv": ["/bin/sh", "-c", "rm -rf /workspace/seam/absent"]}
    )
    _ = reply
    missing_parent = write(client, "seam/absent/note.txt", b"nope", offset=0)
    check("fs.write without create_dirs refuses a missing parent", missing_parent.get("type") == "fs.error", repr(missing_parent))

    # ── fs.walk: the whole tree, in bounded pieces ─────────────────────
    done, entries = walk(client, "", max_depth=8, max_entries=1000)
    check("fs.walk answers with a done frame", done.get("type") == "fs.walk" and done.get("done") is True, repr(done))
    check("fs.walk reports what it listed", done.get("count") == len(entries), repr(done))
    kinds = {entry.get("path"): entry.get("kind") for entry in entries}
    check("fs.walk descends into the tree", "seam/deep/note.txt" in kinds, repr(sorted(kinds)[:8]))
    check("fs.walk names a file a file", kinds.get("seam/deep/note.txt") == "file", repr(kinds.get("seam/deep/note.txt")))
    check("fs.walk names a directory a directory", kinds.get("seam/deep") == "dir", repr(kinds.get("seam/deep")))
    check(
        "every path a walk reports is relative to the workspace",
        all(not path.startswith("/") and ".." not in path.split("/") for path in kinds),
        repr([p for p in kinds if p.startswith("/") or ".." in p.split("/")][:4]),
    )

    _, shallow = walk(client, "", max_depth=1, max_entries=1000)
    shallow_paths = [entry.get("path") for entry in shallow]
    check("fs.walk to depth 1 stops at one level", "seam" in shallow_paths and "seam/deep" not in shallow_paths, repr(shallow_paths[:8]))

    _, bounded = walk(client, "", max_depth=8, max_entries=1)
    check("fs.walk stops at its entry ceiling and says so", len(bounded) == 1, repr(bounded))

    refused, _ = walk(client, "seam/deep/note.txt")
    check("fs.walk refuses to walk a file", refused.get("type") == "fs.error", repr(refused))
    refused, _ = walk(client, "../etc")
    check("fs.walk refuses a path that leaves the workspace", refused.get("type") == "fs.error", repr(refused))

    # The VM is stopped by killing the VMM, so the guest's page cache has to
    # reach the disk first: the offline read below is of the sealed image.
    client.request({"type": "exec", "id": 40, "argv": ["/bin/sh", "-c", "sync"]})

    client.send({"type": "shutdown"})
    bye = client.recv()
    check("shutdown ack", bye.get("type") == "bye", repr(bye))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    try:
        raise SystemExit(main(sys.argv))
    except WireError as exc:
        raise SystemExit("[vm-smoke] FAIL %s" % exc)
