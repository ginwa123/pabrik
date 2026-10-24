const std = @import("std");
const builtin = @import("builtin");

// Win32 GetFileAttributesW — declared locally because std.os.windows 0.16
// doesn't expose it (std.os.windows.kernel32 only ships the functions the std
// lib's own files need).
extern "kernel32" fn GetFileAttributesW(lpPathName: [*:0]const u16) callconv(.winapi) u32;
// NTSTATUS-like sentinel: when the path is missing/inaccessible,
// GetFileAttributesW returns `INVALID_FILE_ATTRIBUTES` (0xFFFFFFFF).
const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
// File-sys flag bit (0x10 = bit 4) indicating the path is a directory,
// not a regular file. Probe mirrors `test -f <path>` semantics, so
// directories count as NOT-a-file.
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x00000010;

/// Cross-platform, pure-Zig "does this file exist" check. Used by the
/// system-deps probe (`dbs_uses_system`, `curl_uses_system`) below.
fn callerSetsStaticDir(args: ?[]const []const u8) bool {
    const forwarded = args orelse return false;
    for (forwarded) |arg| {
        if (std.mem.eql(u8, arg, "--static-dir") or std.mem.eql(u8, arg, "--no-static-dir")) return true;
    }
    return false;
}

fn fileExists(absolute_path: []const u8) bool {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (absolute_path.len >= buf.len) return false;
    @memcpy(buf[0..absolute_path.len], absolute_path);
    buf[absolute_path.len] = 0;
    return switch (builtin.os.tag) {
        .linux => blk: {
            const rc = std.os.linux.faccessat(std.os.linux.AT.FDCWD, &buf, 0, 0);
            break :blk rc == 0;
        },
        // macOS: libc `access()` — same F_OK check as `test -f`. (The build
        // runner links libc, so the extern is always resolvable; no shell-out
        // needed.
        .macos => blk: {
            const rc = std.c.access(&buf, 0); // F_OK = 0
            break :blk rc == 0;
        },
        .windows => blk: {
            // WTF-8 (Zig's UTF-8 with surrogate-half support) → WTF-16
            // little-endian (Win32's wide-char path) for the Win32 API call.
            var wide: [std.fs.max_path_bytes]u16 = undefined;
            const written = std.unicode.wtf8ToWtf16Le(&wide, absolute_path) catch break :blk false;
            if (written >= wide.len) break :blk false;
            wide[written] = 0;
            const attrs = GetFileAttributesW(@ptrCast(&wide));
            if (attrs == INVALID_FILE_ATTRIBUTES) break :blk false;
            if ((attrs & FILE_ATTRIBUTE_DIRECTORY) != 0) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

/// Return the first entry of `candidates` that exists as a file, or null when
/// none match.
fn pickFirstExisting(candidates: []const []const u8) ?[]const u8 {
    for (candidates) |p| {
        if (fileExists(p)) return p;
    }
    return null;
}

/// Locate MSVC's C++ standard-library headers (used by pabrik-desktop's
/// pabrik_webview.cpp on Windows).
fn hasMsvcCppStllib(b: *std.Build, io: std.Io) bool {
    if (b.graph.host.result.os.tag != .windows) return false;

    // vcvars64.bat sets these. `INCLUDE` is the primary env var that
    // lists C/C++ system header search paths.
    if (b.graph.environ_map.get("INCLUDE")) |inc| {
        // Quick check: does the INCLUDE list mention the MSVC `include/`
        // directory? Even a partial match (any path under `VC\Tools\MSVC`)
        // is good enough — we don't need to verify cstddef specifically.
        if (std.mem.indexOf(u8, inc, "MSVC") != null) return true;
    }

    // Fallback: probe the canonical install path. This catches CI runners
    // that sourced vcvars64.bat into a different env (some workflows
    // import just INCLUDE; others also set VCToolsInstallDir).
    const candidates = [_][]const u8{
        "C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC",
        "C:/Program Files/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC",
        "C:/Program Files (x86)/Microsoft Visual Studio/2022/Community/VC/Tools/MSVC",
        "C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/MSVC",
    };
    for (candidates) |root| {
        // Any subdir under `MSVC/` (e.g. `14.44.35207/`) means MSVC is
        // installed.
        const d = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        // `it.next` returns `Error!?Entry` (error union of optional).
        // Return true if the read succeeded AND there's an entry. Any
        // other outcome (error or end-of-stream) means "not installed".
        if (it.next(io)) |maybe_entry| {
            if (maybe_entry) |_| return true;
        } else |_| {} // readdir error — assume not installed
    }
    return false;
}

/// Locate the MSVC include dirs needed by `zig cc` when compiling
/// `platform/windows/pabrik_webview.cpp`.
const MsvcIncludePaths = struct {
    c_stddef: []const u8,
    msvc_include: []const u8,
    ucrt_include: []const u8,
    um_include: []const u8,
    shared_include: []const u8,
    winrt_include: []const u8,
};

fn findMsvcInclude(b: *std.Build) MsvcIncludePaths {
    // Empty defaults — used if everything below fails so the caller
    // still has well-typed string handles (even if empty).
    const empty = &[_]u8{};
    var result = MsvcIncludePaths{
        .c_stddef = empty,
        .msvc_include = empty,
        .ucrt_include = empty,
        .um_include = empty,
        .shared_include = empty,
        .winrt_include = empty,
    };
    if (b.graph.host.result.os.tag != .windows) return result;

    // Find the MSVC root (the dir under `.../VC/Tools/MSVC/<version>/`).
    // 1. Prefer `VCToolsInstallDir` env var (e.g.
    //    `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207`).
    const vc_root: []const u8 = if (b.graph.environ_map.get("VCToolsInstallDir")) |p|
        p
    else
        // 2. Fallback: enumerate the canonical install locations and pick the
        // first one with a `<ver>/include/` subdir. The version directory
        // name is opaque (e.g. `14.44.35207`), so we don't hard-code it.
        firstMsvcRoot(b) orelse &[_]u8{};

    if (vc_root.len == 0) {
        // No MSVC STL root resolved (e.g. standalone Windows SDK
        // install without VS). The Windows SDK dirs are independent of
        // VS — still resolve them instead of bailing with six empties.
        fillWindowsSdkIncludes(b, &result);
        return result;
    }
    result.c_stddef = b.fmt("{s}/include", .{vc_root}); // MSVC C++ stdlib (cstddef, etc.)
    result.msvc_include = result.c_stddef;
    fillWindowsSdkIncludes(b, &result);
    return result;
}

/// Populate the four Windows SDK include subdirs in `result` (`ucrt`, `um`,
/// `shared`, `winrt`). Resolution order: 1.
fn fillWindowsSdkIncludes(b: *std.Build, result: *MsvcIncludePaths) void {
    if (b.graph.environ_map.get("INCLUDE")) |inc| {
        var it = std.mem.splitScalar(u8, inc, ';');
        while (it.next()) |entry_raw| {
            const entry = std.mem.trim(u8, entry_raw, " \t\"");
            if (entry.len == 0) continue;
            const leaf = std.fs.path.basename(entry);
            if (std.mem.eql(u8, leaf, "ucrt") and result.ucrt_include.len == 0) {
                result.ucrt_include = entry;
            } else if (std.mem.eql(u8, leaf, "um") and result.um_include.len == 0) {
                result.um_include = entry;
            } else if (std.mem.eql(u8, leaf, "shared") and result.shared_include.len == 0) {
                result.shared_include = entry;
            } else if (std.mem.eql(u8, leaf, "winrt") and result.winrt_include.len == 0) {
                // Exact basename match — "cppwinrt" deliberately does NOT land here.
                result.winrt_include = entry;
            }
        }
    }

    const kit_roots = [_][]const u8{
        "C:/Program Files (x86)/Windows Kits/10/include",
        "C:/Program Files/Windows Kits/10/include",
    };
    const leaves = [_]struct { leaf: []const u8, field: *[]const u8 }{
        .{ .leaf = "ucrt", .field = &result.ucrt_include },
        .{ .leaf = "um", .field = &result.um_include },
        .{ .leaf = "shared", .field = &result.shared_include },
        .{ .leaf = "winrt", .field = &result.winrt_include },
    };
    for (kit_roots) |root| {
        const ver_root = firstSubdir(b, root) orelse continue;
        for (leaves) |l| {
            if (l.field.*.len != 0) continue;
            const candidate = b.fmt("{s}/{s}", .{ ver_root, l.leaf });
            if (dirExists(b, candidate)) l.field.* = candidate;
        }
    }
}

/// Stage a pruned copy of MSVC's `msvcrt.lib` into the NuGet staging dir:
/// satisfies `/DEFAULTLIB:MSVCRT` (emitted by msvcprt.lib members) without
/// the CFG/TLS startup members that collide with mingw's (`duplicate symbol`
fn stagePrunedMsvcrt(b: *std.Build, msvc_lib_root: []const u8, stage_dir: []const u8) void {
    const src_path = b.fmt("{s}/msvcrt.lib", .{msvc_lib_root});
    const dst_path = b.fmt("{s}/msvcrt.lib", .{stage_dir});
    const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, src_path, b.allocator, .unlimited) catch return;
    defer b.allocator.free(bytes);
    std.Io.Dir.cwd().writeFile(b.graph.io, .{ .sub_path = dst_path, .data = bytes }) catch return;
    // Prune list is evidence-driven: guard_support.obj (proven dup — lld
    // names it against mingw's mingw_cfguard_support.obj) + the TLS-init
    // family (dup set from the full-lib link).
    const prune_members = [_][]const u8{
        "guard_support.obj",
        "dyn_tls_init.obj",
        "dyn_tls_dtor.obj",
        "tlsdtor.obj",
        "tlsdyn.obj",
        "tlssup.obj",
    };
    var ar_argv: [4 + prune_members.len][]const u8 = undefined;
    ar_argv[0] = b.graph.zig_exe;
    ar_argv[1] = "ar";
    ar_argv[2] = "d";
    ar_argv[3] = dst_path;
    for (prune_members, 0..) |m, i| ar_argv[4 + i] = m;
    _ = b.run(ar_argv[0 .. 4 + prune_members.len]);
}

/// True when `dst` is missing or its size differs from `src` (used for the
/// config-time MSVC runtime-lib staging copy). Size-only comparison: cheap,
/// no hashing, and exact for these never-edited-in-place import libs.
fn staleOrMissing(b: *std.Build, src_path: []const u8, dst_path: []const u8) bool {
    const src_stat = std.Io.Dir.cwd().statFile(b.graph.io, src_path, .{}) catch return true;
    const dst_stat = std.Io.Dir.cwd().statFile(b.graph.io, dst_path, .{}) catch return true;
    return src_stat.size != dst_stat.size;
}

/// Return true when `abs_path` exists and is a directory. Mirrors the
/// openDir probe pattern used by `hasMsvcCppStllib` (fileExists only
/// matches files — it explicitly rejects FILE_ATTRIBUTE_DIRECTORY).
fn dirExists(b: *std.Build, abs_path: []const u8) bool {
    const d = std.Io.Dir.cwd().openDir(b.graph.io, abs_path, .{}) catch return false;
    d.close(b.graph.io);
    return true;
}

/// Resolve the MSVC toolset version root (`.../VC/Tools/MSVC/<ver>`) for the
/// `-include` compat header below.
fn msvcVersionRoot(b: *std.Build) ?[]const u8 {
    if (b.graph.host.result.os.tag != .windows) return null;
    if (b.graph.environ_map.get("VCToolsInstallDir")) |p| {
        if (dirExists(b, p)) return p;
    }
    return firstMsvcRoot(b);
}

/// Walk the canonical VS install locations and return the first
/// `<root>/VC/Tools/MSVC/<ver>` dir we find. Returns null on miss.
/// Non-Windows always returns null.
fn firstMsvcRoot(b: *std.Build) ?[]const u8 {
    if (b.graph.host.result.os.tag != .windows) return null;
    const roots = [_][]const u8{
        "C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC",
        "C:/Program Files/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC",
        "C:/Program Files (x86)/Microsoft Visual Studio/2022/Community/VC/Tools/MSVC",
        "C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/MSVC",
    };
    for (roots) |msvc_root| {
        // Open the MSVC root and pick the first subdir (the version dir like
        // `14.44.35207`). Without that subdir, MSVC isn't installed at this
        // root.
        const d = std.Io.Dir.openDirAbsolute(b.graph.io, msvc_root, .{ .iterate = true }) catch continue;
        defer d.close(b.graph.io);
        var it = d.iterate();
        while (it.next(b.graph.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            return b.fmt("{s}/{s}", .{ msvc_root, entry.name });
        }
    }
    return null;
}

/// Numeric dotted-version compare: true when `a` is a HIGHER version than
/// `b`.
fn versionGreater(a: []const u8, b: []const u8) bool {
    var ai = std.mem.splitScalar(u8, a, '.');
    var bi = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const an = ai.next();
        const bn = bi.next();
        if (an == null and bn == null) return false;
        const av = if (an) |s| std.fmt.parseInt(u64, s, 10) catch 0 else 0;
        const bv = if (bn) |s| std.fmt.parseInt(u64, s, 10) catch 0 else 0;
        if (av != bv) return av > bv;
    }
}

/// Return `<root>/<highest-versioned subdirectory that actually contains
/// every name in `required_files`, or null when none does. Do NOT use
/// `firstSubdir` for the Windows SDK.
fn newestSubdirWith(b: *std.Build, root: []const u8, required_files: []const []const u8) ?[]const u8 {
    if (b.graph.host.result.os.tag != .windows) return null;
    const d = std.Io.Dir.openDirAbsolute(b.graph.io, root, .{ .iterate = true }) catch return null;
    defer d.close(b.graph.io);
    var best_name: ?[]const u8 = null;
    var it = d.iterate();
    while (it.next(b.graph.io) catch null) |entry| {
        // `.sym_link` counts: the real SDK leaves ship as links (the image
        // has `wdf0.26100.0` alongside a plain `wdf`), and a dangling one
        // is rejected by the file probe below anyway.
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        const candidate = b.fmt("{s}/{s}", .{ root, entry.name });
        var complete = true;
        for (required_files) |f| {
            if (!fileExists(b.fmt("{s}/{s}", .{ candidate, f }))) {
                complete = false;
                break;
            }
        }
        if (!complete) continue;
        if (best_name == null or versionGreater(entry.name, best_name.?)) {
            // MUST dupe: `entry.name` points into the iterator's name buffer,
            // which the next `it.next()` overwrites.
            best_name = b.dupe(entry.name);
        }
    }
    return if (best_name) |n| b.fmt("{s}/{s}", .{ root, n }) else null;
}

/// Return `<root>/<first-subdirectory>`, or null when `root` doesn't
/// exist or contains no subdirectories. Used to resolve opaque version
/// directories (`14.44.35207`, `10.0.22621.0`) without hard-coding them.
fn firstSubdir(b: *std.Build, root: []const u8) ?[]const u8 {
    if (b.graph.host.result.os.tag != .windows) return null;
    // `OpenOptions.iterate` is required — without it `it.next` fails
    // with AccessDenied on Windows (see hasMsvcCppStllib).
    const d = std.Io.Dir.openDirAbsolute(b.graph.io, root, .{ .iterate = true }) catch return null;
    defer d.close(b.graph.io);
    var it = d.iterate();
    while (it.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        return b.fmt("{s}/{s}", .{ root, entry.name });
    }
    return null;
}

/// Find the system libstdc++ include directory on Linux.
fn findLibstdcxxInclude(b: *std.Build) ?[]const u8 {
    if (b.graph.host.result.os.tag != .linux) return null;

    // Run a small shell snippet via b.run() to find the highest-version gcc
    // c++ include dir. b.run() is std.Build's synchronous configure-time exec
    // helper — it returns stdout bytes and fails the build with a clear
    const stdout = b.run(&.{
        "/bin/sh", "-c",
        \\ls -1 /usr/include/c++ 2>/dev/null | sort -V | tail -1 | tr -d '\n'
    });
    if (stdout.len == 0) return null;
    return b.allocator.dupe(u8, stdout) catch null;
}

/// Check that ALL WebView2 NuGet prerequisites sit next to
/// pabrik_webview.cpp.
fn webview2MissingPrereq(b: *std.Build) ?[]const u8 {
    const prereqs = [_][]const u8{
        "WebView2.h",
        "EventToken.h",
        "WebView2Loader.h",
        "WebView2Loader.lib",
        // Runtime DLL (NuGet-staged).
        "WebView2Loader.dll",
    };
    for (prereqs) |name| {
        const full = b.fmt("src/apps/desktop_app/platform/windows/{s}", .{name});
        if (!fileExists(full)) return name;
    }
    return null;
}

/// Vendored Lua 5.4 sources compiled into a module.
/// A `--test-filter` one shard gets compiled with, plus the cost weight the
/// balancer assigns to it.
const TestShardEntry = struct {
    filter: []const u8,
    weight: u64,
    /// The test's real name, plus the filter shapes `name` can safely be
    /// reduced to. Both are kept so `pickLeastOverlappingFilter` can compare
    /// against every other name once the whole set is known.
    name: []const u8,
    candidates: TestFilterCandidates,
};

/// Weight of a test whose runtime is close to the suite median, which is
/// roughly 10 ms on this box.
const average_test_weight: u64 = 1;

/// Tests whose runtime is orders of magnitude above that median, so a
/// name-count-balanced split would still leave one shard holding all the wall
/// clock.
const slow_test_weights = [_]struct { name: []const u8, weight: u64 }{
    // ~21 s: spawns a command per subshell shape and waits out each timeout.
    // By itself this is the floor for any parallel split.
    .{ .name = "bash_tool: timeout kills descendants across all common subshell shapes", .weight = 2_100 },
    // ~3 s / ~1 s each: same file, real process spawns with real timeouts.
    .{ .name = "bash_tool: no FD accumulation across 20 sequential calls", .weight = 300 },
    .{ .name = "bash_tool: complex pipeline with multiple descendants is killed cleanly", .weight = 100 },
    .{ .name = "bash_tool: pipe-FD-holding subshell does not hang (force-kill cleanup works)", .weight = 100 },
    .{ .name = "bash_tool: returns within bounded wall-clock time even when child hangs", .weight = 100 },
    .{ .name = "bash_tool: subshell holding pipe FD open after parent death", .weight = 100 },
};

fn testWeight(name: []const u8) u64 {
    for (slow_test_weights) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.weight;
    }
    return average_test_weight;
}

/// `haystack.contains(needle)`, but anchored on a SIMD `memchr` for the
/// needle's first byte.
fn containsFast(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    // Stop early once too few bytes remain for the needle to fit — without
    // that, a hit on the needle's first byte near the end of the haystack
    // slices past it.
    const last_start = haystack.len - needle.len;
    var offset: usize = 0;
    while (std.mem.indexOfScalarPos(u8, haystack[0 .. last_start + 1], offset, needle[0])) |pos| {
        if (std.mem.eql(u8, haystack[pos..][0..needle.len], needle)) return true;
        offset = pos + 1;
    }
    return false;
}

/// An inverted index from 2-byte sequence to the test names containing it.
/// Sharding has to answer "which test names contain this filter?" a few
/// million times.
const PairIndex = struct {
    const pair_count = 1 << 16;
    const none = std.math.maxInt(u32);

    /// Counting sort of every (2-byte sequence, name index) occurrence, so a
    /// sequence's occurrences are the contiguous run `items[starts[p]..starts[p + 1]]`.
    starts: []u32,
    items: []u32,
    allocator: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator, names: []const []const u8) !PairIndex {
        // One slot per (name, adjacent byte pair).
        var total: usize = 0;
        for (names) |name| {
            if (name.len >= 2) total += name.len - 1;
        }

        const counts = try alloc.alloc(u32, pair_count);
        defer alloc.free(counts);
        @memset(counts, 0);

        const cursor = try alloc.alloc(u32, pair_count);
        defer alloc.free(cursor);

        for (names) |name| {
            var i: usize = 0;
            while (i + 2 <= name.len) : (i += 1) {
                counts[pairOf(name, i)] += 1;
            }
        }

        const starts = try alloc.alloc(u32, pair_count + 1);
        var running: u32 = 0;
        for (0..pair_count) |p| {
            starts[p] = running;
            running += counts[p];
            cursor[p] = starts[p];
        }
        starts[pair_count] = running;

        const items = try alloc.alloc(u32, total);
        for (names, 0..) |name, name_index| {
            var i: usize = 0;
            while (i + 2 <= name.len) : (i += 1) {
                const p = pairOf(name, i);
                items[cursor[p]] = @intCast(name_index);
                cursor[p] += 1;
            }
        }

        return .{ .starts = starts, .items = items, .allocator = alloc };
    }

    fn deinit(self: *PairIndex) void {
        self.allocator.free(self.starts);
        self.allocator.free(self.items);
    }

    fn pairOf(name: []const u8, i: usize) usize {
        return (@as(usize, name[i]) << 8) | name[i + 1];
    }

    /// The needle's 2-byte sequence with the shortest candidate list, i.e.
    /// the one that will send the fewest names to the exact compare.
    fn bestPair(self: *const PairIndex, needle: []const u8) u32 {
        var best: u32 = 0;
        var best_len: u32 = std.math.maxInt(u32);
        var i: usize = 0;
        while (i + 2 <= needle.len) : (i += 1) {
            const p: u32 = @intCast(pairOf(needle, i));
            const len = self.starts[p + 1] - self.starts[p];
            if (len < best_len) {
                best_len = len;
                best = p;
            }
        }
        return best;
    }

    fn candidates(self: *const PairIndex, pair: u32) []const u32 {
        return self.items[self.starts[pair]..self.starts[pair + 1]];
    }
};

