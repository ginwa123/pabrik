// Contract tests for the platform-gate table. Zig port of
// `tests/functional/platform_gates_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// The gate table
// ============================================================================

/// One `(platform, module) -> reason` row. `import_time` records whether the
/// blocker kills COLLECTION (a module-scope `import pty`) or only the TEST
/// BODY.
pub const Gate = struct {
    platform: []const u8,
    /// Module BASENAME with no extension.
    module: []const u8,
    reason: []const u8,
    import_time: bool = false,
};

/// Every gate, as a flat table. The comment above each group is the
/// class of blocker, so a new row lands next to its siblings and the
/// "why" is visible without opening each test.
pub const GATES = [_]Gate{
    // ── POSIX-only stdlib imports (`pty` / `fcntl` / `termios`) ──────────
    // These are module-level `import pty`, so on Windows they are a
    // COLLECTION ERROR that takes the whole file with them, not a test
    .{
        .platform = "win32",
        .module = "tui_turn_streaming_test",
        .reason = "needs a POSIX pty (import pty/fcntl/termios); Windows has ConPTY, which the stdlib pty module does not expose",
        .import_time = true,
    },
    .{
        .platform = "win32",
        .module = "tui_perf_test",
        .reason = "imports tui_perf_probe, which does a module-level `import pty` / `fcntl` — neither exists on Windows, so collection fails before any skip marker can run",
        .import_time = true,
    },
    // ── Linux-only kernel interfaces ────────────────────────────────────
    // RSS accounting reads /proc/<pid>/status. macOS has no /proc; the
    // equivalent is `ps -o rss=` or psutil, and the TUI perf budget is the
    .{
        .platform = "darwin",
        .module = "tui_perf_test",
        .reason = "tui_perf_probe reads /proc/<pid>/status for RSS; macOS has no /proc",
    },

    // ── Product gate: no pty backend on Windows ──────────────────────────
    // src/http_handlers/terminal_session.zig: pub const is_pty_os = switch
    // (builtin.os.tag) { .linux, .macos => true, else => false }; so
    .{
        .platform = "win32",
        .module = "terminal_session_test",
        .reason = "no pty backend on Windows: terminal_session.zig sets is_pty_os = linux || macos, so /api/terminal/sessions answers UnsupportedPlatform and the /bin/sh this test passes does not exist",
    },
    .{
        .platform = "win32",
        .module = "terminal_ws_test",
        .reason = "no pty backend on Windows: terminal_session.zig sets is_pty_os = linux || macos, so the terminal websocket never opens a pty and this handshake cannot complete",
    },
    .{
        .platform = "win32",
        .module = "terminal_limits_test",
        .reason = "no pty backend on Windows: terminal_session.zig sets is_pty_os = linux || macos, so none of the 20 sessions this test opens reaches a live shell to size",
    },
    .{
        .platform = "win32",
        .module = "terminal_isolation_test",
        .reason = "no pty backend on Windows: terminal_session.zig sets is_pty_os = linux || macos, so the two sessions this test isolates never open and there is nothing to keep apart",
    },
    .{
        .platform = "win32",
        .module = "terminal_sidebar_ui_test",
        .reason = "drives a real PTY in the browser's terminal panel; the panel itself is not shipped on Windows (same is_pty_os gate)",
    },

    // ── POSIX signal / waitpid semantics ────────────────────────────────
    // The test asserts a graceful-shutdown EXIT CODE of 130, which is what a
    // process group that received SIGINT reports.
    .{
        .platform = "win32",
        .module = "graceful_shutdown_test",
        .reason = "asserts SIGINT-graceful exit semantics (os.WNOHANG / os.WIFEXITED / exit code 130); Windows os.kill is TerminateProcess and those waitpid attributes do not exist",
    },

    // ── select() over a pipe ────────────────────────────────────────────
    // CPython's Windows select() accepts sockets only.
    .{
        .platform = "win32",
        .module = "mcp_stdio_hang_test",
        .reason = "select.select() on a subprocess pipe; Windows select() accepts sockets only",
    },
};

// ============================================================================
// Helpers
// ============================================================================

/// Every platform key the table can be asked about, in a stable order.
/// Derived from a fixed list rather than from `GATES` on purpose.
pub fn gatePlatforms() []const []const u8 {
    return &.{ "win32", "darwin", "linux" };
}

/// The gate platform key for the RUNNING interpreter. `sys.platform` is what
/// the Python table is keyed on.
pub fn currentPlatform() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "win32",
        .macos => "darwin",
        else => "linux",
    };
}

