//! `DELETE /api/workspaces/:workspace_id/skills/:skill_name`. Removes one
//! skill row and its companion assets, scoped to one workspace.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const skills_store = @import("../agentic_loop/skills_store.zig");

pub const SkillDeleteError = error{
    IdsRequired,
    NotFound,
    DeleteFailed,
};

pub const SkillDeleteInput = struct {
    workspace_id: []const u8,
    skill_name: []const u8,
};

/// Every response this handler emits — success and failure alike — has
/// this shape, so a client that reads `success` never has to branch on
/// which status code it got first.
pub const SkillDeleteResponse = struct {
    success: bool,
    skill_name: []const u8,
    error_message: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: SkillDeleteInput,
) SkillDeleteError!void {
    if (input.workspace_id.len == 0 or input.skill_name.len == 0) {
        return error.IdsRequired;
    }
    // Every store error is mapped by hand rather than propagated with `try`.
    skills_store.deleteSkill(allocator, db, input.workspace_id, input.skill_name) catch |err| switch (err) {
        error.NotFound => return error.NotFound,
        error.DeleteFailed => return error.DeleteFailed,
        // Both ids are non-empty by the guard above, so this arm is only
        // reachable if the two checks ever drift apart. Caller error, not
        // a silent not-found.
        error.WorkspaceIdNameRequired => return error.IdsRequired,
    };
}

// =====================================================================
// Handler
// =====================================================================

pub fn skillDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const input: SkillDeleteInput = .{
        .workspace_id = req.params.get("workspace_id") orelse "",
        .skill_name = req.params.get("skill_name") orelse "",
    };

    useCase(allocator, sqlite_db, input) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.NotFound => 404,
            error.DeleteFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "workspace_id and skill_name required",
            // A name that belongs to another workspace reports the same
            // message as one that does not exist: a 403 would confirm the
            // name exists, which is the leak the scoping exists to hide.
            error.NotFound => "skill not found",
            error.DeleteFailed => "DB error",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
                .success = false,
                .skill_name = input.skill_name,
                .error_message = message,
            }, .{}),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
        .success = true,
        .skill_name = input.skill_name,
        .error_message = "",
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// The `zig build test` module graph never CALLS this handler — the test
// binary contains no HTTP server — so nothing else in that build analyses its
// body, and an error-set mismatch between the handler and the store it calls
comptime {
    _ = &skillDeleteHandler;
}

// ─── Tests ──────────────────────────────────────────────────────────────

const sqlite = pabrikcore.sqlite;
const testing = std.testing;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try migration.Migration102CreateSkills.up(&db, testing.allocator);
    return .{ .db = db, .threaded = threaded };
}

fn seed(ctx: *TestCtx, workspace_id: []const u8, name: []const u8) !void {
    const row = try skills_store.upsertSkill(testing.allocator, &ctx.db, .{
        .workspace_id = workspace_id,
        .name = name,
        .description = "d",
        .content = "body",
    });
    defer skills_store.freeSkillRow(testing.allocator, row);
    try skills_store.replaceAssets(testing.allocator, &ctx.db, workspace_id, name, &.{
        .{ .rel_path = "scripts/convert.py", .content = "print('hi')" },
    });
}

fn countRows(ctx: *TestCtx, sql: []const u8) !usize {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, sql, &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(usize, row.values[0], 10) catch 0;
}

test "useCase: empty ids return IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "", .skill_name = "pdf" }),
    );
    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .skill_name = "" }),
    );
}

test "useCase: deletes the skill and its companion assets" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seed(&ctx, "ws_1", "pdf");

    try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .skill_name = "pdf" });

    // `PRAGMA foreign_keys` is off project-wide, so the declared CASCADE
    // does nothing — orphaned asset rows would collide with a re-import
    // of the same name on UNIQUE (skill_id, rel_path).
    try testing.expectEqual(@as(usize, 0), try countRows(&ctx, "SELECT COUNT(*) FROM skills"));
    try testing.expectEqual(@as(usize, 0), try countRows(&ctx, "SELECT COUNT(*) FROM skill_assets"));
}

test "useCase: another workspace's skill is deleted from nowhere" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seed(&ctx, "ws_1", "pdf");

    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_2", .skill_name = "pdf" }),
    );
    try testing.expectEqual(@as(usize, 1), try countRows(&ctx, "SELECT COUNT(*) FROM skills"));
    try testing.expectEqual(@as(usize, 1), try countRows(&ctx, "SELECT COUNT(*) FROM skill_assets"));
}

test "useCase: deleting the same name twice reports NotFound the second time" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seed(&ctx, "ws_1", "pdf");

    try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .skill_name = "pdf" });
    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .skill_name = "pdf" }),
    );
}
