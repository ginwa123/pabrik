const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;

/// Max blamed lines per response — bounds the payload on huge files.
/// The parser stops emitting after this many lines (never a partial line).
pub const MAX_BLAME_LINES: usize = 10000;

/// One blamed final-file line.
pub const BlameLine = struct {
    line: usize, // 1-based final-file line number
    commit: []const u8, // 40-hex sha; all zeros when uncommitted
    author: []const u8,
    author_time: i64, // unix seconds; 0 when unknown
    summary: []const u8,
};

/// Parse `git blame --porcelain` output into per-line records.
pub fn parseBlamePorcelain(allocator: std.mem.Allocator, output: []const u8, max_lines: usize) ![]BlameLine {
    var out = std.ArrayList(BlameLine).empty;

    var commit: []const u8 = "";
    var author: []const u8 = "";
    var author_time: i64 = 0;
    var summary: []const u8 = "";
    var next_line: usize = 0;

    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (out.items.len >= max_lines) break;
        if (line.len == 0) continue;
        if (line[0] == '\t') {
            if (next_line == 0) continue;
            try out.append(allocator, .{
                .line = next_line,
                .commit = try allocator.dupe(u8, commit),
                .author = try allocator.dupe(u8, author),
                .author_time = author_time,
                .summary = try allocator.dupe(u8, summary),
            });
            next_line += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "author ")) {
            author = line["author ".len..];
        } else if (std.mem.startsWith(u8, line, "author-time ")) {
            author_time = std.fmt.parseInt(i64, line["author-time ".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, line, "summary ")) {
            summary = line["summary ".len..];
        } else if (line[0] >= '0' and line[0] <= '9' or line[0] >= 'a' and line[0] <= 'f') {
            // Header line: `<sha> <orig> <final> <count>`.
            var parts = std.mem.splitScalar(u8, line, ' ');
            const sha = parts.next() orelse continue;
            _ = parts.next(); // orig line — not needed
            const final_s = parts.next() orelse continue;
            commit = sha;
            author = "";
            author_time = 0;
            summary = "";
            next_line = std.fmt.parseInt(usize, final_s, 10) catch continue;
        }
    }

    return try out.toOwnedSlice(allocator);
}

/// Minimal JSON string escaper for blame fields (author names and
/// summaries are free text and may hold quotes or backslashes).
pub fn escapeJsonString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    for (s) |c| {
        if (c == '"') {
            try buf.appendSlice(allocator, "\\\"");
        } else if (c == '\\') {
            try buf.appendSlice(allocator, "\\\\");
        } else if (c == '\n') {
            try buf.appendSlice(allocator, "\\n");
        } else if (c == '\r') {
            try buf.appendSlice(allocator, "\\r");
        } else if (c == '\t') {
            try buf.appendSlice(allocator, "\\t");
        } else if (c < 0x20) {
            const hex = "0123456789abcdef";
            try buf.appendSlice(allocator, "\\u00");
            try buf.append(allocator, hex[c >> 4]);
            try buf.append(allocator, hex[c & 0xf]);
        } else {
            try buf.append(allocator, c);
        }
    }
    return try buf.toOwnedSlice(allocator);
}

fn makeBlameResponse(allocator: std.mem.Allocator, is_repo: bool, lines: []const BlameLine) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(allocator, "{\"is_git_repo\":");
    try buf.appendSlice(allocator, if (is_repo) "true" else "false");
    try buf.appendSlice(allocator, ",\"lines\":[");
    for (lines, 0..) |bl, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        const commit = try escapeJsonString(allocator, bl.commit);
        const author = try escapeJsonString(allocator, bl.author);
        const summary = try escapeJsonString(allocator, bl.summary);
        const item = try std.fmt.allocPrint(allocator, "{{\"line\":{d},\"commit\":\"{s}\",\"author\":\"{s}\",\"author_time\":{d},\"summary\":\"{s}\"}}", .{ bl.line, commit, author, bl.author_time, summary });
        try buf.appendSlice(allocator, item);
    }
    try buf.appendSlice(allocator, "]}");
    return try buf.toOwnedSlice(allocator);
}

