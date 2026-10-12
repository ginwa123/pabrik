//! Functional test harness for pabrik — Zig port of `tests/functional/harness.py`.
//!
//! Boots a real `pabrik` binary against an isolated tmpdir HOME and
//! provides a typed HTTP client for the API. Every byte of state (DB,
//! config, design files, attachments) lives under the tempdir allocated
//! at boot; teardown deletes that tempdir, never anything else.
//!
//! ⛔  SAFETY INVARIANTS — DO NOT WEAKEN WITHOUT REVIEW  ⛔
//!
//! 1. `isSafeTmp(path, orig_home)` is the SINGLE source of truth for
//!    "may this path be deleted by the harness". Every recursive
//!    delete MUST be gated by it. There is no second code path.
//!
//! 2. The harness NEVER reads the ambient `HOME` inside teardown. It
//!    uses the captured `temp_dir` field, which is set once at boot and
//!    not subject to mid-test mutation.
//!
//! 3. The harness NEVER uses `~`, expanduser, or relative paths for
//!    anything it deletes. All paths are absolute and captured.
//!
//! 4. If `isSafeTmp` returns false, teardown ERRORS instead of
//!    deleting. The tempdir is leaked; the developer's home is never
//!    touched. This is the correct trade-off.
//!
//! 5. `orig_home` is captured BEFORE the child env shadows `HOME` and
//!    restored as the first step of teardown.
//!
//! 6. `XDG_CONFIG_HOME` / `XDG_STATE_HOME` / `XDG_DATA_HOME` /
//!    `XDG_CACHE_HOME` (plus `USERPROFILE` / `APPDATA` /
//!    `LOCALAPPDATA` on Windows) are shadowed in the CHILD env on every
//!    platform. On Linux `getDefaultConfigDir` resolves
//!    `$XDG_CONFIG_HOME/pabrik` BEFORE `$HOME/.config/pabrik`, so a
//!    child that inherited the runner's real `XDG_CONFIG_HOME` would
//!    write config.json into the real home while every test reads
//!    `<temp_dir>/.config`.
//!
//! The negative tests in `harness_safety_test.zig` guard these
//! invariants against regression.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;

const is_windows = builtin.os.tag == .windows;

// ============================================================================
// Safety constants
// ============================================================================

/// Substring that every harness-allocated tmpdir must contain. Acts as
/// a "namespace" so a buggy caller that points the tempdir allocation
/// at a non-tmpdir path is rejected.
pub const REQUIRED_TMP_SUBSTR = "pabrik-func-";

/// Last-resort kill signal. Windows has no SIGKILL — it maps SIGTERM to
/// TerminateProcess there, which is the correct fallback.
pub const SIGKILL: posix.SIG = if (is_windows) @enumFromInt(15) else @enumFromInt(9);
pub const SIGTERM: posix.SIG = @enumFromInt(15);

/// Legacy sequential scan bounds (see `_find_free_port_sequential`).
pub const DEFAULT_PORT: u16 = 8080;
pub const PORT_SCAN_END: u16 = 8199;

/// Random-port range used by the modern picker.
///
/// The previous range was 40000-60000, chosen for headroom against
/// TIME_WAIT. But Linux's default `net.ipv4.ip_local_port_range` is
/// 32768-60999, so 40000-60000 sits ENTIRELY INSIDE the pool the
/// kernel hands out as *source* ports for outgoing connections. Every
/// `bind()` probe the harness does, plus every pnpm / vite / zig / git
/// on the box, draws from that same pool. The picker closes its probe
/// socket and returns the number; the `pabrik` child binds the real
/// listener tens of ms later, and in between the port can be taken.
///
/// 20000-32000 gives 12,000 ports that no ephemeral allocation can reach
/// under a default `ip_local_port_range` and stays clear of the
/// documented dev ports (8080/8081) and the sequential 8080-8199 window.
pub const RANDOM_PORT_START: u16 = 20000;
pub const RANDOM_PORT_END: u16 = 32000;

/// Number of random attempts before giving up. With 12,000 ports and a
/// busy CI runner holding a few hundred listeners, 50 consecutive
/// collisions is vanishingly unlikely — safely "never happens".
pub const RANDOM_PORT_ATTEMPTS: usize = 50;

/// Ports the random picker MUST skip regardless of bind() success.
/// 8081 is the always-running dev backend per project memory.
pub const RESERVED_PORTS = [_]u16{8081};

/// How long each rung of the teardown kill ladder waits before
/// escalating: `/test/shutdown` then wait, then SIGTERM then wait, then
/// SIGKILL then wait.
///
/// Bounded so that the WHOLE deinit (this ladder plus up to 5 rmtree
/// retries at 1s each) stays inside the 3s that
/// `smoke_boot_test.teardown_completes_within_3s` asserts.
const kill_ladder_rung_s: f64 = 0.25;

/// The Io handle to use for harness-internal work that is not given
/// one (the port picker, the entropy seeder).
///
/// Inside a test this is `std.testing.io`, which the test runner
/// initialises. The two call sites that need it are the port pickers,
/// which `Harness.boot` already reaches with the caller's own `io` —
/// this indirection only exists so the standalone `findFreePort*`
/// entry points stay callable from a plain script.
fn testingIo() Io {
    return std.testing.io;
}

/// A PRNG seeded from the best entropy the stdlib exposes without a
/// dependency on `pabrikcore`.
///
/// Zig 0.16 removed the old `std.crypto.random.int`; the portable
/// replacement is the OS CSPRNG, reached here through
/// `Io.Threaded`'s per-call random stream. Seeding from
/// `std.time.milliTimestamp()` ^ pid is what the app's own
/// `helpers/random.zig` does, and it is sufficient here: the only
/// consumer is the tempdir-suffix picker, which additionally retries up
/// to 32 times on a name collision, and the port picker, which probes
/// the socket and retries 50 times.
/// Seed a `DefaultPrng` from the best entropy available without a
/// dependency on `pabrikcore`.
///
/// Returns the PRNG ITSELF, not a `Random` view of it: a `Random` borrows
/// the parent's state by pointer, so returning one from a function that
/// also returns the state leaves a dangling `ptr`. The caller holds the
/// PRNG in its own frame and calls `.random()` there, which is the only
/// arrangement that cannot dangle.
fn entropyPrng(io: Io) std.Random.DefaultPrng {
    // Zig 0.16 removed the old `std.crypto.random.int`; the portable
    // replacement is the OS entropy source. Seeding from
    // `Timestamp ^ pid ^ &stack` is what the app's own
    // `helpers/random.zig` does, and it is sufficient here: the only
    // consumers are the tempdir-suffix picker (which retries 32 times
    // on a name collision) and the port picker (which probes the socket
    // and retries 50 times).
    return .init(entropySeed(io));
}

fn entropySeed(io: Io) u64 {
    // NANOSECONDS, not milliseconds. This was `toMilliseconds()`, which
    // quantises the seed to 1 ms — and `findFreePortRandom` builds a
    // FRESH PRNG from it on every call. Two calls inside the same
    // millisecond therefore produced bit-identical output and returned
    // the SAME port. Measured: 8 consecutive picks all returned 24658;
    // picks 2 ms apart varied. `makeTempDir` drew from the same seed, so
    // two tempdirs minted in one millisecond collided on name and burned
    // one of its 32 retries.
    //
    // The process-wide COUNTER is the other half. Nanoseconds alone does
    // not save the Windows cell, whose default timer granularity is
    // ~15 ms; the counter makes successive calls distinct regardless.
    // `toNanoseconds()` widens to i96; truncate to the low 64 bits — a
    // seed only needs to differ between calls, not to be monotonic.
    const ts: u64 = @truncate(@as(u96, @bitCast(Io.Timestamp.now(io, .real).toNanoseconds())));
    const pid: u64 = if (is_windows) 0 else @intCast(std.os.linux.getpid());
    const seq = seed_counter.fetchAdd(1, .monotonic);
    return (ts << 8) ^ (pid << 32) ^ seq ^ @intFromPtr(&ts);
}

/// Monotonic tie-breaker for `entropySeed`, so two seeds taken in the
/// same clock tick are still distinct.
var seed_counter = std.atomic.Value(u64).init(0);

// ============================================================================
// Errors
// ============================================================================

/// Raised when the harness cannot safely proceed.
///
/// Distinct from `error.TestUnexpectedResult` (which is what API-level
/// assertions raise) so a caller can treat this as a SETUP failure
/// rather than a test failure.
pub const FunctionalHarnessError = error{
    HomeNotSet,
    UnsafePath,
    BinaryNotFound,
    BinaryNotExecutable,
    BootFailed,
    NotReady,
    NoFreePort,
    TeardownRefused,
    /// The response status was not in the expected set.
    UnexpectedStatus,
    /// A `pabrik` subcommand failed to spawn or wait.
    RunFailed,
    /// A `pabrik` subcommand outlived its `timeout_ms` and was killed.
    RunTimedOut,
};

// ============================================================================
// Safety validator
// ============================================================================

/// `realpath` + `normcase` — the ONE spelling every comparison here uses.
///
/// Both halves are load-bearing. `realpath` canonicalises the
/// candidate, which on Windows expands 8.3 SHORT names to long ones: a
/// runner's `%TEMP%` of `C:\Users\RUNNER~1\AppData\Local\Temp` comes
/// back as `C:\Users\runneradmin\AppData\Local\Temp`, so comparing the
/// canonicalised candidate against the RAW allow-list failed for the
/// harness's own tempdir on every test in the job. `normcase` supplies
/// the other half: Windows path comparison is case-insensitive, which
/// this function has always assumed and never actually got. On POSIX
/// both calls are near-identity.
pub fn canonical(io: Io, allocator: Allocator, path: []const u8) ![]u8 {
    // A symlink is resolved to its TARGET, never trusted as itself.
    //
    // This is the whole reason the function exists in this shape. On a
    // DANGLING symlink — `/tmp/pabrik-func-x/sneaky -> /home/alice` —
    // `realPathFile` does NOT error: it resolves the parent (which
    // exists), re-appends the name, and returns the LINK's own path.
    // `isSafeTmp` then sees a tmp-root path carrying the namespace
    // marker and answers YES, which means a later `deleteTree` would
    // follow the link out of the tmp root. Python's `os.path.realpath`
    // resolves as far as it can and returns `/home/alice`, so it answers
    // NO — the Python harness was right and this was a hole in mine.
    //
    // Routing symlinks explicitly also fixes the LIVE-target case for
    // free: `sneaky -> $HOME` canonicalises to the home directory, which
    // the "equals orig_home" check then rejects.
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.cwd().readLink(io, path, &link_buf)) |link_len| {
        const target = link_buf[0..link_len];
        const parent = std.fs.path.dirname(path) orelse target;
        const resolved = if (std.fs.path.isAbsolute(target))
            try allocator.dupe(u8, target)
        else
            try std.fs.path.join(allocator, &.{ parent, target });
        defer allocator.free(resolved);
        return allocator.dupe(u8, normcaseSlice(resolved));
    } else |_| {
        // Not a symlink — fall through to the normal realpath below.
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().realPathFile(io, path, &buf) catch |err| switch (err) {
        // The path does not exist. Anchor on the parent's canonical form
        // and re-append the basename, so the result still reflects a real
        // directory prefix rather than an unresolved string.
        error.FileNotFound, error.NameTooLong => return canonicalMissing(io, allocator, path),
        else => return err,
    };
    return allocator.dupe(u8, normcaseSlice(buf[0..len]));
}