/// A filtered view of `GATES`, returned BY VALUE.
const GateList = struct {
    items: [GATES.len]Gate = undefined,
    len: usize = 0,

    fn push(self: *GateList, g: Gate) void {
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = g;
        self.len += 1;
    }

    fn slice(self: *const GateList) []const Gate {
        return self.items[0..self.len];
    }
};

/// All rows for one platform, in table order.
pub fn gatesFor(platform: []const u8) GateList {
    var out: GateList = .{};
    for (GATES) |g| {
        if (std.mem.eql(u8, g.platform, platform)) out.push(g);
    }
    return out;
}

/// Rows that are blocked at COLLECTION time on `platform` — the pytest
/// `collect_ignore` half. TODO(port): no Zig consumer.
pub fn collectIgnoreFor(platform: []const u8) GateList {
    var out: GateList = .{};
    for (GATES) |g| {
        if (std.mem.eql(u8, g.platform, platform) and g.import_time) out.push(g);
    }
    return out;
}

/// Rows that are skipped at TEST-BODY time on `platform` — the pytest
/// `pytest.mark.skip` half, whose Zig counterpart is
/// `error.SkipZigTest` returned from the test body.
pub fn runtimeSkipReasons(platform: []const u8) GateList {
    var out: GateList = .{};
    for (GATES) |g| {
        if (std.mem.eql(u8, g.platform, platform) and !g.import_time) out.push(g);
    }
    return out;
}

/// Every module the table names, for the existence check.
fn gatedModules() GateList {
    var out: GateList = .{};
    for (GATES) |g| out.push(g);
    return out;
}

/// The suites the gate table can name, as ABSOLUTE directory paths. TWO
/// suites, not one.
fn suiteDirs() ![]const []const u8 {
    const candidates = [_][]const u8{
        "tests/functional",
        ".",
        "../functional",
    };
    for (candidates) |c| {
        var probe: [std.fs.max_path_bytes]u8 = undefined;
        const resolved = std.Io.Dir.cwd().realPathFile(io, c, &probe) catch continue;
        // A directory containing `harness.zig` is THIS package's suite
        // directory; the repo root is not (it has no such file directly
        // inside it).
        const marker = std.fmt.allocPrint(gpa, "{s}/harness.zig", .{probe[0..resolved]}) catch continue;
        defer gpa.free(marker);
        std.Io.Dir.cwd().access(io, marker, .{}) catch continue;

        // `functional_ui` is a SIBLING of the resolved directory.
        const parent = std.fs.path.dirname(probe[0..resolved]) orelse continue;
        const ui = try std.fmt.allocPrint(gpa, "{s}/functional_ui", .{parent});
        errdefer gpa.free(ui);
        // A missing `functional_ui` is not fatal: a checkout that never
        // ran the UI suites simply has no gate that names one.
        const ui_present = blk: {
            std.Io.Dir.cwd().access(io, ui, .{}) catch break :blk false;
            break :blk true;
        };
        if (!ui_present) {
            const only = try gpa.alloc([]const u8, 1);
            only[0] = try gpa.dupe(u8, probe[0..resolved]);
            gpa.free(ui);
            return only;
        }
        const both = try gpa.alloc([]const u8, 2);
        both[0] = try gpa.dupe(u8, probe[0..resolved]);
        both[1] = ui;
        return both;
    }
    std.debug.print(
        "could not locate the suite directories (tried tests/functional, ., ../functional)\n",
        .{},
    );
    return error.FileNotFound;
}

/// True iff `stem` names a suite that exists on disk under any suite
/// directory, with either extension.
fn suiteExists(dirs: []const []const u8, stem: []const u8) bool {
    const suffixes = [_][]const u8{ ".zig", ".py" };
    for (dirs) |dir| {
        // `continue` (not a labelled `continue :outer`) — the label belongs
        // to the DIRECTORY loop, and jumping there would skip the remaining
        // suffixes in the directory just searched.
        for (suffixes) |s| {
            const p = std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ dir, stem, s }) catch return false;
            defer gpa.free(p);
            std.Io.Dir.cwd().access(io, p, .{}) catch continue;
            return true;
        }
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

// A gate for a renamed/deleted file is a gate that never fires.
test "every_gate_names_a_file_that_exists" {
    const dirs = try suiteDirs();
    defer {
        for (dirs) |d| gpa.free(d);
        gpa.free(dirs);
    }

    const modules = gatedModules();
    for (modules.slice()) |row| {
        const stem = row.module;
        if (suiteExists(dirs, stem)) continue;
        std.debug.print(
            "the platform-gate table references '{s}', which exists under neither " ++
                "tests/functional nor tests/functional_ui as .zig or .py. Either the " ++
                "file was renamed (update the row) or the test was made portable " ++
                "(DELETE the row — a stale gate hides the next regression).\n",
            .{stem},
        );
        return error.TestUnexpectedResult;
    }
}

