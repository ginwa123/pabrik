//! Automatic per-user workspace provisioning.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const auth_common = @import("auth_common.zig");
const process = @import("helpers").process;
const getCurrentProcessId = process.getCurrentProcessId;
const workspace_default = @import("workspace_items_default.zig");

/// The name every automatically provisioned workspace gets. Cosmetic — clients
/// select by id and a user may rename it — but it is what a brand-new account
/// sees first, so it is pinned here rather than at each call site.
pub const DEFAULT_WORKSPACE_NAME = "Default";

pub const ProvisionError = error{
    OutOfMemory,
    DatabaseError,
};

/// An owned pair. `deinit` frees both fields unconditionally, so BOTH must
/// come from `allocator` — never a comptime string.
pub const ProvisionedWorkspace = struct {
    id: []const u8,
    name: []const u8,

    pub fn deinit(self: ProvisionedWorkspace, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
    }
};

/// Process-local monotonic counter for workspace_id generation.
var workspace_id_counter: std.atomic.Value(u64) = .init(0);

/// `ws_<ms>_<hex>` — ts_nanos (ms) + a process-unique hex suffix.
pub fn generateWorkspaceId(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const ts = std.Io.Timestamp.now(io, .real);
    const ts_nanos: i64 = @intCast(@divTrunc(ts.nanoseconds, 1_000_000));
    const counter = workspace_id_counter.fetchAdd(1, .seq_cst);
    const pid = getCurrentProcessId();
    const entropy: u64 = (@as(u64, @intCast(pid)) << 32) ^ (@as(u64, @intCast(ts_nanos)) << 16) ^ @as(u64, @intCast(counter));
    var random_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &random_bytes, entropy, .little);
    var hex_buf: [16]u8 = undefined;
    for (random_bytes, 0..) |b, i| {
        hex_buf[i * 2] = process.hex_digits[b >> 4];
        hex_buf[i * 2 + 1] = process.hex_digits[b & 0xF];
    }
    return std.fmt.allocPrint(allocator, "ws_{d}_{s}", .{ ts_nanos, &hex_buf });
}

/// Insert one workspace row plus the membership row that makes it visible to
/// its own creator.
pub fn insertWorkspace(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
    name: []const u8,
    owner: []const u8,
    /// Whether the workspace is VM-backed (Migration 115).
    is_vm: bool,
) !void {
    const member = auth_common.normaliseOwnerId(owner);

    var tx = try db.begin();
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    _ = try tx.exec(allocator,
        \\INSERT INTO workspaces (id, name, position, created_at, updated_at, user_id, is_vm)
        \\VALUES (?, ?,
        \\    COALESCE((SELECT MAX(position) FROM workspaces), -1) + 1,
        \\    datetime('now'), datetime('now'), ?, ?)
    , &[_][]const u8{ workspace_id, name, member, if (is_vm) "1" else "0" });

    // The membership row IS the visibility grant (Migration 100). `user_id`
    // on `workspaces` is kept in sync deliberately — it is the rollback path.
    _ = try tx.exec(
        allocator,
        "INSERT OR IGNORE INTO workspace_members (workspace_id, user_id, role) VALUES (?, ?, 'owner')",
        &[_][]const u8{ workspace_id, member },
    );

    try tx.commit();
}

/// Mint an id, insert the workspace, and attach its default project. This is
/// the whole of workspace creation — `POST /api/workspaces` and the
/// provisioning hook both go through it, so neither can drift.
pub fn createWorkspaceRow(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    name: []const u8,
    owner: []const u8,
    /// Needed to resolve the default project's `path` ($HOME). Read from the
    /// process environment, never from a request body.
    environment: ?*const std.process.Environ.Map,
    /// Whether the new workspace is VM-backed (Migration 115).
    is_vm: bool,
) ProvisionError!ProvisionedWorkspace {
    const id = generateWorkspaceId(allocator, io) catch return error.OutOfMemory;
    errdefer allocator.free(id);
    insertWorkspace(allocator, db, id, name, owner, is_vm) catch return error.DatabaseError;

    // Every workspace has a default project, so a brand-new one shows its
    // default in the Projects list on the very first paint instead of only
    // after a later read fills it in.
    const defaulted = workspace_default.ensureDefaultProject(allocator, db, id, environment, null);
    if (defaulted) |project| {
        defer project.deinit(allocator);
    } else |err| {
        std.log.warn("workspace_provisioning: default project ensure failed (non-fatal, the items list will heal it): {s}", .{@errorName(err)});
    }

    // DUPE the name, never hand back the caller's slice or a comptime string:
    // `ProvisionedWorkspace.deinit` frees both fields unconditionally.
    return .{ .id = id, .name = try allocator.dupe(u8, name) };
}

