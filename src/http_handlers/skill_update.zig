//! `PATCH /api/workspaces/:workspace_id/skills/:skill_name`. Edits one
//! workspace-scoped skill.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const skills_store = @import("../agentic_loop/skills_store.zig");

/// PATCH body. Both fields default to `null` so an omitted field is
/// distinguishable from an explicit `""` — the latter is a real "clear
/// this" request, and it is honoured.
const UpdateSkillBody = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    content: ?[]const u8 = null,
    is_can_auto_improve: ?bool = null,
};

pub const SkillUpdateError = error{
    WorkspaceIdRequired,
    SkillNameRequired,
    InvalidName,
    ContentTooLarge,
    NothingToChange,
    NotFound,
    QueryFailed,
    UpdateFailed,
    OutOfMemory,
};

pub const SkillUpdateInput = struct {
    workspace_id: []const u8,
    skill_name: []const u8,
    body: UpdateSkillBody,
};

pub const SkillUpdateOutput = struct {
    /// Owned; free with `skills_store.freeSkillRow`.
    skill: skills_store.SkillRow,
    /// Owned; free with `skills_store.freeSkillMetadataRows`. A patch that
    /// rewrites the body re-derives this, so it is not the set the caller
    /// sent.
    metadata: []skills_store.SkillMetadataRow = &.{},
};

