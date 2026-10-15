// `llm_history.model` is never empty — wire-level proof. Zig port of
// `tests/functional/llm_history_model_not_empty_test.py` (same test names,
// same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// The sentinel the backend substitutes when no model can be resolved. Mirrors
/// `agentic_loop/llm_history_model_guard.zig::UNKNOWN_MODEL` and the literal in
/// Migration 101's trigger. A real model id is never this string.
const UNKNOWN_MODEL = "unknown";

/// One `llm_history` row as the `sqlite3 -json` output spells it.
const HistoryRow = struct {
    id: []const u8,
    model: ?[]const u8,
    /// `typeof(model) AS t` — `'null'` is the NULL-collapse drop path,
    /// `'text'` with a blank value is the `''`-literal path.
    t: []const u8,
    role: []const u8,
    response_content: ?[]const u8,
};

/// Skip unless a `sqlite3` CLI is present and speaks `-json`. `-json` landed
/// in SQLite 3.33 (2020).
fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

fn requireSqlite3Cli() !void {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-json", ":memory:", "SELECT 1 AS probe;" },
    }) catch |err| {
        std.debug.print("sqlite3 CLI unavailable ({s}); skipping DB-reading assertions\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code = exitCode(res.term);
    if (code == null or code.? != 0 or std.mem.indexOf(u8, res.stdout, "\"probe\"") == null) {
        std.debug.print(
            "sqlite3 CLI lacks -json support (rc={?}, out={s}); skipping DB-reading assertions\n",
            .{ code, res.stdout },
        );
        return error.SkipZigTest;
    }
}

/// Parse `sqlite3 -json` output into a document the caller owns. `-json`
/// prints ZERO BYTES for an empty result set — not `[]`.
fn parseSqliteJson(allocator: std.mem.Allocator, out: []const u8) !std.json.Parsed(std.json.Value) {
    if (std.mem.trim(u8, out, " \t\r\n").len == 0) {
        return std.json.parseFromSlice(std.json.Value, allocator, "[]", .{});
    }
    return std.json.parseFromSlice(std.json.Value, allocator, out, .{});
}

/// Single-quote `s` as an SQL literal, doubling embedded quotes. Owned.
fn sqlLit(s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    out.writer.writeByte('\'') catch return error.OutOfMemory;
    for (s) |c| {
        if (c == '\'') out.writer.writeByte('\'') catch return error.OutOfMemory;
        out.writer.writeByte(c) catch return error.OutOfMemory;
    }
    out.writer.writeByte('\'') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Run one statement against `db_path` and return the CLI's stdout.
fn sqliteRun(db_path: []const u8, sql: []const u8) ![]u8 {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-cmd", ".timeout 5000", "-json", db_path, sql },
    }) catch |err| {
        std.debug.print("sqlite3 did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer gpa.free(res.stderr);

    const code = exitCode(res.term) orelse {
        gpa.free(res.stdout);
        std.debug.print("sqlite3 was killed by a signal: {any}\n", .{res.term});
        return error.TestUnexpectedResult;
    };
    if (code != 0) {
        const msg = res.stderr;
        defer gpa.free(res.stdout);
        std.debug.print("sqlite3 exited {d}: {s}\nsql: {s}\n", .{ code, msg, sql });
        return error.TestUnexpectedResult;
    }
    return res.stdout;
}

/// Agent DB inside the isolated tmpdir HOME (Linux layout). Python `_db_path`.
fn dbPath(temp_dir: []const u8) ![]u8 {
    return harness.harnessPath(gpa, temp_dir, &.{ ".config", "pabrik", "agent.db" });
}

/// `SELECT <cols> FROM llm_history WHERE session_id = ? ORDER BY created_at_nano`
/// as a JSON document the caller owns.
fn historyRowsSql(temp_dir: []const u8, session_id: []const u8) !std.json.Parsed(std.json.Value) {
    const db = try dbPath(temp_dir);
    defer gpa.free(db);
    const sid = try sqlLit(session_id);
    defer gpa.free(sid);

    const sql = try std.fmt.allocPrint(
        gpa,
        \\SELECT id, model, typeof(model) AS t, role, response_content
        \\FROM llm_history WHERE session_id = {s} ORDER BY created_at_nano
    ,
        .{sid},
    );
    defer gpa.free(sql);

    const out = try sqliteRun(db, sql);
    defer gpa.free(out);
    return parseSqliteJson(gpa, out);
}

/// Decode a `sqlite3 -json` result into an owned array of `HistoryRow`.
fn decodeRows(parsed: *const std.json.Parsed(std.json.Value), ctx: []const u8) ![]HistoryRow {
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => {
            std.debug.print("{s}: sqlite3 did not return a JSON array\n", .{ctx});
            return error.TestUnexpectedResult;
        },
    };
    var out = try gpa.alloc(HistoryRow, arr.items.len);
    errdefer gpa.free(out);

    for (arr.items, 0..) |item, i| {
        const o = switch (item) {
            .object => |m| m,
            else => {
                std.debug.print("{s}: row {d} is not an object\n", .{ ctx, i });
                return error.TestUnexpectedResult;
            },
        };
        // `id` is a TEXT column, but SQLite is dynamically typed: a NULL id
        // must fail loudly rather than decode as the empty string, or the
        // failure messages name the wrong row.
        const id = switch (o.get("id") orelse {
            std.debug.print("{s}: row {d} has no id\n", .{ ctx, i });
            return error.TestUnexpectedResult;
        }) {
            .string => |s| s,
            else => {
                std.debug.print("{s}: row {d} id is not a string\n", .{ ctx, i });
                return error.TestUnexpectedResult;
            },
        };
        out[i] = .{
            .id = id,
            .model = switch (o.get("model") orelse std.json.Value{ .null = {} }) {
                .string => |s| s,
                .null => null,
                else => {
                    std.debug.print("{s}: row {d} model is neither text nor NULL\n", .{ ctx, i });
                    return error.TestUnexpectedResult;
                },
            },
            .t = switch (o.get("t") orelse {
                std.debug.print("{s}: row {d} has no typeof(model) column\n", .{ ctx, i });
                return error.TestUnexpectedResult;
            }) {
                .string => |s| s,
                else => {
                    std.debug.print("{s}: row {d} typeof(model) is not a string\n", .{ ctx, i });
                    return error.TestUnexpectedResult;
                },
            },
            .role = switch (o.get("role") orelse {
                std.debug.print("{s}: row {d} has no role\n", .{ ctx, i });
                return error.TestUnexpectedResult;
            }) {
                .string => |s| s,
                else => {
                    std.debug.print("{s}: row {d} role is not a string\n", .{ ctx, i });
                    return error.TestUnexpectedResult;
                },
            },
            .response_content = switch (o.get("response_content") orelse std.json.Value{ .null = {} }) {
                .string => |s| s,
                .null => null,
                else => {
                    std.debug.print("{s}: row {d} response_content is neither text nor NULL\n", .{ ctx, i });
                    return error.TestUnexpectedResult;
                },
            },
        };
    }
    return out;
}

/// `POST /api/workspaces` → the new workspace's id. Python `_create_workspace`.
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("workspace create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// `POST /api/workspaces/<ws>/items/kanban` → the kanban item's id.
/// Python `_create_kanban`.
fn createKanban(h: *Harness, workspace_id: []const u8, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/kanban", .{workspace_id});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const item = doc.object("item") orelse {
        std.debug.print("kanban create returned no `item`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id = switch (item.get("id") orelse {
        std.debug.print("kanban create item has no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("kanban create item id is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

/// `POST .../kanban/tasks` with `mode: "create_session"` — the exact wire the
/// frontend's plain `Create task` button sends. Python `_create_task`.
const TaskBody = struct {
    mode: []const u8 = "create_session",
    name: []const u8,
    description: []const u8,
    is_auto_retry_until_stop: ?[]const u8 = null,
    selected_profile_model: ?[]const u8 = null,
};

fn createTask(
    h: *Harness,
    workspace_id: []const u8,
    kanban_id: []const u8,
    name: []const u8,
    description: []const u8,
    extra_retry: ?[]const u8,
    extra_profile: ?[]const u8,
) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = "create_session",
        .name = name,
        .description = description,
        .is_auto_retry_until_stop = extra_retry,
        .selected_profile_model = extra_profile,
    }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/{s}/kanban/tasks", .{ workspace_id, kanban_id });
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const task = doc.object("task") orelse {
        std.debug.print("task create returned no `task`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id = switch (task.get("id") orelse {
        std.debug.print("task create returned a task with no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("task create id is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

// The regression itself: the seeded row must carry a real model.
test "kanban_create_session_seeds_a_row_with_a_non_empty_model" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // The harness's stub profile leaves `active_profile` unset and the config
    // carries no top-level `model`, so `resolveEffectiveProfile` cascades all
    // the way down to an empty string.
    const ws_id = try createWorkspace(&h, "model-guard-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-guard");
    defer gpa.free(kanban_id);

    const task_id = try createTask(&h, ws_id, kanban_id, "Guarded card", "check the model", null, null);
    defer gpa.free(task_id);

    var doc = try historyRowsSql(h.temp_dir, task_id);
    defer doc.deinit();
    const rows = try decodeRows(&doc, "llm_history rows");
    defer gpa.free(rows);

    // Existence first.
    if (rows.len != 1) {
        std.debug.print(
            "expected exactly 1 seeded llm_history row for {s}, got {d}\n",
            .{ task_id, rows.len },
        );
        return error.TestUnexpectedResult;
    }

    const row = rows[0];
    // `typeof` distinguishes the two failure modes: 'null' = the NULL-collapse
    // drop path, 'text' with a blank value = the `''`-literal path.
    if (std.mem.eql(u8, row.t, "null")) {
        std.debug.print("model is SQL NULL (empty-bind collapse) for row {s}\n", .{row.id});
        return error.TestUnexpectedResult;
    }
    const model = row.model orelse "";
    if (std.mem.trim(u8, model, " \t\r\n").len == 0) {
        std.debug.print("model is blank for row {s} (typeof={s})\n", .{ row.id, row.t });
        return error.TestUnexpectedResult;
    }
    // The seeded row is the synthetic user message, and it must still be there.
    try testing.expectEqualStrings("user", row.role);
    try testing.expectEqualStrings("Guarded card\n\ncheck the model", row.response_content orelse return error.TestUnexpectedResult);
}

// The model must be either a real id or the sentinel — never blank.
test "seeded_model_is_either_real_or_the_sentinel" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "model-guard-ws-2");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-guard-2");
    defer gpa.free(kanban_id);

    const task_id = try createTask(
        &h,
        ws_id,
        kanban_id,
        "Second card",
        "also check the model",
        "1",
        "stub",
    );
    defer gpa.free(task_id);

    var doc = try historyRowsSql(h.temp_dir, task_id);
    defer doc.deinit();
    const rows = try decodeRows(&doc, "llm_history rows");
    defer gpa.free(rows);

    if (rows.len != 1) {
        std.debug.print("expected 1 seeded row, got {d}\n", .{rows.len});
        return error.TestUnexpectedResult;
    }

    const model = rows[0].model orelse "";
    if (model.len == 0) {
        std.debug.print("model must never be blank (row {s}, typeof={s})\n", .{ rows[0].id, rows[0].t });
        return error.TestUnexpectedResult;
    }
    // Two paths are acceptable and both are asserted to be non-empty:
    // a real model id, when the profile cascade resolves one; or
    // UNKNOWN_MODEL, when it resolves to nothing.
    if (!std.mem.eql(u8, model, UNKNOWN_MODEL) and std.mem.trim(u8, model, " \t\r\n").len == 0) {
        std.debug.print("model must be the sentinel or a real id, got '{s}'\n", .{model});
        return error.TestUnexpectedResult;
    }
}

// Database-wide sweep after several task creates.
test "no_blank_model_anywhere_in_the_database" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "model-guard-ws-3");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-guard-3");
    defer gpa.free(kanban_id);

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const name = try std.fmt.allocPrint(gpa, "Card {d}", .{i});
        defer gpa.free(name);
        const desc = try std.fmt.allocPrint(gpa, "body {d}", .{i});
        defer gpa.free(desc);

        const task_id = try createTask(&h, ws_id, kanban_id, name, desc, null, null);
        defer gpa.free(task_id);
    }

    // Catches a regression that a per-session assertion would miss: a write
    // site that still binds an empty model would either drop its row or,
    // after Migration 101's trigger is in place, be caught there.
    const db = try dbPath(h.temp_dir);
    defer gpa.free(db);
    const sql =
        \\SELECT id, session_id, model FROM llm_history
        \\WHERE model IS NULL OR TRIM(model) = ''
    ;
    const out = try sqliteRun(db, sql);
    defer gpa.free(out);

    // `parseSqliteJson`, not a raw parse: a CLEAN sweep is the expected
    // outcome here, and `-json` prints zero bytes (not `[]`) for an empty
    // result set — so the passing case is exactly the one the std parser
    var doc = try parseSqliteJson(gpa, out);
    defer doc.deinit();
    const blank = switch (doc.value) {
        .array => |a| a,
        else => {
            std.debug.print("blank-model sweep did not return a JSON array: {s}\n", .{out});
            return error.TestUnexpectedResult;
        },
    };

    if (blank.items.len != 0) {
        var msg: std.Io.Writer.Allocating = .init(gpa);
        defer msg.deinit();
        msg.writer.writeAll("llm_history rows with a blank model:\n") catch return error.OutOfMemory;
        for (blank.items) |v| {
            msg.writer.print("  {any}\n", .{v}) catch return error.OutOfMemory;
        }
        std.debug.print("{s}", .{msg.written()});
        return error.TestUnexpectedResult;
    }
}
