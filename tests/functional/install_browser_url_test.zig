// install_browser_url_test.zig — the curl-install user flow, end to end.
//
// A user on Linux/macOS runs:
//
//   curl -fsSL https://raw.githubusercontent.com/ginwa123/pabrik/main/install.sh | bash
//
// then types `pabrik` in a terminal and opens the printed URL in a browser.
//
// These tests replay that flow against an isolated staging dir instead of
// the real GitHub release: the "release assets" are copies of the
// just-built binary, install.sh installs them into an isolated bindir via
// PABRIK_BASE_URL=file://..., and the installed binary is booted through
// the real Harness (PABRIK_BIN shadow, PathShadow-style) to prove the
// browser URL serves.
//
//   Test 1 — install.sh exits 0, the installed `pabrik --help` exits 0
//            (the payload runs from its installed location), and the
//            bindir is exported to PATH in the shell rc file.
//   Test 2 — the installed binary boots and serves the browser URL:
//            GET /health returns {"status":"ok",...} and
//            GET /api/workspaces returns 200, both over the wire.
//   Test 3 — with a shipped UI beside the installed binary (the html/
//            tarball layout), GET / serves the app shell with no
//            --static-dir flag (the "/app 404" report).
//
// Windows is skipped here: install.sh refuses Windows itself (it prints
// the irm line), and install.ps1 gets the same install-then-URL coverage
// from the install-windows CI job, which runs the real script.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Release triple install.sh resolves on this host, or SkipZigTest where
/// install.sh has no prebuilt binary (Windows, Intel macOS, ARM Linux).
fn installTriple() ![]const u8 {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) return "x86_64-linux-gnu";
    if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) return "aarch64-macos";
    return error.SkipZigTest;
}

/// Run argv with the parent env plus extra_env, waiting for exit.
/// Child stdio is inherited so a failing install.sh step shows its log.
fn runChild(argv: []const []const u8, extra_env: []const [2][]const u8) !std.process.Child.Term {
    var env_map = try std.process.Environ.createMap(std.testing.environ, gpa);
    defer env_map.deinit();
    for (extra_env) |kv| try env_map.put(kv[0], kv[1]);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &env_map,
    });
    return try child.wait(io);
}

fn expectExitZero(term: std.process.Child.Term, what: []const u8) !void {
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("{s} exited with code {d}\n", .{ what, code });
                return error.TestUnexpectedResult;
            }
        },
        else => {
            std.debug.print("{s} did not exit normally\n", .{what});
            return error.TestUnexpectedResult;
        },
    }
}

/// Shadow one NAME=VALUE pair into std.testing.environ — the exact block
/// Harness.boot copies into the child env and resolvePabrikBin reads —
/// so Harness.boot resolves the INSTALLED binary. Scoped by restore:
/// the shadow must not outlive the test, or every later suite in the
/// same process would boot the installed copy. Mirrors PathShadow in
/// git_pr_checks_test.zig, generalized from PATH-prepend to set-or-add.
const EnvShadow = struct {
    saved: std.process.Environ,
    entries: [:null]const ?[*:0]const u8,

    fn install(name: []const u8, value: []const u8) !EnvShadow {
        // Environ's block is a raw KEY=VALUE slice on POSIX. On Windows
        // it is a PEB pointer Zig offers no way to shadow — and this
        // suite is POSIX-only anyway (install.sh refuses Windows).
        if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
        const saved = std.testing.environ;
        const orig = saved.block.slice;

        const kv = try std.fmt.allocPrintSentinel(gpa, "{s}={s}", .{ name, value }, 0);
        errdefer gpa.free(kv);

        var owned: std.ArrayList([:0]u8) = .empty;
        defer owned.deinit(gpa);
        errdefer for (owned.items) |o| gpa.free(o);
        try owned.append(gpa, kv);

        for (orig) |maybe| {
            const s = std.mem.span(maybe.?);
            // Drop an existing entry for the same name; the shadow wins.
            if (s.len > name.len and std.mem.startsWith(u8, s, name) and s[name.len] == '=') continue;
            try owned.append(gpa, try gpa.dupeZ(u8, s));
        }

        const entries = try gpa.allocSentinel(?[*:0]const u8, owned.items.len, null);
        errdefer gpa.free(entries);
        for (owned.items, 0..) |o, i| entries[i] = o.ptr;

        std.testing.environ = .{ .block = .{ .slice = entries } };
        return .{ .saved = saved, .entries = entries };
    }

    fn restore(self: EnvShadow) void {
        std.testing.environ = self.saved;
        for (self.entries) |e| gpa.free(std.mem.span(e.?));
        gpa.free(self.entries);
    }
};

