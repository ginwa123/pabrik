//! `GET /api/workspaces/:workspace_id/skills/:skill_name`. One skill's body
//! and metadata, scoped to one workspace.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const skills_store = @import("../agentic_loop/skills_store.zig");

pub const SkillDetailError = error{
    IdsRequired,
    NotFound,
    QueryFailed,
    OutOfMemory,
};

pub const SkillDetailInput = struct {
    workspace_id: []const u8,
    skill_name: []const u8,
};

/// The row as it goes on the wire. `asset_count`, not the asset list: the
/// dialog shows "11 companion files" and shipping every body to render that
/// number would put the bundle in the payload. `metadata` comes from the table.
pub const SkillDetailRow = struct {
    name: []const u8,
    description: []const u8,
    content: []const u8,
    asset_count: usize,
    is_can_auto_improve: bool,
    metadata: []const http_response.SkillMetadataEntry,
};

pub const SkillDetailOutput = struct {
    /// Null on a miss. Owned when present; free with
    /// `skills_store.freeSkillRow`.
    skill: ?skills_store.SkillRow = null,
    /// Workspace-scoped skill NAMES, populated only on a miss. Borrowed
    /// from the rows returned alongside, so it lives no longer than the
    /// `available` slice below.
    asset_count: usize = 0,
    /// Owned rows backing `available_skills` on a miss; empty otherwise.
    available: []skills_store.SkillRow = &.{},
    /// Owned rows; free with `skills_store.freeSkillMetadataRows`.
    metadata: []skills_store.SkillMetadataRow = &.{},
};

/// 200 shape.
const SkillDetailFoundResponse = struct {
    skill: SkillDetailRow,
    error_message: []const u8,
};

