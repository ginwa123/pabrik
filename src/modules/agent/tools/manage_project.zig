const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const database = pabrikcore.database;
const project_model = @import("../loop/project_model.zig");
const tools_equipped = @import("tools_equipped.zig");

pub const ManageProjectInput = struct {
    action: []const u8 = "",
    item_type: ?[]const u8 = null,
    project_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
    description: ?[]const u8 = null,
    instruction: ?[]const u8 = null,
    schedule: ?[]const u8 = null,
    enabled: ?bool = null,
};

pub const manage_project_tool_system_prompt =
    \\Use `manage_project` to create a project or change one. A `kanban`
    \\project is a board; a `routine` project is a scheduler entry that fires
    \\its `instruction` on a 5-field cron `schedule`. The project belongs to
    \\the workspace of the calling chat.
;

pub const manage_project_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "manage_project",
        .description =
        \\Create or edit a project (a workspace item) from this chat. `item_type` `kanban` seeds a board with todo / in progress / done columns; `routine` seeds a scheduler entry that fires `instruction` on a 5-field cron `schedule` (`""` = manual run only). The project lands in the workspace of the CALLING chat — there is no workspace parameter. `action` is required: `create` needs `name` plus `item_type` (and `path` for a routine); `edit` needs `project_id` and writes ONLY the fields you pass. `name` / `path` work on any project; the remaining fields only on a routine, and are refused on a kanban. Both kinds appear under PROJECTS in the sidebar.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "action",
                    .type = "string",
                    .description = "'create' or 'edit'.",
                },
                .{
                    .name = "item_type",
                    .type = "string",
                    .description = "'kanban' or 'routine'. Required on create; ignored on edit (the project's own type wins).",
                },
                .{
                    .name = "project_id",
                    .type = "string",
                    .description = "The project to edit (an `item_...` id). Required on edit.",
                },
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Display name. Required on create.",
                },
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Absolute directory that becomes the cwd for this project's chats. Required for a routine, optional for a kanban.",
                },
                .{
                    .name = "instruction",
                    .type = "string",
                    .description = "Routine only: the prompt the agent runs on each fire.",
                },
                .{
                    .name = "description",
                    .type = "string",
                    .description = "Routine only: a one-line summary of what the routine does.",
                },
                .{
                    .name = "schedule",
                    .type = "string",
                    .description = "Routine only: a 5-field cron expression, e.g. '0 9 * * *'. Empty = manual-run only.",
                },
                .{
                    .name = "enabled",
                    .type = "boolean",
                    .description = "Routine only: false parks the routine without deleting it. Default true.",
                },
            },
            .required = &.{"action"},
        },
        .system_prompt = manage_project_tool_system_prompt,
    },
};

const ProjectDto = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
    name: []const u8,
    path: ?[]const u8,
    position: i64,
    description: []const u8,
    instruction: []const u8,
    schedule: []const u8,
    cwd: []const u8,
    enabled: bool,
    next_run_at: []const u8,
};

const ManageProjectOk = struct {
    success: bool = true,
    action: []const u8,
    project: ProjectDto,
    warning: []const u8 = "",
};

const ManageProjectFailure = struct {
    success: bool = false,
    @"error": []const u8,
};

fn projectDto(project: project_model.Project) ProjectDto {
    return .{
        .id = project.id,
        .workspace_id = project.workspace_id,
        .item_type = project.item_type,
        .name = project.name,
        .path = project.path,
        .position = project.position,
        .description = project.description,
        .instruction = project.instruction,
        .schedule = project.schedule,
        .cwd = project.cwd,
        .enabled = project.enabled,
        .next_run_at = project.next_run_at,
    };
}

fn failureJSON(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        ManageProjectFailure{ .@"error" = message },
        .{},
    );
}

fn failureJSONFmt(
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) ![]u8 {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    return failureJSON(allocator, message);
}

fn describe(err: project_model.Error) []const u8 {
    return switch (err) {
        error.WorkspaceIdRequired => "no workspace resolved for this chat",
        error.ProjectIdRequired => "edit needs a `project_id`",
        error.NameRequired => "`name` is required",
        error.PathRequired => "a routine project needs a `path` (the directory it runs in)",
        error.KindRequired => "create needs `item_type`: 'kanban' or 'routine'",
        error.KanbanTakesNoRoutineFields => "`instruction` / `description` / `schedule` only apply to a routine project",
        error.RoutineFieldsOnNonRoutine => "this project is not a routine, so it has no `instruction` / `description` / `schedule` / `enabled`",
        error.InvalidSchedule => "`schedule` is not a 5-field cron expression (e.g. '0 9 * * *')",
        error.NextFireTimeFailed => "`schedule` is a cron expression but no next fire time could be computed",
        error.ProjectNotFound => "no project with that id in this workspace",
        error.NothingToEdit => "edit received no field to change",
        error.DatabaseError => "the database rejected the write",
        error.OutOfMemory => "out of memory",
    };
}

