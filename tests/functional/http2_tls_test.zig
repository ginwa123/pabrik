// HTTP/2 over TLS (ALPN) end-to-end tests — **the acceptance contract**. Zig
// port of `tests/functional/http2_tls_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;

const gpa = testing.allocator;
const io = testing.io;

// The `PABRIK_RUN_KNOWN_BROKEN_TLS` gate that used to live here is gone: the
// upstream fix is in the pinned kabelweb (PR #7, pinned at `eaf2b583`). The
// docstring above keeps the diagnosis for the next person who sees `curl: (35)`.

// ============================================================================
// curl helpers
// ============================================================================

/// Wall-clock ceiling for one curl invocation.
const CURL_MAX_TIME_S: u32 = 10;

fn nowMs() i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

fn sleepMs(ms: i64) void {
    Io.sleep(io, .fromMilliseconds(ms), .awake) catch {};
}

/// `shutil.which("curl")` — owned, or null.
fn findCurl() ?[]u8 {
    const path_env = std.process.Environ.getAlloc(std.testing.environ, gpa, "PATH") catch return null;
    defer gpa.free(path_env);
    const exe = if (builtin.os.tag == .windows) "curl.exe" else "curl";
    var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const cand = std.fs.path.join(gpa, &.{ dir, exe }) catch continue;
        defer gpa.free(cand);
        std.Io.Dir.cwd().access(io, cand, .{ .execute = true }) catch continue;
        return gpa.dupe(u8, cand) catch null;
    }
    return null;
}

/// Skip when this curl cannot ask for h2 at all. CI ships curl 8.22 linked
/// against nghttp2, so this does not fire there; it keeps the suite honest on
/// a minimal dev box instead of asserting on a curl that cannot speak HTTP/2.
fn requireHttp2Curl() ![]u8 {
    // Ownership TRANSFERS to the caller — there is deliberately no `defer
    // gpa.free(curl)` here.
    const curl = findCurl() orelse {
        std.debug.print("curl not on PATH; skipping\n", .{});
        return error.SkipZigTest;
    };

    const res = std.process.run(gpa, io, .{ .argv = &.{ curl, "--version" } }) catch |err| {
        gpa.free(curl);
        std.debug.print("curl --version failed ({s}); skipping\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    if (std.mem.indexOf(u8, res.stdout, "nghttp2") == null and
        std.mem.indexOf(u8, res.stdout, "HTTP2") == null)
    {
        std.debug.print("curl lacks HTTP/2 support: {s}; skipping\n", .{
            if (res.stdout.len == 0) "<no output>" else std.mem.trim(u8, res.stdout, " \r\n"),
        });
        gpa.free(curl);
        return error.SkipZigTest;
    }
    return curl;
}

/// One bounded curl invocation. `rc == 124` means curl hit the wall clock.
const CurlResult = struct {
    rc: i32,
    code: []u8,
    version: []u8,
    stderr: []u8,

    fn deinit(self: *CurlResult) void {
        gpa.free(self.code);
        gpa.free(self.version);
        gpa.free(self.stderr);
        self.* = undefined;
    }

    fn ok(self: *const CurlResult) bool {
        return self.rc == 0;
    }
};

/// Run curl once and report `(rc, http_code, http_version, stderr)`.
fn curlRun(curl: []const u8, url: []const u8, extra: []const []const u8, max_time_s: u32) !CurlResult {
    // Owned separately and freed by the `defer`s below: an `allocPrint`
    // INLINE in the `appendSlice` argument list would outlive nothing and
    // leak once per invocation.
    const max_time_str = try std.fmt.allocPrint(gpa, "{d}", .{max_time_s});
    defer gpa.free(max_time_str);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        curl,
        "-sS",
        "--connect-timeout",
        "3",
        "--max-time",
        max_time_str,
        "-o",
        if (builtin.os.tag == .windows) "nul" else "/dev/null",
        "-w",
        "%{http_code} %{http_version}",
    });
    try argv.appendSlice(gpa, extra);
    try argv.append(gpa, url);

    const res = std.process.run(gpa, io, .{ .argv = argv.items }) catch |err| {
        return .{
            .rc = 124,
            .code = try gpa.dupe(u8, ""),
            .version = try gpa.dupe(u8, ""),
            .stderr = try std.fmt.allocPrint(gpa, "curl could not be spawned ({s})", .{@errorName(err)}),
        };
    };
    // The captured buffers are COPIES of what the caller wants (`code` /
    // `version` / `stderr` are duped below), so they are freed here.
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const term_rc: i32 = switch (res.term) {
        .exited => |c| @intCast(c),
        else => 124, // killed by a signal — indistinguishable from a hang here
    };
    // `code version` on stdout; the version may be EMPTY (a failed
    // transfer writes nothing after the space).
    const cut = std.mem.indexOfScalar(u8, res.stdout, ' ') orelse res.stdout.len;
    return .{
        .rc = term_rc,
        .code = try gpa.dupe(u8, std.mem.trim(u8, res.stdout[0..cut], " \r\n")),
        .version = try gpa.dupe(u8, std.mem.trim(u8, res.stdout[cut..], " \r\n")),
        .stderr = try gpa.dupe(u8, std.mem.trim(u8, res.stderr, " \r\n")),
    };
}