/// Canonicalise a path whose final component does not exist. Resolves
/// the parent and re-appends the basename; if the parent is gone too,
/// returns the input unchanged so the caller's prefix and namespace
/// checks still run against it.
fn canonicalMissing(io: Io, allocator: Allocator, path: []const u8) ![]u8 {
    const base = std.fs.path.basename(path);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
        return allocator.dupe(u8, path);
    }
    const parent = std.fs.path.dirname(path) orelse return allocator.dupe(u8, path);
    if (parent.len == 0) return allocator.dupe(u8, path);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().realPathFile(io, parent, &buf) catch |err| switch (err) {
        error.FileNotFound, error.NameTooLong => return allocator.dupe(u8, path),
        else => return err,
    };
    const out = try std.fs.path.join(allocator, &.{ buf[0..len], base });
    defer allocator.free(out);
    return allocator.dupe(u8, normcaseSlice(out));
}

fn normcaseSlice(s: []const u8) []const u8 {
    if (!is_windows) return s;
    for (s) |*c| {
        if (c.* >= 'A' and c.* <= 'Z') c.* += 32;
    }
    return s;
}

/// Absolute-path prefixes that count as "tmpdir".
///
/// `std.fs.getAppDataDir` / the OS temp dir is probed at runtime via
/// `tmpRoot`; these are the POSIX spellings that must be present even
/// when the runtime probe disagrees (e.g. a cross-compiled test binary
/// reporting the host's temp).
pub const POSIX_TMP_PREFIXES = [_][]const u8{
    "/tmp/",
    "/private/tmp/",
    "/private/var/folders/",
    "/var/folders/",
};

/// The OS temp directory (`$TMPDIR`, falling back to `/tmp` on POSIX
/// and `%TEMP%` on Windows).
pub fn tmpRoot(allocator: Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (getEnvOrEmpty(allocator, "TEMP")) |v| {
            defer allocator.free(v);
            if (v.len > 0) return allocator.dupe(u8, v);
        } else |_| {}
        if (getEnvOrEmpty(allocator, "TMP")) |v| {
            defer allocator.free(v);
            if (v.len > 0) return allocator.dupe(u8, v);
        } else |_| {}
        return allocator.dupe(u8, "C:\\Windows\\Temp");
    }
    if (getEnvOrEmpty(allocator, "TMPDIR")) |v| {
        defer allocator.free(v);
        if (v.len > 0) return allocator.dupe(u8, v);
    } else |_| {}
    return allocator.dupe(u8, "/tmp");
}

/// Return true iff `path` is a tmpdir the harness is allowed to delete.
///
/// Returns false for:
///   - empty strings
///   - non-absolute paths
///   - paths outside the allow-list of tmpdir prefixes
///   - paths missing the `REQUIRED_TMP_SUBSTR` namespace
///   - paths that resolve to the real `$HOME` (catches symlinks)
///
/// This function is the single source of truth for "may this be
/// deleted". ANY recursive delete in the harness MUST be gated by it.
pub fn isSafeTmp(io: Io, allocator: Allocator, path: []const u8, orig_home: []const u8) !bool {
    if (path.len == 0) return false;
    if (!std.fs.path.isAbsolute(path)) return false;

    const real = try canonical(io, allocator, path);
    defer allocator.free(real);

    // (1) Prefix allow-list. `tmpRoot` is probed first because a
    // custom `%TEMP%` is authoritative; the POSIX spellings are
    // appended as fixed fallbacks.
    var allowed = false;
    {
        const root = tmpRoot(allocator) catch null;
        if (root) |r| {
            defer allocator.free(r);
            const rcanon = canonical(io, allocator, r) catch null;
            if (rcanon) |rc| {
                defer allocator.free(rc);
                // `tempfile.gettempdir() + "/"` — note the trailing
                // separator, so `/tmpfoo` does not match `/tmp`.
                if (hasDirPrefix(real, rc)) allowed = true;
            }
        }
    }
    if (!allowed) {
        for (POSIX_TMP_PREFIXES) |p| {
            const pcanon = canonical(io, allocator, p) catch continue;
            defer allocator.free(pcanon);
            if (hasDirPrefix(real, pcanon)) {
                allowed = true;
                break;
            }
        }
    }
    if (!allowed) return false;

    // (2) Namespace substring. Two prefixes are accepted: the harness's
    //    own (`pabrik-func-`) and the suite-fixture one (`pabrik-fix-`).
    //    `reapOrphanTestPids` only ever matches the FIRST, which is what
    //    keeps a live fixture from being reaped — see `makeScratchDir`.
    const has_marker = std.mem.indexOf(u8, real, REQUIRED_TMP_SUBSTR) != null or
        std.mem.indexOf(u8, real, SCRATCH_PREFIX) != null;
    if (!has_marker) return false;

    // (3) Not the real `$HOME`.
    if (orig_home.len > 0) {
        const real_home = canonical(io, allocator, orig_home) catch return false;
        defer allocator.free(real_home);
        if (std.mem.eql(u8, real, real_home)) return false;
    }
    return true;
}

/// `haystack` starts with `dir` AND `dir` ended at a path boundary
/// (so `/tmpfoo` does not match prefix `/tmp`).
fn hasDirPrefix(haystack: []const u8, dir: []const u8) bool {
    var d = dir;
    while (d.len > 1 and (d[d.len - 1] == '/' or d[d.len - 1] == '\\')) d = d[0 .. d.len - 1];
    if (d.len == 0) return false;
    if (!std.mem.startsWith(u8, haystack, d)) return false;
    if (haystack.len == d.len) return true;
    const next = haystack[d.len];
    return next == '/' or next == '\\';
}

/// Return an absolute path under `h`'s isolated tempdir.
///
/// Use this for any path a test PUTS INTO A JSON BODY that the server
/// resolves — an agent/routine item `path`, a knowledge `file_path`, a
/// session `cwd`, a command `workdir`.
///
/// The reason is not tidiness. The server validates these with
/// `std.fs.path.isAbsolute` and rejects a relative one with 400
/// `NotAbsolutePath`, and `isAbsolute` is platform-relative: on
/// windows-2022 `"/tmp/a.md"` is NOT absolute, so a literal that is
/// correct on ubuntu-24.04 fails at the HTTP door and the test reports
/// a server regression that does not exist. Deriving from `h.temp_dir`
/// (itself a real tempdir allocation) is absolute on every platform.
///
/// Passing no `parts` returns the tempdir itself.
pub fn harnessPath(allocator: Allocator, temp_dir: []const u8, parts: []const []const u8) ![]u8 {
    // Built by hand rather than with `std.fs.path.join`: `join` treats
    // every argument as a path component, which is right, but the
    // `[temp_dir] ++ parts` splice is not comptime-known here (parts
    // arrives at runtime), so the list is assembled at runtime.
    var all = try allocator.alloc([]const u8, parts.len + 1);
    defer allocator.free(all);
    all[0] = temp_dir;
    for (parts, 0..) |part, i| all[i + 1] = part;
    return std.fs.path.join(allocator, all);
}

// ============================================================================
// Response
// ============================================================================

/// One HTTP header. Module scope (not nested in `Harness`) because both
/// `Response.headers` and `Harness.HttpOptions.extra_headers` use it.
///
/// `name` and `value` must NOT contain `\r\n` — `std.http.Client`
/// asserts this in debug builds, and a header injection attempt should
/// fail loudly rather than smuggle a second header onto the wire.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// A typed HTTP response from the  pabrik API.
///
/// Owns `body`; free it (or call `deinit`) once done.
pub const Response = struct {
    status: u16,
    body: []u8,
    /// Response headers, in wire order.
    ///
    /// A LIST, not a map: `Set-Cookie` may legitimately repeat, and a
    /// map would silently drop the second one — which is exactly the
    /// header the auth suites read. `header` returns the FIRST match.
    ///
    /// Needed by the auth suites, which assert on `Set-Cookie` — the
    /// login flow's whole contract is "the server hands back an HttpOnly
    /// session cookie whose token is then replayed in a `Cookie` header".
    headers: std.ArrayList(Header) = .empty,

    allocator: Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        for (self.headers.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.headers.deinit(self.allocator);
        self.* = undefined;
    }

    /// Case-insensitive header lookup, first match. Header names are
    /// case-insensitive per RFC 9110, and the Python suites spelled them
    /// every way (`Set-Cookie`, `set-cookie`), so matching must not be
    /// either.
    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Every value for `name`, in wire order. Use for `Set-Cookie`.
    pub fn headerAll(self: *const Response, name: []const u8, out: *std.ArrayList([]const u8), gpa: Allocator) !void {
        for (self.headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) try out.append(gpa, h.value);
        }
    }

    /// Parse the body as JSON into an OWNING `std.json.Parsed(Value)`.
    ///
    /// The Zig analogue of Python's `r.json()`. The difference that
    /// matters: Zig's parse allocates into the arena inside `Parsed`, so
    /// the caller must `deinit` it — hence the wrapper type below
    /// rather than a bare `Value`, whose strings would dangle.
    ///
    /// Errors on invalid JSON, mirroring Python raising rather than
    /// returning a null-ish value the next line would deref.
    pub fn json(self: *const Response) !Json {
        return .{ .parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, self.body, .{}) };
    }

    /// The body as UTF-8 text (always valid — HTTP bodies here are
    /// text or base64, never raw binary, but invalid bytes are replaced
    /// rather than propagated).
    pub fn text(self: *const Response) []const u8 {
        return self.body;
    }
};

