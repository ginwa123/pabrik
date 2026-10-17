// install_browser_url_test.zig — the curl-install user flow, end to end.
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
/// Harness.boot copies into the child env and resolvePabrikBin reads — so
/// Harness.boot resolves the INSTALLED binary.
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
/// copies plus the isolated HOME the install ran under.
const InstallDirs = struct { bindir: []u8, home: []u8, base_url: []u8 };

/// The desktop app's runtime webapp cache under an isolated HOME. install.sh
/// resolves it as `${XDG_DATA_HOME:-$HOME/.local/share}/pabrik/desktop-webapp`
/// — the same path src/apps/desktop_app/extraction.zig materialises into.
fn webappCacheDir(alloc: Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ home, ".local", "share", "pabrik", "desktop-webapp" });
}

fn pathExists(path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// The env install.sh runs under here: an isolated HOME plus its matching
/// XDG_DATA_HOME (so the cache assertions cannot touch the developer's real
/// cache) and no .desktop fetch.
fn installEnv(home: []const u8, xdg_data_home: []const u8, base_url: []const u8) [4][2][]const u8 {
    return .{
        .{ "HOME", home },
        .{ "XDG_DATA_HOME", xdg_data_home },
        .{ "PABRIK_BASE_URL", base_url },
        .{ "PABRIK_SKIP_DESKTOP_ENTRY", "1" },
    };
}

/// Leave a stale runtime webapp cache behind, the way a desktop run from an
/// earlier build does: a `<hash>` dir holding an index.html.
fn seedWebappCache(cache: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, cache);
    const hash_dir = try std.fs.path.join(gpa, &.{ cache, "stalehash0000" });
    defer gpa.free(hash_dir);
    try Io.Dir.cwd().createDirPath(io, hash_dir);
    const index = try std.fs.path.join(gpa, &.{ hash_dir, "index.html" });
    defer gpa.free(index);
    var f = try Io.Dir.cwd().createFile(io, index, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, "<html>stale webapp</html>");
}

