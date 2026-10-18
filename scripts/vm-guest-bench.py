#!/usr/bin/env python3
"""Measure the sealed guest on the workloads P3's filesystem decision needs.

Two arms, one plan. `guest` runs every workload inside the VM over the exec
protocol (scripts/vm_guest_client.py) against the sealed ext4; `host` runs the
identical argv on the host filesystem — the control arm for the `shared` mode
the design demoted to opt-in. One CPU each, and the report prints the ratio.

Subcommands: `fixtures --out DIR`, `run --uds PATH --fixtures DIR`, `--selftest`.
"""

import argparse
import gzip
import io
import json
import os
import random
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from vm_guest_client import WireError, connect

BLOCK = 512
BIG_TAR_BYTES = 500 * 1024 * 1024
BIG_TAR_FILES = 100
SEED = 20261018
NPM_PACKAGES = 12
NPM_FILES = 800
NPM_FILE_BYTES = 2048
REPO_DIRS = 250
REPO_FILES_PER_DIR = 100
WRITE_MIB = 256
TIMEOUT_MS = 600_000
# Derived on purpose: a silent `zig build` must not read as a dead guest, and
# the socket deadline has to outlast the agent's own.
READ_TIMEOUT = TIMEOUT_MS / 1000 + 60
GUEST_FIXTURES = "/opt/bench"
GUEST_WORK = "/workspace"
GIT_ENV = {
    "GIT_AUTHOR_NAME": "Pabrik Bench",
    "GIT_AUTHOR_EMAIL": "bench@pabrik.invalid",
    "GIT_AUTHOR_DATE": "2026-01-01T00:00:00+00:00",
    "GIT_COMMITTER_NAME": "Pabrik Bench",
    "GIT_COMMITTER_EMAIL": "bench@pabrik.invalid",
    "GIT_COMMITTER_DATE": "2026-01-01T00:00:00+00:00",
}
GIT_CONFIG = [
    "-c",
    "init.defaultBranch=main",
    "-c",
    "core.autocrlf=false",
    "-c",
    "commit.gpgsign=false",
    "-c",
    "gc.auto=0",
]
ZIG_BUILD = """const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);
}
"""


class BenchError(RuntimeError):
    """A workload did not run to completion, so its row would be a lie."""


