//! The baseline ratchet: per-file violation ceilings that may only fall.
//! A file above its ceiling, or missing from the pin, fails; a count that
//! fell is printed as a re-pin notice. See CODING_STANDARDS.md §4.

const std = @import("std");
const io_util = @import("io_util.zig");
const max_comment_lines_rule = @import("rules/max_comment_lines.zig");

pub const default_file_name = "zginlint-baseline.json";

/// One pinned file ceiling.
pub const Entry = struct {
    path: []const u8,
    count: u32,
};

/// A file's count today, which is what the ratchet compares.
pub const FileCount = struct {
    path: []const u8,
    count: u32,
};

/// A pinned file that got worse, or a file that was never pinned.
pub const Regression = struct {
    path: []const u8,
    count: u32,
    allowed: u32,
};

/// A pinned file whose count fell, so its ceiling can be lowered.
pub const Shrink = struct {
    path: []const u8,
    count: u32,
    allowed: u32,
};

/// The pinned ceilings and the measurement they were taken with. Only a
/// `Baseline` returned by `load` owns its strings; the rest are views.
pub const Baseline = struct {
    rule: []const u8 = max_comment_lines_rule.id,
    max_comment_lines: u32 = max_comment_lines_rule.default_max_lines,
    /// The path arguments the counts were taken over. A check that stopped
    /// covering one of them would otherwise report a smaller tree clean.
    paths: []const []const u8 = &.{},
    files: []const Entry = &.{},

    pub fn deinit(self: *Baseline, allocator: std.mem.Allocator) void {
        for (self.paths) |path| allocator.free(path);
        allocator.free(self.paths);
        for (self.files) |entry| allocator.free(entry.path);
        allocator.free(self.files);
        self.* = .{};
    }

    pub fn countFor(self: *const Baseline, path: []const u8) ?u32 {
        for (self.files) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry.count;
        }
        return null;
    }

    pub fn totalCount(self: *const Baseline) u32 {
        var total: u32 = 0;
        for (self.files) |entry| total += entry.count;
        return total;
    }

    /// True when `paths` is the set the counts were pinned over, in the same
    /// order — order is part of it, because the report is sorted by path.
    pub fn pinnedOver(self: *const Baseline, paths: []const []const u8) bool {
        if (self.paths.len != paths.len) return false;
        for (self.paths, paths) |pinned, given| {
            if (!std.mem.eql(u8, pinned, given)) return false;
        }
        return true;
    }
};

/// The outcome of checking today's counts against the pinned ones.
pub const Comparison = struct {
    regressions: []Regression,
    shrinks: []Shrink,
    total_count: u32,
    total_allowed: u32,

    pub fn deinit(self: *Comparison, allocator: std.mem.Allocator) void {
        freePaths(Regression, allocator, self.regressions);
        freePaths(Shrink, allocator, self.shrinks);
        self.* = .{ .regressions = &.{}, .shrinks = &.{}, .total_count = 0, .total_allowed = 0 };
    }

    pub fn clean(self: *const Comparison) bool {
        return self.regressions.len == 0;
    }
};

/// The on-disk shape. `load` validates the rule, so a baseline pinned by
/// another linter is refused rather than compared against the wrong numbers.
const Document = struct {
    rule: []const u8 = max_comment_lines_rule.id,
    max_comment_lines: u32 = max_comment_lines_rule.default_max_lines,
    paths: []const []const u8 = &.{},
    files: []const Entry = &.{},
};

