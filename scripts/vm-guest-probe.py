#!/usr/bin/env python3
"""Assert the behaviours the guest agent's protocol owes its callers: `hello`,
`exec` (argv, exit code, non-root uid, timeout, output budget), `shutdown`. The
framing itself lives in `vm_guest_client.py`.

Usage: vm-guest-probe.py <uds_path> [port]
       vm-guest-probe.py <uds_path> -- <argv...>    # run one command and show it
Exit 0 = every assertion held.
"""

import sys

from vm_guest_client import WireError, connect


def check(label, condition, detail=""):
    if condition:
        print("[vm-smoke] ok  %s" % label)
        return
    raise SystemExit("[vm-smoke] FAIL %s %s" % (label, detail))


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
    check("commands run as a non-root uid", out.startswith(b"uid=1000 "), repr(out))

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
        {"type": "exec", "id": 10, "argv": ["/bin/sh", "-c", "cat /etc/alpine-release"]}
    )
    check("the guest image ships a real shell", out.strip().startswith(b"3.24"), repr(out))

    out, _, exit_frame, _ = client.request(
        {"type": "exec", "id": 11, "argv": ["/bin/sh", "-c", "echo $((6*7)); id -u"]}
    )
    check(
        "shell expansion and command substitution",
        out == b"42\n1000\n",
        repr(out),
    )

    out, _, exit_frame, _ = client.request(
        {"type": "exec", "id": 12, "argv": ["/bin/sh", "-c", "busybox --list | wc -l"]}
    )
    applets = int(out.strip() or b"0")
    check("busybox provides the userland", applets > 200, repr(out))

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