def big_tar_layout(total=BIG_TAR_BYTES, count=BIG_TAR_FILES):
    """(name, size) pairs whose tarball — one 512-byte header per file, each
    payload padded to 512, and the 1024-byte trailer — is exactly `total`."""
    if count < 1 or count * BLOCK + 1024 >= total:
        raise ValueError("no layout fits %d bytes in %d files" % (total, count))
    data = total - 1024 - count * BLOCK
    share = (data // count) // BLOCK * BLOCK
    if share == 0:
        raise ValueError("no block-aligned layout fits %d bytes" % total)
    sizes = [share] * (count - 1) + [data - share * (count - 1)]
    if sizes[-1] <= 0 or sizes[-1] % BLOCK:
        raise ValueError("the tail file cannot be block-aligned for %d" % total)
    return [("payload/big-%03d.bin" % i, sizes[i]) for i in range(count)]


def tar_header(name, size):
    """A POSIX ustar header for one regular file, checksum included."""
    if len(name) > 100:
        raise ValueError("a ustar name is at most 100 bytes: %s" % name)
    header = bytearray(BLOCK)
    header[0 : len(name)] = name.encode()
    header[100:108] = b"%07o\0" % 0o644
    header[108:116] = b"%07o\0" % 0
    header[116:124] = b"%07o\0" % 0
    header[124:136] = b"%011o\0" % size
    header[136:148] = b"%011o\0" % 0
    header[148:156] = b" " * 8
    header[156:157] = b"0"
    header[257:263] = b"ustar\0"
    header[263:265] = b"00"
    header[265:269] = b"root"
    header[297:301] = b"root"
    header[148:156] = b"%06o\0 " % sum(header)
    return bytes(header)


def write_tar(path, entries, seed=SEED, chunk=1 << 20):
    """Write the tarball byte for byte, so its size is a fact and not a hope.

    python's tarfile pads an archive out to a 10240-byte record, which would
    make "a 500 MiB tarball" approximate — hence the explicit writer here.
    """
    total = 1024 + sum(BLOCK + -(-size // BLOCK) * BLOCK for _, size in entries)
    base = random.Random(seed).randbytes(chunk)
    with open(path, "wb") as out:
        for index, (name, size) in enumerate(entries):
            out.write(tar_header(name, size))
            written = 0
            while written < size:
                take = min(chunk, size - written)
                block = bytearray(base[:take])
                if take >= 8:
                    block[0:8] = struct.pack(">Q", index * 1_000_003 + written)
                out.write(block)
                written += take
            out.write(b"\0" * (-(-size // BLOCK) * BLOCK - size))
        out.write(b"\0" * 1024)
    actual = os.path.getsize(path)
    if actual != total:
        raise BenchError("%s is %d bytes, not the %d the layout promised" % (path, actual, total))
    return total


def add_bytes(tar, name, payload):
    info = tarfile.TarInfo(name)
    info.size = len(payload)
    info.mtime = 0
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    tar.addfile(info, io.BytesIO(payload))


def write_npm_packages(root, rng):
    """Local tarballs a `npm install` consumes with no registry and no NIC."""
    os.makedirs(root, exist_ok=True)
    for index in range(NPM_PACKAGES):
        name = "bench-pkg-%02d" % index
        with open(os.path.join(root, name + ".tgz"), "wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as zipped:
                with tarfile.open(fileobj=zipped, mode="w") as tar:
                    add_bytes(
                        tar,
                        "package/package.json",
                        json.dumps({"name": name, "version": "1.0.0", "main": "index.js"}).encode(),
                    )
                    add_bytes(tar, "package/index.js", b"module.exports = %d;\n" % index)
                    for f in range(NPM_FILES):
                        add_bytes(tar, "package/lib/f%04d.js" % f, rng.randbytes(NPM_FILE_BYTES))
    manifest = os.path.join(os.path.dirname(root), "app")
    os.makedirs(manifest, exist_ok=True)
    with open(os.path.join(manifest, "package.json"), "w") as fh:
        fh.write(json.dumps({"name": "bench-app", "version": "1.0.0", "private": True}, indent=2) + "\n")
    return ["bench-pkg-%02d" % index for index in range(NPM_PACKAGES)]


def write_repo(path, rng):
    """A repository with a `git status` worth timing: many tracked files."""
    shutil.rmtree(path, ignore_errors=True)
    for d in range(REPO_DIRS):
        sub = os.path.join(path, "src", "mod-%03d" % d)
        os.makedirs(sub)
        for f in range(REPO_FILES_PER_DIR):
            with open(os.path.join(sub, "file-%03d.txt" % f), "wb") as fh:
                fh.write(("mod %d file %d\n" % (d, f)).encode() + rng.randbytes(96))
    env = dict(os.environ, **GIT_ENV)
    for argv in (
        ["git", *GIT_CONFIG, "init", "-q", path],
        ["git", *GIT_CONFIG, "-C", path, "add", "-A"],
        ["git", *GIT_CONFIG, "-C", path, "commit", "-q", "-m", "the fixture commit"],
        ["git", *GIT_CONFIG, "-C", path, "repack", "-adq"],
        ["git", *GIT_CONFIG, "-C", path, "prune-packed"],
    ):
        subprocess.run(argv, check=True, env=env, capture_output=True)
    return REPO_DIRS * REPO_FILES_PER_DIR


def write_zig_project(path, modules=24):
    shutil.rmtree(path, ignore_errors=True)
    os.makedirs(os.path.join(path, "src"))
    with open(os.path.join(path, "build.zig"), "w") as fh:
        fh.write(ZIG_BUILD)
    imports = []
    for m in range(modules):
        with open(os.path.join(path, "src", "mod%02d.zig" % m), "w") as fh:
            fh.write("pub fn value() u64 {\n    return %d;\n}\n" % (m + 1))
        imports.append('const mod%02d = @import("mod%02d.zig");' % (m, m))
    calls = " + ".join("mod%02d.value()" % m for m in range(modules))
    with open(os.path.join(path, "src", "main.zig"), "w") as fh:
        fh.write(
            "const std = @import(\"std\");\n%s\n\npub fn main() !void {\n    const total: u64 = %s;\n    std.debug.print(\"{d}\\n\", .{total});\n}\n"
            % ("\n".join(imports), calls)
        )
    return modules


def write_cargo_project(path, modules=40):
    shutil.rmtree(path, ignore_errors=True)
    os.makedirs(os.path.join(path, "src"))
    with open(os.path.join(path, "Cargo.toml"), "w") as fh:
        fh.write('[package]\nname = "bench"\nversion = "0.1.0"\nedition = "2021"\n')
    mods = []
    for m in range(modules):
        with open(os.path.join(path, "src", "mod%02d.rs" % m), "w") as fh:
            fh.write(
                "pub fn value(seed: u64) -> u64 {\n    let mut acc = seed ^ %d;\n"
                "    for i in 0..64u64 {\n        acc = acc.wrapping_mul(6364136223846793005).wrapping_add(i);\n    }\n    acc\n}\n"
                % (m + 1)
            )
        mods.append("mod mod%02d;" % m)
    calls = " ^ ".join("mod%02d::value(i)" % m for m in range(modules))
    with open(os.path.join(path, "src", "main.rs"), "w") as fh:
        fh.write(
            "%s\n\nfn main() {\n    let mut acc = 0u64;\n    for i in 0..1000u64 {\n        acc = acc.wrapping_add(%s);\n    }\n    println!(\"{}\", acc);\n}\n"
            % ("\n".join(mods), calls)
        )
    return modules


def generate_fixtures(root, log=print):
    rng = random.Random(SEED)
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(root)
    size = write_tar(os.path.join(root, "big.tar"), big_tar_layout())
    log("big.tar     %d bytes (exactly 500 MiB) in %d files" % (size, BIG_TAR_FILES))
    packages = write_npm_packages(os.path.join(root, "npm"), rng)
    log("npm         %d local packages, %d files of %d bytes" % (len(packages), NPM_FILES, NPM_FILE_BYTES))
    tracked = write_repo(os.path.join(root, "repo"), rng)
    log("repo        %d tracked files in %d directories" % (tracked, REPO_DIRS))
    log("zigproj     %d modules behind build.zig" % write_zig_project(os.path.join(root, "zigproj")))
    log("cargoproj   %d modules, no registry dependency" % write_cargo_project(os.path.join(root, "cargoproj")))
    head = subprocess.run(
        ["git", "-C", os.path.join(root, "repo"), "rev-parse", "HEAD"], check=True, capture_output=True, text=True
    ).stdout.strip()
    return {"big_tar_bytes": size, "npm_packages": len(packages), "repo_files": tracked, "git_head": head}


def mb_per_second(total_bytes, seconds):
    if seconds <= 0:
        return float("inf")
    return total_bytes / seconds / (1024 * 1024)


def npm_tarballs(root):
    return ["%s/npm/bench-pkg-%02d.tgz" % (root.rstrip("/"), index) for index in range(NPM_PACKAGES)]


def shell_command(line, shell="/bin/sh"):
    """The shape src/vmd/policy.zig builds for a tenant command. The agent calls
    execve, which searches no PATH, so argv[0] has to be an absolute path."""
    return [shell, "-c", line]


def path_tokens(workload):
    """Every absolute path a workload names, whether it is its own argv entry or
    buried in the shell line."""
    tokens = []
    for argv in [workload.argv, *workload.setup]:
        for arg in argv:
            for word in arg.split():
                for piece in word.split("="):
                    if piece.startswith("/"):
                        tokens.append(piece)
    return tokens


class Workload:
    """One timed step: what to reset first, what to run, and what it reads.

    Setup runs from the arm's work root; `cwd` is where the timed command runs.
    """

    def __init__(self, name, command, setup=(), cwd=None, drop=False, touch=None, figures=None):
        self.name = name
        self.argv = shell_command(command)
        self.setup = [shell_command(step) for step in setup]
        self.cwd = cwd
        self.drop = drop
        self.touch = touch or (lambda fixtures, work: [])
        self.figures = figures or {}


def build_plan(fixtures, work):
    """The workload list, bound to one arm's paths. Both arms take this shape,
    which is what makes the ratio a comparison and not an anecdote."""
    fx = fixtures.rstrip("/")
    wk = work.rstrip("/")
    repo, app, zig, cargo = wk + "/repo", wk + "/app", wk + "/zigproj", wk + "/cargoproj"
    tarballs = " ".join(npm_tarballs(fx))
    fresh_repo = ["rm -rf " + repo, "cp -r " + fx + "/repo " + repo]
    touch_twenty = "i=0; for f in repo/src/mod-000/*.txt; do [ $i -lt 20 ] || break; echo touched >> $f; i=$((i+1)); done"
    return [
        Workload(
            "git status · clean repo, 25000 files",
            "git -C " + repo + " status --porcelain=v1",
            setup=fresh_repo,
            drop=True,
            touch=lambda fixtures, work: [work.rstrip("/") + "/repo"],
            figures={"files": REPO_DIRS * REPO_FILES_PER_DIR},
        ),
        Workload(
            "git status · 20 files touched",
            "git -C " + repo + " status --porcelain=v1",
            setup=fresh_repo + [touch_twenty],
            cwd=repo,
            drop=True,
            touch=lambda fixtures, work: [work.rstrip("/") + "/repo"],
            figures={"files": REPO_DIRS * REPO_FILES_PER_DIR},
        ),
        Workload(
            "npm install · 12 local packages, no registry",
            "npm install --no-audit --no-fund --loglevel=error --cache=" + wk + "/.npm-cache " + tarballs,
            setup=["rm -rf " + app, "mkdir -p " + app, "cp " + fx + "/app/package.json " + app + "/package.json"],
            cwd=app,
            drop=True,
            touch=lambda fixtures, work: npm_tarballs(fixtures),
            figures={"packages": NPM_PACKAGES, "files": NPM_PACKAGES * NPM_FILES},
        ),
        Workload(
            "zig build · cold cache",
            "zig build -Doptimize=ReleaseSafe",
            setup=["rm -rf " + zig, "cp -r " + fx + "/zigproj " + zig],
            cwd=zig,
            drop=True,
            touch=lambda fixtures, work: [work.rstrip("/") + "/zigproj"],
        ),
        Workload("zig build · warm cache", "zig build -Doptimize=ReleaseSafe", cwd=zig),
        Workload(
            "cargo build · cold cache",
            "cargo build --offline",
            setup=["rm -rf " + cargo, "cp -r " + fx + "/cargoproj " + cargo],
            cwd=cargo,
            drop=True,
            touch=lambda fixtures, work: [work.rstrip("/") + "/cargoproj"],
        ),
        Workload("cargo build · warm cache", "cargo build --offline", cwd=cargo),
        Workload(
            "dd read · 500 MiB tarball, cold",
            "dd if=" + fx + "/big.tar of=/dev/null bs=1M",
            drop=True,
            touch=lambda fixtures, work: [fixtures.rstrip("/") + "/big.tar"],
            figures={"bytes": BIG_TAR_BYTES},
        ),
        Workload(
            "dd read · 500 MiB tarball, warm",
            "dd if=" + fx + "/big.tar of=/dev/null bs=1M",
            figures={"bytes": BIG_TAR_BYTES},
        ),
        Workload(
            "tar extract · 500 MiB tarball",
            "tar -xf " + fx + "/big.tar -C " + wk + "/extract",
            setup=["rm -rf " + wk + "/extract", "mkdir -p " + wk + "/extract"],
            drop=True,
            touch=lambda fixtures, work: [fixtures.rstrip("/") + "/big.tar"],
            figures={"bytes": BIG_TAR_BYTES},
        ),
        Workload(
            "dd write · 256 MiB and fsync",
            "dd if=/dev/zero of=" + wk + "/zero.bin bs=1M count=%d conv=fsync" % WRITE_MIB,
            figures={"bytes": WRITE_MIB * 1024 * 1024},
        ),
    ]


class GuestArm:
    """Runs a workload inside the VM over the exec protocol."""

    name = "guest"

    def __init__(self, client, work=GUEST_WORK, drop_cache=True, image=None):
        self.client = client
        self.work = work
        self.drop_cache = drop_cache
        self.image = image
        self.ids = 0

    def execute(self, workload):
        for argv in workload.setup:
            self.run(argv, cwd=self.work)
        if workload.drop and self.drop_cache and self.image:
            if drop_paths([self.image]) == 0:
                note("%s could not drop the host cache for %s, so it is not cold" % (self.name, workload.name))
        self.ids += 1
        start = time.monotonic()
        out, err, final, timed_out = self.client.request(
            {
                "type": "exec",
                "id": self.ids,
                "argv": workload.argv,
                "cwd": workload.cwd or self.work,
                "timeout_ms": TIMEOUT_MS,
            }
        )
        if timed_out or final.get("code") != 0:
            raise BenchError(
                "the guest could not run %r: exit=%s timed_out=%s\n%s%s"
                % (workload.name, final.get("code"), timed_out, out.decode(errors="replace"), err.decode(errors="replace"))
            )
        return [time.monotonic() - start]

    def run(self, argv, cwd=None):
        self.ids += 1
        out, err, final, timed_out = self.client.request(
            {"type": "exec", "id": self.ids, "argv": argv, "cwd": cwd or self.work, "timeout_ms": TIMEOUT_MS}
        )
        if timed_out or final.get("code") != 0:
            raise BenchError(
                "the guest could not run the setup %r: %s%s" % (argv, out.decode(errors="replace"), err.decode(errors="replace"))
            )
        return out


class HostArm:
    """Runs the identical argv on the host filesystem: the `shared` control arm."""

    name = "host"

    def __init__(self, fixtures, work, cpu=0, drop_cache=True):
        self.fixtures = fixtures
        self.work = work
        self.cpu = cpu
        self.drop_cache = drop_cache

    def _run(self, argv, cwd, check):
        prefix = ["taskset", "-c", str(self.cpu)] if self.cpu is not None and shutil.which("taskset") else []
        return subprocess.run(
            prefix + argv,
            cwd=cwd or self.work,
            check=check,
            capture_output=True,
            env=dict(os.environ, **GIT_ENV),
        )

    def execute(self, workload):
        for argv in workload.setup:
            self._run(argv, self.work, check=True)
        if workload.drop and self.drop_cache:
            if drop_paths(workload.touch(self.fixtures, self.work)) == 0:
                note("%s could not drop the host cache for %s, so it is not cold" % (self.name, workload.name))
        start = time.monotonic()
        done = self._run(workload.argv, workload.cwd, check=False)
        seconds = time.monotonic() - start
        if done.returncode != 0:
            raise BenchError(
                "the host could not run %r: exit=%d\n%s%s"
                % (workload.name, done.returncode, done.stdout.decode(errors="replace"), done.stderr.decode(errors="replace"))
            )
        return [seconds]


def fadvise_dontneed(path):
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return False
    try:
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        return True
    except OSError:
        return False
    finally:
        os.close(fd)


def drop_paths(paths):
    """Evict the host's clean page cache for these paths: unprivileged, and the
    difference between measuring the device and measuring the host's RAM.

    Returns how many files were actually advised, so a "cold" row that could
    not drop its cache says so instead of quietly measuring a warm one.
    """
    dropped = 0
    for path in paths:
        if os.path.isdir(path):
            for base, _, names in os.walk(path):
                for name in names:
                    dropped += 1 if fadvise_dontneed(os.path.join(base, name)) else 0
        else:
            dropped += 1 if fadvise_dontneed(path) else 0
    return dropped


def image_clone(image, work):
    """The one row no workload can produce: how long a reflink clone takes."""
    clone = os.path.join(work, "image-clone.ext4")
    start = time.monotonic()
    subprocess.run(["cp", "--reflink=auto", image, clone], check=True)
    seconds = time.monotonic() - start
    os.unlink(clone)
    return seconds


def report(results, log=print):
    """Print the table in seconds, then the rate the byte-bound rows are about."""
    log("%-38s %10s %10s %8s" % ("workload", "guest", "host", "guest/host"))
    for name, arms in results.items():
        guest, host = arms.get("guest"), arms.get("host")
        ratio = "%.2fx" % (guest[0] / host[0]) if guest and host and host[0] > 0 else "—"
        log(
            "%-38s %10s %10s %8s"
            % (name[:38], "—" if not guest else "%.2f" % guest[0], "—" if not host else "%.2f" % host[0], ratio)
        )
    log("")
    log("%-38s %12s %12s" % ("rate (MiB/s)", "guest", "host"))
    for name, arms in results.items():
        total = (arms.get("figures") or {}).get("bytes")
        if not total:
            continue
        cells = [
            "—" if not arms.get(arm) else "%.0f" % mb_per_second(total, arms[arm][0]) for arm in ("guest", "host")
        ]
        log("%-38s %12s %12s" % (name[:38], cells[0], cells[1]))
    log("")


def selftest(log=print):
    """The arithmetic and the boundaries, with no VM, no KVM and no root."""
    state = {"ok": 0, "failed": 0}

    def check(label, expected, actual):
        if expected == actual:
            state["ok"] += 1
            log("  ok   %s" % label)
        else:
            state["failed"] += 1
            log("  FAIL %s\n         expected: %r\n         actual:   %r" % (label, expected, actual))

    layout = big_tar_layout()
    check(
        "the 500 MiB layout totals exactly 500 MiB",
        BIG_TAR_BYTES,
        1024 + sum(BLOCK + -(-size // BLOCK) * BLOCK for _, size in layout),
    )
    check("every payload in the layout is block-aligned", [], [size for _, size in layout if size % BLOCK])
    check("the layout carries one header per file", BIG_TAR_FILES, len(layout))

    small = big_tar_layout(64 * 1024, 4)
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "small.tar")
        check("the writer emits the size its layout promised", 64 * 1024, write_tar(path, small))
        with tarfile.open(path) as tar:
            check("a real tar reader recovers the names", [name for name, _ in small], [m.name for m in tar.getmembers()])
            check("a real tar reader recovers the sizes", [size for _, size in small], [m.size for m in tar.getmembers()])
        odd = os.path.join(tmp, "odd.tar")
        check(
            "a payload that is not block-aligned is padded to the block",
            1024 + BLOCK + 1024,
            write_tar(odd, [("payload/odd.bin", 1000)]),
        )

    check("a rate is bytes over seconds", 100.0, mb_per_second(100 * 1024 * 1024, 1.0))
    check("no elapsed time is not a division by zero", float("inf"), mb_per_second(1024, 0.0))

    plan = build_plan(GUEST_FIXTURES, GUEST_WORK)
    roots = (GUEST_FIXTURES + "/", GUEST_WORK + "/")
    outside = ("/dev/null", "/dev/zero", "/bin/sh")
    strays = [
        (workload.name, token)
        for workload in plan
        for token in path_tokens(workload)
        if token not in outside and (not token.startswith(roots) or "//" in token)
    ]
    check("every path a workload names is inside its own root or a device", [], strays)
    check(
        "a workload runs through the guest shell, like a tenant command does",
        ["/bin/sh", "-c", "git -C " + GUEST_WORK + "/repo status --porcelain=v1"],
        plan[0].argv,
    )
    check("both build tools get a cold and a warm row", 2, sum(1 for w in plan if w.name.startswith("zig build")))
    check("a warm row has no setup, so it measures what the cold row left", [], plan[4].setup)

    results = {
        "a measured row": {"guest": [2.0], "host": [1.0]},
        "a guest-only row": {"guest": [0.5]},
        "a host-only row": {"host": [0.25]},
        "a byte row": {"guest": [1.0], "host": [0.25], "figures": {"bytes": 512 * 1024 * 1024}},
    }
    lines = []
    report(results, lines.append)
    check("a row with both arms reports the ratio", 2, sum(1 for line in lines if "2.00x" in line or "4.00x" in line))
    check("a missing arm prints a dash, never a number", 2, sum(1 for line in lines if "—" in line))
    rates = next(i for i, line in enumerate(lines) if line.startswith("rate"))
    check("a byte row reports both rates", True, "512" in lines[rates + 1] and "2048" in lines[rates + 1])
    check("a row with no byte size stays out of the rate table", rates + 2, len(lines) - 1)

    log("[vm-bench] selftest: %d ok, %d failed" % (state["ok"], state["failed"]))
    return state["failed"] == 0


def note(message):
    print("[vm-bench] %s" % message, file=sys.stderr)


def connect_ready(uds, attempts=25, delay=0.2, timeout=READ_TIMEOUT):
    """Readiness is a hello the agent answered, not a start we issued: the vsock
    muxer accepts a CONNECT before the guest's listener exists (§22 finding 1),
    so the first frame of a too-early connection reads as a closed socket."""
    last = None
    for _ in range(attempts):
        try:
            client = connect(uds, timeout=timeout)
            client.send({"type": "hello"})
            hello = client.recv()
            if hello.get("agent") == "pabrik-vm-agent":
                return client
            last = WireError("an unexpected hello: %r" % (hello,))
        except (WireError, OSError) as exc:
            last = exc
        time.sleep(delay)
    raise BenchError("the guest agent never answered a hello: %s" % last)


def run_bench(args):
    log = note
    drop = not args.no_drop_cache
    wanted = [arm.strip() for arm in args.arms.split(",") if arm.strip()]
    os.makedirs(args.work, exist_ok=True)
    results = {}
    if args.boot_seconds is not None:
        results["boot · InstanceStart to the agent"] = {"guest": [args.boot_seconds]}
    if args.image and os.path.exists(args.image):
        results["image clone · reflink"] = {"host": [image_clone(args.image, args.work)]}
    arms = []
    if "guest" in wanted:
        arms.append(GuestArm(connect_ready(args.uds), drop_cache=drop, image=args.image))
    if "host" in wanted:
        arms.append(HostArm(args.fixtures, args.work, cpu=args.cpu, drop_cache=drop))
    guest_plan = build_plan(GUEST_FIXTURES, GUEST_WORK)
    host_plan = build_plan(args.fixtures, args.work)
    keep = [
        index
        for index, workload in enumerate(guest_plan)
        if not args.only or args.only in workload.name
    ]
    if args.only and not keep:
        raise BenchError("--only %r matches no workload" % args.only)
    for index in keep:
        workload = guest_plan[index]
        row = results.setdefault(workload.name, {"figures": workload.figures})
        for arm in arms:
            bound = host_plan[index] if arm.name == "host" else workload
            log("%s: %s" % (arm.name, workload.name))
            row[arm.name] = arm.execute(bound)
    report(results)
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(results, fh, indent=2, sort_keys=True)
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="vm-guest-bench.py", description=__doc__)
    parser.add_argument("--selftest", action="store_true")
    sub = parser.add_subparsers(dest="command")
    fixtures = sub.add_parser("fixtures")
    fixtures.add_argument("--out", required=True)
    run = sub.add_parser("run")
    run.add_argument("--uds")
    run.add_argument("--fixtures", required=True)
    run.add_argument("--work", required=True)
    run.add_argument("--image")
    run.add_argument("--boot-seconds", type=float)
    run.add_argument("--cpu", type=int, default=0)
    run.add_argument("--no-drop-cache", action="store_true")
    run.add_argument("--arms", default="guest,host")
    run.add_argument("--only")
    run.add_argument("--json")
    args = parser.parse_args(argv[1:])
    if args.selftest:
        return 0 if selftest() else 1
    if args.command == "fixtures":
        print(json.dumps(generate_fixtures(args.out, lambda line: print("[vm-bench] %s" % line, file=sys.stderr)), indent=2, sort_keys=True))
        return 0
    if args.command == "run":
        if "guest" in args.arms and not args.uds:
            parser.error("--uds is required to run the guest arm")
        return run_bench(args)
    parser.print_help()
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except (BenchError, WireError) as exc:
        print("[vm-bench] FAIL %s" % exc, file=sys.stderr)
        raise SystemExit(1)