/// Exactly how many of `all_names` contain `needle`, found by asking the
/// index for candidates and confirming each one.
fn countNamesContaining(all_names: []const []const u8, needle: []const u8, index: *const PairIndex) usize {
    if (needle.len == 0) return all_names.len;
    if (needle.len < 2) {
        // No 2-byte sequence to index on. Rare, and answering 0 here instead
        // of the truth is exactly how a one-character filter slipped past the
        // fan-out guard below while re-running the entire suite.
        var hits: usize = 0;
        for (all_names) |name| {
            if (std.mem.indexOf(u8, name, needle) != null) hits += 1;
        }
        return hits;
    }
    var hits: usize = 0;
    for (index.candidates(index.bestPair(needle))) |name_index| {
        if (std.mem.indexOf(u8, all_names[name_index], needle) != null) hits += 1;
    }
    return hits;
}

/// One pytest invocation for a Python functional suite, optionally pinned to
/// a single shard.
fn addPythonSuiteRun(
    b: *std.Build,
    argv: []const []const u8,
    pabrik_bin: []const u8,
    shard_total: u32,
    index: ?u32,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(argv);
    run.setCwd(b.path(""));
    const env_map = run.getEnvMap();
    env_map.put("PABRIK_BIN", pabrik_bin) catch @panic("OOM");
    if (index) |i| {
        env_map.put("PABRIK_FUNC_SHARD_TOTAL", b.fmt("{d}", .{shard_total})) catch @panic("OOM");
        env_map.put("PABRIK_FUNC_SHARD_INDEX", b.fmt("{d}", .{i})) catch @panic("OOM");
    }
    return run;
}

/// Report an unrecoverable build-configuration problem and stop.
fn fatalConfig(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    @panic("build configuration error");
}

/// Characters that cannot survive Zig's `@args-file` round trip. Zig writes
/// each `zig test` argument into a generated args file and quotes it.
fn isUnsafeFilterByte(c: u8) bool {
    return c == '"' or c == '\'' or c == '\\' or c < 0x20;
}

/// The `--test-filter` shapes a test name can safely be reduced to. `whole`
/// is non-null when the name has no byte the args file cannot carry, and is
/// then always the right answer.
const TestFilterCandidates = struct {
    whole: ?[]const u8,
    head: []const u8,
    tail: []const u8,
};

/// Reduce a test name to the `--test-filter` shapes that survive the args
/// file. See `TestFilterCandidates`.
fn safeTestFilter(name: []const u8) TestFilterCandidates {
    for (name) |c| {
        if (isUnsafeFilterByte(c)) break;
    } else return .{ .whole = name, .head = name, .tail = name };

    const first = blk: {
        for (name, 0..) |c, i| {
            if (isUnsafeFilterByte(c)) break :blk i;
        }
        break :blk name.len;
    };
    const last = blk: {
        var i = name.len;
        while (i > 0) {
            i -= 1;
            if (isUnsafeFilterByte(name[i])) break :blk i;
        }
        break :blk 0;
    };
    const head = std.mem.trim(u8, name[0..first], " \t");
    const tail = std.mem.trim(u8, name[last + 1 ..], " \t");

    // Both sides empty means the whole name is unsafe bytes — almost
    // certainly a machine-generated name.
    if (head.len == 0 and tail.len == 0) {
        fatalConfig(
            "test name has no substring free of \" ' \\ or control bytes, so it " ++
                "cannot be turned into a --test-filter and would silently stop " ++
                "running under the sharded `test` step. Rename the test.\n" ++
                "  offending name: {s}",
            .{name},
        );
    }
    return .{ .whole = null, .head = head, .tail = tail };
}

/// Choose between a test's candidate filters by picking the one that is a
/// substring of the FEWEST other test names. This is not cosmetic.
fn pickLeastOverlappingFilter(
    candidates: TestFilterCandidates,
    all_names: []const []const u8,
    index: *const PairIndex,
) []const u8 {
    if (candidates.whole) |whole| return whole;

    const head_hits = countNamesContaining(all_names, candidates.head, index);
    const tail_hits = countNamesContaining(all_names, candidates.tail, index);
    // Ties go to the longer filter: a longer substring matches fewer names in
    // practice, and if it does not help it cannot hurt either.
    if (head_hits < tail_hits) return candidates.head;
    if (tail_hits < head_hits) return candidates.tail;
    return if (candidates.head.len >= candidates.tail.len) candidates.head else candidates.tail;
}

/// Decode the body of a Zig string literal (without the quotes) into `out`.
fn decodeZigStringBody(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: []const u8,
) !void {
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c != '\\' or i + 1 >= body.len) {
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        i += 1;
        const esc = body[i];
        i += 1;
        switch (esc) {
            'n' => try out.append(alloc, '\n'),
            'r' => try out.append(alloc, '\r'),
            't' => try out.append(alloc, '\t'),
            '\\' => try out.append(alloc, '\\'),
            '"' => try out.append(alloc, '"'),
            '\'' => try out.append(alloc, '\''),
            'x' => {
                const n = std.fmt.parseUnsigned(u16, body[i..][0..2], 16) catch {
                    try out.append(alloc, esc);
                    continue;
                };
                try out.append(alloc, @intCast(n & 0x7f));
                i += 2;
            },
            'u' => {
                const close = std.mem.indexOfScalar(u8, body[i..], '}') orelse {
                    try out.append(alloc, esc);
                    continue;
                };
                const cp = std.fmt.parseUnsigned(u21, body[i..][0..close], 16) catch {
                    try out.append(alloc, esc);
                    continue;
                };
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(cp & 0x10ffff), &buf) catch {
                    try out.append(alloc, esc);
                    continue;
                };
                try out.appendSlice(alloc, buf[0..n]);
                i += close + 1;
            },
            else => try out.append(alloc, esc),
        }
    }
}

/// Collect one test name from the text starting at the `test` keyword's
/// argument. Handles both `test "name" {` and `test ident {`.
fn parseTestName(
    alloc: std.mem.Allocator,
    arg: []const u8,
) !?[]const u8 {
    const trimmed = std.mem.trimStart(u8, arg, " \t");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '{') return null;
    if (trimmed[0] == '(') return null;
    if (trimmed[0] == '"') {
        // Scan to the closing quote, honouring `\` escapes.
        var i: usize = 1;
        while (i < trimmed.len) : (i += 1) {
            if (trimmed[i] == '\\') {
                i += 1;
                continue;
            }
            if (trimmed[i] == '"') break;
        }
        if (i >= trimmed.len) return null; // unterminated — not a test name
        var name: std.ArrayList(u8) = .empty;
        defer name.deinit(alloc);
        try decodeZigStringBody(alloc, &name, trimmed[1..i]);
        return try alloc.dupe(u8, name.items);
    }
    if (std.ascii.isAlphabetic(trimmed[0]) or trimmed[0] == '_') {
        var i: usize = 0;
        while (i < trimmed.len and (std.ascii.isAlphanumeric(trimmed[i]) or trimmed[i] == '_')) i += 1;
        if (i == 0) return null;
        return try alloc.dupe(u8, trimmed[0..i]);
    }
    return null;
}

/// Walk `src/`, collect every named `test` decl, and return the de-duplicated
/// set of filters to shard across.
fn collectTestShardEntries(b: *std.Build) []const TestShardEntry {
    const alloc = b.allocator;
    var seen: std.StringHashMap(void) = .init(alloc);
    defer seen.deinit();
    var entries: std.ArrayList(TestShardEntry) = .empty;
    errdefer entries.deinit(alloc);

    var src_dir = std.Io.Dir.cwd().openDir(
        b.graph.io,
        "src",
        .{ .iterate = true },
    ) catch |err| {
        fatalConfig("cannot open src/ to shard the test suite: {s}", .{@errorName(err)});
    };
    defer src_dir.close(b.graph.io);

    var walker = src_dir.walk(alloc) catch |err| {
        fatalConfig("cannot walk src/ to shard the test suite: {s}", .{@errorName(err)});
    };
    defer walker.deinit();

    while (walker.next(b.graph.io) catch |err| {
        fatalConfig("cannot walk src/ to shard the test suite: {s}", .{@errorName(err)});
    }) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        // `entry.dir` + `entry.basename`, not cwd + `entry.path`: the
        // walker's paths are relative to the directory it was opened on
        // (`src`), so `entry.path` alone does not resolve from cwd.
        const bytes = entry.dir.readFileAlloc(
            b.graph.io,
            entry.basename,
            alloc,
            .unlimited,
        ) catch continue; // generated / unreadable: nothing to shard from

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimStart(u8, raw_line, " \t\r");
            if (!std.mem.startsWith(u8, line, "test")) continue;
            if (line.len == 4) continue; // bare `test`
            if (!std.ascii.isWhitespace(line[4])) continue; // `testing.foo` etc.
            const name = parseTestName(alloc, line[4..]) catch continue orelse continue;
            if (name.len == 0) {
                alloc.free(name);
                continue;
            }
            if (seen.contains(name)) {
                alloc.free(name);
                continue;
            }
            // On success the hash map OWNS `name`, so it must not be freed
            // here — freeing it left a dangling key and the next `put`
            // aborted inside the map.
            seen.put(name, {}) catch {
                alloc.free(name);
                continue;
            };
            const candidates = safeTestFilter(name);
            entries.append(alloc, .{
                // Refined below, once every name is known.
                .filter = candidates.whole orelse candidates.head,
                .weight = testWeight(name),
                .name = name,
                .candidates = candidates,
            }) catch continue;
        }
    }

    const collected = entries.toOwnedSlice(alloc) catch return &.{};

    // Second pass: now that every test name is known, narrow each truncated
    // filter to the side that overlaps the fewest siblings.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    for (collected) |entry| names.append(alloc, entry.name) catch return &.{};

    var index = PairIndex.init(alloc, names.items) catch return &.{};
    defer index.deinit();

    for (collected) |*entry| {
        entry.filter = pickLeastOverlappingFilter(entry.candidates, names.items, &index);
    }

    // Guard the thing that actually goes wrong: a filter SO broad that its
    // shard runs a slice of the whole suite. The filter for a name is
    // normally the name.
    const max_filter_fanout = 64;
    var worst_fanout: usize = 0;
    for (collected) |entry| {
        const fanout = countNamesContaining(names.items, entry.filter, &index);
        worst_fanout = @max(worst_fanout, fanout);
        if (fanout <= max_filter_fanout) continue;
        fatalConfig(
            "test name {s} reduces to the --test-filter {s}, which is a substring of " ++
                "{d} other test names. That shard would re-run {d} tests it does not " ++
                "own, roughly doubling the suite. Rename the test so that no quoted " ++
                "piece of its name is this short.\n" ++
                "  (guard: max_filter_fanout = {d}; measured worst case across the " ++
                "suite is {d})",
            .{ entry.name, entry.filter, fanout - 1, fanout - 1, max_filter_fanout, worst_fanout },
        );
    }

    // Invariant, checked before anything is scheduled: a test's filter must
    // BE a substring of its own name.
    for (collected) |entry| {
        if (std.mem.indexOf(u8, entry.name, entry.filter) != null) continue;
        fatalConfig(
            "internal error: --test-filter {s} is not a substring of test name {s}, " ++
                "so that test would never run under the sharded `test` step.",
            .{ entry.filter, entry.name },
        );
    }

    return collected;
}

/// Group tests whose `--test-filter` would otherwise drag each other into two
/// shards, then longest-processing-time-first across the groups. The grouping
/// is what keeps the split safe.
fn balanceTestShards(
    b: *std.Build,
    entries: []const TestShardEntry,
    shard_count: usize,
) [][]const []const u8 {
    const alloc = b.allocator;

    const parent: []usize = alloc.alloc(usize, entries.len) catch @panic("OOM");
    defer alloc.free(parent);
    for (parent, 0..) |*slot, i| slot.* = i;

    const find = struct {
        fn f(p: []usize, start: usize) usize {
            var root = start;
            while (p[root] != root) root = p[root];
            // Path compression, so repeated finds stay near-flat.
            var walk = start;
            while (p[walk] != root) {
                const next = p[walk];
                p[walk] = root;
                walk = next;
            }
            return root;
        }
    };
    const merge = struct {
        fn f(p: []usize, a: usize, b_: usize) void {
            const ra = find.f(p, a);
            const rb = find.f(p, b_);
            if (ra == rb) return;
            // Deterministic: the lower index always wins, so two checkouts
            // produce the same grouping.
            if (ra < rb) p[rb] = ra else p[ra] = rb;
        }
    };

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    for (entries) |entry| names.append(alloc, entry.name) catch @panic("OOM");
    var index = PairIndex.init(alloc, names.items) catch @panic("OOM");
    defer index.deinit();

    // No length cap and no O(filters x names) loop: the inverted index
    // answers "which names could contain this filter" directly, and the exact
    // compare confirms.
    for (entries, 0..) |entry, i| {
        if (entry.filter.len < 2) continue;
        for (index.candidates(index.bestPair(entry.filter))) |name_index| {
            if (name_index == i) continue;
            if (entries[name_index].name.len <= entry.filter.len) continue;
            if (std.mem.indexOf(u8, entries[name_index].name, entry.filter) == null) continue;
            merge.f(parent, i, name_index);
        }
    }

    // Collapse each group into one scheduling unit carrying the sum of its
    // members' weights and all of their filters.
    var group_weight = alloc.alloc(u64, entries.len) catch @panic("OOM");
    defer alloc.free(group_weight);
    @memset(group_weight, 0);
    var group_seen = alloc.alloc(bool, entries.len) catch @panic("OOM");
    defer alloc.free(group_seen);
    @memset(group_seen, false);

    var shards: std.ArrayList(std.ArrayList([]const u8)) = .empty;
    var loads = alloc.alloc(u64, shard_count) catch @panic("OOM");
    defer alloc.free(loads);
    @memset(loads, 0);
    var shard_sizes = alloc.alloc(usize, shard_count) catch @panic("OOM");
    defer alloc.free(shard_sizes);
    @memset(shard_sizes, 0);
    for (0..shard_count) |_| shards.append(alloc, .empty) catch @panic("OOM");

    var roots: std.ArrayList(usize) = .empty;
    defer roots.deinit(alloc);
    for (entries, 0..) |entry, i| {
        group_weight[find.f(parent, i)] += entry.weight;
    }
    for (entries, 0..) |_, i| {
        const root = find.f(parent, i);
        if (group_seen[root]) continue;
        group_seen[root] = true;
        roots.append(alloc, root) catch @panic("OOM");
    }

    // Heaviest group first; the group's first filter name breaks ties so the
    // result is stable even when every weight is the default 1.
    const Ctx = struct {
        entries: []const TestShardEntry,
        group_weight: []const u64,
        fn lessThan(ctx: @This(), a: usize, b_: usize) bool {
            if (ctx.group_weight[a] != ctx.group_weight[b_]) {
                return ctx.group_weight[a] > ctx.group_weight[b_];
            }
            return std.mem.lessThan(u8, ctx.entries[a].filter, ctx.entries[b_].filter);
        }
    };
    std.mem.sort(
        usize,
        roots.items,
        Ctx{ .entries = entries, .group_weight = group_weight },
        Ctx.lessThan,
    );

    for (roots.items) |root| {
        // Lightest by predicted time; ties broken by FEWEST FILTERS so equal
        // -load shards still spread evenly. Picking the first minimum on a
        // tie hands every tie to the lowest index and skews the split.
        var lightest: usize = 0;
        for (loads, shard_sizes, 0..) |load, size, i| {
            if (load > loads[lightest]) continue;
            if (load < loads[lightest]) {
                lightest = i;
                continue;
            }
            if (size < shard_sizes[lightest]) lightest = i;
        }
        loads[lightest] += group_weight[root];
        // `&shards.items[...]`, NOT `shards.items[...]`: std.ArrayList is
        // unmanaged in Zig 0.16, so indexing yields a COPY of the struct and
        // an append through it grows a buffer nobody ever reads back.
        const shard = &shards.items[lightest];
        // Every member's filter goes into the group's shard.
        for (entries, 0..) |entry, i| {
            if (find.f(parent, i) != root) continue;
            shard.append(alloc, entry.filter) catch @panic("OOM");
            shard_sizes[lightest] += 1;
        }
    }

    const out: [][]const []const u8 = alloc.alloc([]const []const u8, shard_count) catch @panic("OOM");
    for (shards.items, out) |shard, *slot| slot.* = shard.items;
    return out;
}

