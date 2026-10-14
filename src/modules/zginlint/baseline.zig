//! The baseline ratchet: per-file violation ceilings that may only fall.
//! A file above its ceiling, or missing from the pin, fails; a count that
//! fell is printed as a re-pin notice. See CODING_STANDARDS.md §4.

const std = @import("std");
const io_util = @import("io_util.zig");
const zginlint = @import("zginlint.zig");

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

/// What one rule found today, per file. Files with no findings are absent.
pub const RuleCounts = struct {
    rule_id: []const u8,
    files: []const FileCount,
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

/// One rule's pinned ceilings and the options it was measured with.
pub const RulePin = struct {
    rule_id: []const u8,
    fingerprint: []const u8,
    files: []const Entry = &.{},
};

/// The pin: which paths were scanned, and one entry per rule.
pub const Baseline = struct {
    /// The path arguments the counts were taken over. A check that stopped
    /// covering one of them would otherwise report a smaller tree clean.
    paths: []const []const u8 = &.{},
    rules: []const RulePin = &.{},

    pub fn deinit(self: *Baseline, allocator: std.mem.Allocator) void {
        for (self.paths) |path| allocator.free(path);
        allocator.free(self.paths);
        for (self.rules) |pin| {
            allocator.free(pin.rule_id);
            allocator.free(pin.fingerprint);
            for (pin.files) |entry| allocator.free(entry.path);
            allocator.free(pin.files);
        }
        allocator.free(self.rules);
        self.* = .{};
    }

    /// The options a rule was pinned with, or null when the pin predates it.
    /// A rule with no pin entry has a ceiling of zero, which is the reading
    /// that fails closed on a finding rather than hiding it.
    pub fn fingerprintFor(self: *const Baseline, rule_id: []const u8) ?[]const u8 {
        for (self.rules) |pin| {
            if (std.mem.eql(u8, pin.rule_id, rule_id)) return pin.fingerprint;
        }
        return null;
    }

    /// The pinned ceilings of one rule; empty when it is not pinned at all.
    pub fn filesFor(self: *const Baseline, rule_id: []const u8) []const Entry {
        for (self.rules) |pin| {
            if (std.mem.eql(u8, pin.rule_id, rule_id)) return pin.files;
        }
        return &.{};
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

    pub fn totalCount(self: *const Baseline) u32 {
        var total: u32 = 0;
        for (self.rules) |pin| {
            for (pin.files) |entry| total += entry.count;
        }
        return total;
    }
};

/// One rule's verdict: what regressed, what came down, and the totals.
pub const RuleComparison = struct {
    rule_id: []const u8,
    regressions: []Regression,
    shrinks: []Shrink,
    total_count: u32,
    total_allowed: u32,
};

/// Every rule's verdict, in the order the rules were checked.
pub const Comparison = struct {
    rules: []RuleComparison,

    pub fn clean(self: *const Comparison) bool {
        for (self.rules) |rule| {
            if (rule.regressions.len > 0) return false;
        }
        return true;
    }

    pub fn regressionCount(self: *const Comparison) usize {
        var total: usize = 0;
        for (self.rules) |rule| total += rule.regressions.len;
        return total;
    }

    pub fn totalCount(self: *const Comparison) u32 {
        var total: u32 = 0;
        for (self.rules) |rule| total += rule.total_count;
        return total;
    }

    pub fn totalAllowed(self: *const Comparison) u32 {
        var total: u32 = 0;
        for (self.rules) |rule| total += rule.total_allowed;
        return total;
    }

    pub fn deinit(self: *Comparison, allocator: std.mem.Allocator) void {
        for (self.rules) |rule| {
            freePaths(Regression, allocator, rule.regressions);
            freePaths(Shrink, allocator, rule.shrinks);
        }
        allocator.free(self.rules);
        self.* = .{ .rules = &.{} };
    }
};

/// The on-disk shape. `rule` and `fingerprint` are required, so a pin that
/// cannot say what it measured fails to parse instead of being compared.
const Document = struct {
    paths: []const []const u8,
    rules: []const RuleEntry,
};

/// `rule` and `fingerprint` are required, so a pin that cannot say what it
/// measured fails to parse rather than being compared. A pin whose `rules`
/// key is missing or misspelled is the same failure.
const RuleEntry = struct {
    rule: []const u8,
    fingerprint: []const u8,
    files: []const Entry = &.{},
};

/// Read a pin. Errors are the caller's to report: a missing or unreadable
/// pin must never be treated as "nothing is pinned".
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Baseline {
    const bytes = try io_util.readFileAlloc(allocator, io, path);
    defer allocator.free(bytes);
    var document = try std.json.parseFromSlice(Document, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer document.deinit();

    var pinned: Baseline = .{};
    errdefer pinned.deinit(allocator);
    pinned.paths = try dupeStrings(allocator, document.value.paths);
    pinned.rules = try dupeRules(allocator, document.value.rules);
    return pinned;
}

/// Write today's counts as the new ceilings: paths once, then one entry per
/// rule with its fingerprint, its files sorted by path so a re-pin reads as
/// a small diff rather than a reshuffle.
pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    paths: []const []const u8,
    counts: []const RuleCounts,
    prints: []const zginlint.Fingerprint,
) !void {
    const entries = try allocator.alloc(RuleEntry, counts.len);
    defer allocator.free(entries);
    var done: usize = 0;
    defer {
        for (entries[0..done]) |entry| allocator.free(entry.files);
    }
    for (counts, 0..) |rule_counts, index| {
        const files = try allocator.alloc(Entry, rule_counts.files.len);
        for (rule_counts.files, files) |count, *entry| {
            entry.* = .{ .path = count.path, .count = count.count };
        }
        std.mem.sort(Entry, files, {}, byEntryPath);
        entries[index] = .{
            .rule = rule_counts.rule_id,
            .fingerprint = fingerprintFor(prints, rule_counts.rule_id) orelse "-",
            .files = files,
        };
        done = index + 1;
    }

    const body = try std.json.Stringify.valueAlloc(allocator, Document{
        .paths = paths,
        .rules = entries,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(body);
    const text = try std.fmt.allocPrint(allocator, "{s}\n", .{body});
    defer allocator.free(text);
    try io_util.writeFile(io, path, text);
}

/// Check today's counts against the pinned ceilings, one verdict per rule.
pub fn compare(
    allocator: std.mem.Allocator,
    counts: []const RuleCounts,
    pinned: *const Baseline,
) !Comparison {
    const rules = try allocator.alloc(RuleComparison, counts.len);
    var done: usize = 0;
    errdefer {
        for (rules[0..done]) |rule| {
            freePaths(Regression, allocator, rule.regressions);
            freePaths(Shrink, allocator, rule.shrinks);
        }
        allocator.free(rules);
    }
    for (counts, 0..) |rule_counts, index| {
        rules[index] = try compareRule(allocator, rule_counts, pinned.filesFor(rule_counts.rule_id));
        done = index + 1;
    }
    return .{ .rules = rules };
}

fn compareRule(
    allocator: std.mem.Allocator,
    counts: RuleCounts,
    pinned: []const Entry,
) !RuleComparison {
    var regressions: std.ArrayList(Regression) = .empty;
    errdefer freePaths(Regression, allocator, regressions.items);
    var shrinks: std.ArrayList(Shrink) = .empty;
    errdefer freePaths(Shrink, allocator, shrinks.items);

    var total_count: u32 = 0;
    for (counts.files) |file| {
        total_count += file.count;
        const allowed = countFor(pinned, file.path) orelse 0;
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
    for (pinned) |entry| {
        if (containsPath(counts.files, entry.path)) continue;
        try appendOwned(Shrink, allocator, &shrinks, .{
            .path = entry.path,
            .count = 0,
            .allowed = entry.count,
        });
    }

    var total_allowed: u32 = 0;
    for (pinned) |entry| total_allowed += entry.count;

    return .{
        .rule_id = counts.rule_id,
        .regressions = try regressions.toOwnedSlice(allocator),
        .shrinks = try shrinks.toOwnedSlice(allocator),
        .total_count = total_count,
        .total_allowed = total_allowed,
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

fn countFor(entries: []const Entry, path: []const u8) ?u32 {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry.count;
    }
    return null;
}

fn containsPath(counts: []const FileCount, path: []const u8) bool {
    for (counts) |count| {
        if (std.mem.eql(u8, count.path, path)) return true;
    }
    return false;
}

fn fingerprintFor(prints: []const zginlint.Fingerprint, rule_id: []const u8) ?[]const u8 {
    for (prints) |print| {
        if (std.mem.eql(u8, print.rule_id, rule_id)) return print.text;
    }
    return null;
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

fn dupeRules(allocator: std.mem.Allocator, rules: []const RuleEntry) ![]RulePin {
    const owned = try allocator.alloc(RulePin, rules.len);
    var done: usize = 0;
    errdefer {
        for (owned[0..done]) |pin| freePin(allocator, pin);
        allocator.free(owned);
    }
    for (rules, 0..) |entry, index| {
        owned[index] = .{
            .rule_id = try allocator.dupe(u8, entry.rule),
            .fingerprint = try allocator.dupe(u8, entry.fingerprint),
            .files = try dupeEntries(allocator, entry.files),
        };
        done = index + 1;
    }
    return owned;
}

fn freePin(allocator: std.mem.Allocator, pin: RulePin) void {
    allocator.free(pin.rule_id);
    allocator.free(pin.fingerprint);
    for (pin.files) |entry| allocator.free(entry.path);
    allocator.free(pin.files);
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

fn byEntryPath(_: void, left: Entry, right: Entry) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}

const testing = std.testing;

const comment_rule = "zginlint/max-comment-lines";
const scan_rule = "zginlint/no-catch-unreachable";

fn pinPathOf(tmp: *testing.TmpDir, allocator: std.mem.Allocator) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{
        buffer[0..try tmp.dir.realPath(testing.io, &buffer)],
        default_file_name,
    });
}

fn fingerprintsFor(allocator: std.mem.Allocator, max_lines: u32) ![]zginlint.Fingerprint {
    const prints = try allocator.alloc(zginlint.Fingerprint, 2);
    prints[0] = .{ .rule_id = comment_rule, .text = try std.fmt.allocPrint(allocator, "max={d}", .{max_lines}) };
    prints[1] = .{ .rule_id = scan_rule, .text = try allocator.dupe(u8, "-") };
    return prints;
}

test "baseline: save then load round-trips both rules" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try pinPathOf(&tmp, testing.allocator);
    defer testing.allocator.free(path);

    const comment_files = [_]FileCount{
        .{ .path = "src/b.zig", .count = 2 },
        .{ .path = "src/a.zig", .count = 5 },
    };
    const counts = [_]RuleCounts{
        .{ .rule_id = comment_rule, .files = &comment_files },
        .{ .rule_id = scan_rule, .files = &.{} },
    };
    const prints = try fingerprintsFor(testing.allocator, 3);
    defer {
        testing.allocator.free(prints[0].text);
        testing.allocator.free(prints[1].text);
        testing.allocator.free(prints);
    }
    try save(testing.allocator, testing.io, path, &.{ "src", "tests" }, &counts, prints);

    var pinned = try load(testing.allocator, testing.io, path);
    defer pinned.deinit(testing.allocator);
    try testing.expect(pinned.pinnedOver(&.{ "src", "tests" }));
    try testing.expectEqual(@as(usize, 2), pinned.rules.len);
    try testing.expectEqualStrings("max=3", pinned.fingerprintFor(comment_rule).?);
    try testing.expectEqualStrings("-", pinned.fingerprintFor(scan_rule).?);
    try testing.expectEqual(@as(u32, 5), countFor(pinned.filesFor(comment_rule), "src/a.zig").?);
    try testing.expectEqual(@as(usize, 0), pinned.filesFor(scan_rule).len);
    try testing.expectEqual(@as(u32, 7), pinned.totalCount());
    try testing.expect(pinned.fingerprintFor("zginlint/missing") == null);
}

test "baseline: save writes each rule's entries sorted by path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try pinPathOf(&tmp, testing.allocator);
    defer testing.allocator.free(path);

    const files = [_]FileCount{
        .{ .path = "src/b.zig", .count = 2 },
        .{ .path = "src/a.zig", .count = 5 },
    };
    const counts = [_]RuleCounts{.{ .rule_id = comment_rule, .files = &files }};
    const prints = try fingerprintsFor(testing.allocator, 3);
    defer {
        testing.allocator.free(prints[0].text);
        testing.allocator.free(prints[1].text);
        testing.allocator.free(prints);
    }
    try save(testing.allocator, testing.io, path, &.{"src"}, &counts, prints);

    var pinned = try load(testing.allocator, testing.io, path);
    defer pinned.deinit(testing.allocator);
    const entries = pinned.filesFor(comment_rule);
    try testing.expectEqualStrings("src/a.zig", entries[0].path);
    try testing.expectEqualStrings("src/b.zig", entries[1].path);
}

test "baseline: a pin that does not say what it measured is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try pinPathOf(&tmp, testing.allocator);
    defer testing.allocator.free(path);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = default_file_name,
        .data = "{\"paths\":[\"src\"],\"rules\":[{\"rule\":\"zginlint/x\",\"files\":[]}]}\n",
    });

    const loaded = load(testing.allocator, testing.io, path);
    try testing.expectError(error.MissingField, loaded);
}

