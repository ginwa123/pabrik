const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;
const git_route = @import("git_route.zig");

/// Batch file diff endpoint — collapses the SidebarDiffPanel N+1 fan-out (one
/// `GET /api/git/file/diff` per changed file) into at most 2 git spawns.
pub const MAX_BATCH_FILES: usize = 200;
pub const MAX_PER_FILE_BYTES: usize = 512 * 1024;

pub const BatchFileItem = struct {
    file: []const u8,
    staged: bool = false,
};

/// Request body.
pub const BatchDiffBody = struct {
    path: []const u8,
    files: ?[]BatchFileItem = null,
    folder: ?[]const u8 = null,
    /// WHOLE-FILE mode — `git diff -U<all>` for exactly ONE path, so the
    /// client can render every line of the file with the changes still
    /// marked.
    whole_file: ?bool = null,
};

pub const BatchDiffEntry = struct {
    path: []const u8,
    diff_content: []const u8,
    staged: bool,
};

pub const BatchDiffResponse = struct {
    diffs: []BatchDiffEntry,
    /// Set when a whole-file request could not be answered in full (the diff
    /// exceeds `MAX_WHOLE_FILE_BYTES`). The entry's `diff_content` is then
    /// EMPTY — never a partial file, which would read as a complete one.
    whole_file_refused: bool = false,
};

/// Split a combined `git diff` output into per-file chunks.
/// Returns slices into `combined` — caller keeps `combined` alive.
pub fn splitCombinedDiff(allocator: std.mem.Allocator, combined: []const u8) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    if (combined.len == 0) return map;
    const marker = "diff --git ";
    var starts = std.ArrayList(usize).empty;
    defer starts.deinit(allocator);
    var idx: usize = 0;
    while (std.mem.indexOf(u8, combined[idx..], marker)) |rel| {
        starts.append(allocator, idx + rel) catch break;
        idx += rel + marker.len;
    }
    for (starts.items, 0..) |start, i| {
        const end = if (i + 1 < starts.items.len) starts.items[i + 1] else combined.len;
        const chunk = combined[start..end];
        const path = extractDiffPath(chunk) orelse continue;
        // First chunk wins for a path; duplicates shouldn't happen within
        // one (staged|unstaged) output.
        if (!map.contains(path)) {
            map.put(path, chunk) catch continue;
        }
    }
    return map;
}

/// Extract the repo-relative path from one `diff --git` chunk.
/// Prefers `+++ b/<path>`, falls back to `--- a/<path>`, then the
/// `diff --git a/<x> b/<y>` header's b-side.
fn extractDiffPath(chunk: []const u8) ?[]const u8 {
    // +++ b/<path>
    if (std.mem.indexOf(u8, chunk, "\n+++ b/")) |pos| {
        const s = pos + "\n+++ b/".len;
        const e = std.mem.indexOfScalar(u8, chunk[s..], '\n') orelse (chunk.len - s);
        const p = std.mem.trim(u8, chunk[s .. s + e], " \t\r");
        if (p.len > 0) return p;
    }
    // --- a/<path> (deleted files have /dev/null on the +++ side)
    if (std.mem.indexOf(u8, chunk, "\n--- a/")) |pos| {
        const s = pos + "\n--- a/".len;
        const e = std.mem.indexOfScalar(u8, chunk[s..], '\n') orelse (chunk.len - s);
        const p = std.mem.trim(u8, chunk[s .. s + e], " \t\r");
        if (p.len > 0 and !std.mem.eql(u8, p, "/dev/null")) return p;
    }
    // diff --git a/<x> b/<y>
    if (std.mem.indexOf(u8, chunk, "diff --git ")) |pos| {
        const rest = chunk[pos + "diff --git ".len ..];
        // rest = "a/<x> b/<y>\n..."
        if (std.mem.indexOf(u8, rest, " b/")) |bpos| {
            const s = bpos + " b/".len;
            const e = std.mem.indexOfAny(u8, rest[s..], " \t\n\r") orelse (rest.len - s);
            const p = rest[s .. s + e];
            if (p.len > 0) return p;
        }
    }
    return null;
}

