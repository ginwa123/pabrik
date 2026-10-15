//! `POST /api/workspaces/:workspace_id/skills`. Creates one workspace-scoped
//! skill.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const skills_store = @import("../agentic_loop/skills_store.zig");

/// Request body. Both fields default to "" so an empty body parses and is
/// then refused by validation rather than answering "Invalid JSON body" —
/// a blank form submission is a caller error, not a malformed request.
const CreateSkillBody = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    content: []const u8 = "",
    is_can_auto_improve: ?bool = null,
};

pub const SkillCreateError = error{
    WorkspaceIdRequired,
    NameRequired,
    InvalidName,
    ContentTooLarge,
    NameTaken,
    WriteFailed,
    OutOfMemory,
};

pub const SkillCreateInput = struct {
    workspace_id: []const u8,
    body: CreateSkillBody,
};

pub const SkillCreateOutput = struct {
    /// Owned; free with `skills_store.freeSkillRow`.
    skill: skills_store.SkillRow,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: SkillCreateInput,
) SkillCreateError!SkillCreateOutput {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;

    // Trimmed, not rejected: a name pasted with a trailing newline is the
    // same name, and the UNIQUE key is what the URL path segment has to
    // spell.
    const name = std.mem.trim(u8, input.body.name, " \t\r\n");
    if (name.len == 0) return error.NameRequired;
    if (!skills_store.isValidSkillName(name)) return error.InvalidName;

    // A create must not silently overwrite.
    if (skills_store.getSkillByName(allocator, db, input.workspace_id, name)) |existing| {
        // Freed here, not discarded: the row is only read to learn that
        // the name is taken, and `|_|` would drop every string it owns.
        skills_store.freeSkillRow(allocator, existing);
        return error.NameTaken;
    } else |err| switch (err) {
        error.NotFound => {},
        error.WorkspaceIdNameRequired => return error.WorkspaceIdRequired,
        error.QueryFailed => return error.WriteFailed,
        error.OutOfMemory => return error.OutOfMemory,
    }

    const row = skills_store.upsertSkill(allocator, db, .{
        .workspace_id = input.workspace_id,
        .name = name,
        .description = input.body.description,
        .content = input.body.content,
        .is_can_auto_improve = input.body.is_can_auto_improve,
    }) catch |err| switch (err) {
        error.WorkspaceIdNameRequired => return error.WorkspaceIdRequired,
        error.NameTooLong => return error.InvalidName,
        error.ContentTooLarge => return error.ContentTooLarge,
        error.WriteFailed, error.RowNotFoundAfterWrite => return error.WriteFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .skill = row };
}

// ===================================================================== Error
// mapping
// ===================================================================== Two

fn statusFor(err: SkillCreateError) u16 {
    return switch (err) {
        error.WorkspaceIdRequired, error.NameRequired, error.InvalidName => 400,
        error.ContentTooLarge => 413,
        error.NameTaken => 409,
        error.WriteFailed, error.OutOfMemory => 500,
    };
}

/// `requested_name` is only read for the duplicate answer, which names the
/// offending skill so the UI can say which row to change instead of
/// "conflict".
fn messageFor(
    err: SkillCreateError,
    allocator: std.mem.Allocator,
    requested_name: []const u8,
) ![]const u8 {
    return switch (err) {
        error.WorkspaceIdRequired => "workspace_id required",
        error.NameRequired => "name is required",
        error.InvalidName => "name must be 1-128 characters of letters, digits, dot, dash or underscore",
        error.ContentTooLarge => "content exceeds the 2 MiB per-skill cap",
        error.NameTaken => try std.fmt.allocPrint(
            allocator,
            "a skill named '{s}' already exists in this workspace",
            .{std.mem.trim(u8, requested_name, " \t\r\n")},
        ),
        error.WriteFailed => "DB error",
        error.OutOfMemory => "Out of memory",
    };
}

// =====================================================================
// Handler
// =====================================================================

pub fn skillCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";

    // An empty body is legal on the wire so the validation errors below are
    // what a blank submission sees; only unparseable JSON is a 400 here.
    var body = CreateSkillBody{};
    if (req.body.len > 0) {
        body = std.json.parseFromSliceLeaky(CreateSkillBody, allocator, req.body, .{}) catch {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
            });
        };
    }

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .body = body,
    }) catch |err| {
        return res.jsonResponse(.{
            .status_code = statusFor(err),
            .data = try http_response.makeErrorResponse(
                allocator,
                .{ .@"error" = try messageFor(err, allocator, body.name) },
            ),
        });
    };
    defer skills_store.freeSkillRow(allocator, output.skill);

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .skill = http_response.makeSkillDetailResponse(.{
            .name = output.skill.name,
            .description = output.skill.description,
            .content = output.skill.content,
            // This route writes the body only.
            .asset_count = 0,
            .is_can_auto_improve = output.skill.is_can_auto_improve,
        }),
    }, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = data });
}

// See the note in `skill_delete.zig`: the test binary has no HTTP server,
// so nothing else in `zig build test` would analyse this handler's body.
comptime {
    _ = &skillCreateHandler;
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

fn countRows(ctx: *TestCtx) !usize {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM skills", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(usize, row.values[0], 10) catch 0;
}

/// Read the stored body straight from SQL, bypassing the store, so an
/// assertion about what was persisted cannot be satisfied by the same code
/// path it is testing.
fn storedContent(ctx: *TestCtx, name: []const u8) ![]const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT content FROM skills WHERE workspace_id = ? AND name = ?",
        &[_][]const u8{ "ws_1", name },
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.SkillMissing;
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

test "useCase: creates a skill and returns the stored row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .body = .{ .name = "  pdf  ", .description = "Work with PDFs", .content = "body" },
    });
    defer skills_store.freeSkillRow(alloc, output.skill);

    // Trimmed, so the URL path segment and the UNIQUE key both spell the
    // name the user typed without its padding.
    try testing.expectEqualStrings("pdf", output.skill.name);
    try testing.expectEqualStrings("ws_1", output.skill.workspace_id);
    try testing.expectEqualStrings("Work with PDFs", output.skill.description);
    try testing.expectEqualStrings("body", output.skill.content);
    try testing.expect(output.skill.id.len > 0);
    try testing.expectEqual(@as(usize, 1), try countRows(&ctx));
}