/// `(http_version, body)` for a single request — Python's
/// `_curl_http_version`, whose `%{http_version}` write-out tells us which
/// protocol the connection actually used (`"2"` vs `"1.1"`).
fn curlHttpVersion(curl: []const u8, url: []const u8, extra: []const []const u8) ![2][]u8 {
    const max_time_str = try std.fmt.allocPrint(gpa, "{d}", .{CURL_MAX_TIME_S});
    defer gpa.free(max_time_str);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        curl,
        "-sS",
        "--connect-timeout",
        "3",
        "--max-time",
        max_time_str,
        "-o",
        "-",
        "-w",
        "\n%{http_version}",
    });
    try argv.appendSlice(gpa, extra);
    try argv.append(gpa, url);

    const res = std.process.run(gpa, io, .{ .argv = argv.items }) catch |err| {
        std.debug.print("curl exceeded {d}s with no response: {s} ({s})\n", .{ CURL_MAX_TIME_S, url, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    const rc: i32 = switch (res.term) {
        .exited => |c| @intCast(c),
        else => -1,
    };
    if (rc != 0) {
        std.debug.print("curl failed (rc={d}): {s}\n", .{ rc, res.stderr });
        return error.TestUnexpectedResult;
    }
    // `body, _, version = stdout.rpartition("\n")`.
    const cut = std.mem.lastIndexOfScalar(u8, res.stdout, '\n') orelse return error.TestUnexpectedResult;
    return .{
        try gpa.dupe(u8, std.mem.trim(u8, res.stdout[0..cut], "\r")),
        try gpa.dupe(u8, std.mem.trim(u8, res.stdout[cut + 1 ..], " \r\n")),
    };
}

// ============================================================================
// TLS-aware boot helper
// ============================================================================

/// Result of `spawnTlsPabrik`: always a harness, plus whether it got ready.
const Booted = struct {
    h: Harness,
    ready: bool,
    detail: []u8,

    /// The Python `finally: booted.harness.teardown()`, and the ONLY teardown
    /// path: an early `return` after a failed assertion must still stop the
    /// child and delete the isolated HOME.
    fn deinit(self: *Booted) void {
        // `Harness.stopBinary` opens with a PLAINTEXT `POST /test/shutdown`
        // and `catch return`s when it fails — and for a TLS-only listener
        // that POST connects but never gets a response head, so the
        if (self.h.pid) |pid| harness.signalGroup(pid, harness.SIGKILL);

        self.h.deinit(io) catch |err| {
            std.debug.print("harness teardown: {s}\n", .{@errorName(err)});
        };
        gpa.free(self.detail);
    }
};

fn dupeEmpty() []u8 {
    return gpa.dupe(u8, "") catch @panic("OOM duping an empty string");
}

/// Boot `pabrik` the way `Harness.boot` does, but probe for the protocol the
/// listener was *asked* to speak. `extra_args` is appended after `--port`
/// (`--tls-selfsigned` etc.).
fn spawnTlsPabrik(extra_args: []const []const u8, tls: bool, ready_timeout_ms: i64) !Booted {
    const bin = try harness.resolvePabrikBin(io, gpa);
    errdefer gpa.free(bin);
    const curl = try requireHttp2Curl();
    defer gpa.free(curl);

    var orig_home = std.process.Environ.getAlloc(std.testing.environ, gpa, "HOME") catch try gpa.dupe(u8, "");
    if (orig_home.len == 0) {
        gpa.free(orig_home);
        orig_home = std.process.Environ.getAlloc(std.testing.environ, gpa, "USERPROFILE") catch try gpa.dupe(u8, "");
    }
    if (orig_home.len == 0) {
        gpa.free(orig_home);
        std.debug.print("HOME not set; refusing to boot. Functional tests need a normal shell.\n", .{});
        return error.HomeNotSet;
    }
    errdefer gpa.free(orig_home);

    const port = try harness.findFreePortRandom(gpa);
    const temp_dir = try harness.makeScratchDir(gpa);
    errdefer gpa.free(temp_dir);
    errdefer harness.cleanupExtraDir(io, gpa, temp_dir);

    // Every byte of the child's HOME lives inside `temp_dir`, including
    // the XDG dirs — the self-signed cert is written to the app data
    // dir, so a developer's real XDG_DATA_HOME must not be touched.
    const xdg_config = try std.fs.path.join(gpa, &.{ temp_dir, ".config" });
    defer gpa.free(xdg_config);
    const xdg_state = try std.fs.path.join(gpa, &.{ temp_dir, ".local", "state" });
    defer gpa.free(xdg_state);
    const xdg_data = try std.fs.path.join(gpa, &.{ temp_dir, ".local", "share" });
    defer gpa.free(xdg_data);
    const xdg_cache = try std.fs.path.join(gpa, &.{ temp_dir, ".cache" });
    defer gpa.free(xdg_cache);
    try std.Io.Dir.cwd().createDirPath(io, xdg_config);
    try std.Io.Dir.cwd().createDirPath(io, xdg_state);
    try std.Io.Dir.cwd().createDirPath(io, xdg_data);
    try std.Io.Dir.cwd().createDirPath(io, xdg_cache);

    const log_path = try std.fs.path.join(gpa, &.{ temp_dir, "pabrik.log" });
    errdefer gpa.free(log_path);
    const log_file = try std.Io.Dir.cwd().createFile(io, log_path, .{});
    defer log_file.close(io);

    var env_map = try std.process.Environ.createMap(std.testing.environ, gpa);
    defer env_map.deinit();
    try env_map.put("HOME", temp_dir);
    try env_map.put("XDG_CONFIG_HOME", xdg_config);
    try env_map.put("XDG_STATE_HOME", xdg_state);
    try env_map.put("XDG_DATA_HOME", xdg_data);
    try env_map.put("XDG_CACHE_HOME", xdg_cache);

    const port_str = try std.fmt.allocPrint(gpa, "{d}", .{port});
    defer gpa.free(port_str);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ bin, "--port", port_str });
    try argv.appendSlice(gpa, extra_args);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = &env_map,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
        // Own process group, so `Harness.deinit`'s `killpg` reaches the
        // whole tree.
        .pgid = if (builtin.os.tag == .windows) null else 0,
    });
    // Only fires when this function returns an ERROR: on success the pid
    // belongs to the returned `Booted.h`, which tears the child down.
    errdefer child.kill(io);
    // Deliberately NOT `wait`ed: the pid is handed to `Harness`, which
    // signals by process group exactly like the Python harness did.
    const child_pid: u32 = @intCast(child.id.?);

    var h = Harness{
        .allocator = gpa,
        .port = port,
        .pabrik_bin = bin,
        .temp_dir = temp_dir,
        .orig_home = orig_home,
        .log_path = log_path,
        .pid = child_pid,
        .dry_run = false,
        .orig_userprofile = dupeEmpty(),
        .orig_appdata = dupeEmpty(),
        .orig_localappdata = dupeEmpty(),
        .orig_xdg_config_home = dupeEmpty(),
        .orig_xdg_state_home = dupeEmpty(),
        .orig_xdg_data_home = dupeEmpty(),
        .orig_xdg_cache_home = dupeEmpty(),
    };

    const started = nowMs();
    const deadline = started + ready_timeout_ms;
    var last: []u8 = "";
    defer if (last.len > 0) gpa.free(last);

    while (true) {
        // Early exit?  `waitpid(WNOHANG)` reaps, after which `pid = null`
        // keeps `Harness.deinit` from signalling a pid the kernel may
        // have recycled.
        if (reapIfExited(&child)) h.pid = null;

        if (h.pid == null) {
            // `tailLog` returns an OWNED buffer.
            const tail = try h.tailLog(io, gpa, 30);
            defer gpa.free(tail);
            return .{
                .h = h,
                .ready = false,
                .detail = try std.fmt.allocPrint(
                    gpa,
                    "pabrik exited during boot ({s} mode)\n--- last 30 lines of log ---\n{s}\n",
                    .{ if (tls) "TLS" else "plaintext", tail },
                ),
            };
        }

        if (try probe(port, tls, curl, &last)) {
            return .{ .h = h, .ready = true, .detail = try gpa.dupe(u8, "") };
        }

        // The listener answers plaintext while https never negotiates.
        if (tls and nowMs() - started > 3_000) {
            if (try probe(port, false, curl, &last)) {
                const tail = try h.tailLog(io, gpa, 30);
                defer gpa.free(tail);
                return .{
                    .h = h,
                    .ready = false,
                    .detail = try std.fmt.allocPrint(
                        gpa,
                        "the listener answered PLAINTEXT HTTP/1.1 while 'https://' never " ++
                            "negotiated: the requested TLS mode was not honoured " ++
                            "(last TLS probe: {s})\n--- last 30 lines of log ---\n{s}\n",
                        .{ last, tail },
                    ),
                };
            }
        }

        if (nowMs() >= deadline) {
            const tail = try h.tailLog(io, gpa, 30);
            defer gpa.free(tail);
            return .{
                .h = h,
                .ready = false,
                .detail = try std.fmt.allocPrint(
                    gpa,
                    "pabrik did not become ready in {d}ms in {s} mode (last probe: {s})\n--- last 30 lines of log ---\n{s}\n",
                    .{ ready_timeout_ms, if (tls) "TLS" else "plaintext", last, tail },
                ),
            };
        }
        sleepMs(150);
    }
}