test "baseline: a missing pin is an error, not an empty one" {
    const loaded = load(testing.allocator, testing.io, "no/such/zginlint-baseline.json");
    try testing.expectError(error.FileNotFound, loaded);
}

test "baseline: a rule with no pin entry has a ceiling of zero" {
    const pinned: Baseline = .{ .paths = &.{"src"} };
    const files = [_]FileCount{.{ .path = "src/new.zig", .count = 1 }};
    const counts = [_]RuleCounts{.{ .rule_id = scan_rule, .files = &files }};

    var comparison = try compare(testing.allocator, &counts, &pinned);
    defer comparison.deinit(testing.allocator);
    try testing.expect(!comparison.clean());
    try testing.expectEqual(@as(usize, 1), comparison.regressionCount());
}

test "baseline: a file above its ceiling is a regression, at the ceiling it is not" {
    const pinned_entries = [_]Entry{.{ .path = "src/a.zig", .count = 4 }};
    const pinned: Baseline = .{ .paths = &.{"src"}, .rules = &.{.{ .rule_id = comment_rule, .fingerprint = "max=3", .files = &pinned_entries }} };

    const worse = [_]FileCount{.{ .path = "src/a.zig", .count = 5 }};
    const over_counts = [_]RuleCounts{.{ .rule_id = comment_rule, .files = &worse }};
    var over = try compare(testing.allocator, &over_counts, &pinned);
    defer over.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), over.regressionCount());
    try testing.expectEqual(@as(u32, 4), over.rules[0].regressions[0].allowed);

    const same = [_]FileCount{.{ .path = "src/a.zig", .count = 4 }};
    const equal_counts = [_]RuleCounts{.{ .rule_id = comment_rule, .files = &same }};
    var equal = try compare(testing.allocator, &equal_counts, &pinned);
    defer equal.deinit(testing.allocator);
    try testing.expect(equal.clean());
    try testing.expectEqual(@as(usize, 0), equal.rules[0].shrinks.len);
}

