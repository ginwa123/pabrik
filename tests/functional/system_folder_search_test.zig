// Functional wire tests for GET /api/system/folder?action=search. Zig port of
// `tests/functional/system_folder_search_test.py` (same test names, same
// order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// Write `contents` to the absolute `path`, creating/truncating it.
fn writeFileAt(path: []const u8, contents: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

/// `mkdir -p` of `base/<parts[0..n-1]>` then a write of the last part.
fn writeFileIn(base: []const u8, parts: []const []const u8, contents: []const u8) !void {
    const dir = try harness.harnessPath(gpa, base, parts[0 .. parts.len - 1]);
    defer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const p = try std.fs.path.join(gpa, &.{ dir, parts[parts.len - 1] });
    defer gpa.free(p);
    try writeFileAt(p, contents);
}

/// Build the search fixture cwd inside `scratch`. Returns the owned cwd
/// path; the caller frees it and removes `scratch` via `cleanupExtraDir`.
fn buildSearchFixture(scratch: []const u8) ![]u8 {
    const cwd = try std.fs.path.join(gpa, &.{ scratch, "search-proj" });
    errdefer gpa.free(cwd);
    try std.Io.Dir.cwd().createDirPath(io, cwd);

    // Skip-listed dirs (must never appear in search results).
    const node_modules_big = try std.fs.path.join(gpa, &.{ cwd, "node_modules", "big" });
    defer gpa.free(node_modules_big);
    try std.Io.Dir.cwd().createDirPath(io, node_modules_big);
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const name = try std.fmt.allocPrint(gpa, "comp_shim_{d:0>2}.js", .{i});
        defer gpa.free(name);
        const body = try std.fmt.allocPrint(gpa, "// node_modules shim {d}\n", .{i});
        defer gpa.free(body);
        const p = try std.fs.path.join(gpa, &.{ node_modules_big, name });
        defer gpa.free(p);
        try writeFileAt(p, body);
    }

    const zig_out = try std.fs.path.join(gpa, &.{ cwd, "zig-out" });
    defer gpa.free(zig_out);
    try std.Io.Dir.cwd().createDirPath(io, zig_out);
    i = 0;
    while (i < 3) : (i += 1) {
        const name = try std.fmt.allocPrint(gpa, "comp_artifact_{d:0>2}.bin", .{i});
        defer gpa.free(name);
        const body = try std.fmt.allocPrint(gpa, "bin {d}", .{i});
        defer gpa.free(body);
        const p = try std.fs.path.join(gpa, &.{ zig_out, name });
        defer gpa.free(p);
        try writeFileAt(p, body);
    }

    // Real source tree — matches q=comp.
    const comp_dir = try std.fs.path.join(gpa, &.{ cwd, "src", "components" });
    defer gpa.free(comp_dir);
    try std.Io.Dir.cwd().createDirPath(io, comp_dir);
    for ([_][]const u8{ "Button.vue", "Modal.vue", "Composer.ts", "compare_util.ts" }) |name| {
        const body = try std.fmt.allocPrint(gpa, "// {s}\n", .{name});
        defer gpa.free(body);
        const p = try std.fs.path.join(gpa, &.{ comp_dir, name });
        defer gpa.free(p);
        try writeFileAt(p, body);
    }
    try writeFileIn(cwd, &.{ "src", "main.ts" }, "// main\n");

    // 300 generated files for the perf + cap assertions.
    const gen = try std.fs.path.join(gpa, &.{ cwd, "gen" });
    defer gpa.free(gen);
    try std.Io.Dir.cwd().createDirPath(io, gen);
    i = 0;
    while (i < 300) : (i += 1) {
        const name = try std.fmt.allocPrint(gpa, "file_{d:0>3}.txt", .{i});
        defer gpa.free(name);
        const body = try std.fmt.allocPrint(gpa, "generated {d}\n", .{i});
        defer gpa.free(body);
        const p = try std.fs.path.join(gpa, &.{ gen, name });
        defer gpa.free(p);
        try writeFileAt(p, body);
    }

    return cwd;
}

/// The owned outcome of one search request. `doc`'s arena holds every string
/// the `entries` array borrows, so a `Search` MUST stay alive for as long as
/// a caller reads `entries`.
const Search = struct {
    resp: harness.Response,
    doc: harness.Json,

    fn deinit(self: *Search) void {
        self.doc.deinit();
        self.resp.deinit();
    }

    /// The `entries` array, or a hard failure.
    fn entries(self: *Search) !std.json.Array {
        return self.doc.array("entries") orelse {
            std.debug.print("search response missing 'entries': {s}\n", .{self.resp.body});
            return error.TestUnexpectedResult;
        };
    }
};

