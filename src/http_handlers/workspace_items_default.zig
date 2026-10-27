//! `ensureDefaultProject` — the one implementation of this invariant: Every
//! workspace has a default project.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const auth_common = @import("auth_common.zig");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const helpers = @import("helpers");
const agent_db = @import("../models/agent.db.zig");
const tools_equipped = @import("../modules/agent/tools/tools_equipped.zig");
const SystemFolder = pabrikcore.system_folder.SystemFolder;

/// The display name of an auto-created default project. Cosmetic only —
/// both clients follow the `is_default` flag, never the name, so a user is
/// free to rename it without breaking anything.
pub const DEFAULT_PROJECT_NAME = "Project Default";

pub const EnsureDefaultProjectError = error{
    WorkspaceIdRequired,
    /// No usable home directory: missing, empty, or relative. See the
    /// module comment — a bad `path` is worse than a visible error.
    HomeNotFound,
    DatabaseError,
    OutOfMemory,
};

pub const DefaultProject = struct {
    /// Heap-allocated and owned by the caller.
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    /// The server user's home directory.
    path: []const u8,
    position: i64,
    /// True when THIS call created the row. The wire layer uses it to pick
    /// 201 vs 200. False on every subsequent call — that is the invariant.
    created: bool,

    pub fn deinit(self: DefaultProject, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.workspace_id);
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

/// Idempotent. Returns the workspace's default project, creating it when
/// the lookup finds nothing.
pub fn ensureDefaultProject(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_id: []const u8,
    environment: ?*const std.process.Environ.Map,
    config_tools: ?[]const []const u8,
) EnsureDefaultProjectError!DefaultProject {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;

    // Fast path: found. One indexed read, no writes. This is the case that
    // runs on every sidebar load once the default exists.
    if (readDefault(allocator, db, workspace_id)) |found| return found;

    // Miss. Resolve the home directory BEFORE opening a transaction so a bad
    // home leaves nothing half-written (the test for this asserts zero rows).
    const home = SystemFolder.getHomeDirectory(allocator, environment) catch return error.HomeNotFound;
    defer allocator.free(home);

    if (home.len == 0 or !std.fs.path.isAbsolute(home)) return error.HomeNotFound;

    const timestamp_ns = helpers.unixTimestampNanos();
    const item_id = try std.fmt.allocPrint(allocator, "item_{d}", .{timestamp_ns});
    // The production handlers rely on the request arena to reap this, but
    // the inline tests use testing.allocator, which leak-detects.
    errdefer allocator.free(item_id);

    // `tx` so the 3 INSERTs are atomic.
    var tx = db.begin() catch return error.DatabaseError;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    // Every statement below goes through `tx`, never `db`: the tx holds the
    // backend mutex and the lock is not reentrant. (Same constraint as
    // workspace_items_create_agent.zig:139-152.)
    tx.exec(allocator,
        \\INSERT INTO workspace_items
        \\  (id, workspace_id, item_type, name, path, position, is_default, created_at, updated_at)
        \\VALUES (?, ?, 'agent', ?, ?,
        \\  COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1,
        \\  1, datetime('now'), datetime('now'))
    , &[_][]const u8{ item_id, workspace_id, DEFAULT_PROJECT_NAME, home, workspace_id }) catch |err| switch (err) {
        // The partial UNIQUE index rejected us: another caller created the
        // default between our read and our write.
        error.ExecuteFailed => {
            tx.rollback() catch {};
            if (readDefault(allocator, db, workspace_id)) |winner| {
                allocator.free(item_id);
                return winner;
            }
            return error.DatabaseError;
        },
        else => return error.DatabaseError,
    };

    // The agent sibling shares the item's id (spec D3), which
    // `agents.workspace_item_id UNIQUE` turns into a 1-1 invariant.
    agent_db.insert(allocator, .{ .tx = &tx }, item_id, item_id) catch return error.DatabaseError;

    // Seed the tool allowlist so a fresh default is immediately usable
    // rather than a NotConfigured dead-end. Inside the same tx, and through
    // `tx` (not `db`) for the mutex reason above.
    tools_equipped.seedDefaultAgentTools(allocator, .{ .tx = &tx }, item_id, config_tools) catch return error.DatabaseError;

    tx.commit() catch return error.DatabaseError;

    // The INSERT computes position via a correlated subquery, so the
    // persisted value isn't known without a follow-up read — same
    // readInsertedPosition pattern as the kanban/agent create handlers.
    return DefaultProject{
        .id = item_id,
        .workspace_id = try allocator.dupe(u8, workspace_id),
        // DUPE, not the constant.
        .name = try allocator.dupe(u8, DEFAULT_PROJECT_NAME),
        .path = try allocator.dupe(u8, home),
        .position = readPosition(allocator, db, item_id),
        .created = true,
    };
}

/// Is this a name a person could have typed? The rule is deliberately narrow,
/// because a false positive here **destroys a user's rename**.
fn nameLooksUsable(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.unicode.utf8ValidateSlice(name)) return false;

    // Iterate CODEPOINTS, not bytes.
    var view = std.unicode.Utf8View.init(name) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        // C0 controls, DEL, and the C1 range. A control character in a
        // project name is either corruption or a paste accident, and
        // rewriting it is the safer of the two outcomes.
        if (cp < 0x20) return false;
        if (cp == 0x7F) return false;
        if (cp >= 0x80 and cp <= 0x9F) return false;
    }
    return true;
}

