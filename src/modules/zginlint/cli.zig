//! The `zginlint` command line: parse, lint, report, exit.
//! Exit codes are the contract CI is built on: 0 clean (or within the pinned
//! ceilings), 1 findings, 2 a usage or I/O error that must not read as clean.

const std = @import("std");
const baseline = @import("baseline.zig");
const options_mod = @import("options.zig");
const zginlint = @import("zginlint.zig");

pub const exit_clean: u8 = 0;
pub const exit_findings: u8 = 1;
pub const exit_usage: u8 = 2;

pub const usage =
    \\zginlint — a linter for Zig source.
    \\Rules: zginlint/max-comment-lines, zginlint/no-catch-unreachable.
    \\
    \\usage: zginlint [options] <path>...
    \\
    \\  <path> is a .zig file, or a directory walked for .zig files.
    \\
    \\options:
    \\  --max-comment-lines <n>   Ceiling on the lines of one comment block
    \\                            (zginlint/max-comment-lines, default 3).
    \\  --baseline <file>         Fail on any file above its pinned ceiling.
    \\  --update-baseline <file>  Write today's counts as the new ceilings.
    \\  -h, --help                Print this text.
    \\
    \\exit: 0 clean, 1 findings, 2 usage or I/O error
    \\
;

pub const Args = struct {
    max_comment_lines: u32 = options_mod.defaults.max_comment_lines,
    baseline_path: ?[]const u8 = null,
    update_baseline_path: ?[]const u8 = null,
    /// Owned slice of entries borrowed from argv.
    paths: []const []const u8 = &.{},

    pub fn options(self: *const Args) options_mod.Options {
        return .{ .max_comment_lines = self.max_comment_lines };
    }

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        allocator.free(self.paths);
        self.paths = &.{};
    }
};

pub const Parsed = union(enum) {
    run: Args,
    help,
    /// A one-line reason the argv was refused, owned by the caller.
    invalid: []const u8,

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .run => |*args| args.deinit(allocator),
            .invalid => |message| allocator.free(message),
            .help => {},
        }
    }
};

/// Split argv into a runnable instruction, or a reason it is not one.
/// argv excludes the program name.
pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) !Parsed {
    var args: Args = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const argument = argv[index];
        if (std.mem.eql(u8, argument, "-h") or std.mem.eql(u8, argument, "--help")) return .help;
        if (std.mem.eql(u8, argument, "--max-comment-lines")) {
            index += 1;
            const value = valueAt(argv, index) orelse
                return invalid(allocator, "--max-comment-lines needs a number");
            args.max_comment_lines = parseCeiling(value) catch |err| switch (err) {
                error.InvalidNumber => return invalid(allocator, "--max-comment-lines wants a number"),
                error.NotPositive => return invalid(allocator, "--max-comment-lines wants a number of at least 1"),
            };
            continue;
        }
        if (std.mem.eql(u8, argument, "--baseline")) {
            index += 1;
            args.baseline_path = valueAt(argv, index) orelse
                return invalid(allocator, "--baseline needs a file");
            continue;
        }
        if (std.mem.eql(u8, argument, "--update-baseline")) {
            index += 1;
            args.update_baseline_path = valueAt(argv, index) orelse
                return invalid(allocator, "--update-baseline needs a file");
            continue;
        }
        if (argument.len > 1 and argument[0] == '-') {
            const message = try std.fmt.allocPrint(allocator, "unknown option '{s}'", .{argument});
            return .{ .invalid = message };
        }
        try paths.append(allocator, argument);
    }

    if (args.baseline_path != null and args.update_baseline_path != null) {
        return invalid(allocator, "--baseline and --update-baseline are mutually exclusive");
    }
    if (paths.items.len == 0) return invalid(allocator, "at least one path is required");
    args.paths = try paths.toOwnedSlice(allocator);
    return .{ .run = args };
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var parsed = try parse(allocator, argv);
    defer parsed.deinit(allocator);

    switch (parsed) {
        .help => {
            try stdout.writeAll(usage);
            return exit_clean;
        },
        .invalid => |message| {
            try stderr.print("zginlint: {s}\n", .{message});
            try stderr.writeAll("run `zginlint --help` for usage\n");
            return exit_usage;
        },
        .run => |args| return lint(allocator, io, args, stdout, stderr),
    }
}

