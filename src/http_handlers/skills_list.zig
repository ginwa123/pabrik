//! `GET /api/workspaces/:workspace_id/skills`. One workspace, one list, no
//! filesystem walk.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const skills_store = @import("../agentic_loop/skills_store.zig");

pub const SkillsListError = error{
    WorkspaceIdRequired,
    QueryFailed,
    OutOfMemory,
};

pub const SkillsListInput = struct {
    workspace_id: []const u8,
};

pub const SkillsListOutput = struct {
    /// Owned slice; free with `skills_store.freeSkillRows`.
    skills: []skills_store.SkillRow,
};

// ===================================================================== Use
// case =====================================================================
// Takes the allocator and the database handle as ARGUMENTS and never calls

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: SkillsListInput,
) SkillsListError!SkillsListOutput {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    return .{
        .skills = skills_store.listSkills(allocator, db, input.workspace_id) catch |err| switch (err) {
            // `WorkspaceIdRequired` is unreachable behind the guard above,
            // but it is mapped rather than propagated with `try`: that would
            // widen this function's error set to whatever the store declares,
            error.WorkspaceIdRequired => return error.WorkspaceIdRequired,
            error.QueryFailed => return error.QueryFailed,
            error.OutOfMemory => return error.OutOfMemory,
        },
    };
}

// =====================================================================
// Handler
// =====================================================================

/// The per-skill row on the wire. A struct rather than a map so a field
/// added to `SkillRow` cannot silently leak onto the list response.
const SkillSummary = struct {
    name: []const u8,
    description: []const u8,
    is_can_auto_improve: bool,
};

const SkillListResponse = struct {
    skills: []const SkillSummary,
};

pub fn skillsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = req.params.get("workspace_id") orelse "",
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired => 400,
            error.QueryFailed, error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.QueryFailed => "DB error",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    defer skills_store.freeSkillRows(allocator, output.skills);

    const summaries = try allocator.alloc(SkillSummary, output.skills.len);
    defer allocator.free(summaries);
    for (output.skills, 0..) |row, i| {
        summaries[i] = .{
            .name = row.name,
            .description = row.description,
            .is_can_auto_improve = row.is_can_auto_improve,
        };
    }

    const data = try std.json.Stringify.valueAlloc(
        allocator,
        SkillListResponse{ .skills = summaries },
        .{},
    );
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// See the note in `skill_delete.zig`: the test binary has no HTTP server,
// so nothing else in `zig build test` would analyse this handler's body.
comptime {
    _ = &skillsListHandler;
}

// ─── Tests ──────────────────────────────────────────────────────────────

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const testing = std.testing;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

/// Real Migration 101 tables on an in-memory database, seeded with one row
/// per workspace so the scoping assertions have something to be wrong
/// about.
fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    try migration.Migration102CreateSkills.up(&db, testing.allocator);
    try migration.Migration119CreateSkillMetadata.up(&db, testing.allocator);
    return .{ .db = db, .threaded = threaded };
}

fn seed(ctx: *TestCtx, workspace_id: []const u8, name: []const u8, description: []const u8) !void {
    const content = try std.fmt.allocPrint(testing.allocator, "body of {s}", .{name});
    defer testing.allocator.free(content);
    const row = try skills_store.upsertSkill(testing.allocator, &ctx.db, .{
        .workspace_id = workspace_id,
        .name = name,
        .description = description,
        .content = content,
    });
    skills_store.freeSkillRow(testing.allocator, row);
}

test "useCase: empty workspace_id returns WorkspaceIdRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Refused before SQL: `Backend.exec` binds "" as NULL and
    // `skills.workspace_id` is NOT NULL.
    try testing.expectError(
        error.WorkspaceIdRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "" }),
    );
}

test "useCase: a workspace with no skills returns an empty list" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1" });
    defer skills_store.freeSkillRows(alloc, output.skills);
    try testing.expectEqual(@as(usize, 0), output.skills.len);
}

test "useCase: never returns another workspace's skills" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seed(&ctx, "ws_1", "pdf", "Work with PDFs");
    try seed(&ctx, "ws_1", "zig-trap", "A Zig trap");
    try seed(&ctx, "ws_2", "not-mine", "Another workspace's copy");

    const mine = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1" });
    defer skills_store.freeSkillRows(alloc, mine.skills);

    // Name-ordered (the UNIQUE (workspace_id, name) index gives it), and
    // scoped: `not-mine` is absent even though the name is a plain string.
    try testing.expectEqual(@as(usize, 2), mine.skills.len);
    try testing.expectEqualStrings("pdf", mine.skills[0].name);
    try testing.expectEqualStrings("Work with PDFs", mine.skills[0].description);
    try testing.expectEqualStrings("zig-trap", mine.skills[1].name);
}

test "useCase: an empty description round-trips as empty, not as a missing field" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // A model routinely writes the body first and the one-line description
    // second, so "" is a legal skill state.
    try seed(&ctx, "ws_1", "half-written", "");

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1" });
    defer skills_store.freeSkillRows(alloc, output.skills);
    try testing.expectEqual(@as(usize, 1), output.skills.len);
    try testing.expectEqualStrings("", output.skills[0].description);
}

test "useCase: the auto-improve lock travels with each list row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seed(&ctx, "ws_1", "alpha", "first skill");
    const pinned = try skills_store.upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .name = "beta",
        .description = "second skill",
        .content = "body of beta",
        .is_can_auto_improve = false,
    });
    defer skills_store.freeSkillRow(alloc, pinned);

    // The list is the only surface that knows about every skill, so a row
    // that dropped the flag would render every skill as unlocked and the
    // checkbox would lie about what the agent may touch.
    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1" });
    defer skills_store.freeSkillRows(alloc, output.skills);

    try testing.expectEqual(@as(usize, 2), output.skills.len);
    try testing.expectEqualStrings("alpha", output.skills[0].name);
    try testing.expect(output.skills[0].is_can_auto_improve);
    try testing.expectEqualStrings("beta", output.skills[1].name);
    try testing.expect(!output.skills[1].is_can_auto_improve);
}
// Registration ORDER is load-bearing: `matchRoute` returns on the first hit,
// so the collection route must precede `:skill_name`.
