const std = @import("std");
const pabrikcore = @import("pabrikcore");
const database = pabrikcore.database;
const helpers = @import("helpers");
const cron = @import("cron.zig");
const fire = @import("fire.zig");
const kanban_model = @import("kanban_model.zig");

pub const ProjectKind = enum {
    kanban,
    routine,

    pub fn itemType(self: ProjectKind) []const u8 {
        return switch (self) {
            .kanban => "kanban",
            .routine => "routine",
        };
    }

    pub fn parse(text: []const u8) ?ProjectKind {
        if (std.mem.eql(u8, text, "kanban")) return .kanban;
        if (std.mem.eql(u8, text, "routine")) return .routine;
        return null;
    }
};

pub const Error = error{
    WorkspaceIdRequired,
    ProjectIdRequired,
    NameRequired,
    PathRequired,
    KindRequired,
    KanbanTakesNoRoutineFields,
    RoutineFieldsOnNonRoutine,
    InvalidSchedule,
    NextFireTimeFailed,
    ProjectNotFound,
    NothingToEdit,
    DatabaseError,
    OutOfMemory,
};

pub const Project = struct {
    id: []u8,
    workspace_id: []u8,
    item_type: []u8,
    name: []u8,
    path: ?[]u8,
    position: i64,
    description: []u8,
    instruction: []u8,
    schedule: []u8,
    cwd: []u8,
    enabled: bool,
    next_run_at: []u8,
    has_routine_row: bool = false,

    pub fn isRoutine(self: Project) bool {
        return std.mem.eql(u8, self.item_type, "routine");
    }

    pub fn deinit(self: Project, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.workspace_id);
        allocator.free(self.item_type);
        allocator.free(self.name);
        if (self.path) |p| allocator.free(p);
        allocator.free(self.description);
        allocator.free(self.instruction);
        allocator.free(self.schedule);
        allocator.free(self.cwd);
        allocator.free(self.next_run_at);
    }
};

pub const CreateInput = struct {
    workspace_id: []const u8,
    kind: ProjectKind,
    name: []const u8,
    path: []const u8 = "",
    description: []const u8 = "",
    instruction: []const u8 = "",
    schedule: []const u8 = "",
    cwd: []const u8 = "",
    enabled: bool = true,
};

pub const EditInput = struct {
    workspace_id: []const u8,
    item_id: []const u8,
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
    description: ?[]const u8 = null,
    instruction: ?[]const u8 = null,
    schedule: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    enabled: ?bool = null,

    pub fn touchesRoutine(self: EditInput) bool {
        return self.description != null or
            self.instruction != null or
            self.schedule != null or
            self.cwd != null or
            self.enabled != null;
    }
};

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\n\r");
}

fn projectId(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "item_{d}", .{helpers.unixTimestampNanos()});
}

fn nextFireAt(allocator: std.mem.Allocator, schedule: []const u8, enabled: bool) Error![]u8 {
    if (schedule.len == 0 or !enabled) return allocator.dupe(u8, "");
    const next_ns = cron.nextFireTime(schedule, helpers.unixTimestampNanos()) catch
        return error.NextFireTimeFailed;
    return fire.formatSqliteDatetime(allocator, next_ns) catch error.OutOfMemory;
}

fn readRoutine(allocator: std.mem.Allocator, db: *database.Db, item_id: []const u8, into: *Project) Error!void {
    var rows = db.query(allocator,
        \\SELECT COALESCE(CAST(description AS TEXT), ''), COALESCE(CAST(instruction AS TEXT), ''),
        \\COALESCE(CAST(schedule AS TEXT), ''), COALESCE(CAST(enabled AS TEXT), '1'),
        \\COALESCE(CAST(next_run_at AS TEXT), ''), COALESCE(CAST(cwd AS TEXT), '')
        \\FROM workspace_routines WHERE workspace_item_id = ? LIMIT 1
    , &.{item_id}) catch return error.DatabaseError;
    defer rows.deinit();

    const row = (rows.next() catch return error.DatabaseError) orelse return;
    defer row.deinit(allocator);

    into.description = try allocator.dupe(u8, row.values[0]);
    into.instruction = try allocator.dupe(u8, row.values[1]);
    into.schedule = try allocator.dupe(u8, row.values[2]);
    into.enabled = !std.mem.eql(u8, row.values[3], "0");
    into.next_run_at = try allocator.dupe(u8, row.values[4]);
    into.cwd = try allocator.dupe(u8, row.values[5]);
    into.has_routine_row = true;
}