fn lint(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: Args,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const options = args.options();
    const reports = zginlint.lintPaths(allocator, io, args.paths, options) catch |err| {
        try stderr.print("zginlint: could not lint the given paths: {s}\n", .{@errorName(err)});
        return exit_usage;
    };
    defer zginlint.deinitFindings(allocator, reports);

    const counts = try countsFor(allocator, reports);
    defer deinitCounts(allocator, counts);

    if (args.update_baseline_path) |path| {
        return pin(allocator, io, args, options, counts, path, stdout, stderr);
    }
    if (args.baseline_path) |path| {
        return check(allocator, io, args, reports, counts, path, stdout, stderr);
    }

    for (reports) |report| try writeFindings(stdout, report.path, report.diagnostics);
    try stdout.print("zginlint: {d} finding(s) in {d} file(s)", .{ totalFor(counts), reports.len });
    for (counts) |rule_counts| {
        try stdout.print(" — {s}: {d}", .{ rule_counts.rule_id, totalOfFiles(rule_counts.files) });
    }
    try stdout.writeAll("\n");
    return if (reports.len == 0) exit_clean else exit_findings;
}

fn pin(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: Args,
    options: options_mod.Options,
    counts: []const baseline.RuleCounts,
    path: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const prints = try zginlint.fingerprints(allocator, options);
    defer zginlint.deinitFingerprints(allocator, prints);

    baseline.save(allocator, io, path, args.paths, counts, prints) catch |err| {
        try stderr.print("zginlint: cannot write the baseline {s}: {s}\n", .{ path, @errorName(err) });
        return exit_usage;
    };
    try stdout.print(
        "zginlint: pinned {d} file(s), {d} finding(s) into {s}\n",
        .{ fileCount(counts), totalFor(counts), path },
    );
    return exit_clean;
}

fn check(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: Args,
    reports: []const zginlint.FileFindings,
    counts: []const baseline.RuleCounts,
    path: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var pinned = baseline.load(allocator, io, path) catch |err| {
        try stderr.print("zginlint: cannot use the baseline {s}: {s}\n", .{ path, @errorName(err) });
        return exit_usage;
    };
    defer pinned.deinit(allocator);

    if (!pinned.pinnedOver(args.paths)) {
        try stderr.print(
            "zginlint: {s} was pinned over a different path set — re-pin it with --update-baseline\n",
            .{path},
        );
        return exit_usage;
    }
    if (try mismatchedFingerprint(allocator, args.options(), &pinned, stderr)) return exit_usage;

    var comparison = try baseline.compare(allocator, counts, &pinned);
    defer comparison.deinit(allocator);

    try writeRegressed(stdout, reports, comparison.rules);
    for (comparison.rules) |rule| {
        for (rule.shrinks) |shrink| {
            try stderr.print(
                "zginlint: note {s} is down to {d} (pinned {d}) for {s} — re-pin with --update-baseline\n",
                .{ shrink.path, shrink.count, shrink.allowed, rule.rule_id },
            );
        }
    }
    if (!comparison.clean()) {
        for (comparison.rules) |rule| {
            if (rule.regressions.len == 0) continue;
            try stderr.print(
                "zginlint: {s}: {d} file(s) above their pinned ceiling in {s}\n",
                .{ rule.rule_id, rule.regressions.len, path },
            );
        }
        return exit_findings;
    }
    try stdout.print(
        "zginlint: within the pinned ceilings in {s} ({d} finding(s), {d} pinned)\n",
        .{ path, comparison.totalCount(), comparison.totalAllowed() },
    );
    return exit_clean;
}