/// Git blame endpoint — per-line author + time for one file, backing the
/// CodeEditor's inline blame annotation (`You, 2 hours ago`). `GET
/// /api/git/blame?path=<cwd>&file=<repo-relative path>`.
pub fn gitBlameHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const query = req.query;
    const path_param = query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path parameter") });
    };
    const file_param = query.get("file") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing file parameter") });
    };

    const git_check = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "rev-parse", "--git-dir" },
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };
    if (git_check.term.exited != 0) {
        return res.jsonResponse(.{ .status_code = 200, .data = try makeBlameResponse(allocator, false, &.{}) });
    }

    const blame_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "blame", "--porcelain", "--", file_param },
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };
    if (blame_result.term.exited != 0) {
        return res.jsonResponse(.{ .status_code = 200, .data = try makeBlameResponse(allocator, true, &.{}) });
    }

    const lines = try parseBlamePorcelain(allocator, blame_result.stdout, MAX_BLAME_LINES);
    return res.jsonResponse(.{ .status_code = 200, .data = try makeBlameResponse(allocator, true, lines) });
}

test "parseBlamePorcelain extracts per-line author, time and summary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const sample =
        "abc123abc123abc123abc123abc123abc123abc1 1 1 1\n" ++
        "author Ginwa\n" ++
        "author-mail <ginwa@example.com>\n" ++
        "author-time 1788008400\n" ++
        "author-tz +0700\n" ++
        "summary Add split-bill route\n" ++
        "filename routes.go\n" ++
        "\tapp.Post(\n" ++
        "def456def456def456def456def456def456def4 2 2 1\n" ++
        "author Budi\n" ++
        "author-time 1788008500\n" ++
        "summary Fix auth\n" ++
        "\tapp.Put(\n";
    const lines = try parseBlamePorcelain(allocator, sample, MAX_BLAME_LINES);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqual(@as(usize, 1), lines[0].line);
    try std.testing.expectEqualStrings("abc123abc123abc123abc123abc123abc123abc1", lines[0].commit);
    try std.testing.expectEqualStrings("Ginwa", lines[0].author);
    try std.testing.expectEqual(@as(i64, 1788008400), lines[0].author_time);
    try std.testing.expectEqualStrings("Add split-bill route", lines[0].summary);
    try std.testing.expectEqual(@as(usize, 2), lines[1].line);
    try std.testing.expectEqualStrings("Budi", lines[1].author);
}

test "parseBlamePorcelain keeps the zero sha for uncommitted lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const sample =
        "0000000000000000000000000000000000000000 1 1 1\n" ++
        "author Not Committed Yet\n" ++
        "author-time 0\n" ++
        "summary Version of routes.go\n" ++
        "\tnew line\n";
    const lines = try parseBlamePorcelain(allocator, sample, MAX_BLAME_LINES);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("0000000000000000000000000000000000000000", lines[0].commit);
    try std.testing.expectEqualStrings("Not Committed Yet", lines[0].author);
}

test "parseBlamePorcelain returns no lines for empty output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lines = try parseBlamePorcelain(arena.allocator(), "", MAX_BLAME_LINES);
    try std.testing.expectEqual(@as(usize, 0), lines.len);
}

test "parseBlamePorcelain stops at the line cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const sample =
        "abc123abc123abc123abc123abc123abc123abc1 1 1 1\nauthor A\nauthor-time 1\nsummary S\n\tone\n" ++
        "abc123abc123abc123abc123abc123abc123abc1 2 2 1\nauthor A\nauthor-time 1\nsummary S\n\ttwo\n";
    const lines = try parseBlamePorcelain(allocator, sample, 1);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqual(@as(usize, 1), lines[0].line);
}

test "escapeJsonString escapes quotes, backslashes and newlines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try escapeJsonString(arena.allocator(), "say \"hi\" \\ bye\n");
    try std.testing.expectEqualStrings("say \\\"hi\\\" \\\\ bye\\n", out);
}
