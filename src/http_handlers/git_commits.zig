const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;
const validateRepoPath = @import("git_branches_list.zig").validateRepoPath;

/// One commit row. All slices borrow from the use-case arena — the
/// handler serializes before the arena is released.
pub const CommitEntry = struct {
    sha: []const u8,
    short_sha: []const u8,
    author: []const u8,
    email: []const u8,
    timestamp: i64,
    subject: []const u8,
    body: []const u8,
};

/// One file touched by a commit (`git diff-tree --name-status` row).
pub const CommitFileEntry = struct {
    status: []const u8,
    path: []const u8,
};

const CommitsListResult = struct {
    branch: []const u8,
    total_count: i64,
    commits: []const CommitEntry,
};

/// Parse the `%H%x1f%h%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%b%x1e` output of `git
/// log` into commit rows. Records split on `\x1e`, fields on `\x1f`.
pub fn parseLogRecords(allocator: std.mem.Allocator, raw: []const u8) ![]CommitEntry {
    var out: std.ArrayList(CommitEntry) = .empty;
    errdefer {
        for (out.items) |c| {
            allocator.free(c.sha);
            allocator.free(c.short_sha);
            allocator.free(c.author);
            allocator.free(c.email);
            allocator.free(c.subject);
            allocator.free(c.body);
        }
        out.deinit(allocator);
    }

    var records = std.mem.splitScalar(u8, raw, 0x1e);
    while (records.next()) |rec| {
        const trimmed = std.mem.trim(u8, rec, " \n\r\t");
        if (trimmed.len == 0) continue;
        var fields = std.mem.splitScalar(u8, trimmed, 0x1f);
        const sha = fields.next() orelse continue;
        const short_sha = fields.next() orelse continue;
        const author = fields.next() orelse continue;
        const email = fields.next() orelse continue;
        const ts_raw = fields.next() orelse continue;
        const subject = fields.next() orelse continue;
        const body = fields.next() orelse "";
        if (sha.len == 0) continue;
        const timestamp = std.fmt.parseInt(i64, std.mem.trim(u8, ts_raw, " "), 10) catch 0;
        try out.append(allocator, .{
            .sha = try allocator.dupe(u8, sha),
            .short_sha = try allocator.dupe(u8, short_sha),
            .author = try allocator.dupe(u8, author),
            .email = try allocator.dupe(u8, email),
            .timestamp = timestamp,
            .subject = try allocator.dupe(u8, subject),
            .body = try allocator.dupe(u8, std.mem.trim(u8, body, " \n\r\t")),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Release a slice returned by `parseLogRecords`.
pub fn freeCommitEntries(allocator: std.mem.Allocator, entries: []const CommitEntry) void {
    for (entries) |c| {
        allocator.free(c.sha);
        allocator.free(c.short_sha);
        allocator.free(c.author);
        allocator.free(c.email);
        allocator.free(c.subject);
        allocator.free(c.body);
    }
    allocator.free(entries);
}

/// Parse `git diff-tree --no-commit-id --name-status -r <sha>` output
/// (`<STATUS>\t<path>` per line, renames carry `R100\told\tnew`).
/// Pure — no IO.
pub fn parseNameStatus(allocator: std.mem.Allocator, raw: []const u8) ![]CommitFileEntry {
    var out: std.ArrayList(CommitFileEntry) = .empty;
    errdefer {
        for (out.items) |f| {
            allocator.free(f.status);
            allocator.free(f.path);
        }
        out.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        var fields = std.mem.splitScalar(u8, trimmed, '\t');
        const status_raw = fields.next() orelse continue;
        const status = status_raw[0..@min(status_raw.len, 1)];
        const first_path = fields.next() orelse continue;
        // Rename rows have two paths — show `old -> new`.
        const second_path = fields.next();
        var path_buf: std.ArrayList(u8) = .empty;
        defer path_buf.deinit(allocator);
        try path_buf.appendSlice(allocator, first_path);
        if (second_path) |sp| {
            try path_buf.appendSlice(allocator, " -> ");
            try path_buf.appendSlice(allocator, sp);
        }
        if (path_buf.items.len == 0) continue;
        try out.append(allocator, .{
            .status = try allocator.dupe(u8, status),
            .path = try path_buf.toOwnedSlice(allocator),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Clamp a `limit` query value to 1..200, defaulting to 100 on missing
/// or unparsable input. Pure.
pub fn parseLimit(raw: ?[]const u8) usize {
    const v = std.fmt.parseInt(usize, std.mem.trim(u8, raw orelse "", " "), 10) catch return 100;
    if (v < 1) return 1;
    if (v > 200) return 200;
    return v;
}

/// Parse a `skip` query value, defaulting to 0. Pure.
pub fn parseSkip(raw: ?[]const u8) usize {
    return std.fmt.parseInt(usize, std.mem.trim(u8, raw orelse "", " "), 10) catch 0;
}

/// Validate a commit SHA query param: 4..40 hex chars, never a flag.
/// Returns null on success, or an error message. Pure.
pub fn validateSha(sha: []const u8) ?[]const u8 {
    if (sha.len < 4 or sha.len > 40) return "sha must be 4..40 characters";
    if (sha[0] == '-') return "sha must not start with '-'";
    for (sha) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return "sha must be hexadecimal";
    }
    return null;
}

const log_format = "%H%x1f%h%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%b%x1e";

/// Use case — list commits at `path` with pagination. Takes primitives,
/// returns a domain struct. No HTTP types. Returns
/// `error.NotARepository` when `path` is not inside a git repo.
fn listCommitsUseCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limit: usize,
    skip: usize,
) !CommitsListResult {
    const git_dir_check = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path, "rev-parse", "--git-dir" },
    }) catch return error.NotARepository;
    if (git_dir_check.term.exited != 0) return error.NotARepository;

    const branch_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path, "branch", "--show-current" },
    }) catch return error.NotARepository;
    const branch = std.mem.trim(u8, branch_result.stdout, " \n\r\t");

    // Best-effort total for the `N of TOTAL` footer. Zero when the repo
    // has no commits yet or the count fails.
    var total_count: i64 = 0;
    if (std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path, "rev-list", "--count", "HEAD" },
    })) |count_result| {
        if (count_result.term.exited == 0) {
            total_count = std.fmt.parseInt(i64, std.mem.trim(u8, count_result.stdout, " \n\r\t"), 10) catch 0;
        }
    } else |_| {}

    const limit_buf = try std.fmt.allocPrint(allocator, "--max-count={d}", .{limit});
    const skip_buf = try std.fmt.allocPrint(allocator, "--skip={d}", .{skip});
    const log_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path, "log", skip_buf, limit_buf, "--format=" ++ log_format },
    }) catch return error.NotARepository;
    if (log_result.term.exited != 0) return error.NotARepository;

    const commits = try parseLogRecords(allocator, log_result.stdout);
    return CommitsListResult{
        .branch = branch,
        .total_count = total_count,
        .commits = commits,
    };
}