pub fn executeManageProjectToJSON(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    input: ManageProjectInput,
    config_tools: ?[]const []const u8,
) ![]u8 {
    const action = std.mem.trim(u8, input.action, " \t\n\r");
    if (action.len == 0) return failureJSON(allocator, "`action` is required: 'create' or 'edit'");

    if (std.mem.eql(u8, action, "create")) {
        const kind_text = std.mem.trim(u8, input.item_type orelse "", " \t\n\r");
        const kind = project_model.ProjectKind.parse(kind_text) orelse
            return failureJSON(allocator, describe(error.KindRequired));

        const created = project_model.createProject(allocator, db, .{
            .workspace_id = workspace_id,
            .kind = kind,
            .name = input.name orelse "",
            .path = input.path orelse "",
            .description = input.description orelse "",
            .instruction = input.instruction orelse "",
            .schedule = input.schedule orelse "",
            .enabled = input.enabled orelse true,
        }) catch |err| return failureJSONFmt(allocator, "could not create the project: {s}", .{describe(err)});
        defer created.deinit(allocator);

        var warning: []const u8 = "";
        var warning_owned: ?[]u8 = null;
        defer if (warning_owned) |w| allocator.free(w);
        if (kind == .kanban) {
            tools_equipped.seedDefaultKanbanTools(allocator, .{ .db = db }, created.id, config_tools) catch |err| {
                warning_owned = try std.fmt.allocPrint(
                    allocator,
                    "the board was created but its agent tool allowlist could not be seeded: {s}",
                    .{@errorName(err)},
                );
                warning = warning_owned.?;
            };
        }

        return std.json.Stringify.valueAlloc(
            allocator,
            ManageProjectOk{ .action = "create", .project = projectDto(created), .warning = warning },
            .{},
        );
    }

    if (std.mem.eql(u8, action, "edit")) {
        const project_id = input.project_id orelse "";
        if (project_id.len == 0) return failureJSON(allocator, describe(error.ProjectIdRequired));

        const edited = project_model.editProject(allocator, db, .{
            .workspace_id = workspace_id,
            .item_id = project_id,
            .name = input.name,
            .path = input.path,
            .description = input.description,
            .instruction = input.instruction,
            .schedule = input.schedule,
            .enabled = input.enabled,
        }) catch |err| return failureJSONFmt(allocator, "could not edit the project: {s}", .{describe(err)});
        defer edited.deinit(allocator);

        return std.json.Stringify.valueAlloc(
            allocator,
            ManageProjectOk{ .action = "edit", .project = projectDto(edited) },
            .{},
        );
    }

    return failureJSONFmt(allocator, "unknown `action` '{s}': use 'create' or 'edit'", .{action});
}

const exec_pabrikcore = @import("pabrikcore");
const agent = exec_pabrikcore.agent;
const tools = @import("../loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
const workspace_scope = exec_pabrikcore.workspace_scope;

const no_workspace_message =
    "This chat resolves to no workspace, so there is nowhere to put the project. " ++
    "Open the chat from a workspace and retry.";

fn refusalOutput(ctx: ToolExecContext, tc: agent.ToolCall, message: []const u8) !ToolExecResult {
    const output = try wrapToolOutput(ctx.allocator, "manage_project", tc.function.arguments, false, message, "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execManageProject(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        ManageProjectInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "manage_project", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const resolved = workspace_scope.resolveWorkspaceId(ctx.allocator, ctx.db, ctx.session_id) catch |err| {
        const message = try std.fmt.allocPrint(
            ctx.allocator,
            "could not resolve this chat's workspace: {s}",
            .{@errorName(err)},
        );
        defer ctx.allocator.free(message);
        return refusalOutput(ctx, tc, message);
    };
    defer if (resolved) |w| ctx.allocator.free(w);
    const workspace_id = resolved orelse return refusalOutput(ctx, tc, no_workspace_message);

    const inner = try executeManageProjectToJSON(
        ctx.allocator,
        ctx.db,
        workspace_id,
        parsed.value,
        ctx.config.tools,
    );
    defer ctx.allocator.free(inner);

    const output = try wrapToolOutput(ctx.allocator, "manage_project", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
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

fn parsedValue(alloc: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, json, .{});
}

test "manage_project: the schema advertises the create/edit contract" {
    const f = manage_project_tool.function;
    try testing.expectEqualStrings("manage_project", f.name);
    try testing.expectEqualStrings("object", f.parameters.type);

    var saw_action = false;
    var saw_project_id = false;
    var saw_schedule = false;
    for (f.parameters.properties) |p| {
        if (std.mem.eql(u8, p.name, "action")) saw_action = true;
        if (std.mem.eql(u8, p.name, "project_id")) saw_project_id = true;
        if (std.mem.eql(u8, p.name, "schedule")) saw_schedule = true;
    }
    try testing.expect(saw_action);
    try testing.expect(saw_project_id);
    try testing.expect(saw_schedule);

    try testing.expectEqual(@as(usize, 1), f.parameters.required.len);
    try testing.expectEqualStrings("action", f.parameters.required[0]);

    try testing.expect(f.description.len > 0 and f.description.len <= 900);
}

test "manage_project: create kanban writes the board and its three columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const json = try executeManageProjectToJSON(alloc, &ctx.db, "ws_1", .{
        .action = "create",
        .item_type = "kanban",
        .name = "Release board",
        .path = "/home/dev/release",
    }, null);
    defer alloc.free(json);

    const parsed = try parsedValue(alloc, json);
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expect(object.get("success").?.bool);
    try testing.expectEqualStrings("create", object.get("action").?.string);

    const project = object.get("project").?.object;
    try testing.expectEqualStrings("kanban", project.get("item_type").?.string);
    try testing.expectEqualStrings("Release board", project.get("name").?.string);
    try testing.expectEqualStrings("/home/dev/release", project.get("path").?.string);

    const item_id = project.get("id").?.string;
    const cols = try pabrikcore.ai_mod.kanban_model.listColumns(alloc, &ctx.db, item_id);
    defer pabrikcore.ai_mod.kanban_model.freeColumns(alloc, cols);
    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("done", cols[2].name);
}