/// The skill plus the metadata projected from its body. Shared by the
/// patch path and the no-op path so both answer with the same shape.
fn withMetadata(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_id: []const u8,
    row: skills_store.SkillRow,
) SkillUpdateError!SkillUpdateOutput {
    const metadata = skills_store.listMetadata(allocator, db, workspace_id, row.name) catch |err| switch (err) {
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        error.WorkspaceIdNameRequired => return error.WorkspaceIdRequired,
    };
    return .{ .skill = row, .metadata = metadata };
}

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: SkillUpdateInput,
) SkillUpdateError!SkillUpdateOutput {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (input.skill_name.len == 0) return error.SkillNameRequired;

    // A `name` in the body is a claim about which row is being addressed, not
    // a rename instruction: renaming would silently break every `use_skill({
    // name })` call and every `skill_eval` verdict keyed on the name.
    if (input.body.name) |name| {
        if (!skills_store.isValidSkillName(name)) return error.InvalidName;
        const current = try readRow(allocator, db, input.workspace_id, input.skill_name);
        defer skills_store.freeSkillRow(allocator, current);
        if (!std.mem.eql(u8, current.name, name)) return error.NotFound;
    }

    // A PATCH with no field keeps the stored row, and the cheapest way to
    // keep a skill is not to write it: no UPDATE means the row is returned
    // as-is and `updated_at` does not advance either.
    if (input.body.description == null and input.body.content == null and input.body.is_can_auto_improve == null) {
        return withMetadata(
            allocator,
            db,
            input.workspace_id,
            try readRow(allocator, db, input.workspace_id, input.skill_name),
        );
    }

    const row = skills_store.updateSkill(allocator, db, input.workspace_id, input.skill_name, .{
        .description = input.body.description,
        .content = input.body.content,
        .is_can_auto_improve = input.body.is_can_auto_improve,
    }) catch |err| switch (err) {
        error.WorkspaceIdNameRequired => return error.WorkspaceIdRequired,
        error.NotFound => return error.NotFound,
        error.ContentTooLarge => return error.ContentTooLarge,
        error.NothingToChange => return error.NothingToChange,
        error.UpdateFailed => return error.UpdateFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return withMetadata(allocator, db, input.workspace_id, row);
}

/// `skills_store.getSkillByName` narrowed to this handler's error set.
fn readRow(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_id: []const u8,
    name: []const u8,
) SkillUpdateError!skills_store.SkillRow {
    return skills_store.getSkillByName(allocator, db, workspace_id, name) catch |err| switch (err) {
        error.WorkspaceIdNameRequired => return error.WorkspaceIdRequired,
        error.NotFound => return error.NotFound,
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

// ===================================================================== Error
// mapping
// ===================================================================== Two

fn statusFor(err: SkillUpdateError) u16 {
    return switch (err) {
        error.WorkspaceIdRequired, error.SkillNameRequired, error.InvalidName => 400,
        error.ContentTooLarge => 413,
        // 404, never 403: a 403 would confirm the name exists, which is
        // the one thing workspace scoping exists to withhold.
        error.NotFound => 404,
        // 409, not 200: the caller asked for a change and got none. A 200
        // here would render a saved-looking pane that saved nothing.
        error.NothingToChange => 409,
        error.QueryFailed, error.UpdateFailed, error.OutOfMemory => 500,
    };
}

fn messageFor(err: SkillUpdateError) []const u8 {
    return switch (err) {
        error.WorkspaceIdRequired => "workspace_id required",
        error.SkillNameRequired => "skill_name required",
        error.InvalidName => "name must be 1-128 characters of letters, digits, dot, dash or underscore",
        error.ContentTooLarge => "content exceeds the 2 MiB per-skill cap",
        error.NotFound => "skill not found",
        error.NothingToChange => "nothing to change — the skill already holds these values",
        error.QueryFailed => "DB error",
        error.UpdateFailed => "DB error",
        error.OutOfMemory => "Out of memory",
    };
}

// =====================================================================
// Handler
// =====================================================================

pub fn skillUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const body = std.json.parseFromSliceLeaky(UpdateSkillBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = req.params.get("workspace_id") orelse "",
        .skill_name = req.params.get("skill_name") orelse "",
        .body = body,
    }) catch |err| {
        return res.jsonResponse(.{
            .status_code = statusFor(err),
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = messageFor(err) }),
        });
    };
    defer skills_store.freeSkillRow(allocator, output.skill);
    defer skills_store.freeSkillMetadataRows(allocator, output.metadata);

    const entries = try allocator.alloc(http_response.SkillMetadataEntry, output.metadata.len);
    defer allocator.free(entries);
    for (output.metadata, 0..) |meta, i| {
        entries[i] = .{ .key = meta.key, .value = meta.value };
    }

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .skill = http_response.makeSkillDetailResponse(.{
            .name = output.skill.name,
            .description = output.skill.description,
            .content = output.skill.content,
            // The stored row, not the patch: an edit that mentions only
            // the description must come back with the body it did not
            // touch, or the caller would render a blank instruction set.
            .asset_count = 0,
            .is_can_auto_improve = output.skill.is_can_auto_improve,
            .metadata = entries,
        }),
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// See the note in `skill_delete.zig`: the test binary has no HTTP server,
// so nothing else in `zig build test` would analyse this handler's body.
comptime {
    _ = &skillUpdateHandler;
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

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try migration.Migration102CreateSkills.up(&db, testing.allocator);
    try migration.Migration119CreateSkillMetadata.up(&db, testing.allocator);
    return .{ .db = db, .threaded = threaded };
}

fn seed(ctx: *TestCtx, workspace_id: []const u8, name: []const u8, description: []const u8, content: []const u8) !void {
    const row = try skills_store.upsertSkill(testing.allocator, &ctx.db, .{
        .workspace_id = workspace_id,
        .name = name,
        .description = description,
        .content = content,
    });
    defer skills_store.freeSkillRow(testing.allocator, row);
}

/// Read the stored body straight from SQL, bypassing the store, so an
/// assertion about what was persisted cannot be satisfied by the same code
/// path it is testing.
fn storedContent(ctx: *TestCtx, workspace_id: []const u8, name: []const u8) ![]const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT content FROM skills WHERE workspace_id = ? AND name = ?",
        &[_][]const u8{ workspace_id, name },
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.SkillMissing;
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

test "useCase: patches the description and keeps the body it does not mention" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seed(&ctx, "ws_1", "pdf", "old description", "the body that must survive");

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .skill_name = "pdf",
        .body = .{ .description = "new description" },
    });
    defer skills_store.freeSkillRow(alloc, output.skill);
    defer skills_store.freeSkillMetadataRows(alloc, output.metadata);

    // Without the load-current-first step inside the store, a
    // description-only patch would blank the instruction set — which IS
    // the whole skill.
    try testing.expectEqualStrings("new description", output.skill.description);
    try testing.expectEqualStrings("the body that must survive", output.skill.content);
}