/// True when `folder` is usable as a `git diff -- <pathspec>` argument.
pub fn isSafeRelativeFolder(folder: []const u8) bool {
    if (std.fs.path.isAbsolute(folder)) return false;
    // Windows-style absolute ("C:\x", "\\server\share") is not isAbsolute on
    // every platform this builds for.
    if (std.mem.indexOf(u8, folder, "\\") != null) return false;
    var it = std.mem.tokenizeScalar(u8, folder, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

/// Turn `git status --porcelain` output into the same (file, staged) target
/// list a LIST-mode caller would have sent.
pub fn parseStatusTargets(allocator: std.mem.Allocator, porcelain: []const u8) ![]BatchFileItem {
    var targets = std.ArrayList(BatchFileItem).empty;
    errdefer freeTargetList(allocator, targets.items);

    var start: usize = 0;
    while (start < porcelain.len) {
        const nl = std.mem.indexOfScalar(u8, porcelain[start..], '\n') orelse (porcelain.len - start);
        const line = porcelain[start .. start + nl];
        start += nl + 1;
        // Porcelain v1 is "XY<space><path>"; short lines are junk.
        if (line.len < 4) continue;
        const x = line[0];
        const y = line[1];
        var file = std.mem.trim(u8, line[3..], " \t\r");
        if (file.len == 0) continue;
        // Rename/copy porcelain prints "old -> new". Diff against the new
        // side, which is what `+++ b/` carries too.
        if (std.mem.indexOf(u8, file, " -> ")) |arrow| file = std.mem.trim(u8, file[arrow + 4 ..], " \t\r");
        if (file.len == 0) continue;

        const untracked = x == '?' and y == '?';
        if (!untracked and x != ' ') {
            const dup = try allocator.dupe(u8, file);
            try targets.append(allocator, .{ .file = dup, .staged = true });
        }
        if (y != ' ' and !untracked) {
            const dup = try allocator.dupe(u8, file);
            try targets.append(allocator, .{ .file = dup, .staged = false });
        }
        if (untracked) {
            const dup = try allocator.dupe(u8, file);
            try targets.append(allocator, .{ .file = dup, .staged = false });
        }
    }
    return try targets.toOwnedSlice(allocator);
}

pub fn freeTargetList(allocator: std.mem.Allocator, targets: []const BatchFileItem) void {
    for (targets) |t| allocator.free(t.file);
    allocator.free(targets);
}

/// Whole-file mode is a DIFFERENT budget from the panel's diff view.
/// `MAX_PER_FILE_BYTES` truncates a diff and marks the cut, which is fine for
/// a hunk list — the reader scrolls and the diff keeps its meaning.
pub const MAX_WHOLE_FILE_BYTES: usize = 2 * 1024 * 1024;

/// `-U` for whole-file mode.
pub const WHOLE_FILE_UNIFIED_FLAG = "--unified=100000";

/// Marker appended to a diff that exceeded MAX_PER_FILE_BYTES.
pub const TRUNCATION_SUFFIX = "\n... [truncated]\n";

/// Cap a per-file diff at MAX_PER_FILE_BYTES. Every length below is derived
/// from the literal itself.
fn capDiff(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len <= MAX_PER_FILE_BYTES) return try allocator.dupe(u8, s);
    const total = MAX_PER_FILE_BYTES + TRUNCATION_SUFFIX.len;
    const buf = try allocator.alloc(u8, total);
    @memcpy(buf[0..MAX_PER_FILE_BYTES], s[0..MAX_PER_FILE_BYTES]);
    @memcpy(buf[MAX_PER_FILE_BYTES..total], TRUNCATION_SUFFIX);
    return buf;
}

/// Cap a whole-file diff — ALL OR NOTHING. Returns `null` when the body is
/// over `MAX_WHOLE_FILE_BYTES`, in which case the caller serves an empty diff
/// plus `whole_file_refused`.
pub fn capWholeFile(allocator: std.mem.Allocator, s: []const u8) !?[]const u8 {
    if (s.len > MAX_WHOLE_FILE_BYTES) return null;
    return try allocator.dupe(u8, s);
}

fn buildNewFileDiff(allocator: std.mem.Allocator, file_path: []const u8, content: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var line_count: usize = 0;
    for (content) |c| {
        if (c == '\n') line_count += 1;
    }
    if (content.len > 0 and content[content.len - 1] != '\n') line_count += 1;
    try buf.appendSlice(allocator, "diff --git a/");
    try buf.appendSlice(allocator, file_path);
    try buf.appendSlice(allocator, " b/");
    try buf.appendSlice(allocator, file_path);
    try buf.appendSlice(allocator, "\nnew file mode\n--- /dev/null\n+++ b/");
    try buf.appendSlice(allocator, file_path);
    try buf.appendSlice(allocator, "\n@@ -0,0 +1,");
    const n_str = try std.fmt.allocPrint(allocator, "{}", .{line_count});
    defer allocator.free(n_str);
    try buf.appendSlice(allocator, n_str);
    try buf.appendSlice(allocator, " @@\n");
    var start: usize = 0;
    while (std.mem.indexOfScalar(u8, content[start..], '\n')) |rel| {
        try buf.appendSlice(allocator, "+");
        try buf.appendSlice(allocator, content[start .. start + rel]);
        try buf.append(allocator, '\n');
        start += rel + 1;
    }
    if (start < content.len) {
        try buf.appendSlice(allocator, "+");
        try buf.appendSlice(allocator, content[start..]);
        try buf.append(allocator, '\n');
    }
    return try buf.toOwnedSlice(allocator);
}

fn readHostFile(io: std.Io, allocator: std.mem.Allocator, abs: []const u8) ?[]u8 {
    const f = std.Io.Dir.openFileAbsolute(io, abs, .{}) catch return null;
    defer f.close(io);
    var read_buf: [8192]u8 = undefined;
    var reader = f.reader(io, &read_buf);
    return reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch null;
}

/// Bytes of a file the diff never mentioned: an untracked file has no diff, so
/// its `new file` hunk is built from the file itself. The read is ROUTED — under
/// `--saas` the bytes live in the guest and this host holds no copy, so a new
/// file used to reach the panel as "no changes" while `git status` listed it.
fn readNewFile(allocator: std.mem.Allocator, io: std.Io, repo_path: []const u8, file: []const u8) ?[]u8 {
    const full = std.fs.path.join(allocator, &.{ repo_path, file }) catch return null;
    defer allocator.free(full);
    // `openFileAbsolute` ASSERTS the path is absolute and ABORTS the whole
    // process (Debug/ReleaseSafe) instead of returning an error, so never
    // hand it a relative path — `repo_path` is validated at the handler
    if (!std.fs.path.isAbsolute(full)) return null;
    var route = git_route.routeFor(allocator, repo_path);
    defer route.deinit();
    return switch (route) {
        .unavailable => null,
        // `file` is relative to `repo_path` and the guest refuses `.`/`..`
        // segments when it resolves the path inside the workspace, so the
        // joined form cannot climb out (`fs.readAll` -> `policy.relativeWorkspace`).
        .guest => |*fs| fs.readAll(full) catch null,
        .host => readHostFile(io, allocator, full),
    };
}

fn syntheticFallback(allocator: std.mem.Allocator, io: std.Io, repo_path: []const u8, file: []const u8) ![]const u8 {
    const content = readNewFile(allocator, io, repo_path, file) orelse return try allocator.dupe(u8, "");
    defer allocator.free(content);
    if (content.len == 0) return try allocator.dupe(u8, "");
    return try buildNewFileDiff(allocator, file, content);
}

/// POST /api/git/file/diffs — batch diffs in a fixed number of git spawns.
pub fn gitFileDiffsHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    if (req.body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Request body required") });
    }
    const parsed = std.json.parseFromSliceLeaky(BatchDiffBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Invalid JSON body") });
    };
    if (parsed.path.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path") });
    }
    // `parsed.path` is the repo root used as the BASE of every
    // `std.fs.path.join` below, and the joined values reach
    // `std.Io.Dir.openFileAbsolute` in `syntheticFallback`.
    if (!std.fs.path.isAbsolute(parsed.path)) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "path must be an absolute directory") });
    }
    const no_files: []const BatchFileItem = &.{};
    const list_mode_files: []const BatchFileItem = parsed.files orelse no_files;
    // Folder mode only when the caller sent `folder` and did NOT send a file
    // list. A caller that sends both gets list mode — it named the paths.
    const folder_mode = parsed.folder != null and list_mode_files.len == 0;
    if (!folder_mode and list_mode_files.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "No files") });
    }
    const whole_file = parsed.whole_file orelse false;
    // Whole-file is per FILE by construction: `-U<all>` for one path. A
    // folder-wide or multi-file request would be a multi-megabyte response
    // that the caller only ever asked for one section of.
    if (whole_file and (folder_mode or list_mode_files.len != 1)) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "whole_file needs exactly one file and no folder") });
    }
    if (list_mode_files.len > MAX_BATCH_FILES) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Too many files (max 200)") });
    }

    // FOLDER mode: one `git status` gives the target list. Owned here, freed
    // on exit — `defer` reads the variable at scope exit, so it sees the
    // slice the spawn assigned, not the empty one it started as.
    const folder = parsed.folder orelse "";
    if (folder_mode and !isSafeRelativeFolder(folder)) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "folder must be a repo-relative path without '..'") });
    }
    var owned_targets: []const BatchFileItem = &.{};
    defer freeTargetList(allocator, owned_targets);

    var staged = std.ArrayList([]const u8).empty;
    defer staged.deinit(allocator);
    var unstaged = std.ArrayList([]const u8).empty;
    defer unstaged.deinit(allocator);

    if (folder_mode) {
        var args = std.ArrayList([]const u8).empty;
        defer args.deinit(allocator);
        // `-uall` lists untracked FILES, not the untracked directory that
        // `git status --porcelain` reports by default — otherwise every
        // untracked folder collapses to one `dir/` entry and gets no diff.
        args.appendSlice(allocator, &.{ "status", "--porcelain", "-uall" }) catch {};
        if (folder.len > 0) {
            args.appendSlice(allocator, &.{ "--", folder }) catch {};
        }
        if (git_route.run(allocator, io, parsed.path, args.items, .{})) |result| {
            defer allocator.free(result.stderr);
            defer allocator.free(result.stdout);
            if (result.term.exited == 0 or result.term.exited == 1) {
                owned_targets = parseStatusTargets(allocator, result.stdout) catch &.{};
            }
        } else |_| {}
        for (owned_targets) |t| {
            if (t.staged) {
                staged.append(allocator, t.file) catch continue;
            } else {
                unstaged.append(allocator, t.file) catch continue;
            }
        }
        // Nothing changed under the folder: that is a real answer, not a
        // client error — return an empty list rather than a 400.
        if (owned_targets.len == 0) {
            const empty = std.json.Stringify.valueAlloc(allocator, BatchDiffResponse{ .diffs = &.{} }, .{}) catch return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, "serialize failed") });
            return res.jsonResponse(.{ .status_code = 200, .data = empty });
        }
    } else {
        for (list_mode_files) |f| {
            if (f.file.len == 0) continue;
            if (f.staged) {
                staged.append(allocator, f.file) catch continue;
            } else {
                unstaged.append(allocator, f.file) catch continue;
            }
        }
    }

    // Two git processes, never N. FOLDER mode passes the folder as the
    // pathspec so argv stays 7 entries however many files changed; LIST mode
    // passes the paths the caller named.
    var staged_out: []u8 = &.{};
    var unstaged_out: []u8 = &.{};
    if (staged.items.len > 0) {
        var args = std.ArrayList([]const u8).empty;
        defer args.deinit(allocator);
        args.appendSlice(allocator, &.{ "diff", "--cached" }) catch {};
        if (whole_file) args.append(allocator, WHOLE_FILE_UNIFIED_FLAG) catch {};
        args.append(allocator, "--") catch {};
        if (folder_mode) {
            if (folder.len > 0) args.append(allocator, folder) catch {};
        } else {
            args.appendSlice(allocator, staged.items) catch {};
        }
        if (git_route.run(allocator, io, parsed.path, args.items, .{})) |result| {
            defer allocator.free(result.stderr);
            if (result.term.exited == 0 or result.term.exited == 1) {
                staged_out = result.stdout;
            } else {
                allocator.free(result.stdout);
            }
        } else |_| {}
    }
    if (unstaged.items.len > 0) {
        var args = std.ArrayList([]const u8).empty;
        defer args.deinit(allocator);
        args.appendSlice(allocator, &.{ "diff" }) catch {};
        if (whole_file) args.append(allocator, WHOLE_FILE_UNIFIED_FLAG) catch {};
        args.append(allocator, "--") catch {};
        if (folder_mode) {
            if (folder.len > 0) args.append(allocator, folder) catch {};
        } else {
            args.appendSlice(allocator, unstaged.items) catch {};
        }
        if (git_route.run(allocator, io, parsed.path, args.items, .{})) |result| {
            defer allocator.free(result.stderr);
            if (result.term.exited == 0 or result.term.exited == 1) {
                unstaged_out = result.stdout;
            } else {
                allocator.free(result.stdout);
            }
        } else |_| {}
    }
    defer {
        if (staged_out.len > 0) allocator.free(staged_out);
        if (unstaged_out.len > 0) allocator.free(unstaged_out);
    }

    var staged_map = try splitCombinedDiff(allocator, staged_out);
    defer staged_map.deinit();
    var unstaged_map = try splitCombinedDiff(allocator, unstaged_out);
    defer unstaged_map.deinit();

    const targets: []const BatchFileItem = if (folder_mode) owned_targets else list_mode_files;
    var whole_file_refused = false;
    var entries = std.ArrayList(BatchDiffEntry).empty;
    defer entries.deinit(allocator);
    for (targets) |f| {
        if (f.file.len == 0) continue;
        const map = if (f.staged) &staged_map else &unstaged_map;
        var content: []const u8 = map.get(f.file) orelse "";
        var owned: []const u8 = "";
        var need_free = false;
        if (content.len == 0) {
            owned = syntheticFallback(allocator, io, parsed.path, f.file) catch "";
            need_free = owned.len > 0;
            content = owned;
        }
        var capped: []const u8 = "";
        if (whole_file) {
            const maybe = capWholeFile(allocator, content) catch null;
            if (maybe) |full| {
                capped = full;
            } else {
                whole_file_refused = true;
            }
        } else {
            capped = capDiff(allocator, content) catch "";
        }
        if (need_free) allocator.free(owned);
        entries.append(allocator, .{ .path = f.file, .diff_content = capped, .staged = f.staged }) catch continue;
    }

    const response = BatchDiffResponse{ .diffs = entries.items, .whole_file_refused = whole_file_refused };
    const data = try std.json.Stringify.valueAlloc(allocator, response, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
// Splitter is pure (no IO) so it is unit-testable here.

/// A file at `rel` under the repository root, creating parents as needed.
fn writeRepoFile(dir: std.Io.Dir, rel: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(rel)) |parent| try dir.createDirPath(std.testing.io, parent);
    var f = try dir.createFile(std.testing.io, rel, .{});
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, body);
}