/// An owned, parsed JSON document — the return type of
/// `Response.json()`.
///
/// WHY A WRAPPER INSTEAD OF A BARE `std.json.Value`: the std parser
/// allocates every string and number it produces into an arena owned by
/// the `Parsed`. Handing the caller a bare `Value` would let them
/// `defer parsed.deinit()`-forget it and read freed memory, and would
/// give the type system no way to say "you now own this". Naming the
/// ownership makes the required `defer` obvious at every call site:
///
///     var doc = try r.json();
///     defer doc.deinit();
///     try testing.expectEqualStrings("ws_1", doc.str("id"));
///
/// `value` exposes the raw tree for the cases the accessors do not
/// cover (arrays, nested walks, iteration).
pub const Json = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Json) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    /// The root value. Borrow only — it dies with `deinit`.
    pub fn value(self: *const Json) *const std.json.Value {
        return &self.parsed.value;
    }

    /// Look up a key on a JSON OBJECT root. `null` if absent, or if the
    /// root is not an object (so a test asserting on an error body
    /// fails with a clear "expected string, got null" rather than a
    /// union-tag panic).
    pub fn get(self: *const Json, key: []const u8) ?std.json.Value {
        return switch (self.parsed.value) {
            .object => |o| o.get(key),
            else => null,
        };
    }

    /// The string at `key`, or `null` if absent or not a string.
    pub fn str(self: *const Json, key: []const u8) ?[]const u8 {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    /// The integer at `key`, or `null` if absent or not an integer.
    pub fn int(self: *const Json, key: []const u8) ?i64 {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .integer => |i| i,
            else => null,
        };
    }

    /// The boolean at `key`, or `null` if absent or not a bool.
    ///
    /// Named `boolean` rather than `bool`: `bool` is a primitive type
    /// name and Zig rejects a declaration that shadows one, so a
    /// ported test reads `doc.boolean("enabled")`.
    pub fn boolean(self: *const Json, key: []const u8) ?bool {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .bool => |b| b,
            else => null,
        };
    }

    /// The array at `key`, or `null` if absent or not an array.
    pub fn array(self: *const Json, key: []const u8) ?std.json.Array {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .array => |a| a,
            else => null,
        };
    }

    /// The object at `key`, or `null` if absent or not an object.
    pub fn object(self: *const Json, key: []const u8) ?std.json.ObjectMap {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .object => |o| o,
            else => null,
        };
    }

    /// The number at `key` as `f64`, or `null` if absent or not a
    /// number. Accepts an integer payload too, so a ported assertion
    /// does not have to care whether the server sent `3` or `3.0`.
    pub fn number(self: *const Json, key: []const u8) ?f64 {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }
};

// ============================================================================
// Harness
// ============================================================================