/// Reap the child if it already exited. Returns true when it did.
fn reapIfExited(child: *std.process.Child) bool {
    if (comptime builtin.os.tag == .windows) return false;
    if (child.id == null) return true;
    const pid: posix.pid_t = @intCast(child.id.?);
    var status: u32 = 0;
    const got = posix.system.waitpid(pid, &status, posix.W.NOHANG);
    if (got != pid) return false;
    // The pid is now a free slot; null it so nothing signals it again.
    child.id = null;
    return true;
}

/// One readiness attempt: `true` when ready, otherwise a REASON (owned,
/// stored into `detail_out`, whose previous value it frees) so the
/// timeout diagnostic can say what the last probe actually saw.
fn probe(port: u16, tls: bool, curl: []const u8, detail_out: *[]u8) !bool {
    const note = struct {
        fn set(slot: *[]u8, text: []const u8) void {
            if (slot.*.len > 0) gpa.free(slot.*);
            slot.* = gpa.dupe(u8, text) catch @panic("OOM recording a probe detail");
        }
    }.set;

    if (tls) {
        const url = try std.fmt.allocPrint(gpa, "https://127.0.0.1:{d}/health", .{port});
        defer gpa.free(url);
        var res = try curlRun(curl, url, &.{ "-k", "--http2" }, 3);
        defer res.deinit();
        if (res.ok() and std.mem.eql(u8, res.code, "200")) {
            note(detail_out, "");
            return true;
        }
        const msg = try std.fmt.allocPrint(gpa, "curl rc={d} code='{s}' err='{s}'", .{ res.rc, res.code, res.stderr });
        if (detail_out.*.len > 0) gpa.free(detail_out.*);
        detail_out.* = msg;
        return false;
    }

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/health", .{port});
    defer gpa.free(url);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var req = client.request(.GET, std.Uri.parse(url) catch return false, .{}) catch {
        note(detail_out, "connect refused");
        return false;
    };
    defer req.deinit();
    req.sendBodiless() catch {
        note(detail_out, "send failed");
        return false;
    };
    var resp = req.receiveHead(&.{}) catch {
        note(detail_out, "no response head");
        return false;
    };
    if (@intFromEnum(resp.head.status) != 200) {
        const msg = try std.fmt.allocPrint(gpa, "plaintext /health answered {d}", .{@intFromEnum(resp.head.status)});
        if (detail_out.*.len > 0) gpa.free(detail_out.*);
        detail_out.* = msg;
        return false;
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = resp.reader(&.{}).streamRemaining(&out.writer) catch {
        note(detail_out, "body read failed");
        return false;
    };
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, out.written(), .{}) catch {
        note(detail_out, "/health body is not JSON");
        return false;
    };
    defer parsed.deinit();
    const st = parsed.value.object.get("status") orelse {
        note(detail_out, "unexpected /health body");
        return false;
    };
    if (!std.mem.eql(u8, st.string, "ok")) {
        note(detail_out, "unexpected /health body");
        return false;
    }
    note(detail_out, "");
    return true;
}