/// Repair a default project whose stored `name` is garbage, in place.
fn repairGarbageName(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    item_id: []const u8,
    stored_name: []const u8,
) void {
    if (nameLooksUsable(stored_name)) return;
    db.exec(
        allocator,
        "UPDATE workspace_items SET name = ? WHERE id = ?",
        &[_][]const u8{ DEFAULT_PROJECT_NAME, item_id },
    ) catch |err| {
        // Non-fatal on purpose: a stale name is cosmetic, and failing the
        // read over it would be strictly worse than showing it.
        std.log.warn(
            "ensureDefaultProject: could not repair the default project's name (non-fatal): {s}",
            .{@errorName(err)},
        );
        return;
    };
    std.log.info(
        "ensureDefaultProject: repaired a corrupted default project name for item {s}",
        .{item_id},
    );
}

/// Read the workspace's default project, or null when it has none.
/// This is the whole "does a default exist?" query — one row on the hot path.
fn readDefault(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_id: []const u8,
) ?DefaultProject {
    var q = db.query(allocator,
        \\SELECT id, name, path, position FROM workspace_items
        \\WHERE workspace_id = ? AND is_default = 1
    , &[_][]const u8{workspace_id}) catch return null;
    defer q.deinit();

    const row = (q.next() catch null) orelse return null;
    defer row.deinit(allocator);

    // Dup every field up front, before the row's memory is released by
    // `defer` — the same dangling-slice trap that `resolveCwdFromTaskOrItem`
    // fell into, avoided here by never returning a reference into the row.
    const id = allocator.dupe(u8, row.values[0]) catch return null;
    const ws = allocator.dupe(u8, workspace_id) catch {
        allocator.free(id);
        return null;
    };
    const name = allocator.dupe(u8, row.values[1]) catch {
        allocator.free(id);
        allocator.free(ws);
        return null;
    };
    const path = allocator.dupe(u8, row.values[2]) catch {
        allocator.free(id);
        allocator.free(ws);
        allocator.free(name);
        return null;
    };
    const position = std.fmt.parseInt(i64, row.values[3], 10) catch 0;

    // Heal a name corrupted by an earlier build, now that we hold an owned copy
    // and know the row's id. Best effort, and never on a name a user typed.
    if (!nameLooksUsable(name)) {
        repairGarbageName(allocator, db, id, name);
        allocator.free(name);
        return DefaultProject{
            .id = id,
            .workspace_id = ws,
            .name = allocator.dupe(u8, DEFAULT_PROJECT_NAME) catch {
                allocator.free(id);
                allocator.free(ws);
                return null;
            },
            .path = path,
            .position = position,
            .created = false,
        };
    }

    return DefaultProject{
        .id = id,
        .workspace_id = ws,
        .name = name,
        .path = path,
        .position = position,
        .created = false,
    };
}

