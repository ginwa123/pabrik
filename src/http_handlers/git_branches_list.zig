const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;
const git_route = @import("git_route.zig");

/// Domain error set for the branch-list use case.
const BranchListError = error{NotARepository};

/// One branch row, HTTP-layer free.
pub const BranchEntry = struct {
    name: []const u8,
    is_remote: bool,
    is_current: bool,
    is_default: bool,
};

const BranchListResult = struct {
    /// Empty in a bare repo or on a detached HEAD — the picker then has
    /// no highlighted row.
    current_branch: []const u8,
    branches: []const BranchEntry,
};

/// A row parsed out of `git for-each-ref`'s tab-separated output.
pub const RawRef = struct {
    name: []const u8,
    is_remote: bool,
};

/// Validate the `path` query param before it is handed to `git -C`. Pure — no
/// IO. Returns null on success, or an error message.
pub fn validateRepoPath(path: []const u8) ?[]const u8 {
    if (path.len == 0) return "path is required";
    if (path.len > 4096) return "path exceeds 4096 characters";
    if (std.mem.indexOfScalar(u8, path, 0) != null) return "path contains a null byte";
    if (!std.fs.path.isAbsolute(path)) return "path must be absolute";
    if (path[0] == '-') return "path must not start with '-'";
    if (std.mem.indexOf(u8, path, "..") != null) return "path must not contain '..' segments";
    for (path) |c| {
        if (c < 0x20 or c == 0x7f) return "path contains a control character";
    }
    return null;
}