/// Fail the test with the captured boot detail. The deliverable's visible
/// output IS these failures, so keep them to one readable message instead of
/// a repr of the whole `Booted`.
fn requireReady(b: *Booted) !void {
    if (!b.ready) {
        std.debug.print("{s}\n", .{b.detail});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Startup-log parsing
// ============================================================================

/// Extract the certificate path the server printed at startup.
/// `--tls-selfsigned` generates the cert on first run, so the test cannot
/// know the path a priori — the contract is that the startup log prints it.
fn tlsCertPath(h: *Harness) ?[]u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(io, h.log_path, gpa, .limited(1 << 20)) catch return null;
    defer gpa.free(text);

    var best: ?[]const u8 = null;
    var best_score: i32 = std.math.minInt(i32);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var low_buf: [512]u8 = undefined;
        const low = std.ascii.lowerString(low_buf[0..@min(low_buf.len, line.len)], line);

        var tokens = std.mem.tokenizeAny(u8, line, " \t'\"()=");
        while (tokens.next()) |tok| {
            if (!std.fs.path.isAbsolute(tok)) continue;
            const is_pem = std.mem.endsWith(u8, tok, ".pem");
            const is_crt = std.mem.endsWith(u8, tok, ".crt") or std.mem.endsWith(u8, tok, ".cer");
            if (!is_pem and !is_crt) continue;

            var score: i32 = 0;
            if (std.mem.indexOf(u8, low, "cert") != null) score += 2;
            if (is_crt) score += 1;
            if (std.mem.indexOf(u8, low, "key") != null or
                std.mem.indexOf(u8, low, "private") != null) score -= 3;
            if (best == null or score > best_score) {
                best = tok;
                best_score = score;
            }
        }
    }
    const found = best orelse return null;
    return gpa.dupe(u8, found) catch null;
}