test "useCase: patches the body and keeps the description it does not mention" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seed(&ctx, "ws_1", "pdf", "the description that must survive", "old body");

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .skill_name = "pdf",
        .body = .{ .content = "new body" },
    });
    defer skills_store.freeSkillRow(alloc, output.skill);
    defer skills_store.freeSkillMetadataRows(alloc, output.metadata);

    try testing.expectEqualStrings("the description that must survive", output.skill.description);
    try testing.expectEqualStrings("new body", output.skill.content);
}

test "useCase: an explicit empty string clears the field rather than keeping it" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seed(&ctx, "ws_1", "pdf", "a description", "a body");

    // `""` is a real "clear this" request, which is why the body fields are
    // `?[]const u8` and not `[]const u8` with a "" default: an omitted
    // field keeps its value, an explicit empty one does not.
    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .skill_name = "pdf",
        .body = .{ .description = "" },
    });
    defer skills_store.freeSkillRow(alloc, output.skill);
    defer skills_store.freeSkillMetadataRows(alloc, output.metadata);

    try testing.expectEqualStrings("", output.skill.description);
    try testing.expectEqualStrings("a body", output.skill.content);
}

test "useCase: a body with neither field keeps the stored row, untouched" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seed(&ctx, "ws_1", "pdf", "a description", "a body");

    // Backdate so a same-second CURRENT_TIMESTAMP write is still visible.
    try ctx.db.exec(
        alloc,
        "UPDATE skills SET updated_at = '2000-01-01 00:00:00' WHERE workspace_id = 'ws_1' AND name = 'pdf'",
        &.{},
    );

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .skill_name = "pdf",
        .body = .{},
    });
    defer skills_store.freeSkillRow(alloc, output.skill);
    defer skills_store.freeSkillMetadataRows(alloc, output.metadata);

    // "Omitted means keep" is only honest if nothing at all moved: the
    // values stay AND updated_at stays, because no write happened.
    try testing.expectEqualStrings("a description", output.skill.description);
    try testing.expectEqualStrings("a body", output.skill.content);
    try testing.expectEqualStrings("2000-01-01 00:00:00", output.skill.updated_at);
}

test "useCase: a matching name in the body is accepted and changes nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seed(&ctx, "ws_1", "pdf", "a description", "a body");

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .skill_name = "pdf",
        .body = .{ .name = "pdf", .content = "new body" },
    });
    defer skills_store.freeSkillRow(alloc, output.skill);
    defer skills_store.freeSkillMetadataRows(alloc, output.metadata);

    try testing.expectEqualStrings("pdf", output.skill.name);
    try testing.expectEqualStrings("new body", output.skill.content);
}

test "useCase: a rename is refused, and the body is left as it was" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seed(&ctx, "ws_1", "pdf", "a description", "the body that must survive");

    // A rename would break every `use_skill({ name })` call and every
    // `skill_eval` verdict keyed on the name, so the answer is "no such
    // skill" rather than a quiet half-applied edit — and the same answer a
    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .skill_name = "pdf",
            .body = .{ .name = "pdf-renamed", .content = "never applied" },
        }),
    );

    const kept = try storedContent(&ctx, "ws_1", "pdf");
    defer alloc.free(kept);
    try testing.expectEqualStrings("the body that must survive", kept);
}

test "useCase: an unchanged patch is NothingToChange, a 409" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seed(&ctx, "ws_1", "pdf", "same", "same body");

    // A 200 here would render a saved-looking pane that saved nothing.
    try testing.expectError(
        error.NothingToChange,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .skill_name = "pdf",
            .body = .{ .description = "same", .content = "same body" },
        }),
    );
    try testing.expectEqual(@as(u16, 409), statusFor(error.NothingToChange));
}