/// HTTP handler for `GET /api/git/commits?path=<repo>[&limit=100][&skip=0]`.
/// 200: `{ "is_git_repo": true, "branch": "main", "total_count": 300,
/// "commits": [{ "sha": ..., "short_sha": "3bc0e389", "author": ... }] }`.
pub fn gitCommitsListHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const path_param = req.query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing path parameter" }) });
    };
    if (validateRepoPath(path_param)) |err_msg| {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = err_msg }) });
    }

    const result = listCommitsUseCase(allocator, ctx.io, path_param, parseLimit(req.query.get("limit")), parseSkip(req.query.get("skip"))) catch |err| switch (err) {
        error.NotARepository => {
            const empty = http_response.GitCommitsResponse{ .is_git_repo = false };
            return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitCommitsResponse(allocator, empty) });
        },
        else => return err,
    };

    const entries = try allocator.alloc(http_response.GitCommitEntry, result.commits.len);
    for (result.commits, 0..) |c, i| {
        entries[i] = .{
            .sha = c.sha,
            .short_sha = c.short_sha,
            .author = c.author,
            .email = c.email,
            .timestamp = c.timestamp,
            .subject = c.subject,
            .body = c.body,
        };
    }

    const response = http_response.GitCommitsResponse{
        .is_git_repo = true,
        .branch = result.branch,
        .total_count = result.total_count,
        .commits = entries,
    };
    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitCommitsResponse(allocator, response) });
}