// ============================================================================
// Tests
// ============================================================================

// `--tls-selfsigned` + a client that offers h2 (ALPN) → HTTP/2. `curl -k
// --http2` over an https URL negotiates via ALPN; `%{http_version}` reports
// `2` only if the server offered `h2` first and our client took it.
test "tls_selfsigned_serves_http2" {
    try harness.requirePabrikBin(io, gpa);

    var b = try spawnTlsPabrik(&.{"--tls-selfsigned"}, true, 45_000);
    defer b.deinit();
    try requireReady(&b);

    const curl = try requireHttp2Curl();
    defer gpa.free(curl);
    const url = try std.fmt.allocPrint(gpa, "https://127.0.0.1:{d}/health", .{b.h.port});
    defer gpa.free(url);

    const pair = try curlHttpVersion(curl, url, &.{ "-k", "--http2" });
    defer gpa.free(pair[0]);
    defer gpa.free(pair[1]);
    const version = pair[1];
    const body = pair[0];
    if (!std.mem.eql(u8, version, "2")) {
        std.debug.print("expected ALPN h2, got '{s}' (body={s})\n", .{ version, body });
        return error.TestUnexpectedResult;
    }
    if (std.ascii.indexOfIgnoreCase(body, "ok") == null) {
        std.debug.print("unexpected /health body: {s}\n", .{body});
        return error.TestUnexpectedResult;
    }
    // `defer b.deinit()` above already stopped the child and deleted the
    // isolated HOME; that mirrors the Python's `finally:
    // booted.harness.teardown()`.
}