test "useCase: missing ids are 400s before the database is touched" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seed(&ctx, "ws_1", "pdf", "a description", "a body");

    try testing.expectError(
        error.WorkspaceIdRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "", .skill_name = "pdf", .body = .{ .content = "x" } }),
    );
    try testing.expectError(
        error.SkillNameRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .skill_name = "", .body = .{ .content = "x" } }),
    );

    try testing.expectEqual(@as(u16, 400), statusFor(error.WorkspaceIdRequired));
    try testing.expectEqualStrings("workspace_id required", messageFor(error.WorkspaceIdRequired));
    try testing.expectEqual(@as(u16, 400), statusFor(error.SkillNameRequired));
    try testing.expectEqualStrings("skill_name required", messageFor(error.SkillNameRequired));
}

test "useCase: another workspace's skill name is NotFound — 404, never 403" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seed(&ctx, "ws_1", "pdf", "a description", "the body that must survive");

    // A 403 would confirm the name exists, which is exactly what workspace
    // scoping exists to withhold.
    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_2",
            .skill_name = "pdf",
            .body = .{ .content = "stolen" },
        }),
    );
    try testing.expectEqual(@as(u16, 404), statusFor(error.NotFound));
    try testing.expectEqualStrings("skill not found", messageFor(error.NotFound));

    const kept = try storedContent(&ctx, "ws_1", "pdf");
    defer alloc.free(kept);
    try testing.expectEqualStrings("the body that must survive", kept);
}

test "useCase: an unknown skill name is NotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .skill_name = "ghost",
            .body = .{ .content = "x" },
        }),
    );
}

test "useCase: store failures are 500 DB errors" {
    try testing.expectEqual(@as(u16, 500), statusFor(error.UpdateFailed));
    try testing.expectEqualStrings("DB error", messageFor(error.UpdateFailed));
    try testing.expectEqual(@as(u16, 500), statusFor(error.QueryFailed));
    try testing.expectEqual(@as(u16, 413), statusFor(error.ContentTooLarge));
}

test "useCase: a flag-only patch toggles the lock and keeps the body" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seed(&ctx, "ws_1", "pdf", "a description", "the body that must survive");

    // The checkbox in the Skills panel sends exactly this: one field, and
    // a skill whose other fields are identical. Without the flag in the
    // store's no-op comparison the server would answer 409 to it.
    const locked = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .skill_name = "pdf",
        .body = .{ .is_can_auto_improve = false },
    });
    defer skills_store.freeSkillRow(alloc, locked.skill);
    defer skills_store.freeSkillMetadataRows(alloc, locked.metadata);

    try testing.expect(!locked.skill.is_can_auto_improve);
    try testing.expectEqualStrings("a description", locked.skill.description);
    try testing.expectEqualStrings("the body that must survive", locked.skill.content);

    const unlocked = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .skill_name = "pdf",
        .body = .{ .is_can_auto_improve = true },
    });
    defer skills_store.freeSkillRow(alloc, unlocked.skill);
    defer skills_store.freeSkillMetadataRows(alloc, unlocked.metadata);
    try testing.expect(unlocked.skill.is_can_auto_improve);
    try testing.expectEqualStrings("the body that must survive", unlocked.skill.content);
}

test "useCase: the human editor still edits a LOCKED skill" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try skills_store.upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .name = "pinned",
        .description = "a description",
        .content = "old body",
        .is_can_auto_improve = false,
    });
    defer skills_store.freeSkillRow(alloc, created);

    // The flag blocks the AGENT tools, not the human. This route is the
    // only way to correct a skill the agent is no longer allowed to touch,
    // so refusing here would leave a pinned skill unfixable.
    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .skill_name = "pinned",
        .body = .{ .content = "human-edited body" },
    });
    defer skills_store.freeSkillRow(alloc, output.skill);
    defer skills_store.freeSkillMetadataRows(alloc, output.metadata);

    try testing.expectEqualStrings("human-edited body", output.skill.content);
    try testing.expect(!output.skill.is_can_auto_improve);
}
