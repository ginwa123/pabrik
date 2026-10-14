//! The `zginlint` command line: parse, lint, report, exit.
//! Exit codes are the contract CI is built on: 0 clean, 1 findings, 2 a usage
//! or I/O error that must not read as clean. No baseline, no suppression.

const std = @import("std");
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
    \\  -h, --help                Print this text.
    \\
    \\exit: 0 clean, 1 findings, 2 usage or I/O error
    \\
;

pub const Args = struct {
    max_comment_lines: u32 = options_mod.defaults.max_comment_lines,
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
        if (argument.len > 1 and argument[0] == '-') {
            const message = try std.fmt.allocPrint(allocator, "unknown option '{s}'", .{argument});
            return .{ .invalid = message };
        }
        try paths.append(allocator, argument);
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

    var total: u32 = 0;
    for (reports) |report| total += @intCast(report.diagnostics.len);
    for (reports) |report| try writeFindings(stdout, report.path, report.diagnostics);
    try stdout.print("zginlint: {d} finding(s) in {d} file(s)", .{ total, reports.len });
    for (zginlint.rules) |declaration| {
        const per_rule = countRule(reports, declaration.id);
        if (per_rule == 0) continue;
        try stdout.print(" — {s}: {d}", .{ declaration.id, per_rule });
    }
    try stdout.writeAll("\n");
    return if (reports.len == 0) exit_clean else exit_findings;
}

/// How many of the reported findings belong to one rule.
fn countRule(reports: []const zginlint.FileFindings, rule_id: []const u8) u32 {
    var total: u32 = 0;
    for (reports) |report| {
        for (report.diagnostics) |item| {
            if (std.mem.eql(u8, item.rule_id, rule_id)) total += 1;
        }
    }
    return total;
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