// A TLS client that only asks for `http/1.1` is still served, on h1. The ALPN
// list is `["h2", "http/1.1"]`: the server must not require h2 from every TLS
// client.
test "tls_offers_http11_fallback" {
    try harness.requirePabrikBin(io, gpa);

    var b = try spawnTlsPabrik(&.{"--tls-selfsigned"}, true, 45_000);
    defer b.deinit();
    try requireReady(&b);

    const curl = try requireHttp2Curl();
    defer gpa.free(curl);
    const url = try std.fmt.allocPrint(gpa, "https://127.0.0.1:{d}/health", .{b.h.port});
    defer gpa.free(url);

    var res = try curlRun(curl, url, &.{ "-k", "--http1.1" }, CURL_MAX_TIME_S);
    defer res.deinit();
    if (res.rc != 0) {
        std.debug.print("curl failed (rc={d}): {s}\n", .{ res.rc, res.stderr });
        return error.TestUnexpectedResult;
    }
    if (!std.mem.eql(u8, res.code, "200")) {
        std.debug.print("expected 200 over TLS+http/1.1, got '{s}'\n", .{res.code});
        return error.TestUnexpectedResult;
    }
    if (!std.mem.eql(u8, res.version, "1.1")) {
        std.debug.print("expected the http/1.1 fallback, got '{s}'\n", .{res.version});
        return error.TestUnexpectedResult;
    }
    // `defer b.deinit()` above already stopped the child and deleted the
    // isolated HOME; that mirrors the Python's `finally:
    // booted.harness.teardown()`.
}