/// Report a rule whose pinned options differ from this run's, and answer
/// whether there was one. A pin is only comparable under the options it was
/// measured with, so a mismatch is refused rather than compared.
fn mismatchedFingerprint(
    allocator: std.mem.Allocator,
    options: options_mod.Options,
    pinned: *const baseline.Baseline,
    stderr: *std.Io.Writer,
) !bool {
    const prints = try zginlint.fingerprints(allocator, options);
    defer zginlint.deinitFingerprints(allocator, prints);

    for (prints) |print| {
        const was = pinned.fingerprintFor(print.rule_id) orelse continue;
        if (std.mem.eql(u8, was, print.text)) continue;
        try stderr.print(
            "zginlint: {s} was pinned with options \"{s}\" and this run has \"{s}\" — re-pin it\n",
            .{ print.rule_id, was, print.text },
        );
        return true;
    }
    return false;
}

fn writeFindings(
    writer: *std.Io.Writer,
    path: []const u8,
    diagnostics: []const zginlint.Diagnostic,
) !void {
    for (diagnostics) |item| {
        try writer.print("{s}:{d}:{d}: error {s} ({s})\n", .{
            path, item.line, item.column, item.message, item.rule_id,
        });
    }
}

fn writeRegressed(
    writer: *std.Io.Writer,
    reports: []const zginlint.FileFindings,
    rules: []const baseline.RuleComparison,
) !void {
    for (rules) |rule| {
        for (rule.regressions) |regression| {
            for (reports) |report| {
                if (!std.mem.eql(u8, report.path, regression.path)) continue;
                for (report.diagnostics) |item| {
                    if (!std.mem.eql(u8, item.rule_id, rule.rule_id)) continue;
                    try writeFindings(writer, report.path, &.{item});
                }
            }
        }
    }
}

fn countsFor(
    allocator: std.mem.Allocator,
    reports: []const zginlint.FileFindings,
) ![]baseline.RuleCounts {
    const counts = try allocator.alloc(baseline.RuleCounts, zginlint.rules.len);
    var done: usize = 0;
    errdefer deinitCounts(allocator, counts[0..done]);
    for (zginlint.rules, 0..) |declaration, index| {
        counts[index] = .{
            .rule_id = declaration.id,
            .files = try fileCountsFor(allocator, reports, declaration.id),
        };
        done = index + 1;
    }
    return counts;
}

fn fileCountsFor(
    allocator: std.mem.Allocator,
    reports: []const zginlint.FileFindings,
    rule_id: []const u8,
) ![]baseline.FileCount {
    var files: std.ArrayList(baseline.FileCount) = .empty;
    errdefer files.deinit(allocator);
    for (reports) |report| {
        var count: u32 = 0;
        for (report.diagnostics) |item| {
            if (std.mem.eql(u8, item.rule_id, rule_id)) count += 1;
        }
        if (count == 0) continue;
        try files.append(allocator, .{ .path = report.path, .count = count });
    }
    return files.toOwnedSlice(allocator);
}

fn deinitCounts(allocator: std.mem.Allocator, counts: []baseline.RuleCounts) void {
    for (counts) |rule_counts| allocator.free(rule_counts.files);
    allocator.free(counts);
}

fn totalFor(counts: []const baseline.RuleCounts) u32 {
    var total: u32 = 0;
    for (counts) |rule_counts| total += totalOfFiles(rule_counts.files);
    return total;
}

fn totalOfFiles(files: []const baseline.FileCount) u32 {
    var total: u32 = 0;
    for (files) |file| total += file.count;
    return total;
}

fn fileCount(counts: []const baseline.RuleCounts) usize {
    var total: usize = 0;
    for (counts) |rule_counts| total += rule_counts.files.len;
    return total;
}

const CeilingError = error{ InvalidNumber, NotPositive };

fn parseCeiling(value: []const u8) CeilingError!u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidNumber;
    if (parsed == 0) return error.NotPositive;
    return parsed;
}

fn valueAt(argv: []const []const u8, index: usize) ?[]const u8 {
    if (index >= argv.len) return null;
    return argv[index];
}

fn invalid(allocator: std.mem.Allocator, message: []const u8) !Parsed {
    return .{ .invalid = try allocator.dupe(u8, message) };
}

const testing = std.testing;