/// Read a baseline. Errors are the caller's to report: a missing or
/// unreadable baseline must never be treated as "nothing is pinned".
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Baseline {
    const bytes = try io_util.readFileAlloc(allocator, io, path);
    defer allocator.free(bytes);
    var document = try std.json.parseFromSlice(Document, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer document.deinit();
    if (!std.mem.eql(u8, document.value.rule, max_comment_lines_rule.id)) return error.ForeignBaseline;

    var pinned: Baseline = .{ .max_comment_lines = document.value.max_comment_lines };
    errdefer pinned.deinit(allocator);
    pinned.paths = try dupeStrings(allocator, document.value.paths);
    pinned.files = try dupeEntries(allocator, document.value.files);
    return pinned;
}

/// Write today's counts as the new ceilings, sorted by path so a re-pin
/// shows up as a small diff rather than a reshuffle.
pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    max_lines: u32,
    paths: []const []const u8,
    counts: []const FileCount,
) !void {
    const sorted = try allocator.dupe(FileCount, counts);
    defer allocator.free(sorted);
    std.mem.sort(FileCount, sorted, {}, byCountPath);

    const entries = try allocator.alloc(Entry, sorted.len);
    defer allocator.free(entries);
    for (sorted, entries) |count, *entry| entry.* = .{ .path = count.path, .count = count.count };

    const body = try std.json.Stringify.valueAlloc(allocator, Document{
        .max_comment_lines = max_lines,
        .paths = paths,
        .files = entries,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(body);
    const text = try std.fmt.allocPrint(allocator, "{s}\n", .{body});
    defer allocator.free(text);
    try io_util.writeFile(io, path, text);
}

/// Check today's counts against the pinned ceilings. Files with no findings
/// are absent from `current`, so a pinned entry missing there has come down
/// to zero and is reported for re-pinning.
pub fn compare(
    allocator: std.mem.Allocator,
    current: []const FileCount,
    pinned: *const Baseline,
) !Comparison {
    var regressions: std.ArrayList(Regression) = .empty;
    errdefer freePaths(Regression, allocator, regressions.items);
    var shrinks: std.ArrayList(Shrink) = .empty;
    errdefer freePaths(Shrink, allocator, shrinks.items);

    var total_count: u32 = 0;
    for (current) |file| {
        total_count += file.count;
        const allowed = pinned.countFor(file.path) orelse 0;
        if (file.count > allowed) {
            try appendOwned(Regression, allocator, &regressions, .{
                .path = file.path,
                .count = file.count,
                .allowed = allowed,
            });
        } else if (file.count < allowed) {
            try appendOwned(Shrink, allocator, &shrinks, .{
                .path = file.path,
                .count = file.count,
                .allowed = allowed,
            });
        }
    }
    for (pinned.files) |entry| {
        if (containsPath(current, entry.path)) continue;
        try appendOwned(Shrink, allocator, &shrinks, .{
            .path = entry.path,
            .count = 0,
            .allowed = entry.count,
        });
    }

    return .{
        .regressions = try regressions.toOwnedSlice(allocator),
        .shrinks = try shrinks.toOwnedSlice(allocator),
        .total_count = total_count,
        .total_allowed = pinned.totalCount(),
    };
}

fn appendOwned(
    comptime T: type,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(T),
    item: anytype,
) !void {
    const owned: T = .{
        .path = try allocator.dupe(u8, item.path),
        .count = item.count,
        .allowed = item.allowed,
    };
    errdefer allocator.free(owned.path);
    try list.append(allocator, owned);
}

fn freePaths(comptime T: type, allocator: std.mem.Allocator, items: []T) void {
    for (items) |item| allocator.free(item.path);
    allocator.free(items);
}

fn dupeStrings(allocator: std.mem.Allocator, strings: []const []const u8) ![][]const u8 {
    const owned = try allocator.alloc([]const u8, strings.len);
    var done: usize = 0;
    errdefer {
        for (owned[0..done]) |string| allocator.free(string);
        allocator.free(owned);
    }
    for (strings, 0..) |string, index| {
        owned[index] = try allocator.dupe(u8, string);
        done = index + 1;
    }
    return owned;
}

fn dupeEntries(allocator: std.mem.Allocator, entries: []const Entry) ![]Entry {
    const owned = try allocator.alloc(Entry, entries.len);
    var done: usize = 0;
    errdefer {
        for (owned[0..done]) |entry| allocator.free(entry.path);
        allocator.free(owned);
    }
    for (entries, 0..) |entry, index| {
        owned[index] = .{ .path = try allocator.dupe(u8, entry.path), .count = entry.count };
        done = index + 1;
    }
    return owned;
}

fn containsPath(counts: []const FileCount, path: []const u8) bool {
    for (counts) |count| {
        if (std.mem.eql(u8, count.path, path)) return true;
    }
    return false;
}

fn byCountPath(_: void, left: FileCount, right: FileCount) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}

const testing = std.testing;

fn pinPathOf(tmp: *testing.TmpDir, allocator: std.mem.Allocator) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{
        buffer[0..try tmp.dir.realPath(testing.io, &buffer)],
        default_file_name,
    });
}

const one_file = [_]Entry{.{ .path = "src/a.zig", .count = 4 }};
const two_files = [_]Entry{
    .{ .path = "src/a.zig", .count = 4 },
    .{ .path = "src/b.zig", .count = 1 },
};

test "baseline: save then load round-trips the ceilings" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try pinPathOf(&tmp, testing.allocator);
    defer testing.allocator.free(path);

    const counts = [_]FileCount{
        .{ .path = "src/b.zig", .count = 2 },
        .{ .path = "src/a.zig", .count = 5 },
    };
    try save(testing.allocator, testing.io, path, 3, &.{ "src", "tests" }, &counts);

    var pinned = try load(testing.allocator, testing.io, path);
    defer pinned.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), pinned.max_comment_lines);
    try testing.expect(pinned.pinnedOver(&.{ "src", "tests" }));
    try testing.expectEqual(@as(u32, 5), pinned.countFor("src/a.zig").?);
    try testing.expectEqual(@as(u32, 2), pinned.countFor("src/b.zig").?);
    try testing.expectEqual(@as(u32, 7), pinned.totalCount());
    try testing.expect(pinned.countFor("src/missing.zig") == null);
}