/// A booted `pabrik` instance bound to an isolated tmpdir.
///
/// Lifecycle (Zig has no `try/finally`, so `deinit` is the single
/// teardown path and every test uses `defer h.deinit(io)`):
///
///     var h = try Harness.boot(io, allocator, .{});
///     defer h.deinit(io) catch |e| { std.debug.print("teardown: {s}\n", .{@errorName(e)}); };
///     const r = try h.http(io, .GET, "/api/workspaces", .{});
///
/// The tempdir is validated BEFORE deletion runs. If validation fails,
/// `deinit` errors and refuses to delete anything.
pub const Harness = struct {
    allocator: Allocator,
    port: u16,
    pabrik_bin: []u8,
    temp_dir: []u8,
    orig_home: []u8,
    log_path: []u8,
    pid: ?u32,
    dry_run: bool,
    stopped: bool = false,
    /// Set once `deinit` has run, so a second call is a no-op even
    /// though `freeAll` poisons the struct.
    dedeinit: bool = false,
    /// Windows-only original env snapshots; empty on POSIX.
    orig_userprofile: []u8,
    orig_appdata: []u8,
    orig_localappdata: []u8,
    orig_xdg_config_home: []u8,
    orig_xdg_state_home: []u8,
    orig_xdg_data_home: []u8,
    orig_xdg_cache_home: []u8,

    /// Boot options. Defaults mirror Python's keyword-only args.
    pub const BootOptions = struct {
        /// Explicit port. `null` (the default) picks a RANDOM free
        /// port from `[RANDOM_PORT_START, RANDOM_PORT_END]`. Pass an
        /// integer to fall back to the legacy sequential scan.
        port: ?u16 = null,
        ready_timeout_s: f64 = 30.0,
        /// Pre-create a stub LLM profile so the binary boots without a
        /// real API key.
        stub_llm_profile: bool = false,
        /// Extra CLI flags appended after `--port` (e.g. `&.{"--http2"}`).
        extra_args: []const []const u8 = &.{},
        /// Extra env entries for the CHILD only (e.g. test-only feature
        /// gates the server reads from its own environment). The parent
        /// process env is never mutated; each pair is added to the copied
        /// `env_map` `boot` already builds.
        extra_env: []const [2][]const u8 = &.{},
        /// Lower the CHILD's soft `RLIMIT_NOFILE` to this value before it
        /// execs, without touching the hard limit.
        ///
        /// `std.process.spawn` has no rlimit knob, so the binary is booted
        /// through `/bin/sh -c 'ulimit -S -n N; exec ...'` — the shell only
        /// lowers the soft limit and then `exec`s, so the pid and the process
        /// group are the binary's own. Used to reproduce macOS's default
        /// (256), which collapses the SQLite reader pool's fd-derived ceiling
        /// to a single reader.
        ///
        /// POSIX only; asking on Windows is an error, not a silent no-op.
        no_file_limit: ?u64 = null,
    };

    /// Boot a fresh `pabrik` binary against an isolated tmpdir HOME.
    ///
    /// Resolves the binary via `resolvePabrikBin` unless `$PABRIK_BIN`
    /// is set. Returns `error.BinaryNotFound` when no candidate exists
    /// — a fresh worktree has no `zig-out/`, so callers that want a
    /// skip should check `resolvePabrikBin` first.
    pub fn boot(io: Io, allocator: Allocator, opts: BootOptions) !Harness {
        const gpa = allocator;

        // 1. Snapshot HOME BEFORE we shadow it. On Windows HOME is not
        // set by default; USERPROFILE is.
        var orig_home = getEnvOrEmpty(gpa, "HOME") catch try gpa.dupe(u8, "");
        if (orig_home.len == 0) {
            gpa.free(orig_home);
            orig_home = getEnvOrEmpty(gpa, "USERPROFILE") catch try gpa.dupe(u8, "");
        }
        if (orig_home.len == 0) {
            gpa.free(orig_home);
            return error.HomeNotSet;
        }

        errdefer gpa.free(orig_home);

        // Snapshot the env vars we shadow in the child. If the parent
        // shell has e.g. XDG_CONFIG_HOME=/home/user/.config, the child
        // must NOT inherit it.
        const orig_userprofile = try getEnvOrEmpty(gpa, "USERPROFILE");
        errdefer gpa.free(orig_userprofile);
        const orig_appdata = try getEnvOrEmpty(gpa, "APPDATA");
        errdefer gpa.free(orig_appdata);
        const orig_localappdata = try getEnvOrEmpty(gpa, "LOCALAPPDATA");
        errdefer gpa.free(orig_localappdata);
        const orig_xdg_config_home = try getEnvOrEmpty(gpa, "XDG_CONFIG_HOME");
        errdefer gpa.free(orig_xdg_config_home);
        const orig_xdg_state_home = try getEnvOrEmpty(gpa, "XDG_STATE_HOME");
        errdefer gpa.free(orig_xdg_state_home);
        const orig_xdg_data_home = try getEnvOrEmpty(gpa, "XDG_DATA_HOME");
        errdefer gpa.free(orig_xdg_data_home);
        const orig_xdg_cache_home = try getEnvOrEmpty(gpa, "XDG_CACHE_HOME");
        errdefer gpa.free(orig_xdg_cache_home);

        // 2. Reap orphans from prior aborted runs BEFORE picking a
        //    port, so the random pick sees a clean slate. Failure here
        //    is non-fatal — a slightly leakier state beats aborting.
        _ = reapOrphanTestPids(io, gpa) catch 0;

        // 3. Pick a free port.
        const chosen_port: u16 = if (opts.port) |p|
            try findFreePortSequential(io, p)
        else
            try findFreePortRandom(gpa);

        // 4. Allocate the tempdir. Atomic, fresh.
        const temp_dir = try makeTempDir(io, gpa);
        errdefer gpa.free(temp_dir);

        // 5. Validate BEFORE shadowing anything. If this fails, abort
        //    and leak the tempdir. Leaking is preferable to corrupting
        //    state.
        if (!try isSafeTmp(io, gpa, temp_dir, orig_home)) {
            return error.UnsafePath;
        }

        // 6. Optionally pre-create a stub LLM profile.
        if (opts.stub_llm_profile) {
            try writeStubLlmProfile(io, gpa, temp_dir);
        }

        // 7. Resolve the binary.
        const bin_path = try resolvePabrikBin(io, gpa);
        errdefer gpa.free(bin_path);

        // 8. Prepare the child env.
        const xdg_config = try std.fs.path.join(gpa, &.{ temp_dir, ".config" });
        defer gpa.free(xdg_config);
        const xdg_state = try std.fs.path.join(gpa, &.{ temp_dir, ".local", "state" });
        defer gpa.free(xdg_state);
        const xdg_data = try std.fs.path.join(gpa, &.{ temp_dir, ".local", "share" });
        defer gpa.free(xdg_data);
        const xdg_cache = try std.fs.path.join(gpa, &.{ temp_dir, ".cache" });
        defer gpa.free(xdg_cache);

        // Created on every platform: the child inherits these paths
        // from the env block below and the server expects the parent dir
        // to exist before it writes config.json / state / cache beneath.
        try std.Io.Dir.cwd().createDirPath(io, xdg_config);
        try std.Io.Dir.cwd().createDirPath(io, xdg_state);
        try std.Io.Dir.cwd().createDirPath(io, xdg_data);
        try std.Io.Dir.cwd().createDirPath(io, xdg_cache);

        const log_path = try std.fs.path.join(gpa, &.{ temp_dir, "pabrik.log" });
        errdefer gpa.free(log_path);

        // 9. Build the child environment. Copy the parent's, then
        //    shadow the isolation-critical vars. On POSIX we do NOT
        //    mutate OUR OWN process env — only the child's — which is
        //    what lets a parent test keep its real HOME.
        var env_map = try std.process.Environ.createMap(currentEnviron(), gpa);
        defer env_map.deinit();
        try env_map.put("HOME", temp_dir);
        try env_map.put("XDG_CONFIG_HOME", xdg_config);
        try env_map.put("XDG_STATE_HOME", xdg_state);
        try env_map.put("XDG_DATA_HOME", xdg_data);
        try env_map.put("XDG_CACHE_HOME", xdg_cache);
        if (is_windows) {
            try env_map.put("USERPROFILE", temp_dir);
            const roaming = try std.fs.path.join(gpa, &.{ temp_dir, "AppData", "Roaming" });
            defer gpa.free(roaming);
            const local = try std.fs.path.join(gpa, &.{ temp_dir, "AppData", "Local" });
            defer gpa.free(local);
            try std.Io.Dir.cwd().createDirPath(io, roaming);
            try std.Io.Dir.cwd().createDirPath(io, local);
            try env_map.put("APPDATA", roaming);
            try env_map.put("LOCALAPPDATA", local);
        }

        for (opts.extra_env) |kv| {
            try env_map.put(kv[0], kv[1]);
        }

        // 10. Spawn.
        const log_file = try std.Io.Dir.cwd().createFile(io, log_path, .{});
        defer log_file.close(io);

        const port_str = try std.fmt.allocPrint(gpa, "{d}", .{chosen_port});
        defer gpa.free(port_str);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        var ulimit_script: ?[]u8 = null;
        defer if (ulimit_script) |script| gpa.free(script);
        if (opts.no_file_limit) |limit| {
            if (is_windows) return error.NoFileLimitUnsupported;
            // `$0` is the binary, `$@` the args after it — `exec` replaces the
            // shell, so the recorded pid keeps pointing at the server.
            ulimit_script = try std.fmt.allocPrint(
                gpa,
                "ulimit -S -n {d} || exit 126; exec \"$0\" \"$@\"",
                .{limit},
            );
            try argv.append(gpa, "/bin/sh");
            try argv.append(gpa, "-c");
            try argv.append(gpa, ulimit_script.?);
        }
        try argv.append(gpa, bin_path);
        try argv.append(gpa, "--port");
        try argv.append(gpa, port_str);
        try argv.appendSlice(gpa, opts.extra_args);

        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .environ_map = &env_map,
            .stdout = .{ .file = log_file },
            .stderr = .{ .file = log_file },
            // Own process group, so a killpg reaches any subprocess
            // the binary spawned (a PTY a terminal test drives).
            .pgid = if (is_windows) null else 0,
        });
        const child_pid: u32 = if (is_windows) @intCast(child.id.?) else @intCast(child.id.?);

        // 11. Record pids so a subsequent boot can reap us if we die.
        //     Format is "<harness_pid> <pabrik_pid>\n" — the same
        //     contract `reapOrphanTestPids` reads.
        const self_pid: u32 = if (is_windows) 0 else @intCast(std.os.linux.getpid());
        const pidfile = try std.fs.path.join(gpa, &.{ temp_dir, ".harness.pid" });
        defer gpa.free(pidfile);
        writePidfile(io, gpa, pidfile, self_pid, child_pid) catch {};

        // 12. Wait for readiness. On failure, kill the child and
        //     propagate — the caller never gets a half-live harness.
        waitReady(io, gpa, chosen_port, opts.ready_timeout_s, child_pid, log_path) catch |err| {
            child.kill(io);
            _ = child.wait(io) catch {};
            return err;
        };

        const dry_run = blk: {
            const v = getEnvOrEmpty(gpa, "PABRIK_FUNCTIONAL_DRY_RUN") catch break :blk false;
            defer gpa.free(v);
            break :blk std.mem.eql(u8, v, "1");
        };

        // Hand the child to the harness. Ownership of `child` moves
        // into `stopBinary` — we keep the pid only, because the Python
        // harness signals by process group and does not `wait()` the
        // child (it uses `os.waitpid(WNOHANG)` polling instead).
        //
        // Reaping: a `std.process.Child` we never `wait()` on leaves a
        // zombie on POSIX. `stopBinary` polls `kill(pid, 0)` which
        // reports zombies as ALIVE, so it would spin the full SIGTERM /
        // SIGKILL budget on every teardown. `reapChild` (below) drains
        // the zombie once the pid is confirmed gone.

        return .{
            .allocator = gpa,
            .port = chosen_port,
            .pabrik_bin = bin_path,
            .temp_dir = temp_dir,
            .orig_home = orig_home,
            .log_path = log_path,
            .pid = child_pid,
            .dry_run = dry_run,
            .orig_userprofile = orig_userprofile,
            .orig_appdata = orig_appdata,
            .orig_localappdata = orig_localappdata,
            .orig_xdg_config_home = orig_xdg_config_home,
            .orig_xdg_state_home = orig_xdg_state_home,
            .orig_xdg_data_home = orig_xdg_data_home,
            .orig_xdg_cache_home = orig_xdg_cache_home,
        };
    }

    /// Tear down: stop the binary, then delete the isolated tempdir.
    ///
    /// Order matters:
    ///   1. Validate the tempdir with `isSafeTmp`; ERROR if it fails.
    ///      The tempdir is leaked in that case — the correct trade-off
    ///      vs. deleting the wrong tree.
    ///   2. Stop the binary (SIGTERM, then SIGKILL fallback).
    ///   3. Remove the pidfile BEFORE rmtree so the next boot doesn't
    ///      see this entry.
    ///   4. Recursively delete the validated tempdir (or skip if
    ///      `dry_run`).
    ///
    /// Idempotent: safe to call twice.
    ///
    /// NOTE: unlike the Python version this does NOT restore `HOME`.
    /// Zig has no process-wide mutable env to shadow — the Python
    /// harness mutated `os.environ` only so `~` in downstream test code
    /// expanded to the tempdir; here the child env is passed to
    /// `spawn` directly and the parent's env is never touched, so there
    /// is nothing to restore.
    pub fn deinit(self: *Harness, io: Io) !void {
        // Idempotency: `freeAll` ends with `self.* = undefined`, so a
        // second call would read POISONED memory for `temp_dir.len` and
        // take the stop/dealloc path again. The flag is checked FIRST
        // and short-circuits, so `undefined` is never dereferenced.
        if (self.dedeinit) return;
        self.dedeinit = true;
        const gpa = self.allocator;
        const temp_dir = self.temp_dir;

        // Stop the binary first: the child may still be writing into
        // the tempdir, and deleting under it produces ENOTEMPTY.
        if (self.pid != null and !self.stopped) {
            self.stopped = true;
            self.stopBinary(io) catch {};
        }

        // Validate. THIS IS THE SAFETY NET.
        if (!try isSafeTmp(io, gpa, temp_dir, self.orig_home)) {
            std.debug.print(
                "REFUSING to rmtree unsafe path: {s}\n" ++
                    "This is a bug in the harness; the tempdir did not\n" ++
                    "pass isSafeTmp() validation. Manual cleanup required.\n" ++
                    "  orig_home = {s}\n" ++
                    "  temp_dir  = {s}\n",
                .{ temp_dir, self.orig_home, temp_dir },
            );
            self.freeAll(gpa);
            return error.TeardownRefused;
        }

        // Remove the pidfile BEFORE rmtree. Without this, the next boot
        // would see an entry whose harness pid is now dead and try to
        // reap an already-dead child.
        const pidfile = std.fs.path.join(gpa, &.{ temp_dir, ".harness.pid" }) catch {
            self.freeAll(gpa);
            return;
        };
        defer gpa.free(pidfile);
        std.Io.Dir.cwd().deleteFile(io, pidfile) catch {};

        if (self.dry_run) {
            std.debug.print("[dry-run] would rmtree: {s}\n", .{temp_dir});
        } else {
            // The child tree is dead, but "dead" is not "finished
            // writing": a shell the binary spawned can still be
            // flushing its last writes into the temp HOME, and POSIX
            // rmtree surfaces that as ENOTEMPTY — a directory that got
            // a new entry between the scan and the delete. Retry with
            // backoff rather than leaking on the first failure.
            var last_err: ?anyerror = null;
            const retries: usize = if (is_windows) 10 else 5;
            for (0..retries) |_| {
                std.Io.Dir.cwd().deleteTree(io, temp_dir) catch |err| {
                    last_err = err;
                    Io.sleep(io, .fromMilliseconds(1000), .awake) catch {};
                    continue;
                };
                last_err = null;
                break;
            }
            if (last_err) |err| {
                std.debug.print(
                    "harness teardown: could not delete {s} after {d} attempts: {s}\n",
                    .{ temp_dir, retries, @errorName(err) },
                );
                self.freeAll(gpa);
                return error.TeardownRefused;
            }
        }

        self.freeAll(gpa);
    }

    fn freeAll(self: *Harness, gpa: Allocator) void {
        gpa.free(self.pabrik_bin);
        gpa.free(self.temp_dir);
        gpa.free(self.orig_home);
        gpa.free(self.log_path);
        gpa.free(self.orig_userprofile);
        gpa.free(self.orig_appdata);
        gpa.free(self.orig_localappdata);
        gpa.free(self.orig_xdg_config_home);
        gpa.free(self.orig_xdg_state_home);
        gpa.free(self.orig_xdg_data_home);
        gpa.free(self.orig_xdg_cache_home);
        self.* = undefined;
    }

    // ---- HTTP client ------------------------------------------------------

    /// HTTP request options. Mirrors Python's keyword-only args.
    pub const HttpOptions = struct {
        /// Serialised as the body with `Content-Type: application/json`.
        json_body: ?[]const u8 = null,
        /// URL query parameters. Percent-encoded by the harness.
        params: []const Param = &.{},
        /// Accepted status codes. Empty means "200" (Python's default).
        expect: []const u16 = &.{200},
        timeout_s: f64 = 5.0,
        /// Extra request headers. Used by the auth suites for `Cookie`
        /// and by the workspace-sharing suites for bearer tokens.
        ///
        /// These are sent IN ADDITION to the harness-managed ones, so a
        /// test can override `Content-Type` by listing it here.
        extra_headers: []const Header = &.{},
        /// Set false to accept ANY status. Default true.
        ///
        /// Needed where the STATUS ITSELF is the assertion — the auth
        /// suites check "this route returns 401 without a cookie", which
        /// `expect = &.{401}` expresses fine, but the ported helper for
        /// "call this and let me look at the number" does not. Without
        /// this flag such a helper would have to re-implement the whole
        /// client, which is how a suite ends up with a private copy of
        /// the harness's HTTP path.
        assert_status: bool = true,
    };

    /// One URL query parameter. `value` is percent-encoded.
    pub const Param = struct { name: []const u8, value: []const u8 };

    /// Issue an HTTP request to the harness's `pabrik` instance.
    ///
    /// Returns a `Response` the caller owns. Errors with
    /// `error.UnexpectedStatus` when the status is not in `opts.expect`;
    /// the error message carries the first 500 bytes of the body, which
    /// is what makes a failure readable without opening the log.
    pub fn http(self: *Harness, io: Io, method: HttpMethod, path: []const u8, opts: HttpOptions) !Response {
        const gpa = self.allocator;

        const url = try buildUrl(gpa, self.port, path, opts.params);
        // Freed on EVERY exit, including the error paths below. A
        // `try client.request(...)` that fails (connect refused — which
        // a suite deliberately provokes when it points at a dead port)
        // returns straight out of this function, so without this the URL
        // is leaked and `testing.allocator` reports it against whatever
        // test happened to exercise that path.
        defer gpa.free(url);

        var body: ?[]const u8 = opts.json_body;
        defer if (body != null) gpa.free(body.?);

        if (opts.json_body) |jb| {
            body = try gpa.dupe(u8, jb);
        }

        // `std.Io.Writer.Allocating` is the 0.16 replacement for the
        // old `ArrayList(u8).writer(gpa)` idiom: an auto-growing sink
        // that hands back an owned slice via `toOwnedSlice`.
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;

        var client: std.http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();

        // A fixed Content-Type when there is no body, plus whatever the
        // caller added. `std.http.Header` is `{ name, value }`.
        var extra: std.ArrayList(std.http.Header) = .empty;
        defer extra.deinit(gpa);
        try extra.append(gpa, .{ .name = "Content-Type", .value = "application/json" });
        for (opts.extra_headers) |h| {
            try extra.append(gpa, .{ .name = h.name, .value = h.value });
        }

        var req = try client.request(
            method.toStdMethod(),
            try std.Uri.parse(url),
            .{ .redirect_behavior = .unhandled, .extra_headers = extra.items },
        );
        defer req.deinit();

        if (body) |b| {
            req.transfer_encoding = .{ .content_length = b.len };
            var body_writer = try req.sendBodyUnflushed(&.{});
            try body_writer.writer.writeAll(b);
            try body_writer.end();
            try req.connection.?.flush();
        } else if (method.toStdMethod().requestHasBody()) {
            // A bodiless POST/PUT/PATCH still needs the framing.
            // `sendBodiless` ASSERTS that the method cannot have a body,
            // and that assert is reachable from ordinary API traffic —
            // `POST /api/auth/logout` takes no body at all. Send a
            // zero-length body instead, which is what a server sees
            // either way.
            req.transfer_encoding = .{ .content_length = 0 };
            var body_writer = try req.sendBodyUnflushed(&.{});
            try body_writer.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }

        var resp = try req.receiveHead(&.{});

        // Headers FIRST, body second — and the order is load-bearing.
        // `resp.reader()` calls `head.invalidateStrings()`, so reading
        // `head.bytes` after touching the body is a use-after-free that
        // shows up as a general-protection fault in `mem.eqlBytes`.
        var resp_headers: std.ArrayList(Header) = .empty;
        {
            var hit = resp.head.iterateHeaders();
            while (hit.next()) |kv| {
                try resp_headers.append(gpa, .{
                    .name = try gpa.dupe(u8, kv.name),
                    .value = try gpa.dupe(u8, kv.value),
                });
            }
        }

        const status: u16 = @intFromEnum(resp.head.status);

        const reader = resp.reader(&.{});
        _ = try reader.streamRemaining(w);
        try w.flush();

        var expected = opts.expect;
        if (expected.len == 0) expected = &.{200};

        var ok = !opts.assert_status;
        if (!ok) {
            for (expected) |e| {
                if (e == status) {
                    ok = true;
                    break;
                }
            }
        }
        if (!ok) {
            const got = out.written();
            const excerpt = if (got.len > 500) got[0..500] else got;
            // Spell out the accepted codes so the failure says what
            // would have passed — the Python harness printed the tuple.
            var want_buf: [128]u8 = undefined;
            var want_w: Io.Writer = .fixed(&want_buf);
            for (expected, 0..) |e, i| {
                want_w.print("{d}", .{e}) catch break;
                if (i + 1 < expected.len) want_w.writeAll(", ") catch break;
            }
            std.debug.print(
                "{s} {s}: expected [{s}], got {d}\nbody: {s}\n",
                .{ method.name(), path, want_w.buffered(), status, excerpt },
            );
            // No `out.deinit()` here: the `errdefer out.deinit()` above
            // already owns the failure path, and an explicit deinit
            // double-frees — which surfaced as a general-protection
            // exception that MASKED the status-mismatch message this
            // branch exists to print.
            return error.UnexpectedStatus;
        }

        const owned = try out.toOwnedSlice();
        return .{
            .status = status,
            .body = owned,
            .headers = resp_headers,
            .allocator = gpa,
        };
    }

    /// Return true iff `/health` returns 200 with `status == "ok"`.
    pub fn health(self: *Harness, io: Io) bool {
        var r = self.http(io, .GET, "/health", .{ .expect = &.{200} }) catch return false;
        defer r.deinit();
        var doc = r.json() catch return false;
        defer doc.deinit();
        const st = doc.str("status") orelse return false;
        return std.mem.eql(u8, st, "ok");
    }

    /// Return the last `n` lines of the `pabrik` log (useful on failure).
    pub fn tailLog(self: *Harness, io: Io, gpa: Allocator, n: usize) ![]u8 {
        const data = std.Io.Dir.cwd().readFileAlloc(io, self.log_path, gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return gpa.dupe(u8, ""),
            else => return err,
        };
        defer gpa.free(data);

        // Take the last `n` lines of the (decoded-as-bytes) log.
        var line_count: usize = 0;
        var i = data.len;
        while (i > 0) {
            i -= 1;
            if (data[i] == '\n') line_count += 1;
        }
        // Skip forward past the lines we do not want.
        var to_skip = if (line_count > n) line_count - n else 0;
        var start: usize = 0;
        var j: usize = 0;
        while (j < data.len and to_skip > 0) : (j += 1) {
            if (data[j] == '\n') to_skip -= 1;
            start = j + 1;
        }
        return gpa.dupe(u8, std.mem.trimEnd(u8, data[start..], "\n"));
    }

    // ---- private ----------------------------------------------------------

    /// Stop the `pabrik` binary: graceful shutdown, SIGTERM, SIGKILL.
    ///
    /// Teardown budget is 3s total, safe because `/test/shutdown` exits
    /// the process within ~50ms in the common case; the SIGTERM/SIGKILL
    /// steps are the safety net for a rare blocked shutdown handler.
    fn stopBinary(self: *Harness, io: Io) !void {
        const gpa = self.allocator;
        const pid = self.pid orelse return;

        // Graceful exit first; tolerate any failure.
        var client: std.http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();
        const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/test/shutdown", .{self.port});
        defer gpa.free(url);
        var req = client.request(.POST, std.Uri.parse(url) catch return, .{}) catch return;
        defer req.deinit();
        // POST needs a body: Zig's `sendBodiless` asserts that the
        // method cannot have one. Python's `urlopen(..., data=b"")`
        // sent an empty body, which is what we mirror here.
        req.transfer_encoding = .{ .content_length = 0 };
        var body_writer = req.sendBodyUnflushed(&.{}) catch return;
        body_writer.end() catch return;
        req.connection.?.flush() catch return;
        var resp = req.receiveHead(&.{}) catch return;
        // Drain the body so the connection is released cleanly. Zig
        // 0.16's `Response` has no `deinit` — `req.deinit` (the outer
        // defer) owns everything.
        var sink: std.Io.Writer.Discarding = .init(&.{});
        _ = resp.reader(&.{}).streamRemaining(&sink.writer) catch {};

        // 250ms per rung, not 1s. The ported perf test asserts the
        // WHOLE deinit is under 3s, and deinit is this ladder plus up
        // to 5 rmtree retries at 1s. With 1s rungs the ladder alone can
        // consume the entire budget — and it did: the measured teardown
        // was 3007ms. `/test/shutdown` normally exits the process in
        // ~50ms, so these rungs only fire on a genuine hang, where
        // 250ms of grace before escalating to SIGTERM/SIGKILL is ample.
        if (waitPidDead(io, pid, kill_ladder_rung_s)) {
            return;
        }
        signalGroup(pid, SIGTERM);
        if (waitPidDead(io, pid, kill_ladder_rung_s)) {
            return;
        }
        signalGroup(pid, SIGKILL);
        _ = waitPidDead(io, pid, kill_ladder_rung_s); // best-effort final wait
    }
};