const Result = struct {
    code: u8,
    out: []u8,
    err: []u8,
};

fn runCli(argv: []const []const u8, out_buffer: []u8, err_buffer: []u8) !Result {
    var out = std.Io.Writer.fixed(out_buffer);
    var err = std.Io.Writer.fixed(err_buffer);
    const code = try run(testing.allocator, testing.io, argv, &out, &err);
    return .{ .code = code, .out = out.buffered(), .err = err.buffered() };
}

/// A source that trips both rules, built so this file carries no literal
/// copy of the banned token pair.
fn bothRulesSource(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "// one\n// two\n// three\n// four\nconst x = g() catch{s}unreachable;\n",
        .{" "},
    );
}

fn fixtureTree(tmp: *testing.TmpDir) !void {
    try tmp.dir.createDirPath(testing.io, "nested");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "nested/long.zig",
        .data = "// one\n// two\n// three\n// four\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "clean.zig",
        .data = "// one\n// two\n// three\nconst x = 1;\n",
    });
}

fn rootOf(tmp: *testing.TmpDir, buffer: []u8) ![]const u8 {
    return buffer[0..try tmp.dir.realPath(testing.io, buffer)];
}

fn pinPathOf(tmp: *testing.TmpDir, allocator: std.mem.Allocator) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return std.fmt.allocPrint(allocator, "{s}/pin.json", .{buffer[0..try tmp.dir.realPath(testing.io, &buffer)]});
}

test "cli: --help prints usage and exits clean" {
    var out_buffer: [4096]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    const result = try runCli(&.{"--help"}, &out_buffer, &err_buffer);
    try testing.expectEqual(@as(u8, 0), result.code);
    try testing.expect(std.mem.indexOf(u8, result.out, "usage: zginlint") != null);
    try testing.expect(std.mem.indexOf(u8, result.out, "zginlint/no-catch-unreachable") != null);
}

test "cli: an unknown option is a usage error naming it" {
    var out_buffer: [256]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    const result = try runCli(&.{ "--nope", "src" }, &out_buffer, &err_buffer);
    try testing.expectEqual(@as(u8, 2), result.code);
    try testing.expect(std.mem.indexOf(u8, result.err, "unknown option '--nope'") != null);
}

test "cli: a bare run is a usage error" {
    var out_buffer: [256]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    const result = try runCli(&.{}, &out_buffer, &err_buffer);
    try testing.expectEqual(@as(u8, 2), result.code);
    try testing.expect(std.mem.indexOf(u8, result.err, "at least one path is required") != null);
}

test "cli: a ceiling flag without a value is a usage error" {
    var out_buffer: [256]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    const result = try runCli(&.{"--max-comment-lines"}, &out_buffer, &err_buffer);
    try testing.expectEqual(@as(u8, 2), result.code);
    try testing.expect(std.mem.indexOf(u8, result.err, "needs a number") != null);
}

test "cli: a baseline flag without a value is a usage error" {
    var out_buffer: [256]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    const result = try runCli(&.{"--baseline"}, &out_buffer, &err_buffer);
    try testing.expectEqual(@as(u8, 2), result.code);
    try testing.expect(std.mem.indexOf(u8, result.err, "--baseline needs a file") != null);
}

test "cli: a ceiling that is not a number is a usage error" {
    var out_buffer: [256]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    const result = try runCli(&.{ "--max-comment-lines", "three", "src" }, &out_buffer, &err_buffer);
    try testing.expectEqual(@as(u8, 2), result.code);
    try testing.expect(std.mem.indexOf(u8, result.err, "wants a number") != null);
}

test "cli: a ceiling of zero is a usage error" {
    var out_buffer: [256]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    const result = try runCli(&.{ "--max-comment-lines", "0", "src" }, &out_buffer, &err_buffer);
    try testing.expectEqual(@as(u8, 2), result.code);
    try testing.expect(std.mem.indexOf(u8, result.err, "at least 1") != null);
}