/// `GET /api/system/folder?action=search&path=<cwd>&q=<q>&limit=<limit>`.
fn search(h: *Harness, cwd: []const u8, q: []const u8, limit: []const u8) !Search {
    var r = try h.http(io, .GET, "/api/system/folder", .{
        .params = &.{
            .{ .name = "action", .value = "search" },
            .{ .name = "path", .value = cwd },
            .{ .name = "q", .value = q },
            .{ .name = "limit", .value = limit },
        },
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    const doc = r.json() catch |err| {
        r.deinit();
        return err;
    };
    return .{ .resp = r, .doc = doc };
}

/// The `path` of every row, copied into owned strings. The caller frees
/// each element and then the slice via `freeRowPaths`.
fn rowPaths(entries: std.json.Array) ![][]u8 {
    const out = try gpa.alloc([]u8, entries.items.len);
    errdefer gpa.free(out);
    for (entries.items, 0..) |row, i| {
        const obj = switch (row) {
            .object => |o| o,
            else => {
                gpa.free(out);
                std.debug.print("search row is not an object\n", .{});
                return error.TestUnexpectedResult;
            },
        };
        const p = switch (obj.get("path") orelse {
            gpa.free(out);
            std.debug.print("search row missing `path`\n", .{});
            return error.TestUnexpectedResult;
        }) {
            .string => |s| s,
            else => {
                gpa.free(out);
                std.debug.print("search row `path` is not a string\n", .{});
                return error.TestUnexpectedResult;
            },
        };
        out[i] = try gpa.dupe(u8, p);
    }
    return out;
}

fn freeRowPaths(paths: [][]u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

/// Does the entry array carry an entry named exactly `name`?
fn hasName(entries: std.json.Array, name: []const u8) bool {
    for (entries.items) |row| {
        const obj = switch (row) {
            .object => |o| o,
            else => continue,
        };
        const n = switch (obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Boot a harness plus the search fixture, cleaned up on the way out. The
/// fixture is built BEFORE the harness so that a failure in either step can
/// unwind the other's allocation without an `undefined` defer.
fn bootWithFixture(h: *Harness, scratch: *[]u8, cwd: *[]u8) !void {
    try harness.requirePabrikBin(io, gpa);
    scratch.* = try harness.makeScratchDir(gpa);
    cwd.* = buildSearchFixture(scratch.*) catch |err| {
        harness.cleanupExtraDir(io, gpa, scratch.*);
        gpa.free(scratch.*);
        return err;
    };
    h.* = Harness.boot(io, gpa, .{}) catch |err| {
        harness.cleanupExtraDir(io, gpa, scratch.*);
        gpa.free(cwd.*);
        gpa.free(scratch.*);
        return err;
    };
}

// q=comp&limit=50: <=50 rows, hits components/, no node_modules paths.
test "search_comp_returns_components_excludes_node_modules" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var cwd: []u8 = undefined;
    try bootWithFixture(&h, &scratch, &cwd);

    // DEFER ORDER IS LIFO AND LOADS-BEARING. Each `defer` below READS a
    // buffer the one registered after it must still own, so every
    // `free` is registered BEFORE the reader of it.
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer gpa.free(cwd);
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var s = try search(&h, cwd, "comp", "50");
    defer s.deinit();

    const entries = try s.entries();
    if (entries.items.len > 50) {
        std.debug.print("expected <=50 rows, got {d}\n", .{entries.items.len});
        return error.TestUnexpectedResult;
    }

    const paths = try rowPaths(entries);
    defer freeRowPaths(paths);

    var saw_components = false;
    for (paths) |p| {
        if (std.mem.indexOf(u8, p, "components") != null) saw_components = true;
    }
    if (!saw_components) {
        // Python printed `paths[:5]`; guard the empty case here — with
        // zero rows `paths[0]` is out of bounds and would turn a
        // readable assertion failure into an index panic.
        const first = if (paths.len > 0) paths[0] else "<no rows>";
        std.debug.print("expected a components hit in {d} rows, first = {s}\n", .{ paths.len, first });
        return error.TestUnexpectedResult;
    }
    for (paths) |p| {
        if (std.mem.indexOf(u8, p, "node_modules") != null) {
            std.debug.print("skip-list violated, node_modules leaked: {s}\n", .{p});
            return error.TestUnexpectedResult;
        }
    }
    for (paths) |p| {
        if (std.mem.indexOf(u8, p, "zig-out") != null) {
            std.debug.print("skip-list violated, zig-out leaked: {s}\n", .{p});
            return error.TestUnexpectedResult;
        }
    }

    // Wire shape guard: snake_case fields on every row. `is_directory`
    // must be PRESENT (not merely falsy) — an absent key fails.
    for (entries.items) |row| {
        const obj = switch (row) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        if (obj.get("is_directory") == null or obj.get("name") == null or obj.get("path") == null) {
            std.debug.print("search row missing is_directory/name/path\n", .{});
            return error.TestUnexpectedResult;
        }
    }
}

// Empty q returns <=50 (top-N), not the whole ~312-file tree.
test "search_empty_q_returns_top_n_not_whole_tree" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var cwd: []u8 = undefined;
    try bootWithFixture(&h, &scratch, &cwd);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer gpa.free(cwd);
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var s = try search(&h, cwd, "", "50");
    defer s.deinit();

    const n = (try s.entries()).items.len;
    if (n > 50) {
        std.debug.print("empty q must return top-N (<=50), got {d} — whole tree leaked\n", .{n});
        return error.TestUnexpectedResult;
    }
    if (n == 0) {
        std.debug.print("empty q returned zero rows, expected top-N\n", .{});
        return error.TestUnexpectedResult;
    }
}

// limit=5000 clamps to the hard cap (<=200 rows).
test "search_limit_clamps_to_200" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var cwd: []u8 = undefined;
    try bootWithFixture(&h, &scratch, &cwd);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer gpa.free(cwd);
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var s = try search(&h, cwd, "", "5000");
    defer s.deinit();

    const n = (try s.entries()).items.len;
    if (n > 200) {
        std.debug.print("limit=5000 must clamp to <=200, got {d}\n", .{n});
        return error.TestUnexpectedResult;
    }
}

// action=list still returns the single-level {entries:[...]} contract.
test "list_single_level_contract_unchanged" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var cwd: []u8 = undefined;
    try bootWithFixture(&h, &scratch, &cwd);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer gpa.free(cwd);
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/system/folder", .{
        .params = &.{
            .{ .name = "action", .value = "list" },
            .{ .name = "path", .value = cwd },
        },
        .expect = &.{200},
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    const entries = doc.array("entries") orelse {
        std.debug.print("list response missing 'entries': {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };

    // Single level: top-level dirs only, no nested gen/file_000.txt rows.
    if (!hasName(entries, "src")) {
        std.debug.print("expected 'src' in top-level list\n", .{});
        return error.TestUnexpectedResult;
    }
    if (!hasName(entries, "gen")) {
        std.debug.print("expected 'gen' in top-level list\n", .{});
        return error.TestUnexpectedResult;
    }
    if (!hasName(entries, "node_modules")) {
        std.debug.print("list must NOT apply the search skip-list\n", .{});
        return error.TestUnexpectedResult;
    }
    for (entries.items) |row| {
        const obj = switch (row) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const n = switch (obj.get("name") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        if (std.mem.indexOf(u8, n, "file_000") != null) {
            std.debug.print("list must be single-level — nested gen/ rows leaked: {s}\n", .{n});
            return error.TestUnexpectedResult;
        }
        if (obj.get("is_directory") == null) {
            std.debug.print("list row missing is_directory\n", .{});
            return error.TestUnexpectedResult;
        }
    }
}

// Search over the 300-file fixture completes <5s; actual ms logged.
test "search_perf_300_files_under_5s" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var cwd: []u8 = undefined;
    try bootWithFixture(&h, &scratch, &cwd);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer gpa.free(cwd);
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // `.awake` is the MONOTONIC clock — Python's `time.monotonic`. A
    // wall-clock step backwards (NTP) would otherwise read as a
    // negative elapsed time and pass a budget it actually blew.
    const start = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    var s = try search(&h, cwd, "file_", "50");
    defer s.deinit();
    const n = (try s.entries()).items.len;
    const elapsed_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - start;

    std.debug.print(
        "[perf] search q=file_ limit=50 over 300-file fixture: {d}ms, {d} rows\n",
        .{ elapsed_ms, n },
    );

    if (elapsed_ms >= 5_000) {
        std.debug.print("search took {d}ms, exceeds 5s budget\n", .{elapsed_ms});
        return error.TestUnexpectedResult;
    }
    if (n == 0) {
        std.debug.print("expected hits for q=file_ on the gen/ fixture\n", .{});
        return error.TestUnexpectedResult;
    }
}