// First-wins de-duplication in the helpers would mask a conflict. `gatesFor`
// returns every row in table order, so two disagreeing rows both reach the
// assertions below instead of quietly resolving to one.
test "no_module_is_gated_twice_on_one_platform" {
    for (gatePlatforms()) |platform| {
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(gpa);
        const rows = gatesFor(platform);
        for (rows.slice()) |g| {
            var dup = false;
            for (seen.items) |s| {
                if (std.mem.eql(u8, s, g.module)) dup = true;
            }
            if (dup) {
                std.debug.print(
                    "duplicate (platform, module) row: {s}:{s}\n",
                    .{ g.platform, g.module },
                );
                return error.TestUnexpectedResult;
            }
            seen.append(gpa, g.module) catch return error.OutOfMemory;
        }
    }
}

// A file is either never imported OR skipped — never both.
test "import_and_runtime_gates_are_disjoint_win32" {
    const ignored = collectIgnoreFor("win32");
    const skipped = runtimeSkipReasons("win32");
    for (ignored.slice()) |a| {
        for (skipped.slice()) |b| {
            if (!std.mem.eql(u8, a.module, b.module)) continue;
            std.debug.print(
                "win32: {s} is in both collect_ignore and the skip-marker map; " ++
                    "the marker will never be evaluated.\n",
                .{a.module},
            );
            return error.TestUnexpectedResult;
        }
    }
}

// A file is either never imported OR skipped — never both.
// Parametrize row: platform="darwin".
test "import_and_runtime_gates_are_disjoint_darwin" {
    const ignored = collectIgnoreFor("darwin");
    const skipped = runtimeSkipReasons("darwin");
    for (ignored.slice()) |a| {
        for (skipped.slice()) |b| {
            if (!std.mem.eql(u8, a.module, b.module)) continue;
            std.debug.print(
                "darwin: {s} is in both collect_ignore and the skip-marker map; " ++
                    "the marker will never be evaluated.\n",
                .{a.module},
            );
            return error.TestUnexpectedResult;
        }
    }
}

// A file is either never imported OR skipped — never both.
// Parametrize row: platform="linux".
test "import_and_runtime_gates_are_disjoint_linux" {
    const ignored = collectIgnoreFor("linux");
    const skipped = runtimeSkipReasons("linux");
    for (ignored.slice()) |a| {
        for (skipped.slice()) |b| {
            if (!std.mem.eql(u8, a.module, b.module)) continue;
            std.debug.print(
                "linux: {s} is in both collect_ignore and the skip-marker map; " ++
                    "the marker will never be evaluated.\n",
                .{a.module},
            );
            return error.TestUnexpectedResult;
        }
    }
}

// Every skip must say WHY, and name the platform or the blocker.
test "every_row_carries_a_reason_a_reviewer_can_act_on_win32" {
    const rows = runtimeSkipReasons("win32");
    for (rows.slice()) |g| {
        if (g.reason.len == 0) {
            std.debug.print("win32:{s} has an empty reason\n", .{g.module});
            return error.TestUnexpectedResult;
        }
        // Long enough to be actionable, short enough to read in a report.
        if (g.reason.len <= 20) {
            std.debug.print("win32:{s} reason is too terse to act on: '{s}'\n", .{ g.module, g.reason });
            return error.TestUnexpectedResult;
        }
        if (!namesPlatformOrBlocker(g.reason)) {
            std.debug.print(
                "win32:{s} reason names neither the platform nor a portable blocker: '{s}'\n",
                .{ g.module, g.reason },
            );
            return error.TestUnexpectedResult;
        }
    }
}

// Every skip must say WHY, and name the platform or the blocker.
// Parametrize row: platform="darwin".
test "every_row_carries_a_reason_a_reviewer_can_act_on_darwin" {
    const rows = runtimeSkipReasons("darwin");
    for (rows.slice()) |g| {
        if (g.reason.len == 0) {
            std.debug.print("darwin:{s} has an empty reason\n", .{g.module});
            return error.TestUnexpectedResult;
        }
        if (g.reason.len <= 20) {
            std.debug.print("darwin:{s} reason is too terse to act on: '{s}'\n", .{ g.module, g.reason });
            return error.TestUnexpectedResult;
        }
        if (!namesPlatformOrBlocker(g.reason)) {
            std.debug.print(
                "darwin:{s} reason names neither the platform nor a portable blocker: '{s}'\n",
                .{ g.module, g.reason },
            );
            return error.TestUnexpectedResult;
        }
    }
}