/// 404 shape. `available_skills` is present here and ABSENT on success,
/// mirroring `use_skill`: a caller only needs the list when it does not
/// have what it asked for.
const SkillDetailMissingResponse = struct {
    skill: ?SkillDetailRow,
    error_message: []const u8,
    available_skills: []const []const u8,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: SkillDetailInput,
) SkillDetailError!SkillDetailOutput {
    if (input.workspace_id.len == 0 or input.skill_name.len == 0) {
        return error.IdsRequired;
    }

    // A name that exists in ANOTHER workspace lands here as `NotFound` too,
    // and that is deliberate: a 403 would confirm the name exists, which is
    // the thing the workspace scoping exists to hide.
    const row = skills_store.getSkillByName(allocator, db, input.workspace_id, input.skill_name) catch |err| switch (err) {
        error.NotFound => return error.NotFound,
        // Both ids are non-empty by the guard above, so the store can only
        // reach this arm if the two checks ever drift apart. Treat it as
        // a caller error rather than a silent not-found.
        error.WorkspaceIdNameRequired => return error.IdsRequired,
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer skills_store.freeSkillRow(allocator, row);

    // Counted by loading the companions rather than with a `COUNT(*)` query:
    // `skills_store` exposes one read for assets and adding a second shape
    // here would mean a second hand-written SELECT against `skill_assets`
    const assets = skills_store.listAssets(allocator, db, input.workspace_id, input.skill_name) catch |err| switch (err) {
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        error.WorkspaceIdNameRequired => return error.IdsRequired,
    };
    defer skills_store.freeSkillAssetRows(allocator, assets);

    const metadata = skills_store.listMetadata(allocator, db, input.workspace_id, input.skill_name) catch |err| switch (err) {
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        error.WorkspaceIdNameRequired => return error.IdsRequired,
    };
    errdefer skills_store.freeSkillMetadataRows(allocator, metadata);

    return .{ .skill = row, .asset_count = assets.len, .metadata = metadata };
}

/// The workspace's skill names, for the "not found — here is what there
/// is" payload. Separate from `useCase` because it runs only on the miss
/// path; a hit must not pay for it.
fn availableNames(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_id: []const u8,
) SkillDetailError![]skills_store.SkillRow {
    // Mapped by hand for the same reason as `useCase` above: this
    // function's error set is part of the wire contract, and it should not
    // change because a guard inside the store was renamed.
    return skills_store.listSkills(allocator, db, workspace_id) catch |err| switch (err) {
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        // Only reachable with an empty workspace_id, which the handler has
        // already turned into a 400.
        error.WorkspaceIdRequired => return error.IdsRequired,
    };
}

// =====================================================================
// Handler
// =====================================================================

pub fn skillDetailHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const input: SkillDetailInput = .{
        .workspace_id = req.params.get("workspace_id") orelse "",
        .skill_name = req.params.get("skill_name") orelse "",
    };

    const output = useCase(allocator, sqlite_db, input) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.NotFound => 404,
            error.QueryFailed, error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "workspace_id and skill_name required",
            // One message for "no such name" and "belongs to another
            // workspace" on purpose — see the file header.
            error.NotFound => "skill not found",
            error.QueryFailed => "DB error",
            error.OutOfMemory => "Out of memory",
        };

        if (err == error.NotFound) {
            // The one branch that answers with the skill's own payload rather
            // than the generic error envelope.
            const available = availableNames(allocator, sqlite_db, input.workspace_id) catch {
                return res.jsonResponse(.{
                    .status_code = 404,
                    .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
                });
            };
            defer skills_store.freeSkillRows(allocator, available);
            const names = try allocator.alloc([]const u8, available.len);
            defer allocator.free(names);
            for (available, 0..) |row, i| names[i] = row.name;

            return res.jsonResponse(.{
                .status_code = 404,
                .data = try std.json.Stringify.valueAlloc(allocator, SkillDetailMissingResponse{
                    .skill = null,
                    .error_message = message,
                    .available_skills = names,
                }, .{}),
            });
        }

        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    const row = output.skill orelse return error.MissingSkillRow;
    defer skills_store.freeSkillRow(allocator, row);
    defer skills_store.freeSkillMetadataRows(allocator, output.metadata);

    // Borrowed from the rows above, which outlive the stringify.
    const entries = try allocator.alloc(http_response.SkillMetadataEntry, output.metadata.len);
    defer allocator.free(entries);
    for (output.metadata, 0..) |meta, i| {
        entries[i] = .{ .key = meta.key, .value = meta.value };
    }

    const data = try std.json.Stringify.valueAlloc(allocator, SkillDetailFoundResponse{
        .skill = .{
            .name = row.name,
            .description = row.description,
            .content = row.content,
            .asset_count = output.asset_count,
            .is_can_auto_improve = row.is_can_auto_improve,
            .metadata = entries,
        },
        .error_message = "",
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// See the note in `skill_delete.zig`: the test binary has no HTTP server,
// so nothing else in `zig build test` would analyse this handler's body.
comptime {
    _ = &skillDetailHandler;
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

const BUNDLED_BODY = "---\nname: pdf\ndescription: Work with PDFs\n---\n\nRun `scripts/convert.py`.\n";

fn seed(ctx: *TestCtx, workspace_id: []const u8, name: []const u8, assets: []const skills_store.SkillAssetInput) !void {
    const row = try skills_store.upsertSkill(testing.allocator, &ctx.db, .{
        .workspace_id = workspace_id,
        .name = name,
        .description = "Work with PDFs",
        // The body keeps its frontmatter: sha256(body) is the skill_eval
        // identity, so trimming it here would stale every cached verdict.
        .content = BUNDLED_BODY,
    });
    defer skills_store.freeSkillRow(testing.allocator, row);
    try skills_store.replaceAssets(testing.allocator, &ctx.db, workspace_id, name, assets);
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

test "useCase: returns the stored description, not one re-parsed from the body" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seed(&ctx, "ws_1", "pdf", &.{});

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .skill_name = "pdf" });
    const row = output.skill orelse return error.ExpectedSkill;
    defer skills_store.freeSkillRow(alloc, row);
    defer skills_store.freeSkillMetadataRows(alloc, output.metadata);

    try testing.expectEqualStrings("pdf", row.name);
    try testing.expectEqualStrings("Work with PDFs", row.description);
    try testing.expectEqualStrings(BUNDLED_BODY, row.content);
    try testing.expectEqual(@as(usize, 0), output.asset_count);
    // Nothing but the promoted keys in the fence, so there is no metadata.
    try testing.expectEqual(@as(usize, 0), output.metadata.len);
}

test "useCase: the detail read carries the frontmatter the columns do not hold" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try skills_store.upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .name = "pdf",
        .description = "Work with PDFs",
        .content = "---\nname: pdf\ndescription: Work with PDFs\norigin: ECC\ntags: [workflow, documents]\n---\nbody\n",
    });
    defer skills_store.freeSkillRow(alloc, created);

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .skill_name = "pdf" });
    const row = output.skill orelse return error.ExpectedSkill;
    defer skills_store.freeSkillRow(alloc, row);
    defer skills_store.freeSkillMetadataRows(alloc, output.metadata);

    // The UI never sees the fence: `tags` and `origin` arrive as data, so the
    // detail pane can render them without parsing markdown a second time.
    try testing.expectEqual(@as(usize, 2), output.metadata.len);
    try testing.expectEqualStrings("origin", output.metadata[0].key);
    try testing.expectEqualStrings("ECC", output.metadata[0].value);
    try testing.expectEqualStrings("tags", output.metadata[1].key);
    try testing.expectEqualStrings("[workflow, documents]", output.metadata[1].value);
}