/// Best-effort: the persisted `position` of a just-INSERTed item. Returns 0
/// on failure — position is a sort hint, and 0 is a legal value for it.
fn readPosition(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    item_id: []const u8,
) i64 {
    var q = db.query(allocator, "SELECT position FROM workspace_items WHERE id = ?", &[_][]const u8{item_id}) catch return 0;
    defer q.deinit();
    const row = (q.next() catch null) orelse return 0;
    defer row.deinit(allocator);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}

/// True when a workspace row exists.
pub fn workspaceExists(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_id: []const u8,
) bool {
    var q = db.query(allocator, "SELECT 1 FROM workspaces WHERE id = ?", &[_][]const u8{workspace_id}) catch return false;
    defer q.deinit();
    const row = q.next() catch null orelse return false;
    defer row.deinit(allocator);
    return true;
}

// =====================================================================
// Handler — POST /api/workspaces/:workspace_id/default-project
// ===================================================================== The

const DefaultProjectResponse = struct {
    item: http_response.WorkspaceItemGetResponse,
    created: bool,
    /// Sort hint for the item above. Kept beside it, not inside it, so the
    /// item keeps the exact shape `GET /workspaces/:ws/items` emits — one
    /// WorkspaceItem, two producers.
    position: i64,
};

pub const WorkspaceDefaultProjectInput = struct {
    workspace_id: []const u8,
    /// Live config.json `tools` checklist (null = built-in defaults).
    /// Read from the singleton by the handler, matching
    /// `workspace_items_create_agent.zig`.
    config_tools: ?[]const []const u8 = null,
    environment: ?*const std.process.Environ.Map = null,
};

pub fn useCaseGet(allocator: std.mem.Allocator, db: *pabrikcore.database.Db, input: WorkspaceDefaultProjectInput) EnsureDefaultProjectError![]const u8 {
    const project = try ensureDefaultProject(allocator, db, input.workspace_id, input.environment, input.config_tools);
    defer project.deinit(allocator);

    const json = try std.json.Stringify.valueAlloc(allocator, DefaultProjectResponse{
        .item = .{
            .id = project.id,
            .workspace_id = project.workspace_id,
            .item_type = "agent",
            .name = project.name,
            .path = project.path,
            .is_default = 1,
        },
        // Reported next to the item rather than inside it: `position` is a
        // per-item sort hint the workspace_items list already carries, and
        // this envelope is a lookup, not a listing.
        .position = project.position,
        .created = project.created,
    }, .{});
    return json;
}