test "cli: a tree with a long block reports it and exits 1" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixtureTree(&tmp);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootOf(&tmp, &path_buffer);

    var out_buffer: [8192]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    const result = try runCli(&.{root}, &out_buffer, &err_buffer);

    try testing.expectEqual(@as(u8, 1), result.code);
    try testing.expect(std.mem.indexOf(
        u8,
        result.out,
        "nested/long.zig:1:1: error Comment block has 4 lines; max is 3 (zginlint/max-comment-lines)",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, result.out, "1 finding(s) in 1 file(s)") != null);
}

test "cli: both rules report on one file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try bothRulesSource(testing.allocator);
    defer testing.allocator.free(source);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "both.zig", .data = source });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootOf(&tmp, &path_buffer);

    var out_buffer: [8192]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    const result = try runCli(&.{root}, &out_buffer, &err_buffer);

    try testing.expectEqual(@as(u8, 1), result.code);
    try testing.expect(std.mem.indexOf(u8, result.out, "both.zig:1:1: error Comment block has 4 lines") != null);
    try testing.expect(std.mem.indexOf(u8, result.out, "both.zig:5:15: error") != null);
    try testing.expect(std.mem.indexOf(u8, result.out, "zginlint/max-comment-lines: 1") != null);
    try testing.expect(std.mem.indexOf(u8, result.out, "zginlint/no-catch-unreachable: 1") != null);
}

test "cli: a clean tree exits 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "clean.zig", .data = "// one\n// two\n// three\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootOf(&tmp, &path_buffer);

    var out_buffer: [8192]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    const result = try runCli(&.{root}, &out_buffer, &err_buffer);

    try testing.expectEqual(@as(u8, 0), result.code);
    try testing.expect(std.mem.indexOf(u8, result.out, "0 finding(s) in 0 file(s)") != null);
}

test "cli: a path that does not exist is an error, not a clean run" {
    var out_buffer: [256]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    const result = try runCli(&.{"no/such/dir"}, &out_buffer, &err_buffer);
    try testing.expectEqual(@as(u8, 2), result.code);
    try testing.expect(std.mem.indexOf(u8, result.err, "could not lint") != null);
}

test "cli: the ceiling from the command line reaches the rule" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "two.zig", .data = "// one\n// two\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootOf(&tmp, &path_buffer);

    var out_buffer: [8192]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    const result = try runCli(&.{ "--max-comment-lines", "1", root }, &out_buffer, &err_buffer);

    try testing.expectEqual(@as(u8, 1), result.code);
    try testing.expect(std.mem.indexOf(u8, result.out, "max is 1") != null);
}

test "cli: pinning then checking the same tree is clean" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixtureTree(&tmp);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootOf(&tmp, &path_buffer);
    const pin_path = try pinPathOf(&tmp, testing.allocator);
    defer testing.allocator.free(pin_path);

    var out_buffer: [8192]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    const pinned = try runCli(&.{ "--update-baseline", pin_path, root }, &out_buffer, &err_buffer);
    try testing.expectEqual(@as(u8, 0), pinned.code);
    try testing.expect(std.mem.indexOf(u8, pinned.out, "pinned 1 file(s), 1 finding(s)") != null);

    const checked = try runCli(&.{ "--baseline", pin_path, root }, &out_buffer, &err_buffer);
    try testing.expectEqual(@as(u8, 0), checked.code);
    try testing.expect(std.mem.indexOf(u8, checked.out, "within the pinned ceilings") != null);
}

test "cli: a long block added after pinning is a regression" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixtureTree(&tmp);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootOf(&tmp, &path_buffer);
    const pin_path = try pinPathOf(&tmp, testing.allocator);
    defer testing.allocator.free(pin_path);

    var out_buffer: [8192]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    _ = try runCli(&.{ "--update-baseline", pin_path, root }, &out_buffer, &err_buffer);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "added.zig",
        .data = "// a\n// b\n// c\n// d\n",
    });
    const checked = try runCli(&.{ "--baseline", pin_path, root }, &out_buffer, &err_buffer);

    try testing.expectEqual(@as(u8, 1), checked.code);
    try testing.expect(std.mem.indexOf(u8, checked.out, "added.zig:1:1: error") != null);
    try testing.expect(std.mem.indexOf(u8, checked.err, "1 file(s) above their pinned ceiling") != null);
    try testing.expect(std.mem.indexOf(u8, checked.err, "zginlint/max-comment-lines") != null);
}