fn linkVendoredLua(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFiles(.{
        .root = b.path("vendor/lua"),
        .files = &.{
            "lapi.c",     "lauxlib.c",  "lbaselib.c", "lcode.c",
            "lcorolib.c", "lctype.c",   "ldblib.c",   "ldebug.c",
            "ldo.c",      "ldump.c",    "lfunc.c",    "lgc.c",
            "linit.c",    "liolib.c",   "llex.c",     "lmathlib.c",
            "lmem.c",     "loadlib.c",  "lobject.c",  "lopcodes.c",
            "loslib.c",   "lparser.c",  "lstate.c",   "lstring.c",
            "lstrlib.c",  "ltable.c",   "ltablib.c",  "ltm.c",
            "lundump.c",  "lutf8lib.c", "lvm.c",      "lzio.c",
        },
        .flags = &.{ "-std=c99", "-O2" },
    });
}

/// Link platform-specific system libraries + include paths for a Compile step
/// based on the COMPILE'S OWN target (NOT the global default target).
fn linkPlatformDeps(
    _b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) void {
    _ = _b;
    exe.root_module.linkSystemLibrary("c", .{});
    exe.root_module.link_libc = true;
    switch (target.result.os.tag) {
        .linux => {
            // Everything database-related (sqlite3 amalgamation + openssl +
            // crypto + libpq + /usr/include + /usr/include/postgresql) is
            // handled by the `databases` package — propagated to this Compile
            exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        },
        .macos => {
            // Everything database-related (sqlite3 amalgamation) is handled
            // by the `databases` package. macOS doesn't need openssl/pq here
            // (libpq is not currently used on macOS; openssl rides along via
        },
        .windows => {
            // Everything database-related (sqlite3 amalgamation + bcrypt) is
            // handled by the `databases` package. bcrypt.dll is needed by
            // kabelweb repo src/server/security.zig (BCryptGenRandom — Zig's
        },
        else => {
            // Cross-compile to non-Linux/macOS/Windows targets. The
            // `databases` package covers everything — nothing extra to add.
        },
    }
}

/// Resolve the active macOS SDK path via `xcrun --show-sdk-path`.
fn getMacosSdkPath(b: *std.Build) []const u8 {
    const result = std.process.run(
        b.allocator,
        b.graph.io,
        .{
            .argv = &.{ "xcrun", "--show-sdk-path" },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(1024),
        },
    ) catch @panic("`xcrun --show-sdk-path` failed — is Xcode or the Command Line Tools installed? Run `xcode-select --install` or `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`.");
    return std.mem.trim(u8, result.stdout, " \n\r\t");
}

fn createPlatformExe(
    b: *std.Build,
    mod: *std.Build.Module,
    helpers_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pabrikcore", .module = mod },
                .{ .name = "helpers", .module = helpers_mod },
            },
        }),
    });
    linkPlatformDeps(b, exe, target);
    return exe;
}

/// Prepend `C:\vcpkg\installed\x64-windows\bin` to the test process's PATH so
/// the Windows DLL loader can find the runtime DLLs that the test executable
/// depends on (`libcurl.dll`, `sqlite3.dll`, `libssl-3-x64.dll`,
fn prependVcpkgBinToPath(b: *std.Build, run: *std.Build.Step.Run) void {
    if (b.graph.host.result.os.tag != .windows) return;
    const vcpkg_bin = "C:/vcpkg/installed/x64-windows/bin";
    // Only prepend if the dir actually exists — otherwise leave PATH
    // alone (so we don't accidentally shadow a real vcpkg on PATH with
    // a bogus one on a host that doesn't have vcpkg installed).
    if (!dirExists(b, vcpkg_bin)) return;
    const env_map = run.getEnvMap();
    const current = env_map.get("PATH") orelse "";
    // Windows convention: separate paths with `;`, prepend the new one.
    // If PATH is empty (rare), just use the new dir verbatim.
    const new_path = if (current.len == 0) vcpkg_bin else b.fmt("{s};{s}", .{ vcpkg_bin, current });
    env_map.put("PATH", new_path) catch @panic("OOM");
}

/// Bundle vcpkg runtime DLLs next to the exe so Explorer double-click works.
/// WHY: `databases` + `kabelweb` link the vcpkg IMPORT `.lib` files
/// (`sqlite3.lib`, `libcurl.lib`, `libssl.lib`, ...) on Windows.
fn installVcpkgDlls(b: *std.Build, parent: *std.Build.Step) void {
    if (b.graph.host.result.os.tag != .windows) return;
    const vcpkg_bin = "C:/vcpkg/installed/x64-windows/bin";
    if (!dirExists(b, vcpkg_bin)) return;
    const dlls = [_][]const u8{
        "libcurl.dll",
        "sqlite3.dll",
        "libssl-3-x64.dll",
        "libcrypto-3-x64.dll",
        "libpq.dll",
        "z.dll",
        "lz4.dll",
        "legacy.dll",
        "libecpg.dll",
        "libecpg_compat.dll",
        "libpgtypes.dll",
    };
    for (dlls) |dll| {
        const src = b.fmt("{s}/{s}", .{ vcpkg_bin, dll });
        if (!fileExists(src)) continue;
        const install = b.addInstallBinFile(.{ .cwd_relative = src }, dll);
        parent.dependOn(&install.step);
    }
}

/// Detect the Zig 0.16 aarch64-windows crash bug and abort the build early
/// with a clear, actionable message.
fn detectAarch64ZigBug(b: *std.Build) void {
    if (b.graph.host.result.os.tag != .windows) return;
    const exe = b.graph.zig_exe;
    const is_aarch64 = std.mem.indexOf(u8, exe, "aarch64") != null;
    const is_0_16 = std.mem.indexOf(u8, exe, "0.16") != null;
    if (!(is_aarch64 and is_0_16)) return;
    std.log.err(
        "FATAL: Zig 0.16 aarch64-windows binary detected:\n" ++
            "    {s}\n" ++
            "\n" ++
            "  This binary has a known crash bug in `zig build` / `zig run`\n" ++
            "  (see AGENTS.md 'Recent changes'). When it crashes mid-write, it\n" ++
            "  truncates the global ZIR cache files under %LOCALAPPDATA%\\zig\\\n" ++
            "  z\\, which surfaces on every subsequent build as:\n" ++
            "\n" ++
            "      warning(zcu): unexpected EOF reading cached ZIR for\n" ++
            "          ...zig-aarch64-windows-0.16.0\\lib\\std\\fs\\path.zig\n" ++
            "\n" ++
            "  (and similar lines for every other stdlib file it was parsing\n" ++
            "  at crash time). Clearing %LOCALAPPDATA%\\zig only papers over the\n" ++
            "  symptom — the warning reappears as soon as the next crash.\n" ++
            "\n" ++
            "  FIX: use the x86_64-windows Zig 0.16 binary instead — same Zig\n" ++
            "  version, no crash bug, runs natively on ARM64 Windows via\n" ++
            "  emulation. CI uses exactly this setup (.github/workflows/ci.yml\n" ++
            "  uses mlugg/setup-zig@v2 with the x86_64-windows-gnu variant).\n" ++
            "\n" ++
            "  Most dev boxes already have the x86_64 binary installed\n" ++
            "  alongside the WinGet aarch64 one (WinGet's zig.zig package id\n" ++
            "  ships both arches). The x86_64 dir usually lands at:\n" ++
            "    C:\\Users\\<you>\\zig_x64\\zig-x86_64-windows-0.16.0\\\n" ++
            "  or wherever you extracted it manually.\n" ++
            "\n" ++
            "  Quick test:\n" ++
            "    C:\\Users\\<you>\\zig_x64\\zig-x86_64-windows-0.16.0\\zig.exe build --list-steps\n" ++
            "  should list steps without this error.\n" ++
            "\n" ++
            "  To make it permanent, move the x86_64 install dir ahead of\n" ++
            "  the WinGet shim dir (C:\\Users\\<you>\\AppData\\Local\\Microsoft\\\n" ++
            "  WinGet\\Links) in your PATH environment variable.",
        .{exe},
    );
    std.process.exit(1);
}

