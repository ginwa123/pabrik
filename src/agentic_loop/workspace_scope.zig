const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;

/// Resolve which workspace a chat session belongs to. Resolution order (first
/// hit wins): 1.
pub fn resolveWorkspaceId(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?[]u8 {
    if (session_id.len == 0) return null;

    // 1. Exact task link.
    {
        var rows = try db.query(allocator,
            \\SELECT wi.workspace_id FROM workspace_item_tasks t
            \\JOIN workspace_items wi ON wi.id = t.workspace_item_id
            \\WHERE t.id = ? LIMIT 1
        , &.{session_id});
        defer rows.deinit();
        if (try rows.next()) |row| {
            defer row.deinit(allocator);
            if (row.values[0].len > 0) return try allocator.dupe(u8, row.values[0]);
            return null;
        }
    }

    // 2. Cwd heuristic.
    const cwd = try sessionCwd(allocator, db, session_id);
    defer if (cwd) |c| allocator.free(c);
    const c = cwd orelse return null;
    if (c.len == 0) return null;
    const match = (try matchWorkspaceByPath(allocator, db, c)) orelse return null;
    defer allocator.free(match.root);
    return match.workspace_id;
}

/// True when both sessions resolve to the same non-null workspace.
/// Empty ids, unresolvable sessions, and cross-workspace pairs all
/// return false (fail closed). A session always matches itself.
pub fn isSameWorkspace(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
    target_session_id: []const u8,
) !bool {
    if (caller_session_id.len == 0 or target_session_id.len == 0) return false;
    if (std.mem.eql(u8, caller_session_id, target_session_id)) return true;
    const a = try resolveWorkspaceId(allocator, db, caller_session_id);
    defer if (a) |x| allocator.free(x);
    const b = try resolveWorkspaceId(allocator, db, target_session_id);
    defer if (b) |x| allocator.free(x);
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Every session id belonging to `workspace_id`: task-linked sessions plus
/// cwd-matched sessions (longest-prefix-wins per session, so a session can
/// never appear in two workspaces).
pub fn workspaceSessionIds(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    if (workspace_id.len == 0) return try out.toOwnedSlice(allocator);

    // Task-linked sessions (exact).
    {
        var rows = try db.query(allocator,
            \\SELECT t.id FROM workspace_item_tasks t
            \\JOIN workspace_items wi ON wi.id = t.workspace_item_id
            \\WHERE wi.workspace_id = ?
        , &.{workspace_id});
        defer rows.deinit();
        while (try rows.next()) |row| {
            defer row.deinit(allocator);
            if (row.values[0].len == 0) continue;
            if (seen.contains(row.values[0])) continue;
            const duped = try allocator.dupe(u8, row.values[0]);
            errdefer allocator.free(duped);
            try seen.put(allocator, duped, {});
            try out.append(allocator, duped);
        }
    }

    // Cwd-matched sessions (heuristic). Sessions already claimed above
    // resolve via the task link first inside resolveWorkspaceId, so
    // re-resolving them here is consistent, not double-counted.
    {
        var rows = try db.query(allocator, "SELECT id FROM sessions", &.{});
        defer rows.deinit();
        while (try rows.next()) |row| {
            defer row.deinit(allocator);
            if (row.values[0].len == 0) continue;
            if (seen.contains(row.values[0])) continue;
            const resolved = try resolveWorkspaceId(allocator, db, row.values[0]);
            defer if (resolved) |r| allocator.free(r);
            const r = resolved orelse continue;
            if (!std.mem.eql(u8, r, workspace_id)) continue;
            const duped = try allocator.dupe(u8, row.values[0]);
            errdefer allocator.free(duped);
            try seen.put(allocator, duped, {});
            try out.append(allocator, duped);
        }
    }

    return try out.toOwnedSlice(allocator);
}

pub fn freeSessionIds(allocator: std.mem.Allocator, ids: [][]u8) void {
    for (ids) |s| allocator.free(s);
    allocator.free(ids);
}

/// The `cwd` recorded on a session, or null when the row is gone or the
/// column is empty.
pub fn sessionCwd(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?[]u8 {
    var rows = try db.query(allocator, "SELECT COALESCE(cwd, '') FROM sessions WHERE id = ? LIMIT 1", &.{session_id});
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        if (row.values[0].len == 0) return null;
        return try allocator.dupe(u8, row.values[0]);
    }
    return null;
}

/// The winning item of the longest-prefix match: both the workspace it
/// belongs to and the directory it names. Both slices are owned by the caller.
pub const WorkspaceMatch = struct {
    workspace_id: []u8,
    root: []u8,

    pub fn deinit(self: WorkspaceMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.root);
    }
};

/// The host directory a session's workspace lives in, by the same order and
/// longest-prefix rule `resolveWorkspaceId` uses. A session whose workspace
/// cannot be located has no root, and its commands must not be guessed at.
pub fn resolveWorkspaceRoot(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?[]u8 {
    if (session_id.len == 0) return null;

    var rows = try db.query(allocator,
        \\SELECT COALESCE(wi.path, '') FROM workspace_item_tasks t
        \\JOIN workspace_items wi ON wi.id = t.workspace_item_id
        \\WHERE t.id = ? LIMIT 1
    , &.{session_id});
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        if (row.values[0].len > 0) return try allocator.dupe(u8, row.values[0]);
    }

    const cwd = (try sessionCwd(allocator, db, session_id)) orelse return null;
    defer allocator.free(cwd);
    if (cwd.len == 0) return null;
    const match = (try matchWorkspaceByPath(allocator, db, cwd)) orelse return null;
    defer allocator.free(match.workspace_id);
    return match.root;
}

/// The workspace an absolute directory belongs to, for a caller that has a
/// path and no session — the HTTP handlers. Same longest-prefix rule as a
/// session's cwd, and the same fail-closed answer when nothing matches.
pub fn resolveWorkspaceForPath(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    abs_path: []const u8,
) !?WorkspaceMatch {
    if (abs_path.len == 0) return null;
    return matchWorkspaceByPath(allocator, db, abs_path);
}

/// Longest-prefix match of `cwd` against `workspace_items.path`. A path
/// matches when it equals `cwd` or is a `/`-bounded prefix of it.
fn matchWorkspaceByPath(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    cwd: []const u8,
) !?WorkspaceMatch {
    var rows = try db.query(allocator,
        \\SELECT workspace_id, path FROM workspace_items
        \\WHERE path IS NOT NULL AND path != ''
    , &.{});
    defer rows.deinit();

    var best_len: usize = 0;
    // Owned copies of the winner (row memory is freed on every row.deinit,
    // so the winner must be duped to survive).
    var winner: ?[]u8 = null;
    var winner_root: ?[]u8 = null;
    errdefer if (winner) |w| allocator.free(w);
    errdefer if (winner_root) |r| allocator.free(r);
    var tied = false;

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        if (row.values[0].len == 0) continue;
        const item_path = std.mem.trimEnd(u8, row.values[1], "/");
        if (item_path.len == 0) continue;
        if (!isPathPrefix(item_path, cwd)) continue;
        if (item_path.len > best_len) {
            best_len = item_path.len;
            tied = false;
            if (winner) |w| allocator.free(w);
            if (winner_root) |r| allocator.free(r);
            winner = try allocator.dupe(u8, row.values[0]);
            winner_root = try allocator.dupe(u8, item_path);
        } else if (item_path.len == best_len and winner != null and
            !std.mem.eql(u8, row.values[0], winner.?))
        {
            // Same-length match from a DIFFERENT workspace: ambiguous.
            tied = true;
        }
    }

    if (tied or winner == null or winner_root == null) {
        if (winner) |w| allocator.free(w);
        if (winner_root) |r| allocator.free(r);
        return null;
    }
    return .{ .workspace_id = winner.?, .root = winner_root.? };
}