/// HTTP handler for `GET /api/git/commit?path=<repo>&sha=<sha>`. 200: full
/// message + author/date + touched files. 400 on missing/invalid
/// `path`/`sha`; 404 when the path is not a repo or the SHA does not resolve.
pub fn gitCommitDetailHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const path_param = req.query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing path parameter" }) });
    };
    if (validateRepoPath(path_param)) |err_msg| {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = err_msg }) });
    }
    const sha_param = req.query.get("sha") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing sha parameter" }) });
    };
    if (validateSha(sha_param)) |err_msg| {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = err_msg }) });
    }

    const git_dir_check = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "rev-parse", "--git-dir" },
    }) catch {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "not a git repository" }) });
    };
    if (git_dir_check.term.exited != 0) {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "not a git repository" }) });
    }

    const show_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "show", "-s", "--format=" ++ log_format, sha_param },
    }) catch {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "commit not found" }) });
    };
    if (show_result.term.exited != 0) {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "commit not found" }) });
    }
    const parsed = try parseLogRecords(allocator, show_result.stdout);
    if (parsed.len == 0) {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "commit not found" }) });
    }
    const c = parsed[0];

    var files: []const CommitFileEntry = &.{};
    if (std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "diff-tree", "--no-commit-id", "--name-status", "-r", c.sha },
    })) |diff_result| {
        if (diff_result.term.exited == 0) {
            files = try parseNameStatus(allocator, diff_result.stdout);
        }
    } else |_| {}

    const wire_files = try allocator.alloc(http_response.GitCommitFileEntry, files.len);
    for (files, 0..) |f, i| {
        wire_files[i] = .{ .status = f.status, .path = f.path };
    }

    const response = http_response.GitCommitDetailResponse{
        .sha = c.sha,
        .short_sha = c.short_sha,
        .author = c.author,
        .email = c.email,
        .timestamp = c.timestamp,
        .subject = c.subject,
        .body = c.body,
        .files = wire_files,
    };
    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitCommitDetailResponse(allocator, response) });
}

/// Validate a `file` query param for the commit file-diff endpoint. The value
/// reaches git as an argv element after `--` (never a shell string), so this
/// guards against flag injection and path escape.
pub fn validateCommitFile(file: []const u8) ?[]const u8 {
    if (file.len == 0) return "file is required";
    if (file.len > 4096) return "file exceeds 4096 characters";
    if (std.mem.indexOfScalar(u8, file, 0) != null) return "file contains a null byte";
    if (file[0] == '-') return "file must not start with '-'";
    if (std.fs.path.isAbsolute(file)) return "file must be relative";
    if (std.mem.indexOf(u8, file, "..") != null) return "file must not contain '..' segments";
    for (file) |c| {
        if (c < 0x20 or c == 0x7f) return "file contains a control character";
    }
    return null;
}

/// HTTP handler for `GET
/// /api/git/commit/file?path=<repo>&sha=<sha>&file=<path>`. 200: `{ "sha":
/// ..., "path": ..., "diff_content": "<unified diff>" }` with the file's diff
pub fn gitCommitFileDiffHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const path_param = req.query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing path parameter" }) });
    };
    if (validateRepoPath(path_param)) |err_msg| {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = err_msg }) });
    }
    const sha_param = req.query.get("sha") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing sha parameter" }) });
    };
    if (validateSha(sha_param)) |err_msg| {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = err_msg }) });
    }
    const file_param = req.query.get("file") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing file parameter" }) });
    };
    if (validateCommitFile(file_param)) |err_msg| {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = err_msg }) });
    }

    const git_dir_check = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "rev-parse", "--git-dir" },
    }) catch {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "not a git repository" }) });
    };
    if (git_dir_check.term.exited != 0) {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "not a git repository" }) });
    }

    // Resolve the SHA first so an unknown ref is a 404, not an empty diff.
    const verify_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "rev-parse", "--verify", sha_param },
    }) catch {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "commit not found" }) });
    };
    if (verify_result.term.exited != 0) {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "commit not found" }) });
    }

    var diff_content: []const u8 = "";
    const parent_ref = try std.fmt.allocPrint(allocator, "{s}^", .{sha_param});
    if (std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "diff", parent_ref, sha_param, "--", file_param },
    })) |diff_result| {
        if (diff_result.term.exited == 0 or diff_result.term.exited == 1) {
            diff_content = diff_result.stdout;
        }
    } else |_| {}
    if (diff_content.len == 0) {
        // Root commit (no parent) or merge — `git show` always renders.
        if (std.process.run(allocator, io, .{
            .argv = &.{ "git", "-C", path_param, "show", "--format=", sha_param, "--", file_param },
        })) |show_result| {
            if (show_result.term.exited == 0 or show_result.term.exited == 1) {
                diff_content = show_result.stdout;
            }
        } else |_| {}
    }

    const response = http_response.GitCommitFileDiffResponse{
        .sha = sha_param,
        .path = file_param,
        .diff_content = diff_content,
    };
    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitCommitFileDiffResponse(allocator, response) });
}