test "an untracked file's diff is built from the bytes its tree holds" {
    const allocator = std.testing.allocator;
    var repo = std.testing.tmpDir(.{});
    defer repo.cleanup();
    try writeRepoFile(repo.dir, "docs/note.md", "hello\nworld\n");
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try repo.dir.realPath(std.testing.io, &buf);
    const abs = try allocator.dupe(u8, buf[0..n]);
    defer allocator.free(abs);

    const diff = try syntheticFallback(allocator, std.testing.io, abs, "docs/note.md");
    defer allocator.free(diff);

    try std.testing.expect(std.mem.indexOf(u8, diff, "+++ b/docs/note.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+world") != null);
}

test "capWholeFile passes a body under the cap through unmarked" {
    const allocator = std.testing.allocator;
    const body = "diff --git a/a.txt b/a.txt\n@@ -1 +1 @@\n-old\n+new\n";
    const capped = (try capWholeFile(allocator, body)).?;
    defer allocator.free(capped);
    try std.testing.expectEqualStrings(body, capped);
    // The whole point of the whole-file budget: no truncation marker, because
    // a marked-up file view would claim to be complete.
    try std.testing.expect(std.mem.indexOf(u8, capped, TRUNCATION_SUFFIX) == null);
}

test "capWholeFile accepts the boundary exactly at the cap" {
    const allocator = std.testing.allocator;
    const at_cap = try allocator.alloc(u8, MAX_WHOLE_FILE_BYTES);
    defer allocator.free(at_cap);
    @memset(at_cap, 'x');
    const capped = try capWholeFile(allocator, at_cap);
    try std.testing.expect(capped != null);
    allocator.free(capped.?);
}