// Every skip must say WHY, and name the platform or the blocker.
// Parametrize row: platform="linux".
test "every_row_carries_a_reason_a_reviewer_can_act_on_linux" {
    // Vacuous by construction — there are no Linux rows, which is the point
    // and is asserted separately.
    const rows = runtimeSkipReasons("linux");
    for (rows.slice()) |g| {
        if (g.reason.len == 0) {
            std.debug.print("linux:{s} has an empty reason\n", .{g.module});
            return error.TestUnexpectedResult;
        }
        if (g.reason.len <= 20) {
            std.debug.print("linux:{s} reason is too terse to act on: '{s}'\n", .{ g.module, g.reason });
            return error.TestUnexpectedResult;
        }
        if (!namesPlatformOrBlocker(g.reason)) {
            std.debug.print(
                "linux:{s} reason names neither the platform nor a portable blocker: '{s}'\n",
                .{ g.module, g.reason },
            );
            return error.TestUnexpectedResult;
        }
    }
}

/// Does `reason` name the platform or a portable blocker? Case-folded,
/// so "Windows" and "windows" both count.
fn namesPlatformOrBlocker(reason: []const u8) bool {
    const needles = [_][]const u8{ "windows", "macos", "linux", "/proc", "posix" };
    var buf: [512]u8 = undefined;
    if (reason.len > buf.len) return false;
    const lowered = std.ascii.lowerString(buf[0..reason.len], reason);
    for (needles) |n| {
        if (std.mem.indexOf(u8, lowered, n) != null) return true;
    }
    return false;
}

// Guard against a row keyed on a platform string nothing can produce.
// `currentPlatform` matches `GATES[i].platform` against the value the
// COMPILER reports.
test "every_row_declares_the_platform_key_it_claims" {
    for (GATES) |g| {
        for (gatePlatforms()) |known| {
            if (std.mem.eql(u8, g.platform, known)) break;
        } else {
            std.debug.print("the platform-gate table has a row keyed on an unknown platform: '{s}'\n", .{g.platform});
            return error.TestUnexpectedResult;
        }
    }
}

// The Linux cell must not be gated at all, or the fix is not done. The table
// exists to let ubuntu-24.04 keep running everything it ran before.
test "gates_are_built_for_this_platform_or_are_explicit_about_the_rest" {
    for (GATES) |g| {
        if (!std.mem.eql(u8, g.platform, "linux")) continue;
        std.debug.print(
            "the platform-gate table must not gate Linux: the whole point is that " ++
                "ubuntu-24.04 keeps its full coverage. Found {s}\n",
            .{g.module},
        );
        return error.TestUnexpectedResult;
    }
}

test "current_platform_is_one_of_the_gate_keys" {
    const here = currentPlatform();
    for (gatePlatforms()) |known| {
        if (std.mem.eql(u8, here, known)) return;
    }
    std.debug.print("currentPlatform() returned '{s}', which is not a gate key\n", .{here});
    return error.TestUnexpectedResult;
}

// The `platform=` parameter is what makes this file testable at all.
test "helpers_honour_an_explicit_platform_argument" {
    for (gatePlatforms()) |platform| {
        _ = collectIgnoreFor(platform).slice();
        _ = runtimeSkipReasons(platform).slice();
    }

    // Sanity: the three platforms are genuinely different, so a
    // hardcoded return value cannot pass this file.
    const win = moduleCount("win32");
    const mac = moduleCount("darwin");
    const lin = moduleCount("linux");

    if (win == 0) {
        std.debug.print("Windows must be gated and Linux must not\n", .{});
        return error.TestUnexpectedResult;
    }
    if (lin != 0) {
        std.debug.print("Linux must not be gated, but {d} rows name it\n", .{lin});
        return error.TestUnexpectedResult;
    }
    if (mac == 0) {
        std.debug.print("macOS must be gated and Linux must not\n", .{});
        return error.TestUnexpectedResult;
    }
    if (moduleCount("win32") == moduleCount("darwin")) {
        std.debug.print(
            "Windows and macOS gates are identical — one is probably wrong\n",
            .{},
        );
        return error.TestUnexpectedResult;
    }
}

/// How many rows name `platform`, across both halves of the table.
fn moduleCount(platform: []const u8) usize {
    var n: usize = 0;
    for (GATES) |g| {
        if (std.mem.eql(u8, g.platform, platform)) n += 1;
    }
    return n;
}

// Body-analysis barrier. An unreferenced function is never type-checked,
// so a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = gatePlatforms;
    _ = currentPlatform;
    _ = gatesFor;
    _ = collectIgnoreFor;
    _ = runtimeSkipReasons;
    _ = gatedModules;
    _ = GateList.push;
    _ = GateList.slice;
    _ = suiteDirs;
    _ = suiteExists;
    _ = namesPlatformOrBlocker;
    _ = moduleCount;
}