fn isPathPrefix(prefix: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (path.len == prefix.len) return true;
    return path[prefix.len] == '/';
}

const testing = std.testing;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  status TEXT DEFAULT 'active',
        \\  cwd TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT,
        \\  item_type TEXT,
        \\  name TEXT,
        \\  path TEXT,
        \\  position INTEGER
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  workspace_item_id TEXT NOT NULL
        \\)
    , &.{});

    // Workspace w1: item i1 (/proj/a) with task-linked session s1.
    // Workspace w2: item i2 (/proj/b) with task-linked session s2.
    try db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position)
        \\VALUES ('i1', 'w1', 'kanban', 'A', '/proj/a', 1),
        \\       ('i2', 'w2', 'kanban', 'B', '/proj/b', 1)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id)
        \\VALUES ('s1', 'T1', 'i1'), ('s2', 'T2', 'i2')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, status, cwd) VALUES
        \\  ('s1', 'Task one', 'active', '/proj/a'),
        \\  ('s2', 'Task two', 'active', '/proj/b'),
        \\  ('s3', 'Plain chat', 'active', '/proj/a/sub'),
        \\  ('s4', 'Elsewhere', 'active', '/elsewhere'),
        \\  ('s5', 'No cwd', 'active', NULL)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

test "resolveWorkspaceId: task-linked sessions resolve exactly" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    const w1 = try resolveWorkspaceId(alloc, &ctx.db, "s1");
    defer if (w1) |w| alloc.free(w);
    try testing.expect(w1 != null);
    try testing.expectEqualStrings("w1", w1.?);

    const w2 = try resolveWorkspaceId(alloc, &ctx.db, "s2");
    defer if (w2) |w| alloc.free(w);
    try testing.expect(w2 != null);
    try testing.expectEqualStrings("w2", w2.?);
}

test "resolveWorkspaceId: cwd heuristic matches longest prefix, fail-closed otherwise" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    // s3 has no task link; cwd /proj/a/sub falls under w1's /proj/a.
    const w3 = try resolveWorkspaceId(alloc, &ctx.db, "s3");
    defer if (w3) |w| alloc.free(w);
    try testing.expect(w3 != null);
    try testing.expectEqualStrings("w1", w3.?);

    // Unknown cwd, NULL cwd, unknown session, empty session: all null.
    try testing.expect(try resolveWorkspaceId(alloc, &ctx.db, "s4") == null);
    try testing.expect(try resolveWorkspaceId(alloc, &ctx.db, "s5") == null);
    try testing.expect(try resolveWorkspaceId(alloc, &ctx.db, "nope") == null);
    try testing.expect(try resolveWorkspaceId(alloc, &ctx.db, "") == null);
}