pub fn readProject(allocator: std.mem.Allocator, db: *database.Db, item_id: []const u8) Error!?Project {
    if (item_id.len == 0) return null;

    var rows = db.query(allocator,
        \\SELECT id, COALESCE(CAST(workspace_id AS TEXT), ''), COALESCE(CAST(item_type AS TEXT), ''),
        \\COALESCE(CAST(name AS TEXT), ''), COALESCE(CAST(path AS TEXT), ''), COALESCE(CAST(position AS TEXT), '0')
        \\FROM workspace_items WHERE id = ? LIMIT 1
    , &.{item_id}) catch return error.DatabaseError;
    defer rows.deinit();

    const row = (rows.next() catch return error.DatabaseError) orelse return null;
    defer row.deinit(allocator);

    var project = Project{
        .id = try allocator.dupe(u8, row.values[0]),
        .workspace_id = try allocator.dupe(u8, row.values[1]),
        .item_type = try allocator.dupe(u8, row.values[2]),
        .name = try allocator.dupe(u8, row.values[3]),
        .path = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
        .position = std.fmt.parseInt(i64, row.values[5], 10) catch 0,
        .description = try allocator.dupe(u8, ""),
        .instruction = try allocator.dupe(u8, ""),
        .schedule = try allocator.dupe(u8, ""),
        .cwd = try allocator.dupe(u8, ""),
        .enabled = true,
        .next_run_at = try allocator.dupe(u8, ""),
    };
    errdefer project.deinit(allocator);

    if (project.isRoutine()) try readRoutine(allocator, db, project.id, &project);
    return project;
}

pub fn createProject(
    allocator: std.mem.Allocator,
    db: *database.Db,
    input: CreateInput,
) Error!Project {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;

    const name = trim(input.name);
    if (name.len == 0) return error.NameRequired;

    const schedule = trim(input.schedule);
    switch (input.kind) {
        .kanban => {
            if (schedule.len != 0 or
                trim(input.instruction).len != 0 or
                trim(input.description).len != 0 or
                trim(input.cwd).len != 0) return error.KanbanTakesNoRoutineFields;
        },
        .routine => {
            if (input.path.len == 0) return error.PathRequired;
            if (schedule.len != 0) cron.validate(schedule) catch return error.InvalidSchedule;
        },
    }

    const next_run_at = try nextFireAt(allocator, schedule, input.enabled);
    defer allocator.free(next_run_at);

    const item_id = try projectId(allocator);
    defer allocator.free(item_id);

    const cwd = if (input.cwd.len == 0) input.path else input.cwd;
    const enabled_text: []const u8 = if (input.enabled) "1" else "0";

    var tx = db.begin() catch return error.DatabaseError;
    defer tx.commitOrRollback() catch {};

    tx.exec(
        allocator,
        \\INSERT INTO workspace_items
        \\(id, workspace_id, item_type, name, path, position, created_at, updated_at)
        \\VALUES (?, ?, ?, ?, NULLIF(?, ''),
        \\COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1,
        \\datetime('now'), datetime('now'))
    ,
        &.{ item_id, input.workspace_id, input.kind.itemType(), name, input.path, input.workspace_id },
    ) catch return error.DatabaseError;

    if (input.kind == .kanban) {
        kanban_model.seedDefaultColumns(allocator, .{ .tx = &tx }, item_id) catch
            return error.DatabaseError;
    }

    tx.exec(
        allocator,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
        &.{ item_id, item_id, input.kind.itemType() },
    ) catch return error.DatabaseError;

    if (input.kind == .routine) {
        tx.exec(
            allocator,
            \\INSERT INTO workspace_routines
            \\(id, workspace_item_id, description, instruction, schedule, enabled, next_run_at, cwd)
            \\VALUES (?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''),
            \\COALESCE(NULLIF(?, ''), ''), ?, ?,
            \\COALESCE(NULLIF(?, ''), ''))
        ,
            &.{ item_id, item_id, input.description, input.instruction, schedule, enabled_text, next_run_at, cwd },
        ) catch return error.DatabaseError;
    }

    tx.commit() catch return error.DatabaseError;

    return (try readProject(allocator, db, item_id)) orelse error.DatabaseError;
}