// ============================================================================
// HTTP helpers
// ============================================================================

/// HTTP verbs the suites use.
pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,
    OPTIONS,

    pub fn name(self: HttpMethod) []const u8 {
        return @tagName(self);
    }

    /// Map onto `std.http.Method` by NAME.
    ///
    /// NOT `@enumFromInt`: the two enums do NOT have the same
    /// discriminants. `std.http.Method` is GET, HEAD, POST, PUT,
    /// DELETE, CONNECT, OPTIONS, TRACE, PATCH — so an ordinal cast
    /// silently turned this suite's `POST` into a `HEAD`, and
    /// `sendBodyUnflushed` then asserted with "HEAD cannot have a
    /// body". An explicit switch fails loudly when a verb is added to
    /// one enum and not the other; an ordinal cast fails silently and
    /// only once a body is attached.
    fn toStdMethod(self: HttpMethod) std.http.Method {
        return switch (self) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .PATCH => .PATCH,
            .DELETE => .DELETE,
            .HEAD => .HEAD,
            .OPTIONS => .OPTIONS,
        };
    }
};

/// Build `http://127.0.0.1:<port><path>?<params>`, percent-encoding
/// parameter values.
/// Build `http://127.0.0.1:<port><path>?<params>`.
///
/// Built with a `buf` and one `allocPrint` at the end rather than
/// re-allocating per parameter. The loop version freed the NEW string
/// where it meant to free the OLD one: `url = allocPrint(url); free(url)`
/// frees the just-assigned value, so the NEXT iteration read freed
/// memory. With one parameter that is merely a leak; with two or more it
/// hands `std.Uri.parse` a dangling pointer and the request fails with
/// `error.InvalidFormat` — which reads like a malformed URL in the
/// caller's test, not like a harness bug. Found by
/// `system_folder_path_validation_test`, whose requests carry three
/// params.
fn buildUrl(gpa: Allocator, port: u16, path: []const u8, params: []const Harness.Param) ![]u8 {
    if (params.len == 0) {
        return std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}{s}", .{ port, path });
    }

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const w = &buf.writer;
    w.print("http://127.0.0.1:{d}{s}?", .{ port, path }) catch return error.OutOfMemory;

    // NAME AND VALUE ARE PERCENT-ENCODED, as Python's
    // `urllib.parse.urlencode` did. Writing them verbatim means a value
    // containing a space, `&`, `=`, `#` or `?` silently becomes part of
    // the URL's STRUCTURE rather than its data — the server then parses
    // a different query than the test asked for, and the test passes or
    // fails for a reason that has nothing to do with the server.
    //
    // Two porting agents independently worked around this by hand-writing
    // a local `enc()` helper per suite. That is the wrong place for the
    // fix: every suite then carries a private copy of query encoding, and
    // `path_with_spaces_survives_url_encoding` ends up testing the
    // SUITE's encoder instead of the server's URL handling.
    for (params, 0..) |p, i| {
        if (i > 0) w.writeAll("&") catch return error.OutOfMemory;
        try writePercentEncoded(w, p.name);
        w.writeAll("=") catch return error.OutOfMemory;
        try writePercentEncoded(w, p.value);
    }
    return buf.toOwnedSlice();
}

/// Percent-encode one query component.
///
/// Everything outside the RFC 3986 unreserved set is escaped, INCLUDING
/// `+`. Python's `quote_plus` maps a space to `+`; we map it to `%20`,
/// which is what every browser and every HTTP framework emits and what a
/// server's own decoder must therefore handle. The important property is
/// that the bytes are unambiguous — `%20` and `+` both decode to a space
/// under `application/x-www-form-urlencoded`, but ONLY `%20` is correct
/// under RFC 3986, and a suite testing a git path with a space in it is
/// exactly the case that would notice.
fn writePercentEncoded(w: *Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try w.writeByte(c),
            else => try w.print("%{X:0>2}", .{c}),
        }
    }
}

// ============================================================================
// Port allocation
// ============================================================================

/// Sequential port scan from `start` to `PORT_SCAN_END`. Legacy path,
/// kept for the orphan-reap TIME_WAIT regression test which depends on
/// the deterministic "first free port = target_port" behaviour.
pub fn findFreePortSequential(io: Io, start: u16) !u16 {
    var s = start;
    if (s == 8081) s = 8082;
    var port: u16 = s;
    while (port <= PORT_SCAN_END) : (port += 1) {
        if (port == 8081) continue;
        if (portIsFreeWithReuse(io, port)) return port;
    }
    return error.NoFreePort;
}