pub fn workspaceDefaultProjectHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id required" }),
        });
    }

    // The workspace's own tools checklist — it seeds the default project's
    // allowlist. Tools are workspace-scoped, never the user document's.
    const workspace_cfg = auth_common.requestWorkspaceConfig(allocator, di, workspace_id, req.headers) orelse
        pabrikcore.getLlmConfig(di);
    const config_tools = workspace_cfg.tools;

    // An unknown workspace is a 404 here, unlike the list endpoint which
    // answers 200 + []. This is an explicit request for a specific
    // workspace's default, so "no such workspace" is a real answer.
    if (!workspaceExists(allocator, sqlite_db, workspace_id)) {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Workspace not found" }),
        });
    }

    const data = useCaseGet(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .config_tools = config_tools,
        .environment = di.environment,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired => 400,
            error.HomeNotFound, error.DatabaseError, error.OutOfMemory => 500,
        };
        // Never echo the path back — a 500 here means the home directory
        // could not be resolved, and the caller has no need for it.
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.HomeNotFound => "Could not resolve the home directory for the default project",
            error.DatabaseError => "Failed to resolve the default project",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // 201 when this call created the default, 200 when it already existed.
    // The body carries `created` so a client never has to guess.
    const created = std.mem.indexOf(u8, data, "\"created\":true") != null;
    return res.jsonResponse(.{ .status_code = if (created) 201 else 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────

const sqlite = @import("pabrikcore").sqlite;
const database = @import("pabrikcore").database;
const testing = std.testing;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
    env: std.process.Environ.Map,
    home: []const u8,

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
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Migration 094's shape: is_default NOT NULL DEFAULT 0 plus BOTH indexes.
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
        \\CREATE INDEX idx_workspace_items_default_lookup
        \\ON workspace_items(workspace_id, is_default)
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
    try db.exec(alloc, "CREATE TABLE workspaces (id TEXT PRIMARY KEY, name TEXT, user_id TEXT)", &[_][]const u8{});

    // A real environment map with HOME set, because getHomeDirectory takes
    // one and the whole feature is defined by where HOME lands.
    var env: std.process.Environ.Map = .init(alloc);
    errdefer env.deinit();
    try env.put("HOME", "/home/tester");

    return .{ .db = db, .threaded = threaded, .env = env, .home = "/home/tester" };
}

/// Run a `SELECT COUNT(*)` whose WHERE clause needs the item id(s)
/// interpolated.
fn countWhereFmt(
    db: *database.Db,
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

fn countWhere(db: *database.Db, alloc: std.mem.Allocator, table: []const u8, where: []const u8) !u32 {
    var buf: [256]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf, "SELECT COUNT(*) FROM {s} WHERE {s}", .{ table, where });
    var q = try db.query(alloc, sql, &[_][]const u8{});
    defer q.deinit();
    const row = (try q.next()) orelse return 0;
    defer row.deinit(alloc);
    return std.fmt.parseInt(u32, row.values[0], 10);
}

test "ensureDefaultProject creates the default on a miss, rooted at HOME" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    const p = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer p.deinit(alloc);

    try testing.expect(p.created);
    try testing.expectEqualStrings("/home/tester", p.path);
    try testing.expectEqualStrings(DEFAULT_PROJECT_NAME, p.name);

    // The row, and the two siblings that make it a usable agent. The
    // combined WHERE is deliberate: it asserts the type, the flag and the
    // path on the SAME row rather than three independent counts.
    try testing.expectEqual(@as(u32, 1), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_1'"));
    try testing.expectEqual(@as(u32, 1), try countWhereFmt(&ctx.db, alloc, "SELECT COUNT(*) FROM workspace_items WHERE id = '{s}' AND item_type = 'agent' AND is_default = 1 AND path = '/home/tester'", .{p.id}));
    // The 1-1 invariant: the agents row's id AND workspace_item_id are both
    // the item id, which is what `agents.workspace_item_id UNIQUE` relies on.
    try testing.expectEqual(@as(u32, 1), try countWhereFmt(&ctx.db, alloc, "SELECT COUNT(*) FROM agent_configs WHERE id = '{s}' AND workspace_item_id = '{s}'", .{ p.id, p.id }));

    // The tool allowlist must be seeded, or the default project is a
    // NotConfigured dead-end on first use.
    const seeded = try countWhereFmt(&ctx.db, alloc, "SELECT COUNT(*) FROM agent_config_tools WHERE config_id = '{s}'", .{p.id});
    try testing.expect(seeded > 0);
}

test "ensureDefaultProject is idempotent: a second call returns the same id and creates nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    const first = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer first.deinit(alloc);

    const second = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer second.deinit(alloc);

    // The invariant, asserted. Same row, and the second call reports that
    // it did not create anything.
    try testing.expectEqualStrings(first.id, second.id);
    try testing.expect(!second.created);
    try testing.expectEqual(@as(u32, 1), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_1'"));
    try testing.expectEqual(@as(u32, 1), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_1' AND is_default = 1"));
}

test "ensureDefaultProject gives each workspace its own default" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    const a = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer a.deinit(alloc);
    const b = try ensureDefaultProject(alloc, &ctx.db, "ws_2", &ctx.env, null);
    defer b.deinit(alloc);

    try testing.expect(!std.mem.eql(u8, a.id, b.id));
    try testing.expectEqual(@as(u32, 1), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_1' AND is_default = 1"));
    try testing.expectEqual(@as(u32, 1), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_2' AND is_default = 1"));
}

test "ensureDefaultProject returns the existing default alongside ordinary items" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    // A workspace that already has projects but no default — the legacy
    // shape this feature has to heal.
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position)
        \\VALUES ('item_kanban', 'ws_1', 'kanban', 'Board', '/tmp/board', 5)
    , &[_][]const u8{});

    const p = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer p.deinit(alloc);

    try testing.expect(p.created);
    // The ordinary project is untouched, and the default landed at the TOP
    // (position 6 > 5) so it is visible without scrolling.
    try testing.expectEqual(@as(u32, 2), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_1'"));
    try testing.expectEqual(@as(u32, 1), try countWhere(&ctx.db, alloc, "workspace_items", "id = 'item_kanban' AND is_default = 0"));
    try testing.expectEqual(@as(i64, 6), p.position);
}

test "ensureDefaultProject writes nothing when the home directory is unusable" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    var no_home: std.process.Environ.Map = .init(alloc);
    defer no_home.deinit();
    // HOME present but EMPTY. On POSIX that historically "succeeded" with
    // "" — which is exactly the case that would store path='' and send the
    // agent to a temp sandbox. It must be a hard error instead.
    try no_home.put("HOME", "");

    try testing.expectError(
        error.HomeNotFound,
        ensureDefaultProject(alloc, &ctx.db, "ws_1", &no_home, null),
    );
    // Nothing half-written: the miss branch must not leave a row behind.
    try testing.expectEqual(@as(u32, 0), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_1'"));

    // And no env at all.
    try testing.expectError(
        error.HomeNotFound,
        ensureDefaultProject(alloc, &ctx.db, "ws_1", null, null),
    );
    try testing.expectEqual(@as(u32, 0), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_1'"));
}

test "ensureDefaultProject rejects an empty workspace id" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    try testing.expectError(
        error.WorkspaceIdRequired,
        ensureDefaultProject(alloc, &ctx.db, "", &ctx.env, null),
    );
}

test "ensureDefaultProject honours the partial unique index under a simulated race" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    const first = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer first.deinit(alloc);

    // Simulate the loser of a race: force the fast path to miss, then try to
    // insert a second default the way the create branch would.
    try testing.expectError(
        error.ExecuteFailed,
        ctx.db.exec(alloc,
            \\INSERT INTO workspace_items
            \\  (id, workspace_id, item_type, name, path, position, is_default)
            \\VALUES ('item_loser', 'ws_1', 'agent', 'Project Default', '/home/tester', 0, 1)
        , &[_][]const u8{}),
    );
    // Still exactly one default, and the winner is intact.
    try testing.expectEqual(@as(u32, 1), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_1' AND is_default = 1"));

    // And a re-read returns the winner, which is what the catch block does.
    const after = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer after.deinit(alloc);
    try testing.expectEqualStrings(first.id, after.id);
}

test "useCaseGet serializes the project and reports whether it created it" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    const first = try useCaseGet(alloc, &ctx.db, .{ .workspace_id = "ws_1", .environment = &ctx.env });
    defer alloc.free(first);
    const second = try useCaseGet(alloc, &ctx.db, .{ .workspace_id = "ws_1", .environment = &ctx.env });
    defer alloc.free(second);

    // `"created":true` is what the handler reads to choose 201 vs 200, so
    // this asserts the exact substring the handler greps for.
    try testing.expect(std.mem.indexOf(u8, first, "\"created\":true") != null);
    try testing.expect(std.mem.indexOf(u8, second, "\"created\":false") != null);

    // Both must report the SAME id — the envelope, not just the service.
    const View = struct {
        item: http_response.WorkspaceItemGetResponse,
        created: bool,
        position: i64,
    };
    const p1 = try std.json.parseFromSliceLeaky(View, alloc, first, .{});
    const p2 = try std.json.parseFromSliceLeaky(View, alloc, second, .{});
    try testing.expectEqualStrings(p1.item.id, p2.item.id);
    try testing.expectEqual(@as(i64, 1), p1.item.is_default);
    try testing.expectEqualStrings("/home/tester", p1.item.path.?);
    try testing.expectEqualStrings("agent", p1.item.item_type);
}