pub fn editProject(
    allocator: std.mem.Allocator,
    db: *database.Db,
    input: EditInput,
) Error!Project {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (input.item_id.len == 0) return error.ProjectIdRequired;

    const current = (try readProject(allocator, db, input.item_id)) orelse
        return error.ProjectNotFound;
    defer current.deinit(allocator);

    if (!std.mem.eql(u8, current.workspace_id, input.workspace_id)) return error.ProjectNotFound;

    const routine = input.touchesRoutine();
    if (routine and !current.isRoutine()) return error.RoutineFieldsOnNonRoutine;
    if (routine and !current.has_routine_row) return error.ProjectNotFound;
    if (input.name == null and input.path == null and !routine) return error.NothingToEdit;

    var new_name: []const u8 = current.name;
    if (input.name) |raw| {
        new_name = trim(raw);
        if (new_name.len == 0) return error.NameRequired;
    }

    const new_path: []const u8 = input.path orelse (current.path orelse "");
    const new_description: []const u8 = input.description orelse current.description;
    const new_instruction: []const u8 = input.instruction orelse current.instruction;
    const new_schedule: []const u8 = trim(input.schedule orelse current.schedule);
    const new_cwd: []const u8 = input.cwd orelse current.cwd;
    const new_enabled: bool = input.enabled orelse current.enabled;

    if (routine and new_schedule.len != 0) cron.validate(new_schedule) catch
        return error.InvalidSchedule;

    const next_run_at = try nextFireAt(allocator, new_schedule, new_enabled);
    defer allocator.free(next_run_at);

    const enabled_text: []const u8 = if (new_enabled) "1" else "0";

    var tx = db.begin() catch return error.DatabaseError;
    defer tx.commitOrRollback() catch {};

    tx.exec(
        allocator,
        \\UPDATE workspace_items SET name = ?, path = NULLIF(?, ''), updated_at = datetime('now')
        \\WHERE id = ?
    ,
        &.{ new_name, new_path, input.item_id },
    ) catch return error.DatabaseError;

    if (routine) {
        tx.exec(
            allocator,
            \\UPDATE workspace_routines SET description = COALESCE(NULLIF(?, ''), ''),
            \\instruction = COALESCE(NULLIF(?, ''), ''), schedule = COALESCE(NULLIF(?, ''), ''),
            \\enabled = ?, next_run_at = ?, cwd = COALESCE(NULLIF(?, ''), ''),
            \\updated_at = datetime('now')
            \\WHERE workspace_item_id = ?
        ,
            &.{ new_description, new_instruction, new_schedule, enabled_text, next_run_at, new_cwd, input.item_id },
        ) catch return error.DatabaseError;
    }

    tx.commit() catch return error.DatabaseError;

    return (try readProject(allocator, db, input.item_id)) orelse error.DatabaseError;
}

const testing = std.testing;
const test_db = pabrikcore.test_db;
const migration = pabrikcore.migrations_mod.migration;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());

    try db.exec(
        testing.allocator,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL,
        \\    name TEXT,
        \\    path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    is_default INTEGER NOT NULL DEFAULT 0
        \\)
    ,
        &.{},
    );
    try db.exec(
        testing.allocator,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{},
    );
    try migration.Migration051AddKanban.up(&db, testing.allocator);
    try migration.Migration053AddKanbanColumnDescription.up(&db, testing.allocator);
    try migration.Migration111AddKanbanTaskDependencies.up(&db, testing.allocator);
    try migration.Migration084ReplaceRoutinesWithWorkspaceRoutines.up(&db, testing.allocator);
    try migration.Migration116UnifyAgentConfigTables.up(&db, testing.allocator);
    try migration.Migration139AddRoutineCwd.up(&db, testing.allocator);

    return .{ .db = db, .threaded = threaded };
}

fn columnNames(alloc: std.mem.Allocator, db: *database.Db, item_id: []const u8) ![]const []const u8 {
    const cols = try kanban_model.listColumns(alloc, db, item_id);
    defer kanban_model.freeColumns(alloc, cols);
    var names = try alloc.alloc([]const u8, cols.len);
    errdefer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }
    for (cols, 0..) |col, i| names[i] = try alloc.dupe(u8, col.name);
    return names;
}