pub fn build(b: *std.Build) void {
    // Hard-fail at config time if the active Zig binary is the known-bugged
    // aarch64-windows 0.16.x variant.
    detectAarch64ZigBug(b);

    // Target glibc 2.38 on Linux hosts — needed for vendored curl's
    // references to `__isoc23_*` (glibc 2.38+) and `arc4random` (glibc 2.36+
    // in weak-symbol form).
    const target = b.standardTargetOptions(.{
        .default_target = switch (b.graph.host.result.os.tag) {
            .linux => .{
                .cpu_arch = b.graph.host.result.cpu.arch,
                .os_tag = .linux,
                .abi = .gnu,
                .glibc_version = .{ .major = 2, .minor = 38, .patch = 0 },
            },
            .windows => blk: {
                // === Why default to x86_64-windows-gnu on Windows === The
                // CI's self-hosted Windows runner installs all native deps
                // (libcurl, libssl, libcrypto, libpq, sqlite3) via vcpkg
                break :blk .{
                    .cpu_arch = .x86_64,
                    .os_tag = .windows,
                    .abi = .gnu,
                };
            },
            else => .{
                .cpu_arch = b.graph.host.result.cpu.arch,
                .os_tag = b.graph.host.result.os.tag,
                .abi = b.graph.host.result.abi,
            },
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    // CLI flag: `--no-webapp-rebuild` / `-Dno-webapp-rebuild` skips the
    // webapp-rebuild + mcp-hello-world chains.
    const no_webapp_rebuild = b.option(bool, "no-webapp-rebuild", "Skip the webapp-rebuild + mcp-hello-world chains (Windows CI OOM / no-pnpm workaround)") orelse false;

    // CLI flag: `-Drequire-real-webview` turns the no-op webview stub
    // fallback (see use_real_webview below) into a hard config-time error.
    const require_real_webview = b.option(bool, "require-real-webview", "Fail the build instead of falling back to the no-op webview stub") orelse false;

    // `helpers` package (`src/helpers/`): project-wide portable sleep / time
    // / file-existence helpers.
    const helpers_dep = b.dependency("helpers", .{
        .target = target,
        .optimize = optimize,
    });
    const helpers_mod = helpers_dep.module("helpers");

    // Cross-platform Homebrew / vcpkg prefix options.

    const mod = b.addModule("pabrikcore", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "helpers", .module = helpers_mod },
        },
    });

    mod.addImport("pabrikcore", mod);

    // === Self-contained `databases` package (sqlite3 + openssl + libpq) ===
    // The package (ruangsql, github.com/ginwa123/ruangsql, pinned by URL +
    // hash in build.zig.zon) carries its own build.zig that wires sqlite3 /
    const db_used = b.option(
        []const u8,
        "db_used",
        "Comma-separated database backends to compile: 'sqlite' (default, no libpq), add 'postgres' to also compile postgres (needs libpq)",
    ) orelse "sqlite";
    const databases_dep = b.dependency("databases", .{
        .target = target,
        .optimize = optimize,
        .db_used = db_used,
    });
    const databases_mod = databases_dep.module("databases");
    mod.addImport("databases", databases_mod);

    // === `auth_core` (src/http_handlers/auth_core.zig) === The cookie, the
    // token hash and the password hash as their own module: the standalone
    // admin console links this one file instead of all of pabrik.
    const auth_core_mod = b.createModule(.{
        .root_source_file = b.path("src/http_handlers/auth_core.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "databases", .module = databases_mod },
        },
    });
    mod.addImport("auth_core", auth_core_mod);

    // === Self-contained `kabelweb` package (vendored libcurl) === Mirrors
    // the `databases` package pattern.
    const kabelweb_dep = b.dependency("kabelweb", .{
        .target = target,
        .optimize = optimize,
    });
    const kabelweb_mod = kabelweb_dep.module("kabelweb");
    mod.addImport("kabelweb", kabelweb_mod);

    // === Vendored Lua 5.4 (single-file hooks) ===
    // Compiled into `mod` for every target, so all exes (native +
    // install:* cross-compiles) embed Lua with no system dependency.
    linkVendoredLua(b, mod);

    // === kabelweb module (libcurl-backed HTTP) === Exposed as a separate
    // module so Agent2.zig (in src/modules/agent/) can `@import("kabelweb")`.
    // Same libcurl deps as the sibling build in the kabelweb repo.

    // === System-deps probe === Run the same probe as the `databases` and
    // `kabelweb` packages to decide whether to attach the vendor fetch steps.
    // The packages ALSO run their own probes (to decide their own link line).
    const dbs_uses_system = blk: {
        if (target.result.os.tag != b.graph.host.result.os.tag) break :blk false;
        // Pure-Zig header probe (no shell, no `bash` dependency).
        const sqlite_h = switch (b.graph.host.result.os.tag) {
            .linux => "/usr/include/sqlite3.h",
            .macos => pickFirstExisting(&.{
                "/opt/homebrew/opt/sqlite3/include/sqlite3.h",
                "/usr/include/sqlite3.h",
            }) orelse break :blk false,
            .windows => "C:/vcpkg/installed/x64-windows/include/sqlite3.h",
            else => break :blk false,
        };
        const libpq_h = switch (b.graph.host.result.os.tag) {
            .linux => pickFirstExisting(&.{
                "/usr/include/postgresql/libpq-fe.h",
                "/usr/include/libpq-fe.h",
            }) orelse break :blk false,
            .macos => pickFirstExisting(&.{
                "/opt/homebrew/opt/libpq/include/libpq-fe.h",
                "/usr/include/postgresql/libpq-fe.h",
                "/usr/include/libpq-fe.h",
            }) orelse break :blk false,
            .windows => "C:/vcpkg/installed/x64-windows/include/libpq-fe.h",
            else => break :blk false,
        };
        const openssl_h = switch (b.graph.host.result.os.tag) {
            .linux => "/usr/include/openssl/ssl.h",
            .macos => pickFirstExisting(&.{
                "/opt/homebrew/opt/openssl@3/include/openssl/ssl.h",
                "/opt/homebrew/opt/openssl/include/openssl/ssl.h",
                "/usr/include/openssl/ssl.h",
            }) orelse break :blk false,
            .windows => "C:/vcpkg/installed/x64-windows/include/openssl/ssl.h",
            else => break :blk false,
        };
        break :blk fileExists(sqlite_h) and fileExists(libpq_h) and fileExists(openssl_h);
    };

    // Probe host for system libcurl + openssl. Same probe layout as
    // dbs_uses_system but checks curl.h + openssl/ssl.h instead of
    // sqlite3/libpq.
    const curl_uses_system = blk: {
        if (target.result.os.tag != b.graph.host.result.os.tag) break :blk false;
        // Pure-Zig probe mirroring the dbs_uses_system helper above. No
        // shell, no bash dependency.
        const curl_h = switch (b.graph.host.result.os.tag) {
            .linux => "/usr/include/curl/curl.h",
            .macos => pickFirstExisting(&.{
                "/opt/homebrew/opt/curl/include/curl/curl.h",
                "/usr/include/curl/curl.h",
            }) orelse break :blk false,
            .windows => "C:/vcpkg/installed/x64-windows/include/curl/curl.h",
            else => break :blk false,
        };
        const openssl_h = switch (b.graph.host.result.os.tag) {
            .linux => "/usr/include/openssl/ssl.h",
            .macos => pickFirstExisting(&.{
                "/opt/homebrew/opt/openssl@3/include/openssl/ssl.h",
                "/opt/homebrew/opt/openssl/include/openssl/ssl.h",
                "/usr/include/openssl/ssl.h",
            }) orelse break :blk false,
            .windows => "C:/vcpkg/installed/x64-windows/include/openssl/ssl.h",
            else => break :blk false,
        };
        if (!fileExists(curl_h) or !fileExists(openssl_h)) break :blk false;
        // macOS extra check: libcurl.dylib present (header+lib pair).
        if (b.graph.host.result.os.tag == .macos) {
            const libcurl_dylib = pickFirstExisting(&.{
                "/opt/homebrew/opt/curl/lib/libcurl.dylib",
                "/usr/lib/libcurl.dylib",
            }) orelse break :blk false;
            _ = libcurl_dylib;
        }
        break :blk true;
    };

    std.debug.print(
        "[build.zig] system-deps probe: databases_uses_system={}, kabelweb_uses_system={}\n",
        .{ dbs_uses_system, curl_uses_system },
    );

    // === sqlite3 amalgamation: owned by the external `databases` package ===
    // The package (ruangsql, github.com/ginwa123/ruangsql) probes the host
    // for system sqlite3 + libpq + openssl and falls back to its own vendored

    // Platform-specific link libs (sqlite3/ssl/crypto on Linux, vendored
    // sqlite3.c on Windows/macOS) are added below in the
    // test/dev-exe/inline-exe setup blocks.

    const exe = b.addExecutable(.{
        .name = "pabrik",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pabrikcore", .module = mod },
                .{ .name = "helpers", .module = helpers_mod },
            },
        }),
    });

    // NOTE: there is no fetch-vendor-curl step anymore. kabelweb is an
    // external URL dependency — its own package + CI own the vendored curl
    // archive (see the kabelweb repo's scripts/build-vendor-curl.sh). pabrik

    b.installArtifact(exe);

    exe.root_module.linkSystemLibrary("c", .{});
    exe.root_module.link_libc = true;
    // Per-target platform deps (sqlite3/openssl/vendored amalgamation).
    // linkPlatformDeps handles all 4 targets in one switch — replaces the
    // old if/else chain that leaked Linux libs into cross-compile artifacts.
    linkPlatformDeps(b, exe, target);
    // libcurl is linked via kabelweb_mod's transitive deps (the vendored
    // prebuilt archive is added in the package's own build.zig).
    if (target.result.os.tag == .windows) {}
    // === mcp-hello-world: TypeScript test MCP server === Self-test target
    // for the MCP stdio transport.
    const mcp_hello_world_dir = "src/apps/mcp_hello_world";
    const mcp_hello_world_step = b.step("mcp-hello-world", "Build the mcp-hello-world test MCP server");

    // Always run `pnpm install` — pnpm's content-addressed store makes this
    // fast (~1s) when node_modules is already present. We avoid a statFile
    // check because std.fs.cwd was removed in Zig 0.16.
    const mcp_pnpm_install = b.addSystemCommand(&.{ "pnpm", "install", "--frozen-lockfile" });
    mcp_pnpm_install.setCwd(b.path(mcp_hello_world_dir));
    mcp_hello_world_step.dependOn(&mcp_pnpm_install.step);

    // TDD: run the unit tests first. If they fail, the build fails
    // before we waste time on the TS compile.
    const mcp_test = b.addSystemCommand(&.{ "pnpm", "test" });
    mcp_test.setCwd(b.path(mcp_hello_world_dir));
    mcp_test.step.dependOn(&mcp_pnpm_install.step);
    mcp_hello_world_step.dependOn(&mcp_test.step);

    const mcp_build = b.addSystemCommand(&.{ "pnpm", "run", "build" });
    mcp_build.setCwd(b.path(mcp_hello_world_dir));
    mcp_build.step.dependOn(&mcp_test.step);
    mcp_hello_world_step.dependOn(&mcp_build.step);

    // Install the shell wrapper.
    const wrapper_body =
        "#!/bin/sh\n" ++
        \\# mcp-hello-world — pabrik's MCP stdio self-test target.
        \\# Auto-generated by build.zig. Invokes the compiled TypeScript
        \\# output (dist/index.js) via node. Resolves the install path
        \\# relative to this script so the binary works from anywhere.
        \\set -e
        \\SCRIPT_DIR=$(dirname "$0")
        \\# zig-out/bin/mcp-hello-world -> zig-out/bin/. We need to reach
        \\# <repo-root>/src/apps/mcp_hello_world/dist/index.js. From
        \\# zig-out/bin, `..` is zig-out, `../..` is the repo root.
        \\exec node "$SCRIPT_DIR/../../src/apps/mcp_hello_world/dist/index.js" "$@"
        ;
    const wrapper_cache_name = "mcp-hello-world-wrapper.sh";
    const mcp_wrapper_write = b.addWriteFiles();
    const wrapper_lazy_path = mcp_wrapper_write.add(wrapper_cache_name, wrapper_body);
    mcp_wrapper_write.step.dependOn(&mcp_build.step);

    const mcp_wrapper_install = b.addInstallBinFile(
        wrapper_lazy_path,
        "mcp-hello-world",
    );
    mcp_wrapper_install.step.dependOn(&mcp_wrapper_write.step);

    // chmod 0755 on the installed path so `node dist/index.js` actually runs
    // when invoked as `zig-out/bin/mcp-hello-world`.
    if (target.result.os.tag != .windows) {
        const mcp_wrapper_chmod = b.addSystemCommand(&.{
            "chmod",
            "755",
            b.pathJoin(&.{ b.install_path, "bin", "mcp-hello-world" }),
        });
        mcp_wrapper_chmod.step.dependOn(&mcp_wrapper_install.step);
        mcp_hello_world_step.dependOn(&mcp_wrapper_chmod.step);
    } else {
        mcp_hello_world_step.dependOn(&mcp_wrapper_install.step);
    }

    // Make `zig build` (the default) include mcp-hello-world so
    // functional tests can rely on it being present. Skipped when
    // -Dno-webapp-rebuild (Windows CI: pnpm FileNotFound + OOM).
    if (!no_webapp_rebuild) {
        b.getInstallStep().dependOn(mcp_hello_world_step);
    }

    // === mcp-http-hello-world: TypeScript test MCP server (Streamable HTTP)
    // === Sibling of mcp-hello-world: same 3 tools, different transport.
    // Self-test target for the pabrik MCP Streamable HTTP client.
    const mcp_http_hello_world_dir = "src/apps/mcp_http_hello_world";
    const mcp_http_hello_world_step = b.step("mcp-http-hello-world", "Build the mcp-http-hello-world Streamable HTTP test MCP server");

    const mcp_http_npm_install = b.addSystemCommand(&.{ "pnpm", "install", "--no-frozen-lockfile" });
    mcp_http_npm_install.setCwd(b.path(mcp_http_hello_world_dir));
    mcp_http_hello_world_step.dependOn(&mcp_http_npm_install.step);

    // Build first (tsc → dist/index.js), THEN run the tests.
    const mcp_http_build = b.addSystemCommand(&.{ "pnpm", "run", "build" });
    mcp_http_build.setCwd(b.path(mcp_http_hello_world_dir));
    mcp_http_build.step.dependOn(&mcp_http_npm_install.step);
    mcp_http_hello_world_step.dependOn(&mcp_http_build.step);

    // Now run the unit tests — the build output (dist/index.js) is in place.
    const mcp_http_test = b.addSystemCommand(&.{ "pnpm", "test" });
    mcp_http_test.setCwd(b.path(mcp_http_hello_world_dir));
    mcp_http_test.step.dependOn(&mcp_http_build.step);
    mcp_http_hello_world_step.dependOn(&mcp_http_test.step);

    // Install the shell wrapper. Mirrors the mcp-hello-world pattern:
    // write the wrapper to .zig-cache, install it to bin/, chmod 0755.
    const http_wrapper_body =
        "#!/bin/sh\n" ++
        \\# mcp-http-hello-world — pabrik's MCP Streamable HTTP self-test target.
        \\# Auto-generated by build.zig. Invokes the compiled TypeScript
        \\# output (dist/index.js) via node. Resolves the install path
        \\# relative to this script so the binary works from anywhere.
        \\# Usage: mcp-http-hello-world <port>  (port is a CLI positional arg,
        \\# default 3000 if omitted).
        \\set -e
        \\SCRIPT_DIR=$(dirname "$0")
        \\# zig-out/bin/mcp-http-hello-world -> zig-out/bin/. We need to
        \\# reach <repo-root>/src/apps/mcp_http_hello_world/dist/index.js.
        \\exec node "$SCRIPT_DIR/../../src/apps/mcp_http_hello_world/dist/index.js" "$@"
        ;
    const http_wrapper_cache_name = "mcp-http-hello-world-wrapper.sh";
    const mcp_http_wrapper_write = b.addWriteFiles();
    const http_wrapper_lazy_path = mcp_http_wrapper_write.add(http_wrapper_cache_name, http_wrapper_body);
    mcp_http_wrapper_write.step.dependOn(&mcp_http_build.step);

    const mcp_http_wrapper_install = b.addInstallBinFile(
        http_wrapper_lazy_path,
        "mcp-http-hello-world",
    );
    mcp_http_wrapper_install.step.dependOn(&mcp_http_wrapper_write.step);

    // chmod 0755 on the installed path.
    if (target.result.os.tag != .windows) {
        const mcp_http_wrapper_chmod = b.addSystemCommand(&.{
            "chmod",
            "755",
            b.pathJoin(&.{ b.install_path, "bin", "mcp-http-hello-world" }),
        });
        mcp_http_wrapper_chmod.step.dependOn(&mcp_http_wrapper_install.step);
        mcp_http_hello_world_step.dependOn(&mcp_http_wrapper_chmod.step);
    } else {
        mcp_http_hello_world_step.dependOn(&mcp_http_wrapper_install.step);
    }

    // Don't include mcp-http-hello-world in the default `zig build` — it's
    // not needed by the desktop binary. Users invoke it explicitly via `zig
    // build mcp-http-hello-world`.

    // === Build the Vue webapp (pnpm) === Chunk 3: this step is a dependency
    // of the desktop_exe build so the embedded webapp_assets.zig is
    // regenerated on every build.
    const build_webapp_step = b.step("build:webapp", "Build the Vue webapp with pnpm");

    const webapp_dir = "src/apps/desktop";

    // === Pre-flight: vue-tsc needs real Node, and pnpm must be on PATH ===
    // `pnpm run build` invokes `vue-tsc --build` (via the type-check script)
    // + `vite build` in parallel. vue-tsc 3.x relies on @volar/typescript
    const check_webapp_node = b.addSystemCommand(switch (b.graph.host.result.os.tag) {
        // Windows: `sh` isn't on PATH (Git for Windows ships it under
        // C:\Program Files\Git\bin\, not auto-added).
        .windows => &.{
            "cmd.exe", "/c",
            \\
            \\@echo off
            \\for %%t in (node pnpm) do (
            \\    where %%t >nul 2>&1 || (
            \\        echo.
            \\        echo ERROR: '%%t' was not found on PATH.
            \\        echo   vue-tsc (which runs inside 'pnpm run build' via the type-check
            \\        echo   script) patches tsc's source via fs.readFileSync to register
            \\        echo   .vue as a TypeScript source extension; a JS-runtime shim whose
            \\        echo   loader bypasses fs.readFileSync breaks that patching and
            \\        echo   fails with hundreds of TS2307 errors.
            \\        echo   pnpm is the project's package manager (replaced npm on
            \\        echo   2026-08-28) — see the workspace .npmrc + build.zig.
            \\        echo.
            \\        echo   Install Node.js + pnpm for Windows:
            \\        echo     winget install OpenJS.NodeJS.LTS
            \\        echo     OR nvm-windows / Chocolatey / the official msi.
            \\        echo.
            \\        exit /b 1
            \\    )
            \\)
        },
        // Linux + macOS: POSIX `command -v` loop. Same error message as
        // the original pre-Windows-fix check.
        else => &.{
            "sh", "-c",
            \\
            \\for tool in node pnpm; do
            \\    command -v "$tool" >/dev/null 2>&1 || {
            \\        echo "" >&2
            \\        echo "ERROR: '$tool' was not found on PATH." >&2
            \\        echo "  vue-tsc (which runs inside 'pnpm run build' via the type-check" >&2
            \\        echo "  script) patches tsc's source via fs.readFileSync to register" >&2
            \\        echo "  .vue as a TypeScript source extension; a JS-runtime shim whose" >&2
            \\        echo "  loader bypasses fs.readFileSync breaks that patching and" >&2
            \\        echo "  fails with hundreds of TS2307 errors." >&2
            \\        echo "  pnpm is the project's package manager (replaced npm on" >&2
            \\        echo "  2026-08-28) — see the workspace .npmrc + build.zig." >&2
            \\        echo "" >&2
            \\        echo "  Install nodejs + pnpm for your platform:" >&2
            \\        echo "    Arch Linux:   sudo pacman -S --needed nodejs pnpm" >&2
            \\        echo "    Debian/Ubnt:  sudo apt install nodejs && corepack enable && corepack prepare pnpm@latest --activate" >&2
            \\        echo "    macOS:        brew install node pnpm" >&2
            \\        echo "    Alpine:       apk add nodejs pnpm" >&2
            \\        echo "" >&2
            \\        exit 1
            \\    }
            \\done
        },
    });

    // Check if node_modules exists — if so, skip `pnpm install` (saves
    // seconds per build).
    const node_modules_path = b.pathJoin(&.{ webapp_dir, "node_modules" });
    const node_modules_exists = switch (builtin.os.tag) {
        .linux => blk: {
            var buf: [std.fs.max_path_bytes:0]u8 = undefined;
            if (node_modules_path.len >= buf.len) break :blk false;
            @memcpy(buf[0..node_modules_path.len], node_modules_path);
            buf[node_modules_path.len] = 0;
            const rc = std.os.linux.faccessat(std.os.linux.AT.FDCWD, &buf, 0, 0);
            break :blk rc == 0;
        },
        else => false, // On non-Linux, always run `pnpm install` (safe no-op)
    };

    if (!node_modules_exists) {
        const install_cmd = b.addSystemCommand(&.{ "pnpm", "install", "--frozen-lockfile" });
        install_cmd.setCwd(b.path(webapp_dir));
        build_webapp_step.dependOn(&install_cmd.step);
    }

    // Hoisted so the webapp-rebuild path can also depend on it (fresh
    // checkout → `zig build pabrik-desktop` needs node_modules too).
    const rebuild_install_cmd = b.addSystemCommand(&.{ "pnpm", "install", "--frozen-lockfile" });
    rebuild_install_cmd.setCwd(b.path(webapp_dir));
    if (node_modules_exists) {
        // Mirror the cached path's skip: node_modules already present,
        // so the install would be a wasted 1-2 s. Keep the step in the
        // graph but never reached — nothing depends on it.
        _ = &rebuild_install_cmd;
    }

    const pnpm_build = b.addSystemCommand(&.{ "pnpm", "run", "build" });
    pnpm_build.setCwd(b.path(webapp_dir));
    pnpm_build.step.dependOn(&check_webapp_node.step);
    build_webapp_step.dependOn(&pnpm_build.step);

    // === Webapp rebuild workflow === `b.addSystemCommand` caches based on
    // (command string, cwd, watch inputs) only — it does NOT watch webapp
    // source files.
    const webapp_rebuild_step = b.step(
        "webapp-rebuild",
        "Nuke stale webapp_assets.zig + dist/ and rebuild via pnpm run build + codegen",
    );

    // Clean step — a small Zig CLI instead of `sh -c 'rm -rf ...'` so it
    // works with native Windows shells too (no Git Bash dependency).
    const webapp_rebuild_clean = b.addRunArtifact(b.addExecutable(.{
        .name = "clean_webapp_cache",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/clean_webapp_cache.zig"),
            // Same cross-compile rationale as codegen_webapp_assets below:
            // avoid the Zig 0.16 + GCC 16 host-native link failure by using
            // the main target's glibc (no .sframe section in its crt1.o).
            .target = target,
            .link_libc = true,
        }),
    }));

    // Separate pnpm_build step for the rebuild path. Has the SAME
    // command + cwd as the cached one, but chained AFTER the clean
    // step, so the cache can't serve a stale result.
    const webapp_rebuild_pnpm = b.addSystemCommand(&.{ "pnpm", "run", "build" });
    webapp_rebuild_pnpm.setCwd(b.path(webapp_dir));
    webapp_rebuild_pnpm.step.dependOn(&webapp_rebuild_clean.step);
    webapp_rebuild_pnpm.step.dependOn(&check_webapp_node.step);
    // Fresh-checkout fix: the cached path gets a conditional `pnpm install`
    // via the node_modules_exists probe above, but that only attaches to
    // build_webapp_step.
    if (!node_modules_exists) {
        webapp_rebuild_pnpm.step.dependOn(&rebuild_install_cmd.step);
    }
    webapp_rebuild_step.dependOn(&webapp_rebuild_pnpm.step);

    // The codegen step is shared with the cached path — its output
    // (webapp_assets.zig) was just deleted by the clean step, so it'll re-run
    // to regenerate.
    const webapp_rebuild_codegen = b.addRunArtifact(b.addExecutable(.{
        .name = "codegen_webapp_assets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/codegen_webapp_assets.zig"),
            // Cross-compile for the same target as the main binary (NOT
            // b.graph.host) to avoid the Zig 0.16 + GCC 16 host-native link
            // failure: GCC 16's crt1.o has a `.sframe` section with
            .target = target,
            .link_libc = true,
        }),
    }));
    webapp_rebuild_codegen.addArg(b.pathJoin(&.{ webapp_dir, "dist" }));
    webapp_rebuild_codegen.addArg(b.pathJoin(&.{ "src", "apps", "desktop_app", "embedded", "webapp_assets.zig" }));
    webapp_rebuild_codegen.step.dependOn(&webapp_rebuild_pnpm.step);
    webapp_rebuild_step.dependOn(&webapp_rebuild_codegen.step);

    // === Codegen: walk dist/, emit webapp_assets.zig === Chunk 3: this step
    // runs the small Zig tool at tools/codegen_webapp_assets.zig to walk
    // src/apps/desktop/dist/ and emit a Zig source file with every asset's
    const codegen_step = b.step("codegen:webapp-assets", "Generate webapp_assets.zig from the built dist/");
    codegen_step.dependOn(build_webapp_step);

    const codegen = b.addRunArtifact(b.addExecutable(.{
        .name = "codegen_webapp_assets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/codegen_webapp_assets.zig"),
            // Cross-compile for the same target as the main binary (NOT
            // b.graph.host) to avoid the Zig 0.16 + GCC 16 host-native link
            // failure (see the webapp_rebuild_codegen step above for the full
            .target = target,
            .link_libc = true,
        }),
    }));
    codegen.addArg(b.pathJoin(&.{ webapp_dir, "dist" }));
    codegen.addArg(b.pathJoin(&.{ "src", "apps", "desktop_app", "embedded", "webapp_assets.zig" }));
    codegen_step.dependOn(&codegen.step);

    // === pabrik-desktop (native webview wrapper) === Chunk 1: hello-world
    // binary + build wiring.
    const desktop_exe = b.addExecutable(.{
        .name = "pabrik-desktop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/desktop_app/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "pabrikcore", .module = mod },
                .{ .name = "helpers", .module = helpers_mod },
            },
        }),
    });
    desktop_exe.root_module.linkSystemLibrary("c", .{});

    // Windows application icon: the brand "P" mark (packaging/icons, same
    // artwork as the web favicon.ico).
    desktop_exe.root_module.addWin32ResourceFile(.{
        .file = b.path("packaging/windows/pabrik.rc"),
        .include_paths = &.{b.path("packaging/icons")},
    });

    // Set by the `.windows` prong below when the real WebView2 build is
    // taken: install step copying WebView2Loader.dll next to the exe.
    var webview2_dll_install_step: ?*std.Build.Step = null;
    // Platform-specific system libraries (Chunks 5-7 add the real deps).
    // Switch kept here so the pattern is validated by the Chunk 1 build.
    switch (target.result.os.tag) {
        .linux => {
            // Linux webview: vendored webview/webview library
            // (vendor/webview/webview.{h,cc}, upstream 0.12.0). webview.cc is
            // a one-line TU that includes webview.h with
            desktop_exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
            desktop_exe.root_module.linkSystemLibrary("webkit2gtk-4.1", .{});
            desktop_exe.root_module.linkSystemLibrary("gtk-3", .{});
            desktop_exe.root_module.linkSystemLibrary("soup-3.0", .{});
            desktop_exe.root_module.linkSystemLibrary("glib-2.0", .{});
            desktop_exe.root_module.linkSystemLibrary("javascriptcoregtk-4.1", .{});
            // C++ runtime for webview.o (operator new, __cxa_begin_catch,
            // ...). link_libcpp pulls in zig's bundled libc++/libc++abi.
            desktop_exe.root_module.link_libcpp = true;

            // Resolve system libstdc++ include dir once.
            const libstdc_dir = findLibstdcxxInclude(b);

            // Build the cflags array. -nostdlibinc is always on (we
            // explicitly choose the stdlib below).
            var cflags: [32][]const u8 = undefined;
            var cn: usize = 0;
            cflags[cn] = "-std=c++11";
            cn += 1;
            cflags[cn] = "-DWEBVIEW_STATIC";
            cn += 1;
            cflags[cn] = "-DWEBVIEW_GTK";
            cn += 1;
            cflags[cn] = "-Ivendor/webview";
            cn += 1;
            cflags[cn] = "-nostdlibinc";
            cn += 1;
            // System C headers MUST come via -isystem (not -I) so they sort
            // AFTER the C++ stdlib headers — with plain -I/usr/include,
            // clang's <cerrno> wrapper finds glibc's errno.h first and errors
            const isystem_c_args = [_][]const u8{
                "-isystem/usr/include",
                // Full pkg-config cflags for webkit2gtk-4.1 (zig c++ is
                // stricter about transitive includes than the system cc was
                // for the old C shim — e.g. pango's pango-coverage.h includes
                "-isystem/usr/include/webkitgtk-4.1",
                "-isystem/usr/include/gtk-3.0",
                "-isystem/usr/include/pango-1.0",
                "-isystem/usr/include/cloudproviders",
                "-isystem/usr/include/cairo",
                "-isystem/usr/include/gdk-pixbuf-2.0",
                "-isystem/usr/include/at-spi2-atk/2.0",
                "-isystem/usr/include/at-spi-2.0",
                "-isystem/usr/include/atk-1.0",
                "-isystem/usr/include/dbus-1.0",
                "-isystem/usr/lib/dbus-1.0/include",
                "-isystem/usr/include/fribidi",
                "-isystem/usr/include/pixman-1",
                "-isystem/usr/include/harfbuzz",
                "-isystem/usr/include/freetype2",
                "-isystem/usr/include/libpng16",
                "-isystem/usr/include/gio-unix-2.0",
                "-isystem/usr/include/libsoup-3.0",
                "-isystem/usr/include/glib-2.0",
                "-isystem/usr/lib/glib-2.0/include",
            };
            for (isystem_c_args) |a| {
                if (cn >= cflags.len) break;
                cflags[cn] = a;
                cn += 1;
            }
            // Debian/Ubuntu keep the glibc headers in a multiarch subdir and
            // ship NO /usr/include/bits symlink, so with only /usr/include on
            // the path the system headers' own `#include <bits/types.h>`
            const multiarch_include = b.fmt("/usr/include/{s}-linux-gnu", .{@tagName(target.result.cpu.arch)});
            if (dirExists(b, multiarch_include)) {
                if (cn < cflags.len) {
                    cflags[cn] = b.fmt("-isystem{s}", .{multiarch_include});
                    cn += 1;
                }
            }
            if (libstdc_dir) |cxx| {
                // System libstdc++: pin to the highest-version c++ directory
                // + its target-specific c++config.h.
                if (cn < cflags.len) {
                    cflags[cn] = b.fmt("-isystem{s}", .{cxx});
                    cn += 1;
                }
                if (cn < cflags.len) {
                    cflags[cn] = b.fmt("-isystem{s}/x86_64-pc-linux-gnu", .{cxx});
                    cn += 1;
                }
                if (cn < cflags.len) {
                    cflags[cn] = b.fmt("-isystem{s}/backward", .{cxx});
                    cn += 1;
                }
            } else {
                std.log.warn(
                    "pabrik-desktop: no /usr/include/c++/* found — falling back to zig's bundled libc++. " ++
                        "Expect <wint_t>/<errno>/<FP_NAN> typedef conflicts on hosts with a glibc <math.h>. " ++
                        "Install gcc-libs to silence this.",
                    .{},
                );
            }
            desktop_exe.root_module.addCSourceFile(.{
                .file = b.path("vendor/webview/webview.cc"),
                .flags = cflags[0..cn],
            });
        },
        .macos => {
            // macOS webview: vendored webview/webview library (same as the
            // Linux branch above). webview.h auto-selects its Cocoa/WKWebView
            // backend on __APPLE__ — no WEBVIEW_COCOA define needed.
            const sdk_path = getMacosSdkPath(b);
            desktop_exe.root_module.addSystemFrameworkPath(.{
                .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk_path}),
            });
            desktop_exe.root_module.addSystemIncludePath(.{
                .cwd_relative = b.fmt("{s}/usr/include", .{sdk_path}),
            });
            desktop_exe.root_module.addLibraryPath(.{
                .cwd_relative = b.fmt("{s}/usr/lib", .{sdk_path}),
            });

            desktop_exe.root_module.addCSourceFile(.{
                .file = b.path("vendor/webview/webview.cc"),
                .flags = &.{
                    "-std=c++11",
                    "-DWEBVIEW_STATIC",
                    "-Ivendor/webview",
                },
            });
            // C++ runtime for webview.o (operator new, __cxa_begin_catch,
            // ...). On macOS the SDK's libc++ is used via the SDK lib
            // path added above.
            desktop_exe.root_module.link_libcpp = true;
            desktop_exe.root_module.linkFramework("Cocoa", .{});
            desktop_exe.root_module.linkFramework("WebKit", .{});
            // AppKit: linked explicitly so `otool -L` shows AppKit.framework
            // (the vendored webview/webview library fetches NSApplication /
            // NSWindow via runtime objc_getClass + dlopen, so without this
            desktop_exe.root_module.linkFramework("AppKit", .{});
        },
        .windows => {
            // Windows webview: vendored webview/webview library (same as the
            // Linux + macOS branches above). webview.h auto-selects its
            // WebView2 backend on _WIN32 — no WEBVIEW_EDGE define needed.
            const use_real_webview = blk: {
                // NOTE: -Dno-webapp-rebuild does NOT force the stub — it only
                // skips the vite/pnpm chain (the OOM source). The cl.exe
                // single-TU compile below is cheap.
                if (!hasMsvcCppStllib(b, b.graph.io)) break :blk false;
                // cl.exe path + MSVC lib dir below need the resolved
                // version root (hasMsvc alone doesn't bind it, e.g.
                // INCLUDE-env-only setups with custom install paths).
                if (msvcVersionRoot(b) == null) break :blk false;
                if (webview2MissingPrereq(b)) |missing| {
                    std.log.warn(
                        "pabrik-desktop: MSVC C++ toolchain found, but WebView2 prerequisite {s} is missing under " ++
                            "src/apps/desktop_app/platform/windows/ — using the no-op webview stub instead. " ++
                            "Extract build/native/include/* + runtimes/win-x64/native/WebView2Loader.dll from the " ++
                            "Microsoft.Web.WebView2 NuGet package there to enable the real webview.",
                        .{missing},
                    );
                    break :blk false;
                }
                break :blk true;
            };
            if (require_real_webview and !use_real_webview) {
                std.log.err(
                    "pabrik-desktop: -Drequire-real-webview is set but the real webview/webview build is unavailable on this host " ++
                        "(missing MSVC C++ toolchain or WebView2 NuGet staging under src/apps/desktop_app/platform/windows/) — " ++
                        "refusing to build the no-op stub whose webview_create() always returns NULL. See the warnings above for the missing piece.",
                    .{},
                );
                std.process.exit(1);
            }
            if (use_real_webview) {
                // Compile vendor/webview/webview.cc with the REAL cl.exe
                // (MSVC), not `zig cc`.
                const ver_root = msvcVersionRoot(b) orelse unreachable; // gate above guarantees this
                const cl_exe = b.fmt("{s}/bin/Hostx64/x64/cl.exe", .{ver_root});
                const cpp_src = "vendor/webview/webview.cc";
                const msvc_include = findMsvcInclude(b);
                // Skip dirs that failed to resolve (same rationale as
                // before: a bare `/I ""` is a confusing no-op).
                const candidate_dirs = [_][]const u8{
                    msvc_include.c_stddef,
                    msvc_include.msvc_include,
                    msvc_include.ucrt_include,
                    msvc_include.um_include,
                    msvc_include.shared_include,
                    msvc_include.winrt_include,
                };
                var cpp_args: [32][]const u8 = undefined;
                var n: usize = 0;
                cpp_args[n] = cl_exe;
                n += 1;
                cpp_args[n] = "/nologo";
                n += 1;
                cpp_args[n] = "/c";
                n += 1;
                cpp_args[n] = "/std:c++17";
                n += 1;
                cpp_args[n] = "/EHsc";
                n += 1;
                cpp_args[n] = "/MD";
                n += 1;
                cpp_args[n] = "/Z7";
                n += 1;
                // No Control Flow Guard in this TU (`/guard:cf-`; cl.exe
                // enables it by default since VS2022).
                cpp_args[n] = "/guard:cf-";
                n += 1;
                cpp_args[n] = "/DWEBVIEW_STATIC";
                n += 1;
                cpp_args[n] = "/Ivendor/webview";
                n += 1;
                // WebView2.h + EventToken.h (NuGet-staged). webview.h pulls
                // `"WebView2.h"` as a quoted include.
                cpp_args[n] = "/Isrc/apps/desktop_app/platform/windows";
                n += 1;
                for (candidate_dirs) |dir| {
                    if (dir.len == 0) continue;
                    cpp_args[n] = "/I";
                    n += 1;
                    cpp_args[n] = dir;
                    n += 1;
                }
                // NOTE: cl.exe only accepts the GLUED form (`/Fopath`, no
                // space — the separate form warns D9027 `source file ignored`
                // and emits nothing where addOutputFileArg expects it).
                cpp_args[n] = "/Fovendor/webview/webview.obj";
                n += 1;
                cpp_args[n] = cpp_src;
                n += 1;
                const cpp_compile = b.addSystemCommand(cpp_args[0..n]);
                cpp_compile.setCwd(b.path(""));
                desktop_exe.step.dependOn(&cpp_compile.step);
                desktop_exe.root_module.addObjectFile(.{ .cwd_relative = "vendor/webview/webview.obj" });
                // Win32 / COM / WebView2 link deps (same as the old shim used).
                desktop_exe.root_module.linkSystemLibrary("ole32", .{});
                desktop_exe.root_module.linkSystemLibrary("user32", .{});
                // Zig's MinGW (gnu) link line doesn't auto-pull kernel32.dll
                // / ws2_32.dll for raw `extern "kernel32"` / `extern
                // "ws2_32"` decls in Zig code.
                desktop_exe.root_module.linkSystemLibrary("kernel32", .{});
                desktop_exe.root_module.linkSystemLibrary("ws2_32", .{});
                // WebView2Loader.lib lives next to pabrik_webview.cpp in the
                // old layout; webview.h includes <WebView2.h> from
                // src/apps/desktop_app/platform/windows/ (NuGet-staged
                desktop_exe.root_module.addIncludePath(.{
                    .cwd_relative = "src/apps/desktop_app/platform/windows",
                });
                desktop_exe.root_module.addLibraryPath(.{
                    .cwd_relative = "src/apps/desktop_app/platform/windows",
                });
                // WebView2Loader.lib back in place: the bisection proved it
                // innocent (same 2 duplicates without it — the CFG-table
                // references come from msvcprt.lib's own members).
                desktop_exe.root_module.linkSystemLibrary("WebView2Loader", .{}); // Link deps for the real webview object. `#pragma
                // comment(lib, ...)` directives embedded in the TU (MSVC
                // headers auto-link the C++ runtime; webview.h links ole32 /
                // shell32 / shlwapi / version / advapi32 / user32) name libs
                {
                    const runtime_libs = [_][]const u8{ "msvcprt.lib", "vcruntime.lib", "oldnames.lib" };
                    const msvc_lib_root = b.fmt("{s}/lib/x64", .{ver_root});
                    const stage_dir = "src/apps/desktop_app/platform/windows";
                    for (runtime_libs) |lib_name| {
                        const src_path = b.fmt("{s}/{s}", .{ msvc_lib_root, lib_name });
                        const dst_path = b.fmt("{s}/{s}", .{ stage_dir, lib_name });
                        if (staleOrMissing(b, src_path, dst_path)) {
                            const bytes = std.Io.Dir.cwd().readFileAlloc(
                                b.graph.io,
                                src_path,
                                b.allocator,
                                .unlimited,
                            ) catch break;
                            defer b.allocator.free(bytes);
                            std.Io.Dir.cwd().writeFile(
                                b.graph.io,
                                .{ .sub_path = dst_path, .data = bytes },
                            ) catch break;
                        }
                    }
                    // `msvcrt.lib`: PRUNE the CFG-table + TLS startup members
                    // that collide with mingw's (`duplicate symbol` with a
                    // full copy).
                    stagePrunedMsvcrt(b, msvc_lib_root, stage_dir);
                }
                // The exact libs `-luuid -lshlwapi -lversion` below need.
                // Probing the FILES (not just the `um/x64` dir) is what skips
                // the `wdf0.26100.0` decoy, whose um/x64 exists but is empty.
                const kit_lib_root = newestSubdirWith(
                    b,
                    "C:/Program Files (x86)/Windows Kits/10/Lib",
                    &.{ "um/x64/uuid.lib", "um/x64/shlwapi.lib", "um/x64/version.lib" },
                ) orelse newestSubdirWith(
                    b,
                    "C:/Program Files/Windows Kits/10/Lib",
                    &.{ "um/x64/uuid.lib", "um/x64/shlwapi.lib", "um/x64/version.lib" },
                );
                if (kit_lib_root) |kl| {
                    desktop_exe.root_module.addLibraryPath(.{
                        .cwd_relative = b.fmt("{s}/um/x64", .{kl}),
                    });
                    // ucrt.lib lives in its own leaf (Lib/<ver>/ucrt/x64),
                    // NOT under um/ — without this dir the link fails with
                    // `unable to find dynamic system library 'ucrt'`.
                    desktop_exe.root_module.addLibraryPath(.{
                        .cwd_relative = b.fmt("{s}/ucrt/x64", .{kl}),
                    });
                }
                desktop_exe.root_module.linkSystemLibrary("msvcprt", .{});
                desktop_exe.root_module.linkSystemLibrary("uuid", .{});
                desktop_exe.root_module.linkSystemLibrary("shlwapi", .{});
                desktop_exe.root_module.linkSystemLibrary("version", .{});
                // vcruntime: sole provider of `__CxxFrameHandler4` +
                // `__security_cookie` for the cl.exe object. DLL import —
                // no static-CRT heap risk.
                desktop_exe.root_module.linkSystemLibrary("vcruntime", .{});
                // Guard-table stubs (5 CFG/XFG symbols nothing else defines
                // — see guard_tables_stub.c). Plain C, no includes: compiles
                // through the normal Zig CC path, no MSVC involvement.
                desktop_exe.root_module.addCSourceFile(.{
                    .file = b.path("src/apps/desktop_app/platform/windows/guard_tables_stub.c"),
                    .flags = &.{},
                }); // The import lib only records the dependency — at RUNTIME the
                // Windows loader resolves WebView2Loader.dll via the standard
                // search order (exe dir first).
                const wv2_dll_install = b.addInstallBinFile(
                    b.path("src/apps/desktop_app/platform/windows/WebView2Loader.dll"),
                    "WebView2Loader.dll",
                );
                webview2_dll_install_step = &wv2_dll_install.step;
            } else {
                // === Dev-box fallback: no MSVC + WebView2 === The
                // webview/webview library hard-requires MSVC's C++ STL
                // (webview.h's win32 path includes <wrl/client.h> which
                std.log.warn(
                    "pabrik-desktop: MSVC C++ toolchain and/or Microsoft.Web.WebView2 " ++
                        "NuGet headers not found on this host — using no-op stub " ++
                        "(pabrik-desktop will build but cannot open a webview window). " ++
                        "Install Visual Studio Build Tools + extract the " ++
                        "Microsoft.Web.WebView2 NuGet to get a real webview.",
                    .{},
                );
                desktop_exe.root_module.addCSourceFile(.{
                    .file = b.path("src/apps/desktop_app/platform/windows/webview_stub.c"),
                    .flags = &.{},
                });
                // Win32 / WinSock2 deps for Zig's std extern decls
                // (extraction.zig / subprocess.zig).
                desktop_exe.root_module.linkSystemLibrary("kernel32", .{});
                desktop_exe.root_module.linkSystemLibrary("ws2_32", .{});
            }
        },
        else => {},
    }

    // Capture the InstallArtifact so `build:all` can dependOn its inner step
    // (see the build banner section at the end of this file for why).
    const desktop_install = b.addInstallArtifact(desktop_exe, .{});
    // Real-WebView2 Windows builds need WebView2Loader.dll beside the
    // exe at runtime (see the `.windows` prong above). DependOn pulls
    // the dll install into `build:all` via desktop_install's edge.
    if (webview2_dll_install_step) |dll_step| desktop_install.step.dependOn(dll_step);
    // Windows: bundle vcpkg runtime DLLs (libcurl.dll, sqlite3.dll, ...)
    // next to pabrik-desktop.exe AND the pabrik service exe so Explorer
    // double-click works with a clean PATH (see installVcpkgDlls doc).
    installVcpkgDlls(b, &desktop_install.step);
    installVcpkgDlls(b, b.getInstallStep());
    // Shipped webapp staging: src/apps/desktop/dist → zig-out/bin/html, which
    // the release tarball `pabrik-html-<triple>.tar.gz` is built from. Do NOT
    // gate this on the dist probe alone — it runs before the chain builds dist.
    const dist_present = fileExists("src/apps/desktop/dist/index.html");
    if (dist_present or !no_webapp_rebuild) {
        const webapp_dir_install = b.addInstallDirectory(.{
            .source_dir = b.path("src/apps/desktop/dist"),
            .install_dir = .bin,
            .install_subdir = "html",
        });
        if (!no_webapp_rebuild) {
            webapp_dir_install.step.dependOn(&webapp_rebuild_codegen.step);
        }
        desktop_install.step.dependOn(&webapp_dir_install.step);
    } else {
        // -Dno-webapp-rebuild: dist/ has to be prebuilt, so it stays gated.
        std.log.warn(
            "webapp dist/index.html missing and -Dno-webapp-rebuild set -- skipping zig-out/bin/html (desktop falls back to embedded extraction)",
            .{},
        );
    }
    // Late alias kept for comment continuity — actual flag is defined
    // early (near target/optimize) so mcp/webapp sections could be gated.
    // Reuse the early `no_webapp_rebuild` value here; do not re-parse.

    // Make the desktop binary depend on the FRESH-ASSETS codegen chain: clean
    // → `bun run build` → codegen.
    if (!no_webapp_rebuild) {
        desktop_exe.step.dependOn(&webapp_rebuild_codegen.step);
    } else {
        // When skipping the webapp rebuild, ensure a stub exists so the
        // @import("embedded/webapp_assets.zig") in main.zig doesn't fail with
        // FileNotFound on a fresh checkout (gitignored file).
        const stub_path = "src/apps/desktop_app/embedded/webapp_assets.zig";
        if (!fileExists(stub_path)) {
            const stub_content =
                \\// GENERATED stub — webapp rebuild skipped (-Dno-webapp-rebuild)
                \\const std = @import("std");
                \\pub const Asset = struct { path: []const u8, content: []const u8, mime: []const u8 };
                \\pub const assets: []const Asset = &.{};
                \\
            ;
            // Use std.Io (Zig 0.16) — create parent dirs + file.
            const io = b.graph.io;
            // Ensure parent dir exists.
            std.Io.Dir.cwd().createDirPath(io, "src/apps/desktop_app/embedded") catch {};
            if (std.Io.Dir.cwd().createFile(io, stub_path, .{ .truncate = true })) |file| {
                defer file.close(io);
                std.Io.File.writeStreamingAll(file, io, stub_content) catch |err| {
                    std.log.warn("failed to write stub {s}: {any}", .{ stub_path, err });
                };
            } else |err| {
                std.log.warn("failed to create stub {s}: {any}", .{ stub_path, err });
            }
        }
    }

    // `zig build pabrik-desktop` alias — depends on: - the install step
    // (which includes `pabrik` via b.installArtifact above, so the pabrik
    // service binary that pabrik-desktop would auto-spawn ends up in
    const build_pabrik_desktop = b.step("pabrik-desktop", "Build the pabrik-desktop binary (and the pabrik service binary it auto-spawns)");
    build_pabrik_desktop.dependOn(b.getInstallStep());
    build_pabrik_desktop.dependOn(&desktop_install.step);

    const run_desktop = b.step("run:desktop-app", "Run the pabrik desktop wrapper");
    const run_desktop_cmd = b.addRunArtifact(desktop_exe);
    run_desktop.dependOn(&run_desktop_cmd.step);
    if (b.args) |args| run_desktop_cmd.addArgs(args);

    const test_desktop = b.step("test:desktop-app", "Run pabrik-desktop unit tests");
    const desktop_tests = b.addTest(.{
        .root_module = desktop_exe.root_module,
    });
    desktop_tests.root_module.linkSystemLibrary("c", .{});
    // The test compile shares `desktop_exe.root_module`, which imports the
    // gitignored `embedded/webapp_assets.zig`.
    if (!no_webapp_rebuild) {
        desktop_tests.step.dependOn(&webapp_rebuild_codegen.step);
    }
    const run_desktop_tests = b.addRunArtifact(desktop_tests);
    // Windows: ensure vcpkg bin (libcurl.dll, sqlite3.dll, …) is on PATH
    // at test runtime — see `prependVcpkgBinToPath` doc comment.
    prependVcpkgBinToPath(b, run_desktop_tests);
    test_desktop.dependOn(&run_desktop_tests.step);

    // === Cross-target compile check (desktop app's per-OS branches) ===
    // `extraction.zig` / `subprocess.zig` fork on `builtin.os.tag`, and Zig
    // only analyses the branch matching the TARGET — so running
    const check_desktop_cross = b.step(
        "check:desktop-cross",
        "Compile-check the desktop app's per-OS branches for Windows/macOS/Linux",
    );
    const cross_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    };
    for (cross_targets, 0..) |query, i| {
        const resolved = b.resolveTargetQuery(query);
        // A per-TARGET `helpers` module.
        const cross_helpers = b.createModule(.{
            .root_source_file = b.path("src/helpers/mod.zig"),
            .target = resolved,
            .optimize = optimize,
        });
        const obj = b.addObject(.{
            .name = b.fmt("desktop-cross-check-{d}", .{i}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/apps/desktop_app/cross_compile_check.zig"),
                .target = resolved,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "helpers", .module = cross_helpers },
                },
            }),
        });
        check_desktop_cross.dependOn(&obj.step);
    }

    // =====================================================================
    // CLI executable (`src/apps/cli/main.zig`) — wraps - POST
    // /api/llm/session - GET /api/llm/session - GET
    const cli_module = b.addModule("cli", .{
        .root_source_file = b.path("src/apps/cli/src/root.zig"),
        .target = target,
    });
    cli_module.addImport("kabelweb", kabelweb_mod);

    const cli_exe = b.addExecutable(.{
        .name = "pabrikcli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cli", .module = cli_module },
                .{ .name = "kabelweb", .module = kabelweb_mod },
                .{ .name = "helpers", .module = helpers_mod },
            },
        }),
    });
    cli_exe.root_module.linkSystemLibrary("c", .{});
    cli_exe.root_module.link_libc = true;
    // Same linkPlatformDeps treatment as the main exe: on Linux native
    // builds, the linker needs `/usr/lib` on its search path to find the
    // system libcurl / libssl / libcrypto .so files (the ones added by
    linkPlatformDeps(b, cli_exe, target);
    // libcurl is linked via kabelweb_mod's transitive deps (the vendored
    // prebuilt archive is added in the package's own build.zig). No need to
    // call linkCurlIncludePath here — the module graph handles it.
    const cli_install = b.addInstallArtifact(cli_exe, .{});

    const cli_step = b.step("run:cli", "Run the CLI");
    const run_cli_cmd = b.addRunArtifact(cli_exe);
    cli_step.dependOn(&run_cli_cmd.step);
    run_cli_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cli_cmd.addArgs(args);

    // === pabrikcli unit tests (`zig build test:cli`) === The CLI module
    // re-exports test files via its `root.zig`, so a single `b.addTest({
    // .root_module = cli_module })` step picks up every `_test.zig` under
    const cli_tests = b.addTest(.{ .root_module = cli_module });
    cli_tests.root_module.linkSystemLibrary("c", .{});
    cli_tests.root_module.link_libc = true;
    const test_cli = b.step("test:cli", "Run pabrikcli unit tests");
    const run_cli_tests = b.addRunArtifact(cli_tests);
    // Windows: ensure vcpkg bin (libcurl.dll, …) is on PATH at test
    // runtime — see `prependVcpkgBinToPath` doc comment.
    prependVcpkgBinToPath(b, run_cli_tests);
    test_cli.dependOn(&run_cli_tests.step);

    // === pabrikcli install-only (`zig build install:cli`) ===
    // Skips the full `build:all` dance — just installs the cli binary.
    const install_cli_step = b.step("install:cli", "Install the pabrikcli binary only");
    install_cli_step.dependOn(&cli_install.step);

    // =====================================================================
    // TUI executable (`src/apps/cli/src/tui_main.zig`) — an interactive,
    // streaming, Claude-Code-style chat client over the same backend
    const tui_module = b.addModule("tui", .{
        .root_source_file = b.path("src/apps/cli/src/tui/root.zig"),
        .target = target,
    });
    tui_module.addImport("kabelweb", kabelweb_mod);
    // Let the app model reach the transport helpers through the same
    // import surface used by pabrikcli.
    tui_module.addImport("cli", cli_module);

    const tui_exe = b.addExecutable(.{
        .name = "pabrik-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/cli/src/tui_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tui", .module = tui_module },
                .{ .name = "cli", .module = cli_module },
                .{ .name = "kabelweb", .module = kabelweb_mod },
                .{ .name = "helpers", .module = helpers_mod },
            },
        }),
    });
    tui_exe.root_module.linkSystemLibrary("c", .{});
    tui_exe.root_module.link_libc = true;
    linkPlatformDeps(b, tui_exe, target);
    const tui_install = b.addInstallArtifact(tui_exe, .{});

    const run_tui_step = b.step("run:tui", "Run the interactive chat TUI");
    const run_tui_cmd = b.addRunArtifact(tui_exe);
    run_tui_step.dependOn(&run_tui_cmd.step);
    run_tui_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_tui_cmd.addArgs(args);

    // === pabrik-tui unit tests (`zig build test:tui`) ===
    // The tui module re-exports its test files via `tui/root.zig`, so a
    // single addTest on the module picks up every test in the tree.
    const tui_tests = b.addTest(.{ .root_module = tui_module });
    tui_tests.root_module.linkSystemLibrary("c", .{});
    tui_tests.root_module.link_libc = true;
    const test_tui = b.step("test:tui", "Run pabrik-tui unit tests");
    const run_tui_tests = b.addRunArtifact(tui_tests);
    test_tui.dependOn(&run_tui_tests.step);

    // === pabrik-tui install-only (`zig build install:tui`) ===
    const install_tui_step = b.step("install:tui", "Install the pabrik-tui binary only");
    install_tui_step.dependOn(&tui_install.step);

    // === pabrik-tui user-local install (`zig build install-tui`) === Builds
    // pabrik-tui and copies it to the per-user bin directory: Linux:
    // $HOME/.local/bin/pabrik-tui macOS: $HOME/.local/bin/pabrik-tui Windows:
    const install_tui_tool = b.addExecutable(.{
        .name = "install_tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/install_tui.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .link_libc = true,
        }),
    });
    const install_tui_run = b.addRunArtifact(install_tui_tool);
    const tui_bin_name = if (b.graph.host.result.os.tag == .windows) "pabrik-tui.exe" else "pabrik-tui";
    install_tui_run.addArg(b.pathJoin(&.{ b.install_path, "bin", tui_bin_name }));
    install_tui_run.step.dependOn(&tui_install.step);

    const install_tui_user_step = b.step("install-tui", "Build pabrik-tui and install to user bin (~/.local/bin on Linux/macOS, %LOCALAPPDATA%\\pabrik\\bin on Windows)");
    install_tui_user_step.dependOn(&install_tui_run.step);

    // `zig build run` serves the Vue webapp, and rebuilds it first. Two
    // things differ from "build the binary, then run it": 1.
    const run_step = b.step("run", "Run the app (rebuilds and serves the webapp; -Dno-webapp-rebuild for API only)");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (!no_webapp_rebuild) {
        run_cmd.step.dependOn(build_webapp_step);
        if (!callerSetsStaticDir(b.args)) {
            run_cmd.addArgs(&.{ "--static-dir", b.pathJoin(&.{ webapp_dir, "dist" }) });
        }
    }

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Note on per-Compile platform deps (replaces old `mod.linkSystemLibrary`
    // + target-based switches): previously, `mod` itself was the place where
    // the build script added sqlite3/openssl/Linux system libs based on the

    // Tests need a SEPARATE module (not `mod`) so we can attach native
    // platform deps without polluting `mod` for cross-compile consumers.
    const test_target = target; // tests always run on the native host
    const mod_tests_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = test_target,
        .optimize = optimize,
    });
    mod_tests_module.addImport("pabrikcore", mod_tests_module);
    mod_tests_module.addImport("kabelweb", kabelweb_mod);
    mod_tests_module.addImport("helpers", helpers_mod);
    // Same `databases` import as `mod` — tests that touch sqlite3 get the
    // package's deps (link_libc + sqlite3.c amalgamation + openssl + libpq)
    // via the module-graph dep propagation.
    mod_tests_module.addImport("databases", databases_mod);
    mod_tests_module.addImport("auth_core", auth_core_mod);
    // Apply platform deps directly on the module (modules accumulate deps
    // additively).
    {
        mod_tests_module.linkSystemLibrary("c", .{});
        mod_tests_module.link_libc = true;
        if (test_target.result.os.tag == .linux) {
            mod_tests_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        }
        // Vendored Lua for hooks tests (same sources as `mod` above;
        // this is a separate root module so it needs its own attach).
        linkVendoredLua(b, mod_tests_module);
    }

    // If the test module consumes vendored sqlite3 (Windows / cross-
    // compile), make the test wait for the auto-fetch step so a fresh
    // checkout doesn't fail with "file not found".
    if (test_target.result.os.tag == .windows) {}

    const test_step = b.step("test", "Run tests");

    // The mod_tests suite is SPLIT into `shard_count` independent test
    // binaries so `zig build`'s step scheduler can compile and run them
    // concurrently — one 4.4k-test binary executes its tests strictly in
    const host_cpus = std.Thread.getCpuCount() catch 4;
    const default_shards: usize = @max(1, @min(8, host_cpus / 2));
    const shard_count = b.option(
        usize,
        "test-shards",
        "Number of parallel shards for `zig build test` (default: min(8, cpus/2); 1 = single binary, legacy behaviour)",
    ) orelse default_shards;

    const shard_entries = collectTestShardEntries(b);
    // One shard means "no filters at all": pass the whole suite through a
    // single unfiltered compile, which is both faster (one compile) and the
    // exact legacy behaviour. Filtering by name would only slow it down.
    const use_filters = shard_count > 1 and shard_entries.len > 0;
    const shards = if (use_filters)
        balanceTestShards(b, shard_entries, shard_count)
    else
        &[_][]const []const u8{};

    if (shard_entries.len > 0) {
        std.debug.print(
            "[test] mod_tests split into {d} shard(s) from {d} scanned test names " ++
                "(`zig build test:shard:<i>` runs one)\n",
            .{ if (use_filters) shard_count else @as(usize, 1), shard_entries.len },
        );
    }

    for (shards, 0..) |filters, i| {
        const shard_tests = b.addTest(.{
            .root_module = mod_tests_module,
            .filters = filters,
        });
        const run_shard = b.addRunArtifact(shard_tests);
        // Windows: ensure vcpkg bin (libcurl.dll, sqlite3.dll,
        // libssl-3-x64.dll, libcrypto-3-x64.dll, libpq.dll, …) is on PATH at
        // test runtime — see `prependVcpkgBinToPath` doc comment.
        prependVcpkgBinToPath(b, run_shard);
        test_step.dependOn(&run_shard.step);
        // Per-shard step so a failure — or a re-measure for
        // `slow_test_weights` above — can be reproduced in isolation.
        const shard_label = b.fmt("test:shard:{d}", .{i});
        b.step(
            shard_label,
            b.fmt("Run shard {d}/{d} of the mod_tests suite ({d} tests)", .{ i + 1, shards.len, filters.len }),
        ).dependOn(&run_shard.step);
    }

    // sqlite3 comes from the external `databases` package (ruangsql) via the
    // module graph — no in-tree fetch step needed.
    if (!use_filters) {
        const mod_tests = b.addTest(.{ .root_module = mod_tests_module });
        const run_mod_tests = b.addRunArtifact(mod_tests);
        prependVcpkgBinToPath(b, run_mod_tests);
        test_step.dependOn(&run_mod_tests.step);
    }

    // `run_captured.zig` lives in the standalone `helpers` PACKAGE, so its
    // inline tests are not reachable from `src/root.zig` and the mod_tests
    // binary above never compiles them.
    const run_captured_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/helpers/run_captured.zig"),
            .target = test_target,
            .optimize = optimize,
        }),
    });
    const run_run_captured_tests = b.addRunArtifact(run_captured_tests);
    test_step.dependOn(&run_run_captured_tests.step);
    b.step("test:helpers:run_captured", "Run run_captured helper tests").dependOn(&run_run_captured_tests.step);

    // Same story for `test_path.zig`: it is part of the standalone `helpers`
    // PACKAGE (`@import("helpers").test_path.absPath` is how the agent tool
    // tests build an absolute path), so its inline tests are not reachable
    const test_path_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/helpers/test_path.zig"),
            .target = test_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_test_path_tests = b.addRunArtifact(test_path_tests);
    test_step.dependOn(&run_test_path_tests.step);
    b.step("test:helpers:test_path", "Run test_path helper tests")
        .dependOn(&run_test_path_tests.step);

    // Same story for `ansi.zig`: the `helpers` PACKAGE is a separate module,
    // so its inline tests are not reachable from `src/root.zig` and the
    // `mod_tests` binary never compiles them.
    const ansi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/helpers/ansi.zig"),
            .target = test_target,
            .optimize = optimize,
        }),
    });
    const run_ansi_tests = b.addRunArtifact(ansi_tests);
    test_step.dependOn(&run_ansi_tests.step);
    b.step("test:helpers:ansi", "Run ansi (ANSI escape stripper) helper tests")
        .dependOn(&run_ansi_tests.step);

    // Standalone helper (std + libc getenv only), so it needs its own test root.
    const git_env_guard_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/helpers/git_env_guard.zig"),
            .target = test_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_git_env_guard_tests = b.addRunArtifact(git_env_guard_tests);
    test_step.dependOn(&run_git_env_guard_tests.step);
    b.step("test:helpers:git_env_guard", "Run git_env_guard helper tests")
        .dependOn(&run_git_env_guard_tests.step);

    // === The VM trio: the guest agent (installed as /init), the probe
    // fixture, and the manager. All three come out of `zig build`, so no
    // script needs to know how to invoke the compiler on their behalf.
    const vm_step = b.step("vm", "Build pabrik-vm-agent + pabrik-probe, and pabrik-vmd on Linux");
    const guest_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });
    const vm_agent_exe = b.addExecutable(.{
        .name = "pabrik-vm-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vm_agent/main.zig"),
            .target = guest_target,
            .optimize = optimize,
        }),
    });
    // The guest's `/init`: it asks the host for the current agent and execs
    // it, so a workspace's disk never carries the agent (see
    // src/vm_agent/bootstrap.zig).
    const vm_bootstrap_exe = b.addExecutable(.{
        .name = "pabrik-vm-bootstrap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vm_agent/bootstrap.zig"),
            .target = guest_target,
            .optimize = optimize,
        }),
    });
    const vm_probe_exe = b.addExecutable(.{
        .name = "pabrik-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vm_agent/probe.zig"),
            .target = guest_target,
            .optimize = optimize,
        }),
    });
    const vm_netd_exe = b.addExecutable(.{
        .name = "pabrik-vm-netd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vm_agent/netd.zig"),
            .target = guest_target,
            .optimize = optimize,
        }),
    });
    const install_vm_netd = b.addInstallArtifact(vm_netd_exe, .{});
    const install_vm_agent = b.addInstallArtifact(vm_agent_exe, .{});
    const install_vm_bootstrap = b.addInstallArtifact(vm_bootstrap_exe, .{});
    const install_vm_probe = b.addInstallArtifact(vm_probe_exe, .{});
    vm_step.dependOn(&install_vm_agent.step);
    vm_step.dependOn(&install_vm_bootstrap.step);
    vm_step.dependOn(&install_vm_probe.step);
    b.getInstallStep().dependOn(&install_vm_agent.step);
    b.getInstallStep().dependOn(&install_vm_bootstrap.step);
    b.getInstallStep().dependOn(&install_vm_probe.step);
    vm_step.dependOn(&install_vm_netd.step);
    b.getInstallStep().dependOn(&install_vm_netd.step);

    // === pabrik-vmd (src/vmd/main.zig) — the workspace VM manager ===
    // Linux-only: it speaks to a unix socket and forks a VMM, and the tests
    // that drive it need /dev/kvm (scripts/vmd-smoke.sh, scripts/vmd-daemon-smoke.sh).
    const vmd_step = b.step("vmd", "Build pabrik-vmd into zig-out/bin/pabrik-vmd");
    const vmd_test_step = b.step("test:vmd", "Run the pabrik-vmd unit tests");
    var vmd_install: ?*std.Build.Step = null;
    var tap_install: ?*std.Build.Step = null;
    if (target.result.os.tag == .linux) {
        const vmd_exe = b.addExecutable(.{
            .name = "pabrik-vmd",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/vmd/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const install_vmd = b.addInstallArtifact(vmd_exe, .{});
        vmd_step.dependOn(&install_vmd.step);
        vm_step.dependOn(&install_vmd.step);
        b.getInstallStep().dependOn(&install_vmd.step);
        vmd_install = &install_vmd.step;

        const tap_exe = b.addExecutable(.{
            .name = "pabrik-vm-tap",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/vmd/tap.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const install_tap = b.addInstallArtifact(tap_exe, .{});
        vm_step.dependOn(&install_tap.step);
        b.getInstallStep().dependOn(&install_tap.step);
        tap_install = &install_tap.step;

        const vmd_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/vmd/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_vmd_tests = b.addRunArtifact(vmd_tests);
        vmd_test_step.dependOn(&run_vmd_tests.step);
        test_step.dependOn(&run_vmd_tests.step);
    }

    // ── zginlint: the Zig linter (github.com/ginwa123/zglint) ───────────
    // Moved out of this tree; its unit tests run in that repo's CI now, not
    // here (a consumer build never runs a dependency's test blocks).
    const zginlint_dep = b.dependency("zginlint", .{
        .target = target,
        .optimize = optimize,
    });
    const zginlint_exe = zginlint_dep.artifact("zginlint");
    const install_zginlint = b.addInstallArtifact(zginlint_exe, .{});
    b.step("zginlint", "Build the zginlint CLI into zig-out/bin/zginlint")
        .dependOn(&install_zginlint.step);

    // The gate's whole definition: the tree paths it covers. There is no
    // baseline and no per-file ceiling — a finding is a finding, so the only
    // way to make this step pass is to fix the comment.
    const zginlint_scope = [_][]const u8{ "src", "tests", "tools", "build.zig" };

    // `has_side_effects` is load-bearing: a Run step is keyed by its binary
    // and argv, NOT by the tree it reads, so without it a second run is
    // "cached" and the gate silently skips the scan.
    const zginlint_check = b.step("zginlint:check", "Enforce the zginlint rules on the tree (zero findings)");
    const run_zginlint_check = b.addRunArtifact(zginlint_exe);
    run_zginlint_check.setCwd(b.path("."));
    run_zginlint_check.addArgs(&zginlint_scope);
    run_zginlint_check.has_side_effects = true;
    zginlint_check.dependOn(&run_zginlint_check.step);

    // kabelweb's own suites (server + client) run in the kabelweb repo's CI
    // (github.com/ginwa123/kabelweb), not here — it's an external URL
    // dependency, and a consumer build never runs a dependency's test blocks.

    const ai_workflow_tui_test_mod = b.addTest(.{
        .root_module = mod_tests_module,
    });

    const run_ai_workflow_tui_tests = b.addRunArtifact(ai_workflow_tui_test_mod);
    // Windows: ensure vcpkg bin (libcurl.dll, sqlite3.dll, …) is on
    // PATH at test runtime — see `prependVcpkgBinToPath` doc comment.
    prependVcpkgBinToPath(b, run_ai_workflow_tui_tests);
    const test_ai_workflow_tui_step = b.step("test:ai_workflow:tui", "Run AI workflow TUI tests");
    // The TUI test reuses `mod_tests_module` (which transitively imports
    // the external `databases` package) — no fetch wiring needed.
    test_ai_workflow_tui_step.dependOn(&run_ai_workflow_tui_tests.step);

    const linux_step = b.step("install:linux", "Build for Linux x86_64");
    const linux_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
        .glibc_version = .{ .major = 2, .minor = 38, .patch = 0 },
    });
    const linux_exe = createPlatformExe(b, mod, helpers_mod, linux_target, optimize, "pabrikcore-linux-x86_64");
    linux_exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    linux_exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    // libcurl is linked via kabelweb_mod's transitive deps (the vendored
    // prebuilt archive is added in the package's own build.zig).
    linux_exe.root_module.link_libc = true;
    const install_linux = b.addInstallArtifact(linux_exe, .{});
    linux_step.dependOn(&install_linux.step);

    const windows_step = b.step("install:windows", "Build for Windows x86_64");
    const windows_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    });
    // NB: don't include `.exe` in the name — Zig 0.16's `addExecutable`
    // auto-appends `.exe` on Windows targets, so passing a name with `.exe`
    // already produces the doubled suffix `pabrikcore-windows-x86_64.exe.exe`
    const windows_exe = createPlatformExe(b, mod, helpers_mod, windows_target, optimize, "pabrikcore-windows-x86_64");
    // libcurl is linked via kabelweb_mod's transitive deps (kabelweb
    // package owns its Windows/vcpkg wiring).
    windows_exe.root_module.link_libc = true;
    const install_windows = b.addInstallArtifact(windows_exe, .{});
    windows_step.dependOn(&install_windows.step);

    // Native-only macos step: only enabled when the build host IS macos.
    const is_native_macos = b.graph.host.result.os.tag == .macos;

    const macos_step = b.step("install:macos", "Build for macOS x86_64");
    const macos_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .macos,
    });
    const macos_exe = createPlatformExe(b, mod, helpers_mod, macos_target, optimize, "pabrikcore-macos-x86_64");
    // libcurl is linked via kabelweb_mod's transitive deps.
    macos_exe.root_module.link_libc = true;
    const install_macos = b.addInstallArtifact(macos_exe, .{});
    macos_step.dependOn(&install_macos.step);

    const macos_arm_step = b.step("install:macos-arm", "Build for macOS aarch64 (Apple Silicon)");
    const macos_arm_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    });
    const macos_arm_exe = createPlatformExe(b, mod, helpers_mod, macos_arm_target, optimize, "pabrikcore-macos-aarch64");
    // libcurl is linked via kabelweb_mod's transitive deps.
    macos_arm_exe.root_module.link_libc = true;
    const install_macos_arm = b.addInstallArtifact(macos_arm_exe, .{});
    macos_arm_step.dependOn(&install_macos_arm.step);
    _ = is_native_macos;

    const linux_system_step = b.step("install:linux:system", "Build for Linux x86_64 and install to system");
    const linux_system_exe = createPlatformExe(b, mod, helpers_mod, target, optimize, "pabrik");
    linux_system_exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    linux_system_exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    // libcurl is linked via kabelweb_mod's transitive deps.
    linux_system_exe.root_module.link_libc = true;
    linux_system_step.dependOn(&linux_system_exe.step);
    const install_linux_system = b.addInstallArtifact(linux_system_exe, .{});
    linux_system_step.dependOn(&install_linux_system.step);
    const copy_to_system = b.addSystemCommand(&.{
        "cp",
        "zig-out/bin/pabrik",
        "/usr/local/bin/pabrik",
    });
    copy_to_system.step.dependOn(&install_linux_system.step);
    linux_system_step.dependOn(&copy_to_system.step);

    // =====================================================================
    // install:linux:app — Linux desktop launcher entry (GNOME/KDE search)
    // `zig build pabrik-desktop` only drops `zig-out/bin/pabrik-desktop`,
    const linux_app_step = b.step("install:linux:app", "Build pabrik-desktop and install launcher entry so it appears in GNOME/KDE search (requires sudo)");
    linux_app_step.dependOn(&desktop_install.step);
    linux_app_step.dependOn(b.getInstallStep());
    const copy_desktop_bin = b.addSystemCommand(&.{
        "cp",
        "zig-out/bin/pabrik-desktop",
        "/usr/local/bin/pabrik-desktop",
    });
    copy_desktop_bin.step.dependOn(&desktop_install.step);
    linux_app_step.dependOn(&copy_desktop_bin.step);
    const copy_pabrik_svc = b.addSystemCommand(&.{
        "cp",
        "zig-out/bin/pabrik",
        "/usr/local/bin/pabrik",
    });
    copy_pabrik_svc.step.dependOn(b.getInstallStep());
    linux_app_step.dependOn(&copy_pabrik_svc.step);
    const install_desktop_file = b.addSystemCommand(&.{
        "/bin/sh",                                                                                                                                                                                                                                                                                                                  "-c",
        "mkdir -p /usr/share/applications && cp packaging/linux/pabrik.desktop /usr/share/applications/pabrik.desktop && chmod 644 /usr/share/applications/pabrik.desktop && cp packaging/linux/pabrik-browser.desktop /usr/share/applications/pabrik-browser.desktop && chmod 644 /usr/share/applications/pabrik-browser.desktop",
    });
    install_desktop_file.step.dependOn(&copy_desktop_bin.step);
    install_desktop_file.step.dependOn(&copy_pabrik_svc.step);
    linux_app_step.dependOn(&install_desktop_file.step);
    const install_desktop_icon = b.addSystemCommand(&.{
        "/bin/sh",                                                                                                                                                                                                                                                                                                                                                                                         "-c",
        "for s in 16 32 48 64 128 256 512; do mkdir -p /usr/share/icons/hicolor/${s}x${s}/apps && cp packaging/icons/pabrik-${s}.png /usr/share/icons/hicolor/${s}x${s}/apps/pabrik.png && chmod 644 /usr/share/icons/hicolor/${s}x${s}/apps/pabrik.png; done; mkdir -p /usr/share/pixmaps && cp packaging/icons/pabrik-256.png /usr/share/pixmaps/pabrik.png && chmod 644 /usr/share/pixmaps/pabrik.png",
    });
    install_desktop_icon.step.dependOn(&install_desktop_file.step);
    linux_app_step.dependOn(&install_desktop_icon.step);
    const refresh_desktop_db = b.addSystemCommand(&.{
        "/bin/sh",                                                                                                                                              "-c",
        "update-desktop-database /usr/share/applications || true; gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true; pkill -x qs-glauncher || true",
    });
    refresh_desktop_db.step.dependOn(&install_desktop_icon.step);
    linux_app_step.dependOn(&refresh_desktop_db.step);

    // =====================================================================
    // install:windows:app — Windows user-local app install (Start Menu
    // search) Windows-only (invoking on Linux/macOS fails at the powershell
    const windows_app_step = b.step("install:windows:app", "Build pabrik-desktop + service and install user-local with Start Menu shortcut (Windows-only, no admin)");
    windows_app_step.dependOn(&desktop_install.step);
    windows_app_step.dependOn(b.getInstallStep());
    const run_windows_app_install = b.addSystemCommand(&.{
        "powershell", "-NoProfile",                           "-ExecutionPolicy", "Bypass",
        "-File",      "packaging/windows/Install-Pabrik.ps1", "-SourceDir",       "zig-out/bin",
    });
    run_windows_app_install.step.dependOn(&desktop_install.step);
    run_windows_app_install.step.dependOn(b.getInstallStep());
    windows_app_step.dependOn(&run_windows_app_install.step);

    // =====================================================================
    // install:macos:app — macOS user-local app install (Spotlight/Launchpad)
    // macOS-only at runtime (invoking on Linux/Windows fails at the sh spawn
    const macos_app_step = b.step("install:macos:app", "Build pabrik-desktop + service and install Pabrik.app to ~/Applications (macOS-only, no sudo)");
    macos_app_step.dependOn(&desktop_install.step);
    macos_app_step.dependOn(b.getInstallStep());
    const run_macos_app_install = b.addSystemCommand(&.{
        "/bin/sh", "packaging/macos/install-pabrik-app.sh", "zig-out/bin",
    });
    run_macos_app_install.step.dependOn(&desktop_install.step);
    run_macos_app_install.step.dependOn(b.getInstallStep());
    macos_app_step.dependOn(&run_macos_app_install.step);

    const dev_optimize: std.builtin.OptimizeMode = .Debug;

    const dev_linux_system_step = b.step("install:dev:linux:system", "Build pabrik-dev (debug) for Linux x86_64 and install to system");
    const dev_exe = b.addExecutable(.{
        .name = "pabrik-dev",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = dev_optimize,
            .imports = &.{
                .{ .name = "pabrikcore", .module = mod },
                .{ .name = "helpers", .module = helpers_mod },
            },
        }),
    });
    dev_exe.root_module.linkSystemLibrary("c", .{});
    // libcurl is linked via kabelweb_mod's transitive deps.
    dev_exe.root_module.link_libc = true;
    linkPlatformDeps(b, dev_exe, target);
    if (target.result.os.tag == .windows) {}
    const install_dev = b.addInstallArtifact(dev_exe, .{});
    dev_linux_system_step.dependOn(&install_dev.step);
    const copy_dev_to_system = b.addSystemCommand(&.{
        "cp",
        "zig-out/bin/pabrik-dev",
        "/usr/local/bin/pabrik-dev",
    });
    copy_dev_to_system.step.dependOn(&install_dev.step);
    dev_linux_system_step.dependOn(&copy_dev_to_system.step);

    // =====================================================================
    // Functional tests (Python+pytest) — see tests/functional/README.md.
    // Booting a real pabrik against an isolated tmpdir HOME.
    const python_exe = b.option([]const u8, "python", "Path to python3 binary (default: 'python3')") orelse "python3";

    // The artifact `zig build`'s DEFAULT install step writes for this host —
    // the binary the functional suites must exercise.
    const host_binary_name = switch (b.graph.host.result.os.tag) {
        .linux => "pabrikcore-linux-x86_64",
        .macos => if (b.graph.host.result.cpu.arch == .aarch64)
            "pabrikcore-macos-aarch64"
        else
            "pabrikcore-macos-x86_64",
        .windows => "pabrikcore-windows-x86_64.exe",
        else => "pabrikcore-unknown",
    };
    const func_pabrik_bin = b.getInstallPath(.bin, host_binary_name);

    // ── Splitting the Python suites across N disjoint shards ─────────── The
    // shard CONTRACT (the two env vars, and "item index % total == index")
    // lives in tests/func_shard.py + tests/conftest.py and is not touched
    const python_shards: u32 = b.option(
        u32,
        "func-shards",
        "Split each Python functional suite into N disjoint shards (default 1 = no split)",
    ) orelse 1;
    if (python_shards == 0) fatalConfig("-Dfunc-shards must be >= 1 (got 0)", .{});
    const python_shard_only: ?u32 = b.option(
        u32,
        "func-shard-index",
        "Run ONLY this 0-based shard of the Python suites (needs -Dfunc-shards=N; ignored when N is 1)",
    );
    if (python_shard_only) |i| {
        if (i >= python_shards) fatalConfig(
            "-Dfunc-shard-index={d} is out of range for -Dfunc-shards={d}",
            .{ i, python_shards },
        );
    }
    const python_shard_indices: []const ?u32 = if (python_shards == 1)
        &[_]?u32{null}
    else if (python_shard_only) |i|
        &[_]?u32{i}
    else blk: {
        const all = b.allocator.alloc(?u32, python_shards) catch @panic("OOM");
        for (all, 0..) |*slot, i| slot.* = @intCast(i);
        break :blk all;
    };
    // Venv location override (2026-08-25): CI relocates the venv OUTSIDE the
    // workspace via PABRIK_FUNC_VENV_DIR because self-hosted runners `git
    // clean` the workspace between runs — a workspace-relative .venv-func is
    const venv_dir_raw = b.graph.environ_map.get("PABRIK_FUNC_VENV_DIR") orelse ".venv-func";
    // Normalize Windows mixed separators (runner.temp is C:\...\ _temp + "/pabrik-ci-venv" → "C:\...\ _temp/pabrik-ci-venv").
    // Use forward slashes internally; Python on Windows handles both.
    const venv_dir = blk: {
        const dup = b.allocator.dupe(u8, venv_dir_raw) catch @panic("build.zig: dupe of PABRIK_FUNC_VENV_DIR failed");
        for (dup) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        break :blk dup;
    };
    const is_windows_host = b.graph.host.result.os.tag == .windows;
    const venv_bin = if (is_windows_host)
        std.fmt.allocPrint(b.allocator, "{s}/Scripts", .{venv_dir}) catch @panic("build.zig: allocPrint of the venv Scripts dir failed")
    else
        std.fmt.allocPrint(b.allocator, "{s}/bin", .{venv_dir}) catch @panic("build.zig: allocPrint of the venv bin dir failed");
    // On Windows, `python` is the canonical exe; `python3` is often a shim.
    const default_python = if (is_windows_host) "python" else "python3";
    const effective_python = if (std.mem.eql(u8, python_exe, "python3") and is_windows_host) default_python else python_exe;
    // Windows venv creation must survive the Microsoft Store `python` stub
    // ("Python was not found") and must not redo an existing venv: 1.
    const venv_python_name = if (is_windows_host) "python.exe" else "python";
    const venv_python_rel = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ venv_bin, venv_python_name }) catch @panic("build.zig: allocPrint of the venv python path failed");
    const have_venv = blk: {
        _ = std.Io.Dir.cwd().statFile(b.graph.io, venv_python_rel, .{}) catch break :blk false;
        break :blk true;
    };
    const install_venv = blk: {
        if (have_venv) {
            if (is_windows_host) break :blk b.addSystemCommand(&.{ "cmd.exe", "/c", "exit", "0" });
            break :blk b.addSystemCommand(&.{"true"});
        }
        if (!is_windows_host) break :blk b.addSystemCommand(&.{
            // `--clear`: the venv dir may already exist with DANGLING
            // interpreter symlinks -- e.g. a cached venv restored under a
            // different Python patch version (bin/python points at a
            effective_python, "-m", "venv", "--clear", venv_dir,
        });
        var chosen: ?[]const u8 = null;
        var chosen_args: []const []const u8 = &.{};
        if (!std.mem.eql(u8, python_exe, "python3")) {
            chosen = python_exe; // explicit -Dpython: trust it (old behavior)
        } else if (b.graph.environ_map.get("PATH")) |path_var| {
            var it = std.mem.splitScalar(u8, path_var, ';');
            const probes = [_][]const u8{ "python.exe", "python3.exe", "py.exe" };
            outer: while (it.next()) |dir| {
                if (dir.len == 0) continue;
                for (probes) |name| {
                    const cand = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ dir, name }) catch @panic("build.zig: allocPrint of the python probe path failed");
                    // Absolute sub_path: the cwd handle is ignored.
                    const st = std.Io.Dir.cwd().statFile(b.graph.io, cand, .{}) catch continue;
                    if (st.size == 0) continue; // Microsoft Store stub
                    chosen = cand;
                    if (std.mem.eql(u8, name, "py.exe")) chosen_args = &.{"-3"};
                    break :outer;
                }
            }
        }
        var argv: std.ArrayList([]const u8) = .empty;
        argv.append(b.allocator, chosen orelse "python") catch @panic("build.zig: append of the venv interpreter failed");
        argv.appendSlice(b.allocator, chosen_args) catch @panic("build.zig: appendSlice of the venv args failed");
        argv.appendSlice(b.allocator, &.{ "-m", "venv", "--clear", venv_dir }) catch @panic("build.zig: appendSlice of the venv create args failed");
        break :blk b.addSystemCommand(argv.items);
    };
    install_venv.setCwd(b.path(""));

    const pip_exe = if (is_windows_host) "pip.exe" else "pip";
    const install_requirements = b.addSystemCommand(&.{
        b.fmt("{s}/{s}", .{ venv_bin, pip_exe }), "install", "-q", "-r", "tests/functional/requirements.txt",
    });
    install_requirements.setCwd(b.path(""));
    install_requirements.step.dependOn(&install_venv.step);

    // Probe python — skip the step if missing. Without a probe,
    // `addSystemCommand` would error at config time on hosts that don't have
    // python.
    const python_probe = b.addSystemCommand(switch (b.graph.host.result.os.tag) {
        .windows => &.{
            "cmd.exe", "/c",
            \\@where python >nul 2>&1 || @where python3 >nul 2>&1 || echo zig build functional-test: python not found, skipping (install Python from python.org or set -Dpython=...)
        },
        else => &.{
            "sh", "-c",
            \\command -v python3 >/dev/null 2>&1 || { echo 'zig build functional-test: python3 not found, skipping (install with `brew install python@3.11` or set -Dpython=...)'; exit 0; }
        },
    });
    python_probe.setCwd(b.path(""));

    const python_venv_exe = if (is_windows_host) "python.exe" else "python";
    const argv_functional = [_][]const u8{
        b.fmt("{s}/{s}", .{ venv_bin, python_venv_exe }), "-m", "pytest", "tests/functional/", "-v", "--tb=short",
    };
    const functional_test_step = b.step("functional-test", "Run functional tests against a real pabrik with isolated tmpdir data");
    for (python_shard_indices) |maybe_shard| {
        const run_functional = addPythonSuiteRun(b, &argv_functional, func_pabrik_bin, python_shards, maybe_shard);
        run_functional.step.dependOn(&install_requirements.step);
        run_functional.step.dependOn(&python_probe.step);
        // Depend on the top-level `install` step (copies binary to
        // zig-out/bin/pabrik) rather than `install:linux:system` which
        // additionally tries to `cp` to /usr/local/bin/pabrik and fails on
        run_functional.step.dependOn(b.getInstallStep());
        // Depend on the mcp-http-hello-world build step so the HTTP test
        // server is at zig-out/bin/mcp-http-hello-world when the functional
        // tests run.
        run_functional.step.dependOn(mcp_http_hello_world_step);
        functional_test_step.dependOn(&run_functional.step);
        // Per-shard step, mirroring `test:shard:<i>`: it is how a shard is
        // reproduced in isolation, and it is the race-free way to run all N
        // at once (one shell each, so the port pickers never draw
        if (maybe_shard) |shard_index| {
            _ = b.step(
                b.fmt("functional-test:shard:{d}", .{shard_index}),
                b.fmt("Run shard {d}/{d} of the API functional suite (tests/functional/)", .{ shard_index + 1, python_shards }),
            ).dependOn(&run_functional.step);
        }
    }

    // =====================================================================
    // Functional tests (Zig) — tests/functional/, its OWN package.
    const func_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/functional/root.zig"),
        .target = test_target,
        .optimize = optimize,
    });
    const func_tests = b.addTest(.{ .root_module = func_tests_module });
    const run_func_zig = b.addRunArtifact(func_tests);
    // The suite resolves `pabrik` through relative `zig-out/bin/*`
    // paths, so it must run from the repo root.
    run_func_zig.setCwd(b.path(""));
    // Same dependency the Python runner has: the suite boots this binary.
    run_func_zig.step.dependOn(b.getInstallStep());
    // And the HTTP MCP fixture server, for the `mcp_http_*` suites.
    run_func_zig.step.dependOn(mcp_http_hello_world_step);

    b.step("functional-test:zig", "Run the Zig functional test suite (tests/functional/)")
        .dependOn(&run_func_zig.step);

    // =====================================================================
    // Functional UI tests (Python+Playwright) — see
    // tests/functional_ui/README.md.
    const install_ui_requirements = b.addSystemCommand(&.{
        b.fmt("{s}/{s}", .{ venv_bin, pip_exe }), "install", "-q", "-r", "tests/functional_ui/requirements.txt",
    });
    install_ui_requirements.setCwd(b.path(""));
    install_ui_requirements.step.dependOn(&install_requirements.step);

    // Install Playwright Chromium browser. ``playwright install chromium`` is
    // idempotent — re-running it is a no-op if the browser is already cached.
    const install_playwright_browsers = b.addSystemCommand(&.{
        b.fmt("{s}/{s}", .{ venv_bin, python_venv_exe }), "-m", "playwright", "install", "chromium",
    });
    install_playwright_browsers.setCwd(b.path(""));
    install_playwright_browsers.step.dependOn(&install_ui_requirements.step);

    const argv_functional_ui = [_][]const u8{
        b.fmt("{s}/{s}", .{ venv_bin, python_venv_exe }), "-m", "pytest", "tests/functional_ui/", "-v", "--tb=short",
    };
    const functional_test_ui_step = b.step("functional-test-ui", "Run UI functional tests (Playwright Python) against pabrik + Vite dev server");
    for (python_shard_indices) |maybe_shard| {
        const run_functional_ui = addPythonSuiteRun(b, &argv_functional_ui, func_pabrik_bin, python_shards, maybe_shard);
        run_functional_ui.step.dependOn(&install_playwright_browsers.step);
        run_functional_ui.step.dependOn(&python_probe.step);
        // Depend on the same binary install as the API suite.
        run_functional_ui.step.dependOn(b.getInstallStep());
        functional_test_ui_step.dependOn(&run_functional_ui.step);
        if (maybe_shard) |shard_index| {
            _ = b.step(
                b.fmt("functional-test-ui:shard:{d}", .{shard_index}),
                b.fmt("Run shard {d}/{d} of the Playwright UI functional suite (tests/functional_ui/)", .{ shard_index + 1, python_shards }),
            ).dependOn(&run_functional_ui.step);
        }
    }

    // =====================================================================
    // functional-test-all — BOTH suites in ONE pytest invocation.
    const argv_functional_all = [_][]const u8{
        b.fmt("{s}/{s}", .{ venv_bin, python_venv_exe }),
        "-m",
        "pytest",
        "tests/functional/",
        "tests/functional_ui/",
        "-v",
        "--tb=short",
    };
    const functional_test_all_step = b.step("functional-test-all", "Run BOTH functional suites (API + Playwright UI) in one pytest invocation");
    for (python_shard_indices) |maybe_shard| {
        const run_functional_all = addPythonSuiteRun(b, &argv_functional_all, func_pabrik_bin, python_shards, maybe_shard);
        // install_playwright_browsers -> install_ui_requirements -> install_venv,
        // so this one edge covers the venv, both requirements files AND the
        // browser download.
        run_functional_all.step.dependOn(&install_playwright_browsers.step);
        run_functional_all.step.dependOn(&python_probe.step);
        run_functional_all.step.dependOn(b.getInstallStep());
        // Same reason as run_functional: mcp_http_test.py spawns this sibling
        // binary, and without the dep the suite fails on a missing file.
        run_functional_all.step.dependOn(mcp_http_hello_world_step);
        functional_test_all_step.dependOn(&run_functional_all.step);
        if (maybe_shard) |shard_index| {
            _ = b.step(
                b.fmt("functional-test-all:shard:{d}", .{shard_index}),
                b.fmt("Run shard {d}/{d} of BOTH functional suites (API + Playwright UI)", .{ shard_index + 1, python_shards }),
            ).dependOn(&run_functional_all.step);
        }
    }

    // =====================================================================
    // End-of-build success/failure banner
    // =====================================================================
    const desktop_binary_name = switch (b.graph.host.result.os.tag) {
        .windows => "pabrik-desktop.exe",
        else => "pabrik-desktop",
    };
    const cli_binary_name = switch (b.graph.host.result.os.tag) {
        .windows => "pabrikcli.exe",
        else => "pabrikcli",
    };

    // Build the banner script with host-specific binary names spliced in via
    // std.fmt.allocPrint.
    var banner_args: []const []const u8 = &.{};
    if (b.graph.host.result.os.tag == .windows) {
        const script = std.fmt.allocPrint(
            b.allocator,
            \\
            \\echo.
            \\echo [zig build success]
            \\echo.
            \\echo   pabrik service binary  ---^> zig-out\\bin\\{s}
            \\echo   pabrik desktop binary  ---^> zig-out\\bin\\{s}
            \\echo   pabrikcli binary       ---^> zig-out\\bin\\{s}
            \\echo.
            \\echo   (If a binary is missing, run "rmdir /s /q zig-out && zig build"
            \\echo    to force a fresh install -- the cache sometimes hides
            \\echo    manual deletions.)
            \\echo.
            \\echo   Run with:  zig-out\\bin\\{s} service start --port 8080
            \\echo              zig-out\\bin\\{s} --devtools
            \\echo              zig-out\\bin\\{s} sessions list
            \\echo.
            \\
        ,
            .{
                host_binary_name,
                desktop_binary_name,
                cli_binary_name,
                host_binary_name,
                desktop_binary_name,
                cli_binary_name,
            },
        ) catch @panic("OOM allocating Windows build banner");
        banner_args = &.{ "cmd.exe", "/c", script };
    } else {
        const script = std.fmt.allocPrint(
            b.allocator,
            \\
            \\D=zig-out/bin
            \\echo ""
            \\echo "[zig build success]"
            \\echo ""
            \\echo "  pabrik service binary  →  $D/{s}"
            \\echo "  pabrik desktop binary  →  $D/{s}"
            \\echo "  pabrikcli binary       →  $D/{s}"
            \\echo ""
            \\echo '  (If a binary is missing, run "rm -rf $D && zig build"'
            \\echo "   to force a fresh install — the cache sometimes hides"
            \\echo "   manual deletions.)"
            \\echo ""
            \\echo "  Run with:  $D/{s} service start --port 8080"
            \\echo "             $D/{s} --devtools"
            \\echo "             $D/{s} sessions list"
            \\echo ""
        ,
            .{
                host_binary_name,
                desktop_binary_name,
                cli_binary_name,
                host_binary_name,
                desktop_binary_name,
                cli_binary_name,
            },
        ) catch @panic("OOM allocating POSIX build banner");
        banner_args = &.{ "/bin/sh", "-c", script };
    }

    const build_banner = b.addSystemCommand(banner_args);
    const build_all_step = b.step("build:all", "Build pabrik service + pabrik-desktop, with end-of-build summary");
    // The binaries live on different top-level install steps: - host-specific
    // pabrikcore binary → install:<host> (Linux / macOS-arm / macOS /
    // Windows) - pabrik-desktop → install (native target, includes
    const host_install_step = switch (b.graph.host.result.os.tag) {
        .linux => &install_linux.step,
        .macos => if (b.graph.host.result.cpu.arch == .aarch64)
            &install_macos_arm.step
        else
            &install_macos.step,
        .windows => &install_windows.step,
        else => &install_linux.step, // safest default for exotic hosts
    };
    build_all_step.dependOn(host_install_step);
    build_all_step.dependOn(&desktop_install.step);
    build_all_step.dependOn(&cli_install.step);
    // pabrik-tui is POSIX-only: src/apps/cli/src/tui/terminal.zig passes
    // integer fds (std.posix.STDIN_FILENO) where Windows' fd_t is *anyopaque,
    // so it cannot compile on Windows.
    if (b.graph.host.result.os.tag != .windows) {
        build_all_step.dependOn(&tui_install.step);
    }
    build_all_step.dependOn(&build_banner.step);
    // `build:all` is a step of its own, so hooking only `install` left
    // `zig build` producing none of the trio. The agent and the probe are
    // fixed-target musl, so every host compiles them; `pabrik-vmd` is Linux-only.
    build_all_step.dependOn(&install_vm_agent.step);
    build_all_step.dependOn(&install_vm_probe.step);
    build_all_step.dependOn(&install_vm_netd.step);
    if (tap_install) |step| build_all_step.dependOn(step);
    if (vmd_install) |step| build_all_step.dependOn(step);
    // Make `zig build` (default) auto-fetch the vendored curl archive
    // when missing. The fetch script is idempotent — re-running on a
    // populated vendor/ is a fast no-op.

    // Default: same as `build:all`. Without this, `zig build` (no args) runs
    // the `install` step alone, which prints no summary on success.
    b.default_step = build_all_step;
}