test "cli: a site added after pinning is a regression for the second rule" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixtureTree(&tmp);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootOf(&tmp, &path_buffer);
    const pin_path = try pinPathOf(&tmp, testing.allocator);
    defer testing.allocator.free(pin_path);

    var out_buffer: [8192]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    _ = try runCli(&.{ "--update-baseline", pin_path, root }, &out_buffer, &err_buffer);

    const source = try std.fmt.allocPrint(testing.allocator, "const x = g() catch{s}unreachable;\n", .{" "});
    defer testing.allocator.free(source);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "site.zig", .data = source });
    const checked = try runCli(&.{ "--baseline", pin_path, root }, &out_buffer, &err_buffer);

    try testing.expectEqual(@as(u8, 1), checked.code);
    try testing.expect(std.mem.indexOf(u8, checked.out, "site.zig:1:15: error") != null);
    try testing.expect(std.mem.indexOf(u8, checked.err, "zginlint/no-catch-unreachable: 1 file(s) above") != null);
}

test "cli: a block fixed after pinning is a re-pin notice, not a failure" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixtureTree(&tmp);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootOf(&tmp, &path_buffer);
    const pin_path = try pinPathOf(&tmp, testing.allocator);
    defer testing.allocator.free(pin_path);

    var out_buffer: [8192]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    _ = try runCli(&.{ "--update-baseline", pin_path, root }, &out_buffer, &err_buffer);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "nested/long.zig",
        .data = "// one\n// two\n// three\n",
    });
    const checked = try runCli(&.{ "--baseline", pin_path, root }, &out_buffer, &err_buffer);

    try testing.expectEqual(@as(u8, 0), checked.code);
    try testing.expect(std.mem.indexOf(u8, checked.err, "is down to 0 (pinned 1)") != null);
}

test "cli: a baseline pinned with another ceiling is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixtureTree(&tmp);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootOf(&tmp, &path_buffer);
    const pin_path = try pinPathOf(&tmp, testing.allocator);
    defer testing.allocator.free(pin_path);

    var out_buffer: [8192]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    _ = try runCli(
        &.{ "--max-comment-lines", "2", "--update-baseline", pin_path, root },
        &out_buffer,
        &err_buffer,
    );

    const checked = try runCli(&.{ "--baseline", pin_path, root }, &out_buffer, &err_buffer);
    try testing.expectEqual(@as(u8, 2), checked.code);
    try testing.expect(std.mem.indexOf(u8, checked.err, "max=2") != null);
    try testing.expect(std.mem.indexOf(u8, checked.err, "max=3") != null);
}

test "cli: a baseline pinned over another path set is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixtureTree(&tmp);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootOf(&tmp, &path_buffer);
    const pin_path = try pinPathOf(&tmp, testing.allocator);
    defer testing.allocator.free(pin_path);

    var out_buffer: [8192]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    _ = try runCli(&.{ "--update-baseline", pin_path, root }, &out_buffer, &err_buffer);

    const other = try std.fmt.allocPrint(testing.allocator, "{s}/nested", .{root});
    defer testing.allocator.free(other);
    const checked = try runCli(&.{ "--baseline", pin_path, root, other }, &out_buffer, &err_buffer);

    try testing.expectEqual(@as(u8, 2), checked.code);
    try testing.expect(std.mem.indexOf(u8, checked.err, "pinned over a different path set") != null);
}

test "cli: --baseline and --update-baseline together are refused" {
    var out_buffer: [256]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    const result = try runCli(
        &.{ "--baseline", "a.json", "--update-baseline", "b.json", "src" },
        &out_buffer,
        &err_buffer,
    );
    try testing.expectEqual(@as(u8, 2), result.code);
    try testing.expect(std.mem.indexOf(u8, result.err, "mutually exclusive") != null);
}