test "baseline: save writes the entries sorted by path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try pinPathOf(&tmp, testing.allocator);
    defer testing.allocator.free(path);

    const counts = [_]FileCount{
        .{ .path = "src/b.zig", .count = 2 },
        .{ .path = "src/a.zig", .count = 5 },
    };
    try save(testing.allocator, testing.io, path, 3, &.{"src"}, &counts);

    var pinned = try load(testing.allocator, testing.io, path);
    defer pinned.deinit(testing.allocator);
    try testing.expectEqualStrings("src/a.zig", pinned.files[0].path);
    try testing.expectEqualStrings("src/b.zig", pinned.files[1].path);
}

test "baseline: a baseline pinned by another rule is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try pinPathOf(&tmp, testing.allocator);
    defer testing.allocator.free(path);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = default_file_name,
        .data = "{\"rule\":\"zginlint/other\",\"max_comment_lines\":3,\"paths\":[],\"files\":[]}\n",
    });

    const loaded = load(testing.allocator, testing.io, path);
    try testing.expectError(error.ForeignBaseline, loaded);
}

test "baseline: a missing baseline is an error, not an empty one" {
    const loaded = load(testing.allocator, testing.io, "no/such/zginlint-baseline.json");
    try testing.expectError(error.FileNotFound, loaded);
}

test "baseline: a file that is not pinned at all is a regression" {
    const pinned: Baseline = .{ .paths = &.{"src"} };
    const counts = [_]FileCount{.{ .path = "src/new.zig", .count = 1 }};

    var comparison = try compare(testing.allocator, &counts, &pinned);
    defer comparison.deinit(testing.allocator);
    try testing.expect(!comparison.clean());
    try testing.expectEqual(@as(usize, 1), comparison.regressions.len);
    try testing.expectEqualStrings("src/new.zig", comparison.regressions[0].path);
    try testing.expectEqual(@as(u32, 0), comparison.regressions[0].allowed);
    try testing.expectEqual(@as(u32, 1), comparison.total_count);
}

test "baseline: a file above its ceiling is a regression, at the ceiling it is not" {
    const pinned: Baseline = .{ .paths = &.{"src"}, .files = &one_file };

    const worse = [_]FileCount{.{ .path = "src/a.zig", .count = 5 }};
    var over = try compare(testing.allocator, &worse, &pinned);
    defer over.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), over.regressions.len);
    try testing.expectEqual(@as(u32, 4), over.regressions[0].allowed);

    const same = [_]FileCount{.{ .path = "src/a.zig", .count = 4 }};
    var equal = try compare(testing.allocator, &same, &pinned);
    defer equal.deinit(testing.allocator);
    try testing.expect(equal.clean());
    try testing.expectEqual(@as(usize, 0), equal.shrinks.len);
}

test "baseline: a count that fell is a shrink with the value to re-pin" {
    const pinned: Baseline = .{ .paths = &.{"src"}, .files = &one_file };
    const counts = [_]FileCount{.{ .path = "src/a.zig", .count = 2 }};

    var comparison = try compare(testing.allocator, &counts, &pinned);
    defer comparison.deinit(testing.allocator);
    try testing.expect(comparison.clean());
    try testing.expectEqual(@as(usize, 1), comparison.shrinks.len);
    try testing.expectEqual(@as(u32, 2), comparison.shrinks[0].count);
    try testing.expectEqual(@as(u32, 4), comparison.shrinks[0].allowed);
}

test "baseline: a pinned file with no findings left is a shrink to zero" {
    const pinned: Baseline = .{ .paths = &.{"src"}, .files = &one_file };
    const counts = [_]FileCount{.{ .path = "src/other.zig", .count = 1 }};

    var comparison = try compare(testing.allocator, &counts, &pinned);
    defer comparison.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), comparison.regressions.len);
    try testing.expectEqual(@as(usize, 1), comparison.shrinks.len);
    try testing.expectEqualStrings("src/a.zig", comparison.shrinks[0].path);
    try testing.expectEqual(@as(u32, 0), comparison.shrinks[0].count);
}

test "baseline: the comparison totals both sides" {
    const pinned: Baseline = .{ .paths = &.{"src"}, .files = &two_files };
    const counts = [_]FileCount{.{ .path = "src/a.zig", .count = 6 }};

    var comparison = try compare(testing.allocator, &counts, &pinned);
    defer comparison.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 6), comparison.total_count);
    try testing.expectEqual(@as(u32, 5), comparison.total_allowed);
}

test "baseline: pinnedOver compares the path set and its order" {
    const pinned: Baseline = .{ .paths = &.{ "src", "tests" } };
    try testing.expect(pinned.pinnedOver(&.{ "src", "tests" }));
    try testing.expect(!pinned.pinnedOver(&.{"src"}));
    try testing.expect(!pinned.pinnedOver(&.{ "tests", "src" }));
}