fn installToIsolatedBindir(scratch: []const u8, triple: []const u8) !InstallDirs {
    const stage = try harness.harnessPath(gpa, scratch, &.{"release-stage"});
    defer gpa.free(stage);
    try Io.Dir.cwd().createDirPath(io, stage);

    const bindir = try harness.harnessPath(gpa, scratch, &.{"bin"});
    errdefer gpa.free(bindir);

    // Isolated HOME with a pre-existing .bashrc: install.sh only appends its
    // PATH export to rc files that already exist (never creates them), and
    // the isolated HOME keeps the test from touching the developer's real
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

    // A stale runtime webapp cache, the way an earlier install's desktop run
    // leaves one behind: a real install must clear it.
    const cache = try webappCacheDir(gpa, home);
    defer gpa.free(cache);
    try seedWebappCache(cache);

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
    errdefer gpa.free(base_url);

    // The user flow: pipe install.sh into a shell against the staged
    // "release". XDG_DATA_HOME is pinned to the isolated HOME so the cache
    // install.sh clears is the fixture's, never the developer's.
    const xdg_data_home = try std.fs.path.join(gpa, &.{ home, ".local", "share" });
    defer gpa.free(xdg_data_home);
    const env = installEnv(home, xdg_data_home, base_url);
    try expectExitZero(
        try runChild(&.{ "bash", "install.sh", "--dir", bindir }, &env),
        "install.sh",
    );
    return .{ .bindir = bindir, .home = home, .base_url = base_url };
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
    defer gpa.free(dirs.base_url);
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

    // The stale runtime webapp cache the fixture seeded is gone: a real
    // install clears it so the next launch re-extracts this build's assets.
    const cache = try webappCacheDir(gpa, dirs.home);
    defer gpa.free(cache);
    if (pathExists(cache)) {
        std.debug.print("install.sh left the webapp cache behind: {s}\n", .{cache});
        return error.TestUnexpectedResult;
    }

    // Re-seed it, then re-run against identical content: the up-to-date fast
    // path exits 0 before touching anything, so the cache survives — that is
    // what "user updates when there is nothing new" must do.
    try seedWebappCache(cache);
    const rerun_xdg = try std.fs.path.join(gpa, &.{ dirs.home, ".local", "share" });
    defer gpa.free(rerun_xdg);
    const rerun_env = installEnv(dirs.home, rerun_xdg, dirs.base_url);
    try expectExitZero(
        try runChild(&.{ "bash", "install.sh", "--dir", bindir }, &rerun_env),
        "install.sh re-run",
    );
    if (!pathExists(cache)) {
        std.debug.print("the up-to-date re-run cleared the cache at {s}\n", .{cache});
        return error.TestUnexpectedResult;
    }

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

// --uninstall removes the binaries, the shipped html dir AND the runtime
// webapp cache: a removed install leaves nothing of the webapp behind.
test "install_sh --uninstall removes the webapp cache" {
    const triple = try installTriple();
    try harness.requirePabrikBin(io, gpa);

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const dirs = try installToIsolatedBindir(scratch, triple);
    defer gpa.free(dirs.bindir);
    defer gpa.free(dirs.home);
    defer gpa.free(dirs.base_url);
    const bindir = dirs.bindir;

    // The shipped-UI layout install.sh produces, plus a runtime webapp cache
    // (the fixture's install cleared the one it seeded) — both must be gone
    // afterwards.
    const html_dir = try std.fs.path.join(gpa, &.{ bindir, "html" });
    defer gpa.free(html_dir);
    try Io.Dir.cwd().createDirPath(io, html_dir);
    const html_index = try std.fs.path.join(gpa, &.{ html_dir, "index.html" });
    defer gpa.free(html_index);
    {
        var f = try Io.Dir.cwd().createFile(io, html_index, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "<html>shipped ui</html>");
    }
    const cache = try webappCacheDir(gpa, dirs.home);
    defer gpa.free(cache);
    try seedWebappCache(cache);
    try testing.expect(pathExists(cache));

    const xdg_data_home = try std.fs.path.join(gpa, &.{ dirs.home, ".local", "share" });
    defer gpa.free(xdg_data_home);
    const env = installEnv(dirs.home, xdg_data_home, dirs.base_url);
    try expectExitZero(
        try runChild(&.{ "bash", "install.sh", "--dir", bindir, "--uninstall" }, &env),
        "install.sh --uninstall",
    );

    const installed = try std.fs.path.join(gpa, &.{ bindir, "pabrik" });
    defer gpa.free(installed);
    if (pathExists(installed) or pathExists(html_index) or pathExists(cache)) {
        std.debug.print(
            "--uninstall left something behind: bin={} html={} cache={}\n",
            .{ pathExists(installed), pathExists(html_index), pathExists(cache) },
        );
        return error.TestUnexpectedResult;
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
    defer gpa.free(dirs.base_url);
    const bindir = dirs.bindir;

    const installed = try std.fs.path.join(gpa, &.{ bindir, "pabrik" });
    defer gpa.free(installed);

    // Boot THROUGH the harness so the server gets the isolated-HOME treatment
    // every other suite gets; the shadow is what steers binary resolution at
    // the installed copy.
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

// The installed server discovers the shipped UI next to itself and serves the
// app with no --static-dir flag: this is the "/app 404" report.
test "installed pabrik serves the app from its bundled html dir" {
    const triple = try installTriple();
    try harness.requirePabrikBin(io, gpa);

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const dirs = try installToIsolatedBindir(scratch, triple);
    defer gpa.free(dirs.bindir);
    defer gpa.free(dirs.home);
    defer gpa.free(dirs.base_url);
    const bindir = dirs.bindir;

    // Fixture UI at <bindir>/html/index.html — the exact layout install.sh
    // produces and the server's next-to-exe probe reads.
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

    // Spawn EXACTLY like the user does: bare `pabrik`, resolved through PATH
    // — so argv[0] has no directory at all.
    var env_map = try std.process.Environ.createMap(std.testing.environ, gpa);
    defer env_map.deinit();
    try env_map.put("HOME", dirs.home);
    const path_val = try std.fmt.allocPrint(gpa, "{s}{c}{s}", .{
        bindir,
        std.fs.path.delimiter,
        env_map.get("PATH") orelse "",
    });
    defer gpa.free(path_val);
    try env_map.put("PATH", path_val);

    const log_path = try std.fs.path.join(gpa, &.{ bindir, "server.log" });
    defer gpa.free(log_path);
    var log_file = try Io.Dir.cwd().createFile(io, log_path, .{});
    defer log_file.close(io);

    // argv[0] is the BARE name, and cwd is the repo root — nothing ties this
    // process to bindir except PATH.
    const argv = [_][]const u8{ "bash", "-c", "exec pabrik" };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .environ_map = &env_map,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
    });
    errdefer {
        // kill() already reaps and clears the id; wait() would assert.
        child.kill(io);
    }

    // Wait for readiness, then read the port off the startup line.
    var ready = false;
    var attempt: usize = 0;
    while (attempt < 300) : (attempt += 1) {
        const body = Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(1 << 20)) catch {
            Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
            continue;
        };
        ready = std.mem.indexOf(u8, body, "Agent is ready to serve!") != null;
        gpa.free(body);
        if (ready) break;
        Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
    }
    if (!ready) {
        const body = Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(1 << 20)) catch "";
        defer if (body.len > 0) gpa.free(body);
        std.debug.print("installed server never became ready; log:\n{s}\n", .{body});
        return error.TestUnexpectedResult;
    }

    const log = try Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(1 << 20));
    defer gpa.free(log);
    const url_prefix = "Open in your browser: http://127.0.0.1:";
    const at = std.mem.indexOf(u8, log, url_prefix) orelse {
        std.debug.print("log missing the browser URL line\n", .{});
        return error.TestUnexpectedResult;
    };
    var end = at + url_prefix.len;
    while (end < log.len and log[end] >= '0' and log[end] <= '9') : (end += 1) {}
    const port = std.fmt.parseInt(u16, log[at + url_prefix.len .. end], 10) catch {
        std.debug.print("could not parse the port from the log\n", .{});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, log, "serving installed webapp") == null) {
        std.debug.print("server did not discover the bundled html dir; log:\n{s}\n", .{log});
        return error.TestUnexpectedResult;
    }

    // GET / serves the bundled shell — not a 404.
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const app_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{port});
    defer gpa.free(app_url);
    {
        var req = try client.request(.GET, try std.Uri.parse(app_url), .{ .redirect_behavior = .unhandled });
        defer req.deinit();
        try req.sendBodiless();
        var resp = try req.receiveHead(&.{});
        const status: u16 = @intFromEnum(resp.head.status);
        var body_buf: [4096]u8 = undefined;
        var body_len: usize = 0;
        var reader = resp.reader(&.{});
        while (body_len < body_buf.len) {
            const n = reader.readSliceShort(body_buf[body_len..]) catch break;
            if (n == 0) break;
            body_len += n;
        }
        const page = body_buf[0..body_len];
        if (status != 200 or std.mem.indexOf(u8, page, "pabrik installed app shell") == null) {
            std.debug.print("GET / returned {d}, body: {s}\n", .{ status, page });
            return error.TestUnexpectedResult;
        }
    }

    // Teardown: ask nicely, then make sure.
    {
        const shutdown_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/test/shutdown", .{port});
        defer gpa.free(shutdown_url);
        if (client.request(.POST, try std.Uri.parse(shutdown_url), .{ .redirect_behavior = .unhandled })) |req| {
            var r = req;
            defer r.deinit();
            r.sendBodyComplete(&.{}) catch {};
            _ = r.receiveHead(&.{}) catch {};
        } else |_| {}
    }
    Io.sleep(io, .fromMilliseconds(2000), .awake) catch {};
    child.kill(io); // reaps + clears the id (wait() after this would assert)
}