/// Parse the tab-separated `%(refname)\t%(refname:short)\t%(symref)` output
/// of `git for-each-ref refs/heads refs/remotes` into short-name rows.
pub fn parseRefRows(allocator: std.mem.Allocator, raw: []const u8) ![]RawRef {
    var out: std.ArrayList(RawRef) = .empty;
    errdefer {
        for (out.items) |r| allocator.free(r.name);
        out.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \r\t");
        if (trimmed_line.len == 0) continue;

        var fields = std.mem.splitScalar(u8, trimmed_line, '\t');
        const full = fields.next() orelse continue;
        const short = fields.next() orelse continue;
        const symref = fields.next() orelse "";

        if (std.mem.trim(u8, symref, " \r\t").len > 0) continue;
        if (std.mem.endsWith(u8, full, "/HEAD")) continue;
        if (std.mem.trim(u8, short, " ").len == 0) continue;

        try out.append(allocator, .{
            .name = try allocator.dupe(u8, std.mem.trim(u8, short, " ")),
            .is_remote = std.mem.startsWith(u8, full, "refs/remotes/"),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Release a slice returned by `parseRefRows`.
pub fn freeRawRefs(allocator: std.mem.Allocator, refs: []const RawRef) void {
    for (refs) |r| allocator.free(r.name);
    allocator.free(refs);
}

/// Pick the default base ref name from parsed rows.
pub fn pickDefaultRef(refs: []const RawRef) []const u8 {
    const preferred = [_][]const u8{ "main", "master", "develop" };
    for (preferred) |name| {
        var buf: [64]u8 = undefined;
        const remote_name = std.fmt.bufPrint(buf[0..], "origin/{s}", .{name}) catch continue;
        for (refs) |r| {
            if (std.mem.eql(u8, r.name, remote_name)) return r.name;
        }
    }
    for (preferred) |name| {
        for (refs) |r| {
            if (std.mem.eql(u8, r.name, name)) return r.name;
        }
    }
    for (refs) |r| {
        if (r.is_remote) return r.name;
    }
    return "";
}

/// Stable ordering for the picker: `default_name` first (when present), then
/// every remote-tracking ref, then every local branch.
pub fn orderRefs(
    allocator: std.mem.Allocator,
    refs: []const RawRef,
    default_name: []const u8,
) ![]RawRef {
    var out: std.ArrayList(RawRef) = .empty;
    errdefer out.deinit(allocator);

    if (default_name.len > 0) {
        for (refs) |r| {
            if (std.mem.eql(u8, r.name, default_name)) {
                try out.append(allocator, r);
                break;
            }
        }
    }
    for (refs) |r| {
        if (r.is_remote and !std.mem.eql(u8, r.name, default_name)) {
            try out.append(allocator, r);
        }
    }
    for (refs) |r| {
        if (!r.is_remote and !std.mem.eql(u8, r.name, default_name)) {
            try out.append(allocator, r);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Use case — ask git for the repo's branches at `path`. Takes primitives,
/// returns a domain struct. No HTTP types.
fn listBranchesUseCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !BranchListResult {
    // 1) Confirm it's a git repo.
    const git_dir_check = git_route.run(allocator, io, path, &.{ "rev-parse", "--git-dir" }, .{}) catch return error.NotARepository;
    if (git_dir_check.term.exited != 0) return error.NotARepository;

    // 2) Current branch. Empty in a bare repo / detached HEAD.
    const current_result = git_route.run(allocator, io, path, &.{ "branch", "--show-current" }, .{}) catch return error.NotARepository;
    const current_branch = std.mem.trim(u8, current_result.stdout, " \n\r\t");

    // 3) Every local + remote-tracking ref, with symbolic refs flagged
    //    in the third column so parseRefRows can drop them.
    const refs_result = git_route.run(allocator, io, path, &.{
        "for-each-ref", "--format=%(refname)%09%(refname:short)%09%(symref)", "refs/heads",
        "refs/remotes",
    }, .{}) catch return error.NotARepository;
    if (refs_result.term.exited != 0) return error.NotARepository;

    const parsed = try parseRefRows(allocator, refs_result.stdout);
    const default_name = pickDefaultRef(parsed);
    const ordered = try orderRefs(allocator, parsed, default_name);

    const entries = try allocator.alloc(BranchEntry, ordered.len);
    for (ordered, 0..) |r, i| {
        entries[i] = .{
            .name = r.name,
            .is_remote = r.is_remote,
            .is_current = current_branch.len > 0 and std.mem.eql(u8, r.name, current_branch),
            .is_default = default_name.len > 0 and std.mem.eql(u8, r.name, default_name),
        };
    }

    return BranchListResult{
        .current_branch = current_branch,
        .branches = entries,
    };
}

/// HTTP handler for `GET /api/git/branches?path=<repo>`.
pub fn gitBranchesListHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const path_param = req.query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing path parameter" }) });
    };
    if (validateRepoPath(path_param)) |err_msg| {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = err_msg }) });
    }

    const result = listBranchesUseCase(allocator, ctx.io, path_param) catch |err| switch (err) {
        error.NotARepository => {
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "not a git repository" }) });
        },
        // Allocator failures (OOM) fall through to the server's generic 500.
        // The explicit `else` is required: the use case's error set is
        // inferred and includes `std.mem.Allocator.Error`.
        else => return err,
    };

    const entries = try allocator.alloc(http_response.GitBranchEntry, result.branches.len);
    for (result.branches, 0..) |b, i| {
        entries[i] = .{
            .name = b.name,
            .is_remote = b.is_remote,
            .is_current = b.is_current,
            .is_default = b.is_default,
        };
    }

    const response = http_response.GitBranchesResponse{
        .is_git_repo = true,
        .current_branch = result.current_branch,
        .branches = entries,
    };
    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitBranchesResponse(allocator, response) });
}

// ===== Tests =====
const testing = std.testing;
// ─── validateRepoPath ─────────────────────────────────────────────────────

test "validateRepoPath accepts an absolute path" {
    try testing.expect(validateRepoPath("/home/you/repo") == null);
    try testing.expect(validateRepoPath("/home/you/repo with spaces") == null);
}

test "validateRepoPath rejects empty, relative, dash-prefixed, and traversal paths" {
    try testing.expect(validateRepoPath("") != null);
    try testing.expect(validateRepoPath("relative/repo") != null);
    try testing.expect(validateRepoPath("-C/etc/passwd") != null);
    try testing.expect(validateRepoPath("/home/you/../etc") != null);
}

test "validateRepoPath rejects control characters and oversized paths" {
    try testing.expect(validateRepoPath("/home/you/re\npo") != null);
    var big: [4097]u8 = undefined;
    @memset(big[0..], 'a');
    big[0] = '/';
    try testing.expect(validateRepoPath(big[0..]) != null);
}