test "resolveWorkspaceId: prefix boundary is slash-aware, ties fail closed" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    // /proj/abc must NOT match item path /proj/a (no slash boundary).
    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name, status, cwd) VALUES ('s6', 'Boundary', 'active', '/proj/abc')", &.{});
    try testing.expect(try resolveWorkspaceId(alloc, &ctx.db, "s6") == null);

    // Ambiguity: second workspace claims the same path -> tie -> null.
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position)
        \\VALUES ('i3', 'w2', 'kanban', 'Dup', '/proj/a', 1)
    , &.{});
    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name, status, cwd) VALUES ('s7', 'Tied', 'active', '/proj/a/x')", &.{});
    try testing.expect(try resolveWorkspaceId(alloc, &ctx.db, "s7") == null);
}

test "isSameWorkspace: same workspace true, cross/unknown false, self true" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try testing.expect(try isSameWorkspace(alloc, &ctx.db, "s1", "s3"));
    try testing.expect(!(try isSameWorkspace(alloc, &ctx.db, "s1", "s2")));
    try testing.expect(!(try isSameWorkspace(alloc, &ctx.db, "s1", "s4")));
    try testing.expect(!(try isSameWorkspace(alloc, &ctx.db, "s4", "s5")));
    try testing.expect(try isSameWorkspace(alloc, &ctx.db, "s1", "s1"));
    try testing.expect(!(try isSameWorkspace(alloc, &ctx.db, "", "s1")));
    try testing.expect(!(try isSameWorkspace(alloc, &ctx.db, "s1", "")));
}

test "workspaceSessionIds: task-linked plus cwd-matched, others excluded" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    const ids = try workspaceSessionIds(alloc, &ctx.db, "w1");
    defer freeSessionIds(alloc, ids);

    var found_s1 = false;
    var found_s3 = false;
    for (ids) |id| {
        if (std.mem.eql(u8, id, "s1")) found_s1 = true;
        if (std.mem.eql(u8, id, "s3")) found_s3 = true;
        try testing.expect(!std.mem.eql(u8, id, "s2"));
        try testing.expect(!std.mem.eql(u8, id, "s4"));
        try testing.expect(!std.mem.eql(u8, id, "s5"));
    }
    try testing.expect(found_s1);
    try testing.expect(found_s3);

    const empty = try workspaceSessionIds(alloc, &ctx.db, "");
    defer freeSessionIds(alloc, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "resolveWorkspaceRoot: a task-linked session reports its item's directory" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    const root = (try resolveWorkspaceRoot(alloc, &ctx.db, "s1")) orelse
        return error.TestUnexpectedResult;
    defer alloc.free(root);
    try testing.expectEqualStrings("/proj/a", root);
}

test "resolveWorkspaceRoot: a cwd-matched session reports the longest matching item" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    const root = (try resolveWorkspaceRoot(alloc, &ctx.db, "s3")) orelse
        return error.TestUnexpectedResult;
    defer alloc.free(root);
    try testing.expectEqualStrings("/proj/a", root);
}

test "resolveWorkspaceRoot: a session with no workspace, and a workspace with no path, have none" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try testing.expect(try resolveWorkspaceRoot(alloc, &ctx.db, "s4") == null);
    try testing.expect(try resolveWorkspaceRoot(alloc, &ctx.db, "s5") == null);
    try testing.expect(try resolveWorkspaceRoot(alloc, &ctx.db, "nope") == null);
    try testing.expect(try resolveWorkspaceRoot(alloc, &ctx.db, "") == null);

    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position)
        \\VALUES ('i9', 'w9', 'kanban', 'NoPath', '', 1)
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id)
        \\VALUES ('s9', 'T9', 'i9')
    , &.{});
    try testing.expect(try resolveWorkspaceRoot(alloc, &ctx.db, "s9") == null);
}

test "resolveWorkspaceForPath: a directory's owner is found without a session" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    const nested = (try resolveWorkspaceForPath(alloc, &ctx.db, "/proj/a/src/deep")).?;
    defer nested.deinit(alloc);
    try testing.expectEqualStrings("w1", nested.workspace_id);
    try testing.expectEqualStrings("/proj/a", nested.root);

    const at_root = (try resolveWorkspaceForPath(alloc, &ctx.db, "/proj/b")).?;
    defer at_root.deinit(alloc);
    try testing.expectEqualStrings("w2", at_root.workspace_id);

    // /proj/abc is nobody's, exactly as it is for a session's cwd.
    try testing.expect(try resolveWorkspaceForPath(alloc, &ctx.db, "/proj/abc") == null);
    try testing.expect(try resolveWorkspaceForPath(alloc, &ctx.db, "/elsewhere") == null);
    try testing.expect(try resolveWorkspaceForPath(alloc, &ctx.db, "") == null);
}