test "capWholeFile REFUSES one byte over the cap instead of truncating" {
    const allocator = std.testing.allocator;
    const over = try allocator.alloc(u8, MAX_WHOLE_FILE_BYTES + 1);
    defer allocator.free(over);
    @memset(over, 'x');
    // Null, not a shortened slice: the caller serves an empty diff and sets
    // `whole_file_refused`, so the UI can offer the code viewer. Returning a
    // 2 MiB prefix here would look like the end of the file.
    try std.testing.expect(try capWholeFile(allocator, over) == null);
}

test "whole-file mode is a bigger budget than the panel diff cap" {
    // If these two ever invert, whole-file mode can never serve a file that
    // the hunk view already renders.
    try std.testing.expect(MAX_WHOLE_FILE_BYTES > MAX_PER_FILE_BYTES);
    try std.testing.expect(std.mem.startsWith(u8, WHOLE_FILE_UNIFIED_FLAG, "--unified="));
}

test "splitCombinedDiff splits two files" {
    const allocator = std.testing.allocator;
    const combined =
        "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n" ++
        "diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-x\n+y\n";
    var map = try splitCombinedDiff(allocator, combined);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 2), map.count());
    try std.testing.expect(map.get("a.txt") != null);
    try std.testing.expect(map.get("b.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, map.get("a.txt").?, "+new") != null);
}

test "extractDiffPath prefers b-side" {
    const chunk = "diff --git a/old.txt b/new.txt\n--- a/old.txt\n+++ b/new.txt\n@@ -1 +1 @@\n-x\n+y\n";
    try std.testing.expectEqualStrings("new.txt", extractDiffPath(chunk).?);
}

test "extractDiffPath handles deleted file" {
    const chunk = "diff --git a/gone.txt b/gone.txt\n--- a/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-x\n";
    try std.testing.expectEqualStrings("gone.txt", extractDiffPath(chunk).?);
}

test "splitCombinedDiff empty input" {
    const allocator = std.testing.allocator;
    var map = try splitCombinedDiff(allocator, "");
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 0), map.count());
}