test "baseline: a count that fell is a shrink with the value to re-pin" {
    const pinned_entries = [_]Entry{.{ .path = "src/a.zig", .count = 4 }};
    const pinned: Baseline = .{ .paths = &.{"src"}, .rules = &.{.{ .rule_id = comment_rule, .fingerprint = "max=3", .files = &pinned_entries }} };
    const files = [_]FileCount{.{ .path = "src/a.zig", .count = 2 }};
    const counts = [_]RuleCounts{.{ .rule_id = comment_rule, .files = &files }};

    var comparison = try compare(testing.allocator, &counts, &pinned);
    defer comparison.deinit(testing.allocator);
    try testing.expect(comparison.clean());
    try testing.expectEqual(@as(usize, 1), comparison.rules[0].shrinks.len);
    try testing.expectEqual(@as(u32, 2), comparison.rules[0].shrinks[0].count);
    try testing.expectEqual(@as(u32, 4), comparison.rules[0].shrinks[0].allowed);
}

test "baseline: a pinned file with no findings left is a shrink to zero" {
    const pinned_entries = [_]Entry{.{ .path = "src/gone.zig", .count = 3 }};
    const pinned: Baseline = .{ .paths = &.{"src"}, .rules = &.{.{ .rule_id = comment_rule, .fingerprint = "max=3", .files = &pinned_entries }} };
    const files = [_]FileCount{.{ .path = "src/other.zig", .count = 1 }};
    const counts = [_]RuleCounts{.{ .rule_id = comment_rule, .files = &files }};

    var comparison = try compare(testing.allocator, &counts, &pinned);
    defer comparison.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), comparison.regressionCount());
    try testing.expectEqual(@as(usize, 1), comparison.rules[0].shrinks.len);
    try testing.expectEqualStrings("src/gone.zig", comparison.rules[0].shrinks[0].path);
    try testing.expectEqual(@as(u32, 0), comparison.rules[0].shrinks[0].count);
}