/// Give `user_id` a workspace of their own, when they have none. Idempotent:
/// returns null and writes nothing when the user already owns a workspace.
/// Returns the created row otherwise.
pub fn ensureDefaultWorkspace(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    user_id: []const u8,
    environment: ?*const std.process.Environ.Map,
    /// Whether the new workspace is VM-backed (Migration 115).
    is_vm: bool,
) ProvisionError!?ProvisionedWorkspace {
    if (ownsAnyWorkspace(db, allocator, user_id)) return null;
    return try createWorkspaceRow(allocator, db, io, DEFAULT_WORKSPACE_NAME, user_id, environment, is_vm);
}

/// True when `user_id` has a membership row of its own. The predicate is
/// deliberately `user_id = ?` and NOT "can this user see any workspace".
fn ownsAnyWorkspace(db: *sqlite.SqliteBackend, allocator: std.mem.Allocator, user_id: []const u8) bool {
    var q = db.query(allocator,
        \\SELECT 1 FROM workspace_members WHERE user_id = ? LIMIT 1
    , &[_][]const u8{user_id}) catch return false;
    defer q.deinit();
    const row = q.next() catch return false;
    defer if (row) |r| r.deinit(allocator);
    return row != null;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    env: std.process.Environ.Map,

    fn deinit(self: *TestCtx) void {
        self.env.deinit();
        self.threaded.deinit();
        self.db.deinit();
    }
};

fn setupDb(alloc: std.mem.Allocator) !TestCtx {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // `workspaces` in its Migration 027 + 077 shape: `position` drives the
    // listing order and `user_id` is the pre-Migration-100 owner column.
    try db.exec(alloc,
        \\CREATE TABLE workspaces (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL DEFAULT '',
        \\  position INTEGER,
        \\  user_id TEXT,
        \\  created_at DATETIME,
        \\  updated_at DATETIME,
        \\  is_vm INTEGER NOT NULL DEFAULT 0
        \\)
    , &[_][]const u8{});

    // Migration 100. The `role` CHECK constraint is kept so a regression that
    // writes a role outside the enum fails here rather than in production.
    try db.exec(alloc,
        \\CREATE TABLE workspace_members (
        \\  workspace_id TEXT NOT NULL,
        \\  user_id TEXT NOT NULL,
        \\  role TEXT NOT NULL DEFAULT 'viewer' CHECK (role IN ('owner', 'admin', 'editor', 'viewer')),
        \\  joined_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  invited_by TEXT,
        \\  PRIMARY KEY (workspace_id, user_id)
        \\)
    , &[_][]const u8{});

    // Migration 094's shape, including the partial UNIQUE index — without it
    // `ensureDefaultProject`'s race guard is untestable and the fixture would
    // be testing a different system than production runs.
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT NOT NULL,
        \\  item_type TEXT NOT NULL,
        \\  name TEXT,
        \\  path TEXT,
        \\  position INTEGER NOT NULL DEFAULT 0,
        \\  is_default INTEGER NOT NULL DEFAULT 0,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE UNIQUE INDEX idx_workspace_items_default_per_workspace
        \\ON workspace_items(workspace_id) WHERE is_default = 1
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE agent_configs (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT NOT NULL UNIQUE,
        \\  item_type TEXT NOT NULL,
        \\  description TEXT,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE agent_config_tools (
        \\  id TEXT PRIMARY KEY,
        \\  config_id TEXT NOT NULL,
        \\  tool_name TEXT NOT NULL,
        \\  enabled INTEGER NOT NULL DEFAULT 1,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &[_][]const u8{});

    // A real environment map with HOME set, because the default project's
    // `path` IS the home directory and the whole feature is defined by where
    // HOME lands.
    var env: std.process.Environ.Map = .init(alloc);
    errdefer env.deinit();
    try env.put("HOME", "/home/tester");

    return .{ .db = db, .threaded = threaded, .env = env };
}

/// Count rows in `workspaces` whose WHERE clause needs the id interpolated.
/// `template` is a comptime fmt string with one `{{s}}` per argument.
fn countWorkspacesFmt(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    comptime template: []const u8,
    ids: anytype,
) !u32 {
    const sql = try std.fmt.allocPrint(alloc, template, ids);
    defer alloc.free(sql);
    var q = try db.query(alloc, sql, &[_][]const u8{});
    defer q.deinit();
    const row = (try q.next()) orelse return 0;
    defer row.deinit(alloc);
    return std.fmt.parseInt(u32, row.values[0], 10);
}

fn countMembersOf(db: *sqlite.SqliteBackend, alloc: std.mem.Allocator, user_id: []const u8) !u32 {
    var q = try db.query(alloc,
        \\SELECT COUNT(*) FROM workspace_members WHERE user_id = ?
    , &[_][]const u8{user_id});
    defer q.deinit();
    const row = (try q.next()) orelse return 0;
    defer row.deinit(alloc);
    return std.fmt.parseInt(u32, row.values[0], 10);
}

test "ensureDefaultWorkspace: a user who owns no workspace gets one named Default" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();
    const io = ctx.threaded.io();

    const created = (try ensureDefaultWorkspace(alloc, &ctx.db, io, "user_a", &ctx.env, false)) orelse
        return error.TestExpectedEqual;
    defer created.deinit(alloc);

    try testing.expectEqualStrings("Default", created.name);
    try testing.expect(created.id.len > 0);

    // The row is real, and it is wired to its owner — a workspace with no
    // membership row is invisible to the very user it was made for.
    try testing.expectEqual(
        @as(u32, 1),
        try countWorkspacesFmt(&ctx.db, alloc, "SELECT COUNT(*) FROM workspaces WHERE id = '{s}' AND name = 'Default'", .{created.id}),
    );
    try testing.expectEqual(@as(u32, 1), try countMembersOf(&ctx.db, alloc, "user_a"));
}