test "workspaceExists distinguishes a real workspace from an invented one" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    try ctx.db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_real', 'Real')", &[_][]const u8{});

    try testing.expect(workspaceExists(alloc, &ctx.db, "ws_real"));
    // This is the orphan guard. useCaseList returns [] for an unknown
    // workspace rather than 404, so without this probe a list read of
    // "ws_ghost" would create a default for a workspace that never existed.
    try testing.expect(!workspaceExists(alloc, &ctx.db, "ws_ghost"));
    try testing.expect(!workspaceExists(alloc, &ctx.db, ""));
}

// ─── The corrupted-name repair ─────────────────────────────────────────── A
// build with the bad free wrote default projects whose `name` came back as
// 0xAA poison bytes, which the UI rendered as `[ 170, 170, … ]`.

test "nameLooksUsable rejects poison bytes and blanks, accepts real names" {
    // The exact shape the bug produced: 0xAA repeated.
    var poison: [8]u8 = undefined;
    @memset(&poison, 0xAA);
    try testing.expect(!nameLooksUsable(&poison));

    // Invalid UTF-8 (a lone continuation byte), and a blank.
    try testing.expect(!nameLooksUsable("\x80"));
    try testing.expect(!nameLooksUsable(""));

    // Real names, including ones a person deliberately chose. A false
    // negative here means the heal would clobber a user's rename, which is
    // the one way this repair could do harm.
    try testing.expect(nameLooksUsable(DEFAULT_PROJECT_NAME));
    try testing.expect(nameLooksUsable("My Home Chat"));
    try testing.expect(nameLooksUsable("project 2"));
    // Non-ASCII is a legitimate name, not corruption. An earlier ASCII-only
    // version of this check rejected all three of these and would have silently
    // rewritten a user's rename.
    try testing.expect(nameLooksUsable("caf\u{00e9}"));
    try testing.expect(nameLooksUsable("\u{043f}\u{0440}\u{043e}\u{043a}\u{0435}\u{043a}\u{0442}"));
    // Punctuation-only is odd but is still something a person typed.
    try testing.expect(nameLooksUsable("."));
    try testing.expect(nameLooksUsable("---"));

    // Control characters ARE rejected, even when the rest is valid UTF-8 —
    // this is the second line of defence behind the UTF-8 check.
    try testing.expect(!nameLooksUsable("New\u{0001}Chat"));
    try testing.expect(!nameLooksUsable("\u{007f}"));
}