test "useCase: a bundle reports its companion count without shipping the bodies" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seed(&ctx, "ws_1", "pdf", &.{
        .{ .rel_path = "scripts/convert.py", .content = "print('hi')" },
        .{ .rel_path = "references/schemas.md", .content = "# schemas" },
    });

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .skill_name = "pdf" });
    const row = output.skill orelse return error.ExpectedSkill;
    defer skills_store.freeSkillRow(alloc, row);
    defer skills_store.freeSkillMetadataRows(alloc, output.metadata);

    try testing.expectEqual(@as(usize, 2), output.asset_count);
}

test "useCase: a locked skill reports its lock on the detail read" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const pinned = try skills_store.upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .name = "pdf",
        .description = "Work with PDFs",
        .content = BUNDLED_BODY,
        .is_can_auto_improve = false,
    });
    defer skills_store.freeSkillRow(alloc, pinned);

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .skill_name = "pdf" });
    const row = output.skill orelse return error.ExpectedSkill;
    defer skills_store.freeSkillRow(alloc, row);
    defer skills_store.freeSkillMetadataRows(alloc, output.metadata);

    // The detail pane owns the checkbox, so the flag has to be on this
    // read or the toggle would always render as checked.
    try testing.expect(!row.is_can_auto_improve);
}

test "useCase: another workspace's skill name is NotFound, not forbidden" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seed(&ctx, "ws_1", "pdf", &.{});

    // 403 here would confirm the name exists — the exact leak the
    // workspace scoping exists to prevent.
    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_2", .skill_name = "pdf" }),
    );
}

test "availableNames lists the requesting workspace's skills and no others" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seed(&ctx, "ws_1", "pdf", &.{});
    try seed(&ctx, "ws_1", "skill-creator", &.{});
    try seed(&ctx, "ws_2", "secret-skill", &.{});

    const available = try availableNames(alloc, &ctx.db, "ws_1");
    defer skills_store.freeSkillRows(alloc, available);

    try testing.expectEqual(@as(usize, 2), available.len);
    try testing.expectEqualStrings("pdf", available[0].name);
    try testing.expectEqualStrings("skill-creator", available[1].name);
}