test "isSafeRelativeFolder accepts repo-relative paths and the whole-repo empty string" {
    try std.testing.expect(isSafeRelativeFolder(""));
    try std.testing.expect(isSafeRelativeFolder("src"));
    try std.testing.expect(isSafeRelativeFolder("src/app"));
    try std.testing.expect(isSafeRelativeFolder("src/agentic_loop/tools"));
    // A filename that merely CONTAINS dots is not an escape.
    try std.testing.expect(isSafeRelativeFolder("src/a..b/c"));
}

test "isSafeRelativeFolder rejects absolute and parent-escaping paths" {
    // These become `git diff -- <folder>` argv entries, and `..` would walk
    // the pathspec out of the repo the caller named.
    try std.testing.expect(!isSafeRelativeFolder("/etc"));
    try std.testing.expect(!isSafeRelativeFolder(".."));
    try std.testing.expect(!isSafeRelativeFolder("../sibling"));
    try std.testing.expect(!isSafeRelativeFolder("src/../../etc"));
    try std.testing.expect(!isSafeRelativeFolder("src\\windows"));
}

test "parseStatusTargets routes each porcelain row to the side it belongs to" {
    const allocator = std.testing.allocator;
    // M  staged-and-modified → BOTH sides;  M  worktree-only → unstaged;
    // ?? untracked → unstaged;  A  added → staged.
    const porcelain =
        "MM src/both.txt\n" ++
        " M src/worktree.txt\n" ++
        "A  src/added.txt\n" ++
        "?? src/new.txt\n";
    const targets = try parseStatusTargets(allocator, porcelain);
    defer freeTargetList(allocator, targets);

    try std.testing.expectEqual(@as(usize, 5), targets.len);
    try std.testing.expectEqualStrings("src/both.txt", targets[0].file);
    try std.testing.expect(targets[0].staged);
    try std.testing.expectEqualStrings("src/both.txt", targets[1].file);
    try std.testing.expect(!targets[1].staged);
    try std.testing.expectEqualStrings("src/worktree.txt", targets[2].file);
    try std.testing.expect(!targets[2].staged);
    try std.testing.expectEqualStrings("src/added.txt", targets[3].file);
    try std.testing.expect(targets[3].staged);
    try std.testing.expectEqualStrings("src/new.txt", targets[4].file);
    try std.testing.expect(!targets[4].staged);
}