fn freeNames(alloc: std.mem.Allocator, names: []const []const u8) void {
    for (names) |n| alloc.free(n);
    alloc.free(names);
}

test "create a kanban project seeds the three default columns and its agent config" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const project = try createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .kind = .kanban,
        .name = "  Release board  ",
        .path = "/home/dev/release",
    });
    defer project.deinit(alloc);

    try testing.expectEqualStrings("kanban", project.item_type);
    try testing.expectEqualStrings("Release board", project.name);
    try testing.expectEqualStrings("/home/dev/release", project.path.?);
    try testing.expectEqual(@as(i64, 0), project.position);
    try testing.expectEqualStrings("", project.schedule);

    const names = try columnNames(alloc, &ctx.db, project.id);
    defer freeNames(alloc, names);
    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("todo", names[0]);
    try testing.expectEqualStrings("in progress", names[1]);
    try testing.expectEqualStrings("done", names[2]);

    var rows = try ctx.db.query(
        alloc,
        "SELECT item_type FROM agent_configs WHERE workspace_item_id = ?",
        &.{project.id},
    );
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.NoAgentConfig;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("kanban", row.values[0]);
}

test "create a routine project stores its cron schedule and the next fire time" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const project = try createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .kind = .routine,
        .name = "Nightly sweep",
        .path = "/home/dev/sweep",
        .description = "check the logs",
        .instruction = "read the log and report",
        .schedule = "0 9 * * *",
        .cwd = "/home/dev/sweep",
    });
    defer project.deinit(alloc);

    try testing.expectEqualStrings("routine", project.item_type);
    try testing.expectEqualStrings("0 9 * * *", project.schedule);
    try testing.expectEqualStrings("check the logs", project.description);
    try testing.expectEqualStrings("read the log and report", project.instruction);
    try testing.expectEqualStrings("/home/dev/sweep", project.cwd);
    try testing.expect(project.enabled);
    try testing.expect(project.next_run_at.len > 0);

    const names = try columnNames(alloc, &ctx.db, project.id);
    defer freeNames(alloc, names);
    try testing.expectEqual(@as(usize, 0), names.len);
}

test "a routine created disabled has no next fire time" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const project = try createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .kind = .routine,
        .name = "Manual only",
        .path = "/tmp",
        .schedule = "*/5 * * * *",
        .enabled = false,
    });
    defer project.deinit(alloc);

    try testing.expect(!project.enabled);
    try testing.expectEqualStrings("", project.next_run_at);
}

test "create rejects a routine with no path" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.PathRequired, createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .kind = .routine,
        .name = "No path",
    }));
}

test "create rejects a schedule on a kanban project" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.KanbanTakesNoRoutineFields, createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .kind = .kanban,
        .name = "Board with a cron",
        .schedule = "0 9 * * *",
    }));
}

test "create rejects an unparsable cron expression" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.InvalidSchedule, createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .kind = .routine,
        .name = "Broken",
        .path = "/tmp",
        .schedule = "every morning",
    }));
}

test "create rejects an empty name" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.NameRequired, createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .kind = .kanban,
        .name = "   ",
    }));
}

test "create appends after the last position in the same workspace only" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const first = try createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .kind = .kanban,
        .name = "First",
    });
    defer first.deinit(alloc);

    const second = try createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .kind = .kanban,
        .name = "Second",
    });
    defer second.deinit(alloc);

    const other = try createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_2",
        .kind = .kanban,
        .name = "Elsewhere",
    });
    defer other.deinit(alloc);

    try testing.expectEqual(@as(i64, 0), first.position);
    try testing.expectEqual(@as(i64, 1), second.position);
    try testing.expectEqual(@as(i64, 0), other.position);
}

test "edit renames a kanban project and keeps its columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .kind = .kanban,
        .name = "Old name",
        .path = "/home/dev/old",
    });
    defer created.deinit(alloc);

    const edited = try editProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .item_id = created.id,
        .name = "New name",
    });
    defer edited.deinit(alloc);

    try testing.expectEqualStrings("New name", edited.name);
    try testing.expectEqualStrings("/home/dev/old", edited.path.?);

    const names = try columnNames(alloc, &ctx.db, created.id);
    defer freeNames(alloc, names);
    try testing.expectEqual(@as(usize, 3), names.len);
}