test "ensureDefaultWorkspace: a user who already owns a workspace gets no second one" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();
    const io = ctx.threaded.io();

    // The user already worked here — they are an established account, not a
    // fresh one, and a login must not sprout a second workspace behind them.
    try insertWorkspace(alloc, &ctx.db, "ws_existing", "Client Project", "user_a", false);

    const created = try ensureDefaultWorkspace(alloc, &ctx.db, io, "user_a", &ctx.env, false);
    try testing.expect(created == null);
    try testing.expectEqual(
        @as(u32, 1),
        try countWorkspacesFmt(&ctx.db, alloc, "SELECT COUNT(*) FROM workspaces WHERE user_id = '{s}'", .{"user_a"}),
    );
}

test "ensureDefaultWorkspace: the new workspace lists above the existing ones" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();
    const io = ctx.threaded.io();

    // A legacy installation: shared rows already hold the whole position
    // range.
    try insertWorkspace(alloc, &ctx.db, "ws_legacy", "Legacy", auth_common.system_user_id, false);
    try ctx.db.exec(alloc, "UPDATE workspaces SET position = 7 WHERE id = 'ws_legacy'", &[_][]const u8{});

    const created = (try ensureDefaultWorkspace(alloc, &ctx.db, io, "user_a", &ctx.env, false)).?;
    defer created.deinit(alloc);

    try testing.expectEqual(
        @as(i64, 8),
        try scalarI64Fmt(&ctx.db, alloc, "SELECT position FROM workspaces WHERE id = '{s}'", .{created.id}),
    );
}

test "ensureDefaultWorkspace: the provisioned workspace already has its default project" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();
    const io = ctx.threaded.io();

    const created = (try ensureDefaultWorkspace(alloc, &ctx.db, io, "user_a", &ctx.env, false)).?;
    defer created.deinit(alloc);

    // A workspace with no project in it is the SAME dead end one level down:
    // the user lands in "Default" and immediately meets an empty Projects
    // list.
    try testing.expectEqual(
        @as(u32, 1),
        try countWorkspacesFmt(
            &ctx.db,
            alloc,
            "SELECT COUNT(*) FROM workspace_items WHERE workspace_id = '{s}' AND is_default = 1",
            .{created.id},
        ),
    );
    // Its path is the server user's home — that is what makes a chat started
    // in the default project resolve a cwd instead of failing.
    const default_path = try scalarTextFmt(
        &ctx.db,
        alloc,
        "SELECT path FROM workspace_items WHERE workspace_id = '{s}' AND is_default = 1",
        .{created.id},
    );
    defer alloc.free(default_path);
    try testing.expectEqualStrings("/home/tester", default_path);
}