test "parseStatusTargets never emits an untracked file as staged" {
    const allocator = std.testing.allocator;
    const targets = try parseStatusTargets(allocator, "?? new/a.txt\n?? new/b.txt\n");
    defer freeTargetList(allocator, targets);
    try std.testing.expectEqual(@as(usize, 2), targets.len);
    for (targets) |t| try std.testing.expect(!t.staged);
}

test "parseStatusTargets takes the new side of a rename" {
    const allocator = std.testing.allocator;
    // `+++ b/` in the diff carries the destination too, so a rename must be
    // keyed on the destination or the lookup misses and the file falls back
    // to a synthetic (wrong) new-file diff.
    const targets = try parseStatusTargets(allocator, "R  old/name.txt -> new/name.txt\n");
    defer freeTargetList(allocator, targets);
    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("new/name.txt", targets[0].file);
    try std.testing.expect(targets[0].staged);
}

test "parseStatusTargets skips junk lines and returns nothing for a clean tree" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), (try parseStatusTargets(allocator, "")).len);
    try std.testing.expectEqual(@as(usize, 0), (try parseStatusTargets(allocator, "XY\n")).len);
    const padded = try parseStatusTargets(allocator, "?? name with spaces.txt\n");
    defer freeTargetList(allocator, padded);
    try std.testing.expectEqualStrings("name with spaces.txt", padded[0].file);
}