test "baseline: the comparison totals both sides across rules" {
    const pinned_entries = [_]Entry{.{ .path = "src/a.zig", .count = 5 }};
    const pinned: Baseline = .{
        .paths = &.{"src"},
        .rules = &.{
            .{ .rule_id = comment_rule, .fingerprint = "max=3", .files = &pinned_entries },
            .{ .rule_id = scan_rule, .fingerprint = "-", .files = &.{} },
        },
    };
    const comment_files = [_]FileCount{.{ .path = "src/a.zig", .count = 6 }};
    const other_files = [_]FileCount{.{ .path = "src/c.zig", .count = 2 }};
    const counts = [_]RuleCounts{
        .{ .rule_id = comment_rule, .files = &comment_files },
        .{ .rule_id = scan_rule, .files = &other_files },
    };

    var comparison = try compare(testing.allocator, &counts, &pinned);
    defer comparison.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 8), comparison.totalCount());
    try testing.expectEqual(@as(u32, 5), comparison.totalAllowed());
    try testing.expectEqual(@as(usize, 2), comparison.regressionCount());
    try testing.expect(!comparison.clean());
}

test "baseline: pinnedOver compares the path set and its order" {
    const pinned: Baseline = .{ .paths = &.{ "src", "tests" } };
    try testing.expect(pinned.pinnedOver(&.{ "src", "tests" }));
    try testing.expect(!pinned.pinnedOver(&.{"src"}));
    try testing.expect(!pinned.pinnedOver(&.{ "tests", "src" }));
}
