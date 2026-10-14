//! The `zginlint` command line: parse, lint, report, exit.
//! Exit codes are the contract CI is built on: 0 clean (or within the pinned
//! ceilings), 1 findings, 2 a usage or I/O error that must not read as clean.

const std = @import("std");
const baseline = @import("baseline.zig");
const diagnostic = @import("diagnostic.zig");
const max_comment_lines_rule = @import("rules/max_comment_lines.zig");
const zginlint = @import("zginlint.zig");

pub const exit_clean: u8 = 0;
pub const exit_findings: u8 = 1;
pub const exit_usage: u8 = 2;

pub const usage =
    \\zginlint — a linter for Zig source. Rules: zginlint/max-comment-lines.
    \\
    \\usage: zginlint [options] <path>...
    \\
    \\  <path> is a .zig file, or a directory walked for .zig files.
    \\
    \\options:
    \\  --max-comment-lines <n>   Ceiling on the lines of one comment block,
    \\                            reported at the block's first line.
    \\  --baseline <file>         Fail on any file above its pinned ceiling.
    \\  --update-baseline <file>  Write today's counts as the new ceilings.
    \\  -h, --help                Print this text.
    \\
    \\exit: 0 clean, 1 findings, 2 usage or I/O error
    \\
;

pub const Args = struct {
    max_comment_lines: u32 = max_comment_lines_rule.default_max_lines,
    baseline_path: ?[]const u8 = null,
    update_baseline_path: ?[]const u8 = null,
    /// Owned slice of entries borrowed from argv.
    paths: []const []const u8 = &.{},

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
    const options: zginlint.Options = .{ .max_comment_lines = args.max_comment_lines };
    const reports = zginlint.lintPaths(allocator, io, args.paths, options) catch |err| {
        try stderr.print("zginlint: could not lint the given paths: {s}\n", .{@errorName(err)});
        return exit_usage;
    };
    defer zginlint.deinitFindings(allocator, reports);

    const counts = try countsFor(allocator, reports);
    defer allocator.free(counts);

    if (args.update_baseline_path) |path| {
        return pin(allocator, io, args, counts, path, stdout, stderr);
    }
    if (args.baseline_path) |path| {
        return check(allocator, io, args, reports, counts, path, stdout, stderr);
    }

    for (reports) |report| try writeFindings(allocator, stdout, report.path, report.diagnostics);
    try stdout.print(
        "zginlint: {d} finding(s) in {d} file(s) — {s}, max {d} line(s) per comment block\n",
        .{ totalFor(counts), reports.len, max_comment_lines_rule.id, args.max_comment_lines },
    );
    return if (reports.len == 0) exit_clean else exit_findings;
}

fn pin(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: Args,
    counts: []const baseline.FileCount,
    path: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    baseline.save(allocator, io, path, args.max_comment_lines, args.paths, counts) catch |err| {
        try stderr.print("zginlint: cannot write the baseline {s}: {s}\n", .{ path, @errorName(err) });
        return exit_usage;
    };
    try stdout.print(
        "zginlint: pinned {d} file(s), {d} finding(s) into {s}\n",
        .{ counts.len, totalFor(counts), path },
    );
    return exit_clean;
}

fn check(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: Args,
    reports: []const zginlint.FileFindings,
    counts: []const baseline.FileCount,
    path: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var pinned = baseline.load(allocator, io, path) catch |err| {
        try stderr.print("zginlint: cannot use the baseline {s}: {s}\n", .{ path, @errorName(err) });
        return exit_usage;
    };
    defer pinned.deinit(allocator);

    if (pinned.max_comment_lines != args.max_comment_lines) {
        try stderr.print(
            "zginlint: {s} was pinned with max {d} line(s) and this run uses {d} — re-pin it\n",
            .{ path, pinned.max_comment_lines, args.max_comment_lines },
        );
        return exit_usage;
    }
    if (!pinned.pinnedOver(args.paths)) {
        try stderr.print(
            "zginlint: {s} was pinned over a different path set — re-pin it with --update-baseline\n",
            .{path},
        );
        return exit_usage;
    }

    var comparison = try baseline.compare(allocator, counts, &pinned);
    defer comparison.deinit(allocator);

    try writeRegressed(allocator, stdout, reports, comparison.regressions);
    for (comparison.shrinks) |shrink| {
        try stderr.print(
            "zginlint: note {s} is down to {d} (pinned {d}) — re-pin with --update-baseline\n",
            .{ shrink.path, shrink.count, shrink.allowed },
        );
    }
    if (!comparison.clean()) {
        try stderr.print(
            "zginlint: {d} file(s) above their pinned ceiling in {s}\n",
            .{ comparison.regressions.len, path },
        );
        return exit_findings;
    }
    try stdout.print(
        "zginlint: within the pinned ceilings in {s} ({d} finding(s), {d} pinned)\n",
        .{ path, comparison.total_count, comparison.total_allowed },
    );
    return exit_clean;
}

fn writeFindings(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    path: []const u8,
    diagnostics: []const zginlint.Diagnostic,
) !void {
    for (diagnostics) |item| {
        const message = try diagnostic.message(allocator, item);
        defer allocator.free(message);
        try writer.print("{s}:{d}:{d}: error {s} ({s})\n", .{
            path, item.line, item.column, message, item.rule_id,
        });
    }
}

fn writeRegressed(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    reports: []const zginlint.FileFindings,
    regressions: []const baseline.Regression,
) !void {
    for (regressions) |regression| {
        for (reports) |report| {
            if (!std.mem.eql(u8, report.path, regression.path)) continue;
            try writeFindings(allocator, writer, report.path, report.diagnostics);
        }
    }
}

fn countsFor(
    allocator: std.mem.Allocator,
    reports: []const zginlint.FileFindings,
) ![]baseline.FileCount {
    const counts = try allocator.alloc(baseline.FileCount, reports.len);
    for (reports, counts) |report, *count| {
        count.* = .{ .path = report.path, .count = @intCast(report.diagnostics.len) };
    }
    return counts;
}

fn totalFor(counts: []const baseline.FileCount) u32 {
    var total: u32 = 0;
    for (counts) |count| total += count.count;
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
    try testing.expect(std.mem.indexOf(u8, checked.err, "was pinned with max 2 line(s)") != null);
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