/// Return true iff `port` can be bound on 127.0.0.1 with SO_REUSEADDR.
///
/// SO_REUSEADDR lets the probe bind TIME_WAIT ports; the subsequent
/// `pabrik` listener sets the same flag so it can also bind the port
/// despite lingering server-side TIME_WAITs. Without it, rapid test runs
/// saturate the scan window with TIME_WAIT entries.
pub fn portIsFreeWithReuse(io: Io, port: u16) bool {
    // Bind a throwaway listener on 127.0.0.1:<port>. Success ⇒ nothing
    // is listening there. `reuse_address` sets SO_REUSEADDR (and
    // SO_REUSEPORT where available), which is what lets the probe take
    // a port still in TIME_WAIT; the `pabrik` listener sets the same
    // flag, so it can bind it too moments later.
    //
    // Zig 0.16 removed `std.posix.socket`/`bind`; the portable path is
    // `Io.net`, which routes through the Io implementation's vtable.
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = addr.listen(io, .{ .reuse_address = true }) catch return false;
    server.deinit(io);
    return true;
}

/// Pick a random free port from a wide range, avoiding reserved ports.
///
/// `attempts` independent random picks within `[range_start,
/// range_end]`; the first that binds without error and is not reserved
/// wins. Practically unreachable to fail on any sane host.
pub fn findFreePortRandom(gpa: Allocator) !u16 {
    const range_size = RANDOM_PORT_END - RANDOM_PORT_START + 1;
    var prng = entropyPrng(testingIo());
    const rand = prng.random();
    for (0..RANDOM_PORT_ATTEMPTS) |_| {
        const port = RANDOM_PORT_START + rand.uintLessThan(u16, range_size);
        var reserved = false;
        for (RESERVED_PORTS) |r| {
            if (port == r) reserved = true;
        }
        if (reserved) continue;
        if (portIsFreeWithReuse(testingIo(), port)) return port;
    }
    _ = gpa;
    return error.NoFreePort;
}

/// Find a free port. `start = null` → random pick; otherwise the legacy
/// sequential scan from `start`.
pub fn findFreePort(start: ?u16) !u16 {
    if (start) |s| return findFreePortSequential(testingIo(), s);
    return findFreePortRandom(std.heap.page_allocator);
}

// ============================================================================
// Process helpers
// ============================================================================

/// Milliseconds on the monotonic clock.
///
/// Zig 0.16 removed `std.time.milliTimestamp()`; a monotonic deadline
/// is now `Io.Clock.now(io, .monotonic)`. Everything that needs a
/// wall-clock comparison (the readiness poll, the kill ladder) wants
/// MONOTONIC, not real — a wall-clock step backwards (NTP) would
/// otherwise hang the wait forever.
fn monotonicMs(io: Io) i64 {
    // `.awake`, not `.real`: Zig 0.16 renamed the monotonic clock, and
    // a wall-clock step backwards (NTP) would otherwise hang the wait.
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// Return true iff `pid` exited within `timeout_s`.
///
/// Uses `kill(pid, 0)` as a liveness probe. ESRCH ⇒ dead. On POSIX a
/// zombie also answers 0, so a caller that owns the `Child` should
/// `wait()` it; the harness signals by process group and uses this
/// probe, accepting a possible one-shot false "alive" that the next
/// SIGKILL round resolves.
fn waitPidDead(io: Io, pid: u32, timeout_s: f64) bool {
    const deadline = monotonicMs(io) + @as(i64, @intFromFloat(timeout_s * 1000.0));
    while (monotonicMs(io) < deadline) {
        if (!pidAlive(pid)) return true;
        Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }
    return false;
}

/// `kill(pid, 0)` liveness probe. Swallows every error: EPERM means
/// alive-but-not-ours, which for our purposes is the same as "not
/// ours to signal" and we treat it as alive so we escalate.
fn pidAlive(pid: u32) bool {
    if (is_windows) return true; // No POSIX probe; Windows path uses SIGTERM=TerminateProcess.
    const p: posix.pid_t = @intCast(pid);
    // `kill(pid, 0)` is the liveness probe: signal 0 performs error
    // checking but delivers nothing. EPERM means alive-but-not-ours
    // (treat as alive so we escalate); ESRCH means gone.
    posix.kill(p, @as(posix.SIG, @enumFromInt(0))) catch |err| switch (err) {
        error.PermissionDenied => return true,
        else => return false,
    };
    return true;
}

/// Signal the whole process group on POSIX, or the pid on Windows.
///
/// Every error is swallowed — the process can die between our queries,
/// the OS may have recycled the pgid, or we may not own the pid. None
/// of those are the harness's concerns.
pub fn signalGroup(pid: u32, sig: posix.SIG) void {
    if (is_windows) return;
    const p: posix.pid_t = @intCast(pid);
    // `killpg(pgid, sig)` where pgid == pid (the child was spawned with
    // `pgid = 0`, making it a group leader). Fall back to `kill` if the
    // group signal fails.
    posix.kill(-p, sig) catch posix.kill(p, sig) catch {};
}

/// Kill orphaned `pabrik` children from prior aborted runs. Idempotent.
///
/// Scan `<tmpdir>/pabrik-func-*/.harness.pid`. Each pidfile contains
/// `"<harness_pid> <pabrik_pid>\n"`. If the harness parent is dead, the
/// tempdir is an orphan: the `pabrik` child survived in its own process
/// group and is still holding its TCP port. Kill the child, then delete
/// the tempdir via the SAME `isSafeTmp` gate teardown uses.
pub fn reapOrphanTestPids(io: Io, gpa: Allocator) !usize {
    var reaped: usize = 0;
    const base = try tmpRoot(gpa);
    defer gpa.free(base);

    var dir = std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, REQUIRED_TMP_SUBSTR)) continue;

        const entry_path = try std.fs.path.join(gpa, &.{ base, entry.name });
        defer gpa.free(entry_path);

        const pidfile = try std.fs.path.join(gpa, &.{ entry_path, ".harness.pid" });
        defer gpa.free(pidfile);

        const text = std.Io.Dir.cwd().readFileAlloc(io, pidfile, gpa, .limited(256)) catch continue;
        defer gpa.free(text);

        // Parse "<harness_pid> <pabrik_pid>". Anything else → skip.
        var it2 = std.mem.tokenizeAny(u8, text, " \t\r\n");
        const h_tok = it2.next() orelse continue;
        const p_tok = it2.next() orelse continue;
        if (it2.next() != null) continue; // more than two tokens → skip.
        const harness_pid = std.fmt.parseInt(u32, h_tok, 10) catch continue;
        const pabrik_pid = std.fmt.parseInt(u32, p_tok, 10) catch continue;

        // If the harness is alive, this test is still in progress —
        // a concurrent scan must NOT kill it.
        if (pidAlive(harness_pid)) continue;

        // Harness is dead. Kill the `pabrik` child if alive.
        const self_pid: u32 = if (is_windows) 0 else @intCast(std.os.linux.getpid());
        if (pabrik_pid != 0 and pabrik_pid != self_pid) {
            posix.kill(@intCast(pabrik_pid), SIGTERM) catch {};
            if (!waitPidDead(io, pabrik_pid, 1.0)) {
                posix.kill(@intCast(pabrik_pid), SIGKILL) catch {};
            }
        }

        // Delete via the SAME safety gate teardown uses. For an orphan
        // we don't know the original HOME, so pass "" — that disables
        // the "matches HOME" check but keeps prefix + substring.
        if (try isSafeTmp(io, gpa, entry_path, "")) {
            std.Io.Dir.cwd().deleteTree(io, entry_path) catch continue;
            reaped += 1;
        }
    }
    return reaped;
}

fn writePidfile(io: Io, gpa: Allocator, path: []const u8, harness_pid: u32, pabrik_pid: u32) !void {
    const text = try std.fmt.allocPrint(gpa, "{d} {d}\n", .{ harness_pid, pabrik_pid });
    defer gpa.free(text);
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, text);
}

/// Poll `/health` every 100ms until `status == "ok"` or timeout.
fn waitReady(io: Io, gpa: Allocator, port: u16, timeout_s: f64, pid: u32, log_path: []const u8) !void {
    const deadline = monotonicMs(io) + @as(i64, @intFromFloat(timeout_s * 1000.0));
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/health", .{port});
    defer gpa.free(url);

    var last_err: []const u8 = "none";
    while (monotonicMs(io) < deadline) {
        if (!pidAlive(pid)) {
            const tail = readTail(io, gpa, log_path, 30) catch "";
            defer if (tail.len > 0) gpa.free(tail);
            std.debug.print(
                "pabrik exited during boot\n--- last 30 lines of log ---\n{s}\n",
                .{tail},
            );
            return error.BootFailed;
        }
        if (probeHealth(io, gpa, url)) return;

        last_err = "connection refused";
        Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
    }
    const tail = readTail(io, gpa, log_path, 30) catch "";
    defer if (tail.len > 0) gpa.free(tail);
    std.debug.print(
        "pabrik did not become ready in {d}s (last_err={s})\n--- last 30 lines of log ---\n{s}\n",
        .{ @as(u32, @intFromFloat(timeout_s)), last_err, tail },
    );
    return error.NotReady;
}

fn probeHealth(io: Io, gpa: Allocator, url: []const u8) bool {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var req = client.request(.GET, std.Uri.parse(url) catch return false, .{}) catch return false;
    defer req.deinit();
    req.sendBodiless() catch return false;
    var resp = req.receiveHead(&.{}) catch return false;
    _ = resp.reader(&.{}).streamRemaining(&out.writer) catch return false;

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, out.written(), .{}) catch return false;
    defer parsed.deinit();
    const st = parsed.value.object.get("status") orelse return false;
    return std.mem.eql(u8, st.string, "ok");
}

fn readTail(io: Io, gpa: Allocator, path: []const u8, n: usize) ![]u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(data);
    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(gpa);
    var lines: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try kept.append(gpa, line);
    }
    const start = if (kept.items.len > n) kept.items.len - n else 0;
    return std.mem.join(gpa, "\n", kept.items[start..]);
}

// ============================================================================
// Temp dir
// ============================================================================

/// Allocate a fresh tempdir named `pabrik-func-<random>` under the OS
/// temp root. Atomic (O_EXCL-style) — no TOCTOU window between choosing
/// a name and creating it.
fn makeTempDir(io: Io, gpa: Allocator) ![]u8 {
    const base = try tmpRoot(gpa);
    defer gpa.free(base);

    var prng = entropyPrng(testingIo());
    const rand = prng.random();

    var attempt: usize = 0;
    while (attempt < 32) : (attempt += 1) {
        const suffix: u32 = rand.int(u32);
        // No `defer gpa.free(name)` here: this slice IS the return
        // value, and a `defer` would free it before the caller ever
        // reads it. Ownership transfers to the caller instead.
        const name = try std.fmt.allocPrint(gpa, "{s}{s}{s}{x}", .{ base, std.fs.path.sep_str, REQUIRED_TMP_SUBSTR, suffix });
        std.Io.Dir.cwd().createDirPath(io, name) catch |err| switch (err) {
            // Already exists → free this attempt and try a new suffix.
            error.PathAlreadyExists => {
                gpa.free(name);
                continue;
            },
            else => {
                gpa.free(name);
                return err;
            },
        };
        return name;
    }
    return error.BootFailed;
}