test "capDiff passes through content at or below the cap" {
    const allocator = std.testing.allocator;
    const exact = try allocator.alloc(u8, MAX_PER_FILE_BYTES);
    defer allocator.free(exact);
    @memset(exact, 'x');

    // Exactly at the cap — boundary, must NOT truncate.
    const at = try capDiff(allocator, exact);
    defer allocator.free(at);
    try std.testing.expectEqual(MAX_PER_FILE_BYTES, at.len);
    try std.testing.expectEqualSlices(u8, exact, at);

    // One below the cap.
    const under = try capDiff(allocator, exact[0 .. MAX_PER_FILE_BYTES - 1]);
    defer allocator.free(under);
    try std.testing.expectEqual(MAX_PER_FILE_BYTES - 1, under.len);
    try std.testing.expectEqualSlices(u8, exact[0 .. MAX_PER_FILE_BYTES - 1], under);
}

test "capDiff truncates one byte over the cap" {
    const allocator = std.testing.allocator;
    const over = try allocator.alloc(u8, MAX_PER_FILE_BYTES + 1);
    defer allocator.free(over);
    @memset(over, 'a');

    // This is the call that used to abort the process: it panicked with
    // "source and destination arguments have non-equal lengths" because the
    // destination slice was 24 bytes and the suffix literal was 17.
    const capped = try capDiff(allocator, over);
    defer allocator.free(capped);

    // Exactly the bytes written. A longer slice would ship uninitialized
    // heap memory to the client through the JSON response.
    try std.testing.expectEqual(MAX_PER_FILE_BYTES + TRUNCATION_SUFFIX.len, capped.len);
    try std.testing.expectEqualSlices(u8, over[0..MAX_PER_FILE_BYTES], capped[0..MAX_PER_FILE_BYTES]);
    try std.testing.expectEqualStrings(TRUNCATION_SUFFIX, capped[MAX_PER_FILE_BYTES..]);
}

test "capDiff output length is independent of how far over the cap the input is" {
    const allocator = std.testing.allocator;
    for ([_]usize{ MAX_PER_FILE_BYTES + 1, MAX_PER_FILE_BYTES + 2, MAX_PER_FILE_BYTES * 4 }) |len| {
        const over = try allocator.alloc(u8, len);
        defer allocator.free(over);
        @memset(over, 'q');

        const capped = try capDiff(allocator, over);
        defer allocator.free(capped);
        try std.testing.expectEqual(MAX_PER_FILE_BYTES + TRUNCATION_SUFFIX.len, capped.len);
        try std.testing.expectEqualStrings(TRUNCATION_SUFFIX, capped[MAX_PER_FILE_BYTES..]);
    }
}