// ─── parseRefRows ─────────────────────────────────────────────────────────

test "parseRefRows drops symbolic HEAD refs and keeps short names" {
    const raw =
        "refs/heads/main\tmain\t\n" ++
        "refs/remotes/origin/HEAD\torigin\trefs/remotes/origin/main\n" ++
        "refs/remotes/origin/main\torigin/main\t\n" ++
        "refs/heads/fix/x\tfix/x\t\n";

    const rows = try parseRefRows(testing.allocator, raw);
    defer freeRawRefs(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("main", rows[0].name);
    try testing.expect(!rows[0].is_remote);
    try testing.expectEqualStrings("origin/main", rows[1].name);
    try testing.expect(rows[1].is_remote);
    try testing.expectEqualStrings("fix/x", rows[2].name);
    try testing.expect(!rows[2].is_remote);
}

test "parseRefRows skips blank lines, malformed rows, and whitespace symrefs" {
    const raw =
        "\n" ++
        "refs/heads/only-one-field\n" ++
        // The /HEAD full-refname guard catches this row even though the
        // symref column is whitespace-only (a build of git that did not
        // report the symref target would otherwise surface a bogus branch
        "refs/remotes/origin/HEAD\torigin\t   \n" ++
        "refs/heads/main\tmain\t\n" ++
        "\n";

    const rows = try parseRefRows(testing.allocator, raw);
    defer freeRawRefs(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("main", rows[0].name);
}

test "parseRefRows on empty output returns an empty slice" {
    const rows = try parseRefRows(testing.allocator, "");
    defer freeRawRefs(testing.allocator, rows);
    try testing.expectEqual(@as(usize, 0), rows.len);
}

// ─── pickDefaultRef ───────────────────────────────────────────────────────

test "pickDefaultRef prefers origin/main over locals and other remotes" {
    const rows = [_]RawRef{
        .{ .name = "main", .is_remote = false },
        .{ .name = "origin/dev", .is_remote = true },
        .{ .name = "origin/main", .is_remote = true },
    };
    try testing.expectEqualStrings("origin/main", pickDefaultRef(&rows));
}

test "pickDefaultRef falls back to a local main, then to the first remote" {
    const local_only = [_]RawRef{
        .{ .name = "feature/x", .is_remote = false },
        .{ .name = "main", .is_remote = false },
    };
    try testing.expectEqualStrings("main", pickDefaultRef(&local_only));

    const remote_only = [_]RawRef{
        .{ .name = "release", .is_remote = false },
        .{ .name = "origin/trunk", .is_remote = true },
    };
    try testing.expectEqualStrings("origin/trunk", pickDefaultRef(&remote_only));

    const none = [_]RawRef{};
    try testing.expectEqualStrings("", pickDefaultRef(&none));
}

// ─── orderRefs ────────────────────────────────────────────────────────────

test "orderRefs hoists the default, then remotes, then locals" {
    const rows = [_]RawRef{
        .{ .name = "fix/x", .is_remote = false },
        .{ .name = "main", .is_remote = false },
        .{ .name = "origin/dev", .is_remote = true },
        .{ .name = "origin/main", .is_remote = true },
    };
    const ordered = try orderRefs(testing.allocator, &rows, "origin/main");
    defer testing.allocator.free(ordered);

    try testing.expectEqual(@as(usize, 4), ordered.len);
    try testing.expectEqualStrings("origin/main", ordered[0].name);
    try testing.expectEqualStrings("origin/dev", ordered[1].name);
    try testing.expectEqualStrings("fix/x", ordered[2].name);
    try testing.expectEqualStrings("main", ordered[3].name);
}

test "orderRefs keeps every row when the default name matches nothing" {
    const rows = [_]RawRef{
        .{ .name = "a", .is_remote = false },
        .{ .name = "origin/b", .is_remote = true },
    };
    const ordered = try orderRefs(testing.allocator, &rows, "origin/missing");
    defer testing.allocator.free(ordered);

    try testing.expectEqual(@as(usize, 2), ordered.len);
    try testing.expectEqualStrings("origin/b", ordered[0].name);
    try testing.expectEqualStrings("a", ordered[1].name);
}