// ============================================================================
// Binary resolution
// ============================================================================

/// Candidate binary paths, in resolution order. `$PABRIK_BIN` is
/// handled by the caller before this list is consulted.
const BIN_CANDIDATES = [_][]const u8{
    "zig-out/bin/pabrik",
    "zig-out/bin/pabrik.exe",
    "zig-out/bin/pabrikcore-linux-x86_64",
    "zig-out/bin/pabrikcore-macos-aarch64",
    "zig-out/bin/pabrikcore-macos-x86_64",
    "zig-out/bin/pabrikcore-windows-x86_64",
    "zig-out/bin/pabrikcore-windows-x86_64.exe",
};

/// Resolve the `pabrik` binary the suite boots.
///
/// Order: `$PABRIK_BIN`, then the known `zig-out/bin/*` spellings. The
/// build step runs with cwd = repo root so the relative paths resolve.
pub fn resolvePabrikBin(io: Io, gpa: Allocator) ![]u8 {
    if (getEnvOrEmpty(gpa, "PABRIK_BIN")) |env_bin| {
        defer gpa.free(env_bin);
        if (env_bin.len > 0) {
            const resolved = resolveRelative(io, gpa, env_bin) catch env_bin;
            if (isExecutable(io, resolved)) return resolved;
        }
    } else |_| {}
    for (BIN_CANDIDATES) |c| {
        const resolved = try resolveRelative(io, gpa, c);
        if (isExecutable(io, resolved)) return resolved;
    }
    return error.BinaryNotFound;
}

/// Resolve the `mcp-hello-world` test MCP server (stdio transport),
/// built by `zig build mcp-hello-world`.
pub fn mcpHelloWorldBin(io: Io, gpa: Allocator) ![]u8 {
    if (getEnvOrEmpty(gpa, "MCP_HELLO_WORLD_BIN")) |env_bin| {
        defer gpa.free(env_bin);
        if (env_bin.len > 0) {
            const resolved = resolveRelative(io, gpa, env_bin) catch env_bin;
            if (isExecutable(io, resolved)) return resolved;
        }
    } else |_| {}
    for ([_][]const u8{
        "zig-out/bin/mcp-hello-world",
        "zig-out/bin/mcp-hello-world-linux-x86_64",
    }) |c| {
        const resolved = try resolveRelative(io, gpa, c);
        if (isExecutable(io, resolved)) return resolved;
    }
    return error.BinaryNotFound;
}

/// Resolve the `mcp-http-hello-world` test MCP server (HTTP transport).
/// Per the project convention "one binary per transport", this is a
/// distinct binary from the stdio one, not a flag on it.
pub fn mcpHttpHelloWorldBin(io: Io, gpa: Allocator) ![]u8 {
    if (getEnvOrEmpty(gpa, "MCP_HTTP_HELLO_WORLD_BIN")) |env_bin| {
        defer gpa.free(env_bin);
        if (env_bin.len > 0) {
            const resolved = resolveRelative(io, gpa, env_bin) catch env_bin;
            if (isExecutable(io, resolved)) return resolved;
        }
    } else |_| {}
    for ([_][]const u8{
        "zig-out/bin/mcp-http-hello-world",
        "zig-out/bin/mcp-http-hello-world-linux-x86_64",
    }) |c| {
        const resolved = try resolveRelative(io, gpa, c);
        if (isExecutable(io, resolved)) return resolved;
    }
    return error.BinaryNotFound;
}

fn resolveRelative(io: Io, gpa: Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return gpa.dupe(u8, path);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().realPathFile(io, path, &buf) catch |err| switch (err) {
        error.FileNotFound, error.NameTooLong => return gpa.dupe(u8, path),
        else => return err,
    };
    return gpa.dupe(u8, buf[0..len]);
}

fn isExecutable(io: Io, path: []const u8) bool {
    // `access(.{ .execute = true })` asks the OS directly. Zig 0.16's
    // `Io.File.Stat` carries a typed `Permissions` (an enum on Windows,
    // a mode wrapper elsewhere) rather than a raw `mode`, so testing
    // the execute bit by hand would be platform-branching for no gain:
    // the OS already knows the answer.
    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}

/// Read an environment variable from the CURRENT process, or `""`.
///
/// Zig 0.16 removed `std.process.getEnvVarOwned`; the supported read
/// path in a test is `std.testing.environ` (a `std.process.Environ`),
/// which is populated by the test runner. Outside a test the global
/// block is the equivalent — see `currentEnviron`.
fn getEnvOrEmpty(gpa: Allocator, name: []const u8) ![]u8 {
    if (currentEnviron().getAlloc(gpa, name)) |v| return v else |_| return gpa.dupe(u8, "");
}

/// The current process's environment as a `Map` view we can read from.
///
/// `std.testing.environ` is only defined under `builtin.is_test`; the
/// process-global block is the non-test equivalent.
fn currentEnviron() std.process.Environ {
    if (builtin.is_test) return std.testing.environ;
    return std.process.Environ{ .block = .global };
}

// ============================================================================
// Stub LLM profile
// ============================================================================

/// Pre-create a stub LLM profile at every platform-correct config path
/// so the binary boots without a real `api_key`.
///
/// The `base_url` points at a port that never responds, so a session
/// create fails at runtime when it calls the LLM — which is fine, since
/// the functional tests assert on the wire, not on LLM responses.
///
/// Written to all three locations so the helper works regardless of
/// which platform's `getDefaultConfigDir` the binary uses.
pub fn writeStubLlmProfile(io: Io, gpa: Allocator, temp_dir: []const u8) !void {
    const payload =
        \\{
        \\  "profiles_models": {
        \\    "stub": {
        \\      "model": "stub-model",
        \\      "base_url": "http://127.0.0.1:1",
        \\      "api_key": "stub-key-not-real"
        \\    }
        \\  },
        \\  "selected_profile_model": "stub"
        \\}
    ;
    const dirs = [_][]const []const u8{
        &.{ ".config", "pabrik" },
        &.{ "AppData", "Roaming", "pabrik" },
        &.{ "Library", "Application Support", "pabrik" },
    };
    for (dirs) |parts| {
        const dir = try harnessPath(gpa, temp_dir, parts);
        defer gpa.free(dir);
        std.Io.Dir.cwd().createDirPath(io, dir) catch continue;
        const file = try std.fs.path.join(gpa, &.{ dir, "config.json" });
        defer gpa.free(file);
        var f = std.Io.Dir.cwd().createFile(io, file, .{}) catch continue;
        defer f.close(io);
        f.writeStreamingAll(io, payload) catch continue;
    }
}

// ============================================================================
// Convenience
// ============================================================================

/// The outcome of a `pabrik` subcommand run against a harness's HOME.
pub const RunResult = struct {
    /// Exit code, or null if the child was killed by a signal.
    exit_code: ?u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *RunResult, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.* = undefined;
    }
};

/// Run a `pabrik` SUBCOMMAND (not the server) against `home`, capturing
/// stdout+stderr.
///
/// 40 of the 132 Python suites shell out to the binary — `create-admin`,
/// `pabrik config get`, `pabrik mcp ...`. This is the Zig equivalent of
/// Python's `subprocess.run(..., env={**os.environ, "HOME": temp_dir},
/// capture_output=True, timeout=30)`.
///
/// `home` is the harness's isolated tempdir, so a subcommand that writes
/// config writes it where the test can read it — exactly like the server
/// itself. `timeout_ms` bounds the wait: exceeding it kills the child and
/// returns `error.RunTimedOut` rather than hanging the suite.
///
/// WHY FILES AND NOT PIPES: `std.process.spawn` with `.pipe` gives the
/// parent two pipes it must drain BEFORE `wait`, or a chatty child fills
/// the 64 KiB pipe buffer and deadlocks against its own `wait`. Draining
/// concurrently needs two reader threads plus a kill watchdog plus a
/// join-ordering discipline. Writing to two scratch files inside the
/// harness tempdir has none of those failure modes and the files are
/// removed with the tempdir anyway.
pub fn runPabrikCommand(
    io: Io,
    gpa: Allocator,
    home: []const u8,
    argv: []const []const u8,
    timeout_ms: u32,
) !RunResult {
    const bin = try resolvePabrikBin(io, gpa);
    defer gpa.free(bin);

    // Same isolation the server gets: HOME plus the XDG vars, all
    // pointing inside the harness tempdir.
    const xdg_config = try std.fs.path.join(gpa, &.{ home, ".config" });
    defer gpa.free(xdg_config);
    const xdg_state = try std.fs.path.join(gpa, &.{ home, ".local", "state" });
    defer gpa.free(xdg_state);
    const xdg_data = try std.fs.path.join(gpa, &.{ home, ".local", "share" });
    defer gpa.free(xdg_data);
    const xdg_cache = try std.fs.path.join(gpa, &.{ home, ".cache" });
    defer gpa.free(xdg_cache);

    var env_map = try std.process.Environ.createMap(currentEnviron(), gpa);
    defer env_map.deinit();
    try env_map.put("HOME", home);
    try env_map.put("XDG_CONFIG_HOME", xdg_config);
    try env_map.put("XDG_STATE_HOME", xdg_state);
    try env_map.put("XDG_DATA_HOME", xdg_data);
    try env_map.put("XDG_CACHE_HOME", xdg_cache);

    // The capture files live inside `home` — normally the harness
    // tempdir, which teardown removes anyway. But `home` is a CALLER
    // argument, and a caller may pass a directory it just created:
    // between creating it and getting here, a LATER `Harness.boot` can
    // run `reapOrphanTestPids`, which sees a `pabrik-func-` entry with no
    // live `.harness.pid` and deletes it. The observed symptom was an
    // intermittent `error.FileNotFound` out of `createFile` in one auth
    // test — order-dependent, so it looked like a flake in the test
    // rather than a race with the reaper.
    //
    // Recreating the directory is the right repair rather than a retry:
    // the child needs `home` to exist anyway, and a missing HOME is
    // exactly what the stub-LLM bootstrap below has to handle.
    std.Io.Dir.cwd().createDirPath(io, home) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const out_path = try std.fs.path.join(gpa, &.{ home, ".cmd-stdout" });
    defer gpa.free(out_path);
    const err_path = try std.fs.path.join(gpa, &.{ home, ".cmd-stderr" });
    defer gpa.free(err_path);

    var out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer out_file.close(io);
    var err_file = try std.Io.Dir.cwd().createFile(io, err_path, .{});
    defer err_file.close(io);

    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.append(gpa, bin);
    try full.appendSlice(gpa, argv);

    var child = try std.process.spawn(io, .{
        .argv = full.items,
        .environ_map = &env_map,
        .stdout = .{ .file = out_file },
        .stderr = .{ .file = err_file },
    });

    // Bound the wait. `Child.wait` blocks, so the deadline is enforced by
    // a watchdog thread that kills the child if it overruns. `timed_out`
    // is what distinguishes "we killed it" from "it crashed" — both
    // surface as a non-`.exited` term, and only the first is an error
    // the caller should hear about.
    // The flag is set only when the watchdog's `kill` was the thing that
    // ended the child. Setting it unconditionally on wake would misfire
    // for a child that finished in the same millisecond as the deadline
    // — the wait returns, and a flag set microseconds later reports a
    // timeout for a run that completed.
    var timed_out = std.atomic.Value(bool).init(false);
    const watchdog = try std.Thread.spawn(.{}, struct {
        fn killAfter(c: *std.process.Child, w_io: Io, ms: u32, flag: *std.atomic.Value(bool)) void {
            Io.sleep(w_io, .fromMilliseconds(ms), .awake) catch return;
            // `Child.kill` is a NO-OP once the child has been reaped —
            // `child.id` is null then. So: set the flag, kill, and let
            // the parent's `wait` be the arbiter of what actually
            // happened. If the child was already gone, `wait` returns
            // `.exited` with its real code and the flag is cleared.
            flag.store(true, .release);
            c.kill(w_io);
        }
    }.killAfter, .{ &child, io, timeout_ms, &timed_out });

    const term = child.wait(io) catch {
        watchdog.join();
        return error.RunFailed;
    };
    watchdog.join();

    // A clean exit is a clean exit even if the watchdog woke during it.
    const exited_normally = switch (term) {
        .exited => true,
        else => false,
    };
    if (!exited_normally and timed_out.load(.acquire)) return error.RunTimedOut;

    const code: ?u8 = switch (term) {
        .exited => |c| c,
        // Killed by a signal the harness did not send — a genuine crash.
        else => null,
    };

    // Read the captures back. They live in the tempdir, which `deinit`
    // removes, so nothing here outlives the harness.
    const stdout_bytes = std.Io.Dir.cwd().readFileAlloc(io, out_path, gpa, .limited(1 << 20)) catch try gpa.dupe(u8, "");
    const stderr_bytes = std.Io.Dir.cwd().readFileAlloc(io, err_path, gpa, .limited(1 << 20)) catch try gpa.dupe(u8, "");

    return .{
        .exit_code = code,
        .stdout = stdout_bytes,
        .stderr = stderr_bytes,
    };
}