test "manage_project: create routine reports the next fire time" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const json = try executeManageProjectToJSON(alloc, &ctx.db, "ws_1", .{
        .action = "create",
        .item_type = "routine",
        .name = "Nightly sweep",
        .path = "/home/dev/sweep",
        .instruction = "read the logs and report",
        .schedule = "0 9 * * *",
    }, null);
    defer alloc.free(json);

    const parsed = try parsedValue(alloc, json);
    defer parsed.deinit();
    const project = parsed.value.object.get("project").?.object;
    try testing.expectEqualStrings("routine", project.get("item_type").?.string);
    try testing.expectEqualStrings("0 9 * * *", project.get("schedule").?.string);
    try testing.expect(project.get("next_run_at").?.string.len > 0);
}

test "manage_project: create a routine with no path names the missing field" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const json = try executeManageProjectToJSON(alloc, &ctx.db, "ws_1", .{
        .action = "create",
        .item_type = "routine",
        .name = "No path",
    }, null);
    defer alloc.free(json);

    const parsed = try parsedValue(alloc, json);
    defer parsed.deinit();
    try testing.expect(!parsed.value.object.get("success").?.bool);
    try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("error").?.string, "path") != null);

    var rows = try ctx.db.query(alloc, "SELECT COUNT(*) FROM workspace_items", &.{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.NoRow;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "manage_project: create needs an item_type" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const json = try executeManageProjectToJSON(alloc, &ctx.db, "ws_1", .{
        .action = "create",
        .name = "Nameless kind",
    }, null);
    defer alloc.free(json);

    const parsed = try parsedValue(alloc, json);
    defer parsed.deinit();
    try testing.expect(!parsed.value.object.get("success").?.bool);
    try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("error").?.string, "item_type") != null);
}

test "manage_project: an unknown action is refused, not guessed" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const json = try executeManageProjectToJSON(alloc, &ctx.db, "ws_1", .{ .action = "delete" }, null);
    defer alloc.free(json);

    const parsed = try parsedValue(alloc, json);
    defer parsed.deinit();
    try testing.expect(!parsed.value.object.get("success").?.bool);
}

test "manage_project: edit renames the project the caller already has" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created_json = try executeManageProjectToJSON(alloc, &ctx.db, "ws_1", .{
        .action = "create",
        .item_type = "kanban",
        .name = "Old name",
    }, null);
    defer alloc.free(created_json);
    const created = try parsedValue(alloc, created_json);
    defer created.deinit();
    const item_id = try alloc.dupe(u8, created.value.object.get("project").?.object.get("id").?.string);
    defer alloc.free(item_id);

    const edited_json = try executeManageProjectToJSON(alloc, &ctx.db, "ws_1", .{
        .action = "edit",
        .project_id = item_id,
        .name = "New name",
    }, null);
    defer alloc.free(edited_json);

    const edited = try parsedValue(alloc, edited_json);
    defer edited.deinit();
    const project = edited.value.object.get("project").?.object;
    try testing.expectEqualStrings("edit", edited.value.object.get("action").?.string);
    try testing.expectEqualStrings("New name", project.get("name").?.string);
    try testing.expectEqualStrings(item_id, project.get("id").?.string);
}

test "manage_project: edit a project in another workspace reports not found" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created_json = try executeManageProjectToJSON(alloc, &ctx.db, "ws_1", .{
        .action = "create",
        .item_type = "kanban",
        .name = "Mine",
    }, null);
    defer alloc.free(created_json);
    const created = try parsedValue(alloc, created_json);
    defer created.deinit();
    const item_id = try alloc.dupe(u8, created.value.object.get("project").?.object.get("id").?.string);
    defer alloc.free(item_id);

    const edited_json = try executeManageProjectToJSON(alloc, &ctx.db, "ws_2", .{
        .action = "edit",
        .project_id = item_id,
        .name = "Hijacked",
    }, null);
    defer alloc.free(edited_json);

    const edited = try parsedValue(alloc, edited_json);
    defer edited.deinit();
    try testing.expect(!edited.value.object.get("success").?.bool);
    try testing.expect(std.mem.indexOf(u8, edited.value.object.get("error").?.string, "no project") != null);
}