test "edit an instruction keeps the routine schedule and its next fire time" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .kind = .routine,
        .name = "Nightly",
        .path = "/tmp",
        .instruction = "old prompt",
        .schedule = "0 9 * * *",
    });
    defer created.deinit(alloc);
    try testing.expect(created.next_run_at.len > 0);

    const edited = try editProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .item_id = created.id,
        .instruction = "new prompt",
    });
    defer edited.deinit(alloc);

    try testing.expectEqualStrings("new prompt", edited.instruction);
    try testing.expectEqualStrings("0 9 * * *", edited.schedule);
    try testing.expectEqualStrings(created.next_run_at, edited.next_run_at);
}

test "edit recomputes the next fire time when the schedule changes" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .kind = .routine,
        .name = "Nightly",
        .path = "/tmp",
        .schedule = "0 9 * * *",
    });
    defer created.deinit(alloc);

    const edited = try editProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .item_id = created.id,
        .schedule = "30 3 * * 1",
    });
    defer edited.deinit(alloc);

    try testing.expectEqualStrings("30 3 * * 1", edited.schedule);
    try testing.expect(edited.next_run_at.len > 0);
}

test "edit clearing the schedule nulls the next fire time" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .kind = .routine,
        .name = "Nightly",
        .path = "/tmp",
        .schedule = "0 9 * * *",
    });
    defer created.deinit(alloc);

    const edited = try editProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .item_id = created.id,
        .schedule = "",
    });
    defer edited.deinit(alloc);

    try testing.expectEqualStrings("", edited.schedule);
    try testing.expectEqualStrings("", edited.next_run_at);
}

test "edit disabling a scheduled routine nulls the next fire time" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .kind = .routine,
        .name = "Nightly",
        .path = "/tmp",
        .schedule = "0 9 * * *",
    });
    defer created.deinit(alloc);

    const edited = try editProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .item_id = created.id,
        .enabled = false,
    });
    defer edited.deinit(alloc);

    try testing.expect(!edited.enabled);
    try testing.expectEqualStrings("0 9 * * *", edited.schedule);
    try testing.expectEqualStrings("", edited.next_run_at);
}

test "edit refuses routine fields on a kanban project" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .kind = .kanban,
        .name = "Board",
    });
    defer created.deinit(alloc);

    try testing.expectError(error.RoutineFieldsOnNonRoutine, editProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .item_id = created.id,
        .schedule = "0 9 * * *",
    }));
}

test "edit a project in another workspace is not found" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .kind = .kanban,
        .name = "Board",
    });
    defer created.deinit(alloc);

    try testing.expectError(error.ProjectNotFound, editProject(alloc, &ctx.db, .{
        .workspace_id = "ws_2",
        .item_id = created.id,
        .name = "Hijacked",
    }));
}

test "edit with nothing to change is an error, not a silent success" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try createProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .kind = .kanban,
        .name = "Board",
    });
    defer created.deinit(alloc);

    try testing.expectError(error.NothingToEdit, editProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .item_id = created.id,
    }));
}

test "edit a routine whose workspace_routines row is gone refuses instead of no-opping" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name)
        \\VALUES ('item_orphan', 'ws_1', 'routine', 'Orphan')
    , &.{});

    const read_back = (try readProject(alloc, &ctx.db, "item_orphan")).?;
    defer read_back.deinit(alloc);
    try testing.expect(!read_back.has_routine_row);

    try testing.expectError(error.ProjectNotFound, editProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_orphan",
        .instruction = "run it",
    }));

    const renamed = try editProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_orphan",
        .name = "Renamed",
    });
    defer renamed.deinit(alloc);
    try testing.expectEqualStrings("Renamed", renamed.name);
}

test "edit an unknown project id is not found" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.ProjectNotFound, editProject(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_missing",
        .name = "Ghost",
    }));
}

test "ProjectKind round-trips its wire names" {
    try testing.expectEqualStrings("kanban", ProjectKind.kanban.itemType());
    try testing.expectEqualStrings("routine", ProjectKind.routine.itemType());
    try testing.expectEqual(ProjectKind.kanban, ProjectKind.parse("kanban").?);
    try testing.expectEqual(ProjectKind.routine, ProjectKind.parse("routine").?);
    try testing.expect(ProjectKind.parse("agent") == null);
    try testing.expect(ProjectKind.parse("") == null);
}