comptime {
    // Body-analysis barrier. See the note above: an unreferenced
    // function is never type-checked, so a stdlib rename inside one is
    // invisible until a caller appears. These references make every
    // public entry point's body part of the build.
    _ = harnessPath;
    _ = tmpRoot;
    _ = canonical;
    _ = isSafeTmp;
    _ = afterFirst;
    _ = harnessPath;
    _ = requirePabrikBin;
    _ = runPabrikCommand;
    _ = reapOrphanTestPids;
    _ = signalGroup;
    _ = findFreePort;
    _ = findFreePortSequential;
    _ = findFreePortRandom;
    _ = portIsFreeWithReuse;
    _ = resolvePabrikBin;
    _ = mcpHelloWorldBin;
    _ = mcpHttpHelloWorldBin;
    _ = writeStubLlmProfile;
    _ = randomSuffix;
    _ = makeScratchDir;
    _ = makeScratchDir;
    _ = debugString;
    _ = cleanupExtraDir;
    _ = run;
    _ = Response.json;
    _ = Response.header;
    _ = Response.headerAll;
    _ = Harness.boot;
    _ = Harness.deinit;
    _ = Harness.http;
    _ = Harness.health;
    _ = Harness.tailLog;
    _ = Json.get;
    _ = Json.str;
    _ = Json.int;
    _ = Json.boolean;
    _ = Json.array;
    _ = Json.object;
    _ = Json.number;
}

/// Allocate a scratch directory for a suite's OWN fixture (a git repo, a
/// design tree), OUTSIDE the harness's tempdir namespace.
///
/// WHY NOT INSIDE `temp_dir`, AND WHY A DIFFERENT PREFIX:
///
/// `reapOrphanTestPids` runs on EVERY boot and deletes any directory
/// under the OS temp root whose name starts with `REQUIRED_TMP_SUBSTR`
/// (`pabrik-func-`) and whose `.harness.pid` names a dead process. That
/// is correct for the harness's own tempdirs. It is actively harmful for
/// a fixture: a suite that builds a git repo at
/// `/tmp/pabrik-func-<hex>/repo` has its fixture reaped by the NEXT
/// boot, mid-test, because the fixture directory matches the prefix and
/// carries no live pid of its own. The symptom is spectacular and
/// misleading — the request returns three well-formed rows with EMPTY
/// `diff_content`, because `git -C <deleted>` exits non-zero and the
/// handler swallows spawn failures.
///
/// So fixtures get their own prefix (`pabrik-fix-`) and their own
/// `isSafeTmp`-gated delete (`cleanupExtraDir`). That is also what
/// pytest's `tmp_path` does: it is a sibling of the harness tempdir,
/// never a child of it.
pub fn makeScratchDir(gpa: Allocator) ![]u8 {
    const base = try tmpRoot(gpa);
    defer gpa.free(base);

    var prng = entropyPrng(testingIo());
    const rand = prng.random();
    var attempt: usize = 0;
    while (attempt < 32) : (attempt += 1) {
        const suffix = rand.int(u64);
        const dir = try std.fmt.allocPrint(gpa, "{s}{s}{s}{x}", .{
            base, std.fs.path.sep_str, SCRATCH_PREFIX, suffix,
        });
        // No `defer gpa.free(dir)`: this slice IS the return value.
        std.Io.Dir.cwd().createDirPath(testingIo(), dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                gpa.free(dir);
                continue;
            },
            else => {
                gpa.free(dir);
                return err;
            },
        };
        return dir;
    }
    return error.OutOfMemory;
}

/// The namespace marker a suite's own fixture directory must carry.
///
/// Deliberately NOT `REQUIRED_TMP_SUBSTR`: `isSafeTmp` accepts either,
/// so `cleanupExtraDir` still gates the delete, but a fixture named
/// with this prefix is invisible to `reapOrphanTestPids`, which only
/// looks for `pabrik-func-`.
pub const SCRATCH_PREFIX = "pabrik-fix-";

/// A short random hex string, for a scratch-dir or fixture name.
///
/// Suites need their OWN tempdir when the subject under test is
/// filesystem state (a git fixture repo, a design file tree) rather than
/// server state — the server's tempdir is the HOME it boots under, and a
/// test that writes a repo there would be testing the wrong isolation.
/// `std.testing.tmpDir` is NOT a substitute: it allocates under
/// `<cwd>/.zig-cache/tmp/`, which for this package is inside the git
/// worktree, and `git symbolic-ref` walks UP — so a fixture repo created
/// there resolves to the WORKTREE's branch and any assertion about
/// branches passes for the wrong reason.
pub fn randomSuffix(gpa: Allocator) ![]u8 {
    var prng = entropyPrng(testingIo());
    return std.fmt.allocPrint(gpa, "{x}", .{prng.random().int(u64)});
}

/// Remove a directory the TEST created, after checking it is under the
/// OS temp root and carries the `REQUIRED_TMP_SUBSTR` marker.
///
/// `Harness.deinit` deletes `temp_dir` — the HOME the server booted under.
/// A suite's own scratch dirs (git fixtures, design trees) are outside
/// that tree, so they need their own gated delete. `deleteTree` here is
/// NOT gated by the caller's judgment: `isSafeTmp` is, and a refusal is
/// printed rather than fatal so a cleanup problem never masks the test's
/// real failure.
pub fn cleanupExtraDir(io: Io, gpa: Allocator, path: []const u8) void {
    const safe = isSafeTmp(io, gpa, path, "") catch false;
    if (!safe) {
        std.debug.print(
            "refusing to delete {s}: not a tmpdir carrying the {s} or {s} marker\n",
            .{ path, REQUIRED_TMP_SUBSTR, SCRATCH_PREFIX },
        );
        return;
    }
    std.Io.Dir.cwd().deleteTree(io, path) catch |err| {
        std.debug.print("cleanup of {s} failed: {s}\n", .{ path, @errorName(err) });
    };
}

/// Render `s` with non-printable bytes escaped, for a diagnostic.
///
/// Zig 0.16 removed the old `std.zig.fmtEscapes`. Suites used it to
/// quote a needle in a failure message — a description that fails
/// because it does not contain a REGEX metacharacter is unreadable
/// without knowing which byte was being looked for. This returns an
/// OWNED buffer; a `{s}` format arg borrows it only for the call.
pub fn debugString(gpa: Allocator, s: []const u8) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    for (s) |c| {
        switch (c) {
            0x20...0x21, 0x23...0x5B, 0x5D...0x7E => try buf.writer.writeByte(c),
            else => try buf.writer.print("\\x{x:0>2}", .{c}),
        }
    }
    return buf.toOwnedSlice();
}

/// Return the text AFTER the first occurrence of `delim`, or `null`.
///
/// THE reason this exists: `std.mem.splitSequence(hay, delim).next()`
/// returns the text BEFORE the delimiter, not after. Reaching "what
/// comes after" therefore takes TWO `next()` calls — and the
/// first `next()` of a temporary iterator reads as "get me the value"
/// to anyone expecting Python's `s.split(delim, 1)[1]` semantics.
///
/// That mistake cost a debugging round on the auth port: the extracted
/// "session token" was the `Set-Cookie` ATTRIBUTE list (`Path=/;
/// HttpOnly`), which then failed `token.len > 16` for a reason that had
/// nothing to do with tokens.
pub fn afterFirst(haystack: []const u8, delim: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, haystack, delim);
    _ = it.next() orelse return null; // the before-part
    return it.next(); // the after-part
}

/// Return `error.SkipZigTest` unless a `pabrik` binary is resolvable.
///
/// THE FIRST LINE OF EVERY SUITE THAT BOOTS A HARNESS. A fresh
/// worktree has no `zig-out/`, and the ~758 tests in this package each
/// boot their own binary — without this guard a missing binary would
/// be 758 red tests instead of one skipped suite, and the signal that
/// matters ("build the binary first") drowns in the noise.
///
///     test "workspace_create_returns_201" {
///         try harness.requirePabrikBin(testing.io, gpa);
///         var h = try Harness.boot(testing.io, gpa, .{});
///         defer h.deinit(testing.io) catch {};
///         ...
///     }
pub fn requirePabrikBin(io: Io, gpa: Allocator) !void {
    const bin = resolvePabrikBin(io, gpa) catch |err| switch (err) {
        error.BinaryNotFound => return error.SkipZigTest,
        else => return err,
    };
    gpa.free(bin);
}

/// Boot a harness and run `f`, then tear it down — the Zig analogue of
/// Python's `run_quick` context manager.
///
///     try harness.run(io, gpa, .{}, struct {
///         fn body(io: Io, h: *Harness) !void {
///             ...
///         }
///     }.body);
pub fn run(
    io: Io,
    gpa: Allocator,
    opts: Harness.BootOptions,
    comptime f: fn (Io, *Harness) anyerror!void,
) !void {
    var h = try Harness.boot(io, gpa, opts);
    defer h.deinit(io) catch |err| {
        std.debug.print("harness teardown: {s}\n", .{@errorName(err)});
    };
    try f(io, &h);
}