test "createWorkspaceRow: a saas server's workspace is VM-backed, a local one's is not" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();
    const io = ctx.threaded.io();

    const vm_workspace = try createWorkspaceRow(alloc, &ctx.db, io, "VM", "user_a", &ctx.env, true);
    defer vm_workspace.deinit(alloc);
    const host_workspace = try createWorkspaceRow(alloc, &ctx.db, io, "Host", "user_b", &ctx.env, false);
    defer host_workspace.deinit(alloc);

    // The flag is on the row, so the read path and the runtime agree on which
    // workspace may be given a Firecracker.
    try testing.expectEqual(
        @as(i64, 1),
        try scalarI64Fmt(&ctx.db, alloc, "SELECT is_vm FROM workspaces WHERE id = '{s}'", .{vm_workspace.id}),
    );
    try testing.expectEqual(
        @as(i64, 0),
        try scalarI64Fmt(&ctx.db, alloc, "SELECT is_vm FROM workspaces WHERE id = '{s}'", .{host_workspace.id}),
    );
}

test "ensureDefaultWorkspace: the legacy shared bucket is not a workspace of the user's own" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();
    const io = ctx.threaded.io();

    // An installation that predates `--auth`: the machine owner's workspaces
    // sit in the `user_system` bucket, which `workspaceVisibilityClause` lets
    // a real user SEE.
    try insertWorkspace(alloc, &ctx.db, "ws_shared", "Shared Legacy", auth_common.system_user_id, false);

    const created = (try ensureDefaultWorkspace(alloc, &ctx.db, io, "user_a", &ctx.env, false)) orelse
        return error.TestExpectedEqual;
    defer created.deinit(alloc);

    try testing.expectEqualStrings("Default", created.name);
    try testing.expectEqual(@as(u32, 1), try countMembersOf(&ctx.db, alloc, "user_a"));
    try testing.expectEqual(@as(u32, 1), try countMembersOf(&ctx.db, alloc, auth_common.system_user_id));
}

test "ensureDefaultWorkspace: two users each get their own, neither sees the other's" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();
    const io = ctx.threaded.io();

    const for_a = (try ensureDefaultWorkspace(alloc, &ctx.db, io, "user_a", &ctx.env, false)).?;
    defer for_a.deinit(alloc);
    const for_b = (try ensureDefaultWorkspace(alloc, &ctx.db, io, "user_b", &ctx.env, false)).?;
    defer for_b.deinit(alloc);

    try testing.expect(for_a.id.len > 0);
    try testing.expect(for_b.id.len > 0);
    try testing.expect(!std.mem.eql(u8, for_a.id, for_b.id));

    // Each user has exactly one membership, and it points at their own row.
    try testing.expectEqual(@as(u32, 1), try countMembersOf(&ctx.db, alloc, "user_a"));
    try testing.expectEqual(@as(u32, 1), try countMembersOf(&ctx.db, alloc, "user_b"));
    try testing.expectEqual(
        @as(u32, 1),
        try countWorkspacesFmt(&ctx.db, alloc, "SELECT COUNT(*) FROM workspace_members WHERE workspace_id = '{s}'", .{for_a.id}),
    );
    try testing.expectEqual(
        @as(u32, 1),
        try countWorkspacesFmt(&ctx.db, alloc, "SELECT COUNT(*) FROM workspace_members WHERE workspace_id = '{s}'", .{for_b.id}),
    );
    // No id collision either — two workspaces in the same millisecond from the
    // same process used to collide and fail the second INSERT.
    try testing.expectEqual(
        @as(u32, 2),
        try countWorkspacesFmt(&ctx.db, alloc, "SELECT COUNT(*) FROM workspaces WHERE name = 'Default'", .{}),
    );
}

/// Read a single text column, interpolating ids that the code under test
/// generated (never user input).
fn scalarTextFmt(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    comptime template: []const u8,
    ids: anytype,
) ![]const u8 {
    const sql = try std.fmt.allocPrint(alloc, template, ids);
    defer alloc.free(sql);
    var q = try db.query(alloc, sql, &[_][]const u8{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.TestExpectedEqual;
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

/// Read a single integer column, interpolating ids that the code under test
/// generated (never user input).
fn scalarI64Fmt(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    comptime template: []const u8,
    ids: anytype,
) !i64 {
    const sql = try std.fmt.allocPrint(alloc, template, ids);
    defer alloc.free(sql);
    var q = try db.query(alloc, sql, &[_][]const u8{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.TestExpectedEqual;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10);
}