// `--cacert <cert>` verifies for BOTH `localhost` and `127.0.0.1`.
test "tls_cert_san_matches_localhost" {
    try harness.requirePabrikBin(io, gpa);

    var b = try spawnTlsPabrik(&.{"--tls-selfsigned"}, true, 45_000);
    defer b.deinit();
    try requireReady(&b);

    const curl = try requireHttp2Curl();
    defer gpa.free(curl);

    const cert = tlsCertPath(&b.h) orelse {
        const tail = try b.h.tailLog(io, gpa, 30);
        defer gpa.free(tail);
        std.debug.print(
            "the startup log must print the certificate path for --tls-selfsigned; " ++
                "no *.pem/*.crt path was found in {s}\n--- log ---\n{s}\n",
            .{ b.h.log_path, tail },
        );
        return error.TestUnexpectedResult;
    };
    defer gpa.free(cert);
    std.Io.Dir.cwd().access(io, cert, .{}) catch {
        std.debug.print("logged certificate path does not exist: {s}\n", .{cert});
        return error.TestUnexpectedResult;
    };

    for ([_][]const u8{ "localhost", "127.0.0.1" }) |host| {
        const url = try std.fmt.allocPrint(gpa, "https://{s}:{d}/health", .{ host, b.h.port });
        defer gpa.free(url);
        var res = try curlRun(curl, url, &.{ "--cacert", cert }, CURL_MAX_TIME_S);
        defer res.deinit();
        if (!res.ok() or !std.mem.eql(u8, res.code, "200")) {
            std.debug.print(
                "https://{s}/health did not verify against {s} (rc={d}, code='{s}', http='{s}', " ++
                    "err='{s}'); the cert's SANs must include DNS:localhost and IP:127.0.0.1\n",
                .{ host, cert, res.rc, res.code, res.version, res.stderr },
            );
            return error.TestUnexpectedResult;
        }
    }
    // `defer b.deinit()` above already stopped the child and deleted the
    // isolated HOME; that mirrors the Python's `finally:
    // booted.harness.teardown()`.
}

// Default (no TLS flags): HTTP/1.1 and h2c keep working exactly as today.
// `--http2 h2c` is passed because it is the pre-existing, non-TLS flag that
// makes the prior-knowledge assertion meaningful; nothing TLS-related is set.
test "plaintext_still_works_without_tls_flags" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{ .extra_args = &.{ "--http2", "h2c" } });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const curl = try requireHttp2Curl();
    defer gpa.free(curl);
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/health", .{h.port});
    defer gpa.free(url);

    {
        const pair = try curlHttpVersion(curl, url, &.{});
        defer gpa.free(pair[0]);
        defer gpa.free(pair[1]);
        if (!std.mem.eql(u8, pair[1], "1.1")) {
            std.debug.print("expected plaintext HTTP/1.1, got '{s}'\n", .{pair[1]});
            return error.TestUnexpectedResult;
        }
        if (std.ascii.indexOfIgnoreCase(pair[0], "ok") == null) {
            std.debug.print("unexpected /health body: {s}\n", .{pair[0]});
            return error.TestUnexpectedResult;
        }
    }
    {
        const pair = try curlHttpVersion(curl, url, &.{"--http2-prior-knowledge"});
        defer gpa.free(pair[0]);
        defer gpa.free(pair[1]);
        if (!std.mem.eql(u8, pair[1], "2")) {
            std.debug.print("expected h2c to still work, got '{s}'\n", .{pair[1]});
            return error.TestUnexpectedResult;
        }
        if (std.ascii.indexOfIgnoreCase(pair[0], "ok") == null) {
            std.debug.print("unexpected /health body: {s}\n", .{pair[0]});
            return error.TestUnexpectedResult;
        }
    }
}