/// Stage copies of the just-built binaries as fake release assets, run
/// install.sh against them, and return the bindir holding the installed
/// copies plus the isolated HOME the install ran under. The caller owns
/// both returned slices; scratch cleanup stays with the caller's scratch
/// dir.
const InstallDirs = struct { bindir: []u8, home: []u8 };

fn installToIsolatedBindir(scratch: []const u8, triple: []const u8) !InstallDirs {
    const stage = try harness.harnessPath(gpa, scratch, &.{"release-stage"});
    defer gpa.free(stage);
    try Io.Dir.cwd().createDirPath(io, stage);

    const bindir = try harness.harnessPath(gpa, scratch, &.{"bin"});
    errdefer gpa.free(bindir);

    // Isolated HOME with a pre-existing .bashrc: install.sh only appends
    // its PATH export to rc files that already exist (never creates them),
    // and the isolated HOME keeps the test from touching the developer's
    // real ~/.bashrc.
    const home = try harness.harnessPath(gpa, scratch, &.{"home"});
    errdefer gpa.free(home);
    try Io.Dir.cwd().createDirPath(io, home);
    {
        const rc = try std.fs.path.join(gpa, &.{ home, ".bashrc" });
        defer gpa.free(rc);
        var f = try Io.Dir.cwd().createFile(io, rc, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "# fake rc for the installer test\n");
    }

    const real_bin = try harness.resolvePabrikBin(io, gpa);
    defer gpa.free(real_bin);
    const real_desktop = try std.fs.path.join(gpa, &.{
        std.fs.path.dirname(real_bin) orelse ".",
        if (builtin.os.tag == .windows) "pabrik-desktop.exe" else "pabrik-desktop",
    });
    defer gpa.free(real_desktop);

    // The "release assets": exact names install.sh downloads.
    for ([_]struct { src: []const u8, name: []const u8 }{
        .{ .src = real_bin, .name = try std.fmt.allocPrint(gpa, "pabrik-{s}", .{triple}) },
        .{ .src = real_desktop, .name = try std.fmt.allocPrint(gpa, "pabrik-desktop-{s}", .{triple}) },
    }) |asset| {
        defer gpa.free(asset.name);
        const dst = try std.fs.path.join(gpa, &.{ stage, asset.name });
        defer gpa.free(dst);
        try expectExitZero(
            try runChild(&.{ "cp", asset.src, dst }, &.{}),
            "cp release asset",
        );
    }

    const base_url = try std.fmt.allocPrint(gpa, "file://{s}", .{stage});
    defer gpa.free(base_url);

    // The user flow: pipe install.sh into a shell against the staged
    // "release". PABRIK_SKIP_DESKTOP_ENTRY=1 keeps the test hermetic
    // (no raw.githubusercontent fetch); the launcher step is covered
    // by the install-linux CI job, which has network. HOME points at
    // the isolated home dir (see above), never the developer's real one.
    try expectExitZero(
        try runChild(
            &.{ "bash", "install.sh", "--dir", bindir },
            &.{
                .{ "PABRIK_BASE_URL", base_url },
                .{ "PABRIK_SKIP_DESKTOP_ENTRY", "1" },
                .{ "HOME", home },
            },
        ),
        "install.sh",
    );
    return .{ .bindir = bindir, .home = home };
}