test "a corrupted default project name is repaired on read" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    // Seed a default whose name is poison bytes, the way the bad build did.
    var poison: [8]u8 = undefined;
    @memset(&poison, 0xAA);
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, is_default)
        \\VALUES ('item_poison', 'ws_1', 'agent', ?, '/home/tester', 0, 1)
    , &[_][]const u8{&poison});

    const p = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer p.deinit(alloc);

    // The caller gets a usable name, not the poison.
    try testing.expectEqualStrings(DEFAULT_PROJECT_NAME, p.name);
    try testing.expect(nameLooksUsable(p.name));

    // And the stored row was actually rewritten, so the next read is clean too.
    const stored = try countWhereFmt(&ctx.db, alloc, "SELECT COUNT(*) FROM workspace_items WHERE id = '{s}' AND name = 'Project Default'", .{p.id});
    try testing.expectEqual(@as(u32, 1), stored);
}

test "a user rename of the default project is never clobbered" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    const created = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer created.deinit(alloc);
    try ctx.db.exec(
        alloc,
        "UPDATE workspace_items SET name = 'Work stuff' WHERE id = ?",
        &[_][]const u8{created.id},
    );

    const p = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer p.deinit(alloc);

    // A name a person chose survives the heal, and the row is not rewritten.
    try testing.expectEqualStrings("Work stuff", p.name);
    try testing.expectEqual(@as(u32, 1), try countWhereFmt(&ctx.db, alloc, "SELECT COUNT(*) FROM workspace_items WHERE id = '{s}' AND name = 'Work stuff'", .{p.id}));
}

// ===== Tests merged from workspace_items_default_test.zig (2026-09-29
// flatten) ===== The default-project ROUTE contract is not asserted here:
// `matchRoute` walks the shared table in registration order, so "is the