// `--tls` with only one path (or a nonexistent path) must fail loudly. The
// contract: non-zero exit, and the message mentions BOTH the flag (`--tls`)
// and the offending path — so the failure is actionable.
test "tls_flag_requires_both_files" {
    try harness.requirePabrikBin(io, gpa);

    // A scratch dir for the "does not exist" paths. NOT `h.temp_dir`:
    // this test never boots a server through the harness, and a scratch
    // dir is what `pytest`'s `tmp_path` provided.
    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const missing_cert = try std.fs.path.join(gpa, &.{ scratch, "does-not-exist-cert.pem" });
    defer gpa.free(missing_cert);
    const missing_key = try std.fs.path.join(gpa, &.{ scratch, "does-not-exist-key.pem" });
    defer gpa.free(missing_key);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, missing_cert, .{}));

    // Case A: only one path (the key is missing from the command line).
    {
        var r = harness.runPabrikCommand(io, gpa, scratch, &.{
            "--port", "0", "--tls", missing_cert,
        }, 15_000) catch |err| switch (err) {
            // The flag was accepted and the process ran on — precisely
            // the failure this test exists to catch.
            error.RunTimedOut => {
                std.debug.print("`--tls <cert.pem>` with no key: the binary started and served instead of exiting non-zero\n", .{});
                return error.TestUnexpectedResult;
            },
            else => return err,
        };
        defer r.deinit(gpa);
        try testing.expect(r.exit_code != null and r.exit_code.? != 0);
        if (std.mem.indexOf(u8, r.stderr, "--tls") == null) {
            std.debug.print("error must name the flag; got:\n{s}\n", .{r.stderr});
            return error.TestUnexpectedResult;
        }
        if (std.mem.indexOf(u8, r.stderr, missing_cert) == null) {
            std.debug.print("error must name the path; got:\n{s}\n", .{r.stderr});
            return error.TestUnexpectedResult;
        }
    }

    // Case B: both paths given, neither exists.
    {
        var r = harness.runPabrikCommand(io, gpa, scratch, &.{
            "--port", "0", "--tls", missing_cert, missing_key,
        }, 15_000) catch |err| switch (err) {
            error.RunTimedOut => {
                std.debug.print("`--tls <cert> <key>` with nonexistent files: the binary started and served instead of exiting non-zero\n", .{});
                return error.TestUnexpectedResult;
            },
            else => return err,
        };
        defer r.deinit(gpa);
        try testing.expect(r.exit_code != null and r.exit_code.? != 0);
        if (std.mem.indexOf(u8, r.stderr, "--tls") == null) {
            std.debug.print("error must name the flag; got:\n{s}\n", .{r.stderr});
            return error.TestUnexpectedResult;
        }
        if (std.mem.indexOf(u8, r.stderr, missing_cert) == null) {
            std.debug.print("error must name the cert path; got:\n{s}\n", .{r.stderr});
            return error.TestUnexpectedResult;
        }
    }
}

// A TLS listener serves TLS ONLY; plaintext on the same port must fail. The
// contract says there is no second port and no sniffing: one port, one
// transport.
test "tls_and_h2c_are_mutually_exclusive_on_a_port" {
    try harness.requirePabrikBin(io, gpa);

    var b = try spawnTlsPabrik(&.{"--tls-selfsigned"}, true, 45_000);
    defer b.deinit();
    try requireReady(&b);

    const curl = try requireHttp2Curl();
    defer gpa.free(curl);
    const port = b.h.port;

    {
        const url = try std.fmt.allocPrint(gpa, "https://127.0.0.1:{d}/health", .{port});
        defer gpa.free(url);
        var res = try curlRun(curl, url, &.{"-k"}, CURL_MAX_TIME_S);
        defer res.deinit();
        if (!res.ok() or !std.mem.eql(u8, res.code, "200")) {
            std.debug.print("TLS listener broken (rc={d}, code='{s}', err='{s}')\n", .{ res.rc, res.code, res.stderr });
            return error.TestUnexpectedResult;
        }
    }
    {
        const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/health", .{port});
        defer gpa.free(url);
        var res = try curlRun(curl, url, &.{}, CURL_MAX_TIME_S);
        defer res.deinit();
        if (res.ok()) {
            std.debug.print(
                "the port answered plaintext HTTP while serving TLS — TLS and plaintext " ++
                    "must be mutually exclusive (rc={d}, code='{s}')\n",
                .{ res.rc, res.code },
            );
            return error.TestUnexpectedResult;
        }
    }
    // `defer b.deinit()` above already stopped the child and deleted the
    // isolated HOME; that mirrors the Python's `finally:
    // booted.harness.teardown()`.
}

// Body-analysis barrier: an unreferenced helper is never type-checked, so a
// stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = findCurl;
    _ = requireHttp2Curl;
    _ = curlRun;
    _ = curlHttpVersion;
    _ = spawnTlsPabrik;
    _ = reapIfExited;
    _ = probe;
    _ = requireReady;
    _ = tlsCertPath;
    _ = nowMs;
    _ = sleepMs;
    _ = CurlResult.deinit;
    _ = Booted.deinit;
    _ = Harness.boot;
}