// install.sh exits 0, drops runnable binaries into an isolated bindir,
// and appends the bindir to PATH in the (isolated) shell rc file.
test "install_sh installs runnable pabrik binaries" {
    const triple = try installTriple();
    try harness.requirePabrikBin(io, gpa);

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const dirs = try installToIsolatedBindir(scratch, triple);
    defer gpa.free(dirs.bindir);
    defer gpa.free(dirs.home);
    const bindir = dirs.bindir;

    const installed = try std.fs.path.join(gpa, &.{ bindir, "pabrik" });
    defer gpa.free(installed);
    const installed_desktop = try std.fs.path.join(gpa, &.{ bindir, "pabrik-desktop" });
    defer gpa.free(installed_desktop);

    // Both payloads landed where the user was told they would.
    Io.Dir.cwd().access(io, installed, .{}) catch {
        std.debug.print("installed pabrik missing at {s}\n", .{installed});
        return error.TestUnexpectedResult;
    };
    Io.Dir.cwd().access(io, installed_desktop, .{}) catch {
        std.debug.print("installed pabrik-desktop missing at {s}\n", .{installed_desktop});
        return error.TestUnexpectedResult;
    };

    // And the installed server binary runs from its installed location.
    try expectExitZero(
        try runChild(&.{ installed, "--help" }, &.{}),
        "installed pabrik --help",
    );

    // And the bindir was exported to PATH in the isolated rc file
    // (marker once — re-running the installer never duplicates it).
    {
        const rc = try std.fs.path.join(gpa, &.{ dirs.home, ".bashrc" });
        defer gpa.free(rc);
        const body = try Io.Dir.cwd().readFileAlloc(io, rc, gpa, .limited(1 << 20));
        defer gpa.free(body);
        if (std.mem.indexOf(u8, body, "# Added by pabrik installer") == null) {
            std.debug.print("rc file missing the installer marker:\n{s}\n", .{body});
            return error.TestUnexpectedResult;
        }
        if (std.mem.indexOf(u8, body, bindir) == null) {
            std.debug.print("rc file missing the bindir export:\n{s}\n", .{body});
            return error.TestUnexpectedResult;
        }
        var count: usize = 0;
        var idx: usize = 0;
        const marker = "# Added by pabrik installer";
        while (std.mem.indexOfPos(u8, body, idx, marker)) |pos| {
            count += 1;
            idx = pos + marker.len;
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

// The installed binary boots and serves the browser URL: this is the
// "user types `pabrik`, opens the URL" moment, asserted over the wire.
test "installed pabrik serves the browser url" {
    const triple = try installTriple();
    try harness.requirePabrikBin(io, gpa);

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const dirs = try installToIsolatedBindir(scratch, triple);
    defer gpa.free(dirs.bindir);
    defer gpa.free(dirs.home);
    const bindir = dirs.bindir;

    const installed = try std.fs.path.join(gpa, &.{ bindir, "pabrik" });
    defer gpa.free(installed);

    // Boot THROUGH the harness so the server gets the isolated-HOME
    // treatment every other suite gets; the shadow is what steers
    // binary resolution at the installed copy. Restore is registered
    // first so it runs last, after harness teardown.
    const shadow = try EnvShadow.install("PABRIK_BIN", installed);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // The browser URL: http://127.0.0.1:<port>/health answers status ok.
    {
        var r = try h.http(io, .GET, "/health", .{});
        defer r.deinit();
        if (std.mem.indexOf(u8, r.text(), "\"status\":\"ok\"") == null) {
            std.debug.print("GET /health did not report status ok: {s}\n", .{r.text()});
            return error.TestUnexpectedResult;
        }
    }
    // The full stack behind that URL is alive, not just the listener.
    {
        var r = try h.http(io, .GET, "/api/workspaces", .{});
        defer r.deinit();
    }

    // The startup log tells the user where to point the browser: the
    // base URL on every boot path (this is the reported bug — a bare
    // `pabrik` used to print no URL at all).
    {
        const log = try Io.Dir.cwd().readFileAlloc(io, h.log_path, gpa, .limited(1 << 20));
        defer gpa.free(log);
        const port_str = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{h.port});
        defer gpa.free(port_str);
        if (std.mem.indexOf(u8, log, port_str) == null) {
            std.debug.print("server log missing the browser URL {s}\n", .{port_str});
            return error.TestUnexpectedResult;
        }
    }
}

// The installed server discovers the shipped UI next to itself and
// serves the app with no --static-dir flag: this is the "/app 404"
// report. The fixture stands in for the html/ tarball install.sh
// extracts (tarball download+extract itself is asserted by the
// install-* CI jobs against the real release, which have network;
// here the server-side discovery is what's under test, over the wire).
test "installed pabrik serves the app from its bundled html dir" {
    const triple = try installTriple();
    try harness.requirePabrikBin(io, gpa);

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const dirs = try installToIsolatedBindir(scratch, triple);
    defer gpa.free(dirs.bindir);
    defer gpa.free(dirs.home);
    const bindir = dirs.bindir;

    // Fixture UI at <bindir>/html/index.html — the exact layout
    // install.sh produces and the server's next-to-exe probe reads.
    // Harness.boot passes the installed binary by absolute path, so
    // argv[0] carries a dir and the probe engages.
    const html_dir = try std.fs.path.join(gpa, &.{ bindir, "html" });
    defer gpa.free(html_dir);
    try Io.Dir.cwd().createDirPath(io, html_dir);
    const index_path = try std.fs.path.join(gpa, &.{ html_dir, "index.html" });
    defer gpa.free(index_path);
    {
        var f = try Io.Dir.cwd().createFile(io, index_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "<!DOCTYPE html><html><body>pabrik installed app shell</body></html>");
    }

    const installed = try std.fs.path.join(gpa, &.{ bindir, "pabrik" });
    defer gpa.free(installed);

    const shadow = try EnvShadow.install("PABRIK_BIN", installed);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // GET / serves the bundled shell — not a 404.
    {
        var r = try h.http(io, .GET, "/", .{});
        defer r.deinit();
        if (std.mem.indexOf(u8, r.text(), "pabrik installed app shell") == null) {
            std.debug.print("GET / did not serve the bundled app shell: {s}\n", .{r.text()});
            return error.TestUnexpectedResult;
        }
    }
}