test "useCase: an empty description round-trips as empty, not as a missing field" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // A model routinely writes the body first and the one-line description
    // second, so "" is a legal skill state.
    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .body = .{ .name = "half-written", .description = "", .content = "body" },
    });
    defer skills_store.freeSkillRow(alloc, output.skill);

    try testing.expectEqualStrings("", output.skill.description);
    try testing.expectEqualStrings("body", output.skill.content);
}

test "useCase: an empty workspace_id is WorkspaceIdRequired, a 400" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.WorkspaceIdRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "", .body = .{ .name = "pdf" } }),
    );
    try testing.expectEqual(@as(u16, 400), statusFor(error.WorkspaceIdRequired));
    try testing.expectEqualStrings("workspace_id required", messageFor(
        error.WorkspaceIdRequired,
        alloc,
        "",
    ) catch @panic("allocPrint failed for the skill_create message fixture"));
}

test "useCase: a blank name is NameRequired, a 400" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    for ([_][]const u8{ "", "   \t\n " }) |blank| {
        try testing.expectError(
            error.NameRequired,
            useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .body = .{ .name = blank } }),
        );
    }
    try testing.expectEqual(@as(u16, 400), statusFor(error.NameRequired));
    try testing.expectEqualStrings("name is required", messageFor(
        error.NameRequired,
        alloc,
        "",
    ) catch @panic("allocPrint failed for the skill_create message fixture"));

    // Nothing was written on the way to the error.
    try testing.expectEqual(@as(usize, 0), try countRows(&ctx));
}

test "useCase: a name the grammar cannot spell is InvalidName, a 400" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // `name` is joined onto a materialisation directory by `use_skill`, so
    // `..` and `a/b` would escape it. The grammar is the guard, and it runs
    // on the TRIMMED value so " pdf " cannot smuggle a space past it.
    for ([_][]const u8{ "..", "../../etc", "a/b", "has space", ".hidden", "trailing.", "a" ** 129 }) |bad| {
        try testing.expectError(
            error.InvalidName,
            useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .body = .{ .name = bad } }),
        );
    }
    try testing.expectEqual(@as(u16, 400), statusFor(error.InvalidName));
    try testing.expectEqual(@as(usize, 0), try countRows(&ctx));
}

test "useCase: a duplicate name in one workspace is NameTaken, a 409" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const first = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .body = .{ .name = "pdf", .description = "first", .content = "first body" },
    });
    defer skills_store.freeSkillRow(alloc, first.skill);

    try testing.expectError(
        error.NameTaken,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .body = .{ .name = "pdf", .description = "second", .content = "second body" },
        }),
    );
    try testing.expectEqual(@as(u16, 409), statusFor(error.NameTaken));

    // The duplicate must not have overwritten the stored body — a 409 that
    // half-applied would be worse than no answer at all.
    const kept = try storedContent(&ctx, "pdf");
    defer alloc.free(kept);
    try testing.expectEqualStrings("first body", kept);

    // The conflict names the skill, so the UI can say which row to change.
    const message = try messageFor(error.NameTaken, alloc, "pdf");
    defer alloc.free(message);
    try testing.expectEqualStrings(
        "a skill named 'pdf' already exists in this workspace",
        message,
    );
}

test "useCase: the same name in a second workspace is not a duplicate" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const in_ws1 = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .body = .{ .name = "pdf", .content = "A's copy" },
    });
    defer skills_store.freeSkillRow(alloc, in_ws1.skill);

    // Names are unique per workspace, not per database — two workspaces
    // are two different tenants and each keeps its own `pdf`.
    const in_ws2 = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_2",
        .body = .{ .name = "pdf", .content = "B's copy" },
    });
    defer skills_store.freeSkillRow(alloc, in_ws2.skill);

    try testing.expectEqualStrings("ws_2", in_ws2.skill.workspace_id);
    try testing.expect(!std.mem.eql(u8, in_ws1.skill.id, in_ws2.skill.id));
    try testing.expectEqual(@as(usize, 2), try countRows(&ctx));
}

test "useCase: a store failure is a 500 DB error" {
    try testing.expectEqual(@as(u16, 500), statusFor(error.WriteFailed));
    try testing.expectEqualStrings("DB error", messageFor(error.WriteFailed, testing.allocator, "x") catch @panic("allocPrint failed for the skill_create message fixture"));
    try testing.expectEqual(@as(u16, 500), statusFor(error.OutOfMemory));
    try testing.expectEqual(@as(u16, 413), statusFor(error.ContentTooLarge));
}

test "useCase: a create may arrive already locked" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // The checkbox is on the create form too, so a pinned skill can be
    // written once instead of created and then immediately toggled.
    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .body = .{ .name = "pinned", .description = "d", .content = "body", .is_can_auto_improve = false },
    });
    defer skills_store.freeSkillRow(alloc, output.skill);
    try testing.expect(!output.skill.is_can_auto_improve);

    // An omitted flag still means "the agent may evolve this".
    const open = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .body = .{ .name = "open", .description = "d", .content = "body" },
    });
    defer skills_store.freeSkillRow(alloc, open.skill);
    try testing.expect(open.skill.is_can_auto_improve);
}