// ===== Tests =====
const testing = std.testing;
test "parseLogRecords parses two records with unit separators" {
    const raw = "abc123def456\tu001fab\tu0041lice\tu0041lice@x.io\tu00411700000000\tu0041feat: one\tu0041body one\tu001e" ++
        "def456abc123\tu0044ef\tu0042ob\tu0042ob@x.io\tu00411700000999\tu0044fix: two\tu0044\tu001e";
    // Rebuild with real control bytes (the literal above uses placeholders).
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "abc123def456\x1fabc1234\x1fAlice\x1falice@x.io\x1f1700000000\x1ffeat: one\x1fbody one\x1e");
    try buf.appendSlice(testing.allocator, "def456abc123\x1fdef456a\x1fBob\x1fbob@x.io\x1f1700000999\x1ffix: two\x1f\x1e");
    _ = raw;
    const entries = try parseLogRecords(testing.allocator, buf.items);
    defer freeCommitEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("abc123def456", entries[0].sha);
    try testing.expectEqualStrings("abc1234", entries[0].short_sha);
    try testing.expectEqualStrings("Alice", entries[0].author);
    try testing.expectEqual(@as(i64, 1700000000), entries[0].timestamp);
    try testing.expectEqualStrings("feat: one", entries[0].subject);
    try testing.expectEqualStrings("body one", entries[0].body);
    try testing.expectEqualStrings("", entries[1].body);
}

test "parseLogRecords skips blank and malformed records" {
    const raw = "\x1e\n  \x1eonly-one-field\x1e\x1e";
    const entries = try parseLogRecords(testing.allocator, raw);
    defer freeCommitEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "parseNameStatus parses modify/add/delete and rename rows" {
    const raw = "M\tsrc/main.zig\nA\tsrc/new.zig\nD\told.txt\nR100\told/name.zig\tnew/name.zig\n";
    const files = try parseNameStatus(testing.allocator, raw);
    defer {
        for (files) |f| {
            testing.allocator.free(f.status);
            testing.allocator.free(f.path);
        }
        testing.allocator.free(files);
    }
    try testing.expectEqual(@as(usize, 4), files.len);
    try testing.expectEqualStrings("M", files[0].status);
    try testing.expectEqualStrings("src/main.zig", files[0].path);
    try testing.expectEqualStrings("R", files[3].status);
    try testing.expectEqualStrings("old/name.zig -> new/name.zig", files[3].path);
}

test "parseLimit clamps to 1..200 with default 100" {
    try testing.expectEqual(@as(usize, 100), parseLimit(null));
    try testing.expectEqual(@as(usize, 100), parseLimit("bogus"));
    try testing.expectEqual(@as(usize, 1), parseLimit("0"));
    try testing.expectEqual(@as(usize, 50), parseLimit("50"));
    try testing.expectEqual(@as(usize, 200), parseLimit("9999"));
}

test "parseSkip defaults to 0" {
    try testing.expectEqual(@as(usize, 0), parseSkip(null));
    try testing.expectEqual(@as(usize, 0), parseSkip("bogus"));
    try testing.expectEqual(@as(usize, 25), parseSkip("25"));
}

test "validateSha accepts hex and rejects flags and junk" {
    try testing.expect(validateSha("3bc0e389") == null);
    try testing.expect(validateSha("ABCDEF1234") == null);
    try testing.expect(validateSha("--help") != null);
    try testing.expect(validateSha("-C/etc") != null);
    try testing.expect(validateSha("ab") != null);
    try testing.expect(validateSha("zzzz") != null);
}

test "validateCommitFile accepts relative paths and rejects escapes" {
    try testing.expect(validateCommitFile("src/main.zig") == null);
    try testing.expect(validateCommitFile("a b/c.txt") == null);
    try testing.expect(validateCommitFile("") != null);
    try testing.expect(validateCommitFile("--output=/tmp/x") != null);
    try testing.expect(validateCommitFile("/etc/passwd") != null);
    try testing.expect(validateCommitFile("../escape.zig") != null);
    try testing.expect(validateCommitFile("a\nb") != null);
}
