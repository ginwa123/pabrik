// Functional tests for the per-workspace default project and the New Chat
// flow.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Wire helpers
// ============================================================================

/// Python's `_create_workspace` → the new workspace's id (OWNED).
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const id = doc.str("id") orelse {
        std.debug.print("POST /api/workspaces carried no `id`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// One `workspace_items` row, with its strings COPIED.
const ItemRow = struct {
    id: []u8,
    name: []u8,
    path: []u8,
    item_type: []u8,
    is_default: bool,

    fn deinit(self: *ItemRow) void {
        gpa.free(self.id);
        gpa.free(self.name);
        gpa.free(self.path);
        gpa.free(self.item_type);
        self.* = undefined;
    }
};

fn freeItems(rows: []ItemRow) void {
    for (rows) |*r| r.deinit();
    gpa.free(rows);
}

/// The string at `key` of a JSON object, or a named failure.
fn objStr(o: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (o.get(key) orelse {
        std.debug.print("missing `{s}` in a JSON object\n", .{key});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("`{s}` is not a string\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
}

/// Python's `_items`: `GET /api/workspaces/{id}/items` as owned rows.
fn listItems(h: *Harness, ws_id: []const u8) ![]ItemRow {
    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items", .{ws_id});
    defer gpa.free(url);

    var r = try h.http(io, .GET, url, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const arr = doc.array("items") orelse {
        std.debug.print("items response has no `items` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };

    const rows = try gpa.alloc(ItemRow, arr.items.len);
    errdefer freeItems(rows);
    for (arr.items, 0..) |item, i| {
        const o = switch (item) {
            .object => |m| m,
            else => {
                std.debug.print("item {d} is not an object\n", .{i});
                return error.TestUnexpectedResult;
            },
        };
        const is_default = switch (o.get("is_default") orelse {
            std.debug.print("item {d} carries no `is_default`\n", .{i});
            return error.TestUnexpectedResult;
        }) {
            .integer => |n| n == 1,
            else => {
                std.debug.print("`is_default` must be 0 or 1, got {any}\n", .{o.get("is_default").?});
                return error.TestUnexpectedResult;
            },
        };
        rows[i] = .{
            .id = try gpa.dupe(u8, try objStr(o, "id")),
            .name = try gpa.dupe(u8, try objStr(o, "name")),
            .path = try gpa.dupe(u8, try objStr(o, "path")),
            .item_type = try gpa.dupe(u8, try objStr(o, "item_type")),
            .is_default = is_default,
        };
    }
    return rows;
}

/// Python's `_defaults`: the rows with `is_default == 1`.
fn defaultsOf(rows: []const ItemRow) ![]*const ItemRow {
    var out: std.ArrayList(*const ItemRow) = .empty;
    errdefer out.deinit(gpa);
    for (rows) |*r| {
        if (r.is_default) try out.append(gpa, r);
    }
    return out.toOwnedSlice(gpa);
}

fn describeItems(rows: []const ItemRow) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (rows, 0..) |r, i| {
        if (i > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.print("{s}({s}, default={})", .{ r.name, r.id, r.is_default }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

/// `DELETE /api/workspaces/{ws}/items/{item}` (expect 200).
fn deleteItem(h: *Harness, ws_id: []const u8, item_id: []const u8) !void {
    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/{s}", .{ ws_id, item_id });
    defer gpa.free(url);
    var r = try h.http(io, .DELETE, url, .{ .expect = &.{200} });
    defer r.deinit();
}

/// Exactly one default row, or a named failure.
fn theDefault(rows: []const ItemRow) !*const ItemRow {
    const defaults = try defaultsOf(rows);
    defer gpa.free(defaults);
    if (defaults.len != 1) {
        const desc = try describeItems(rows);
        defer gpa.free(desc);
        std.debug.print("expected exactly one default project, got {d}: {s}\n", .{ defaults.len, desc });
        return error.TestUnexpectedResult;
    }
    return defaults[0];
}

// ============================================================================
// sqlite3 CLI helpers (see the header note)
// ============================================================================

fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// Skip unless a `sqlite3` CLI is present.
fn requireSqlite3Cli() !void {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", ":memory:", "SELECT 1;" },
    }) catch |err| {
        std.debug.print("sqlite3 CLI unavailable ({s}); skipping DB assertions\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code = exitCode(res.term);
    if (code == null or code.? != 0) {
        std.debug.print(
            "sqlite3 CLI unusable (rc={?}); skipping DB assertions\n",
            .{code},
        );
        return error.SkipZigTest;
    }
}

/// Run one statement against `db_path`. `.timeout 5000` is the `busy_timeout`
/// the server's WAL connection needs; a bare CLI invocation would otherwise
/// fail with SQLITE_BUSY.
fn sqliteRun(db_path: []const u8, sql: []const u8) ![]u8 {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-cmd", ".timeout 5000", db_path, sql },
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

/// The agent DB inside the isolated tmpdir HOME.
fn findAgentDb(root: []const u8) ![]u8 {
    const candidates = [_][]const []const u8{
        &.{ ".config", "pabrik", "agent.db" },
        &.{ "AppData", "Roaming", "pabrik", "agent.db" },
        &.{ "Library", "Application Support", "pabrik", "agent.db" },
        &.{ ".local", "share", "pabrik", "agent.db" },
    };
    for (candidates) |parts| {
        const p = try harness.harnessPath(gpa, root, parts);
        if (std.Io.Dir.cwd().access(io, p, .{})) |_| {
            return p;
        } else |_| {
            gpa.free(p);
        }
    }
    if (try walkForDb(root, 6)) |p| return p;
    std.debug.print("expected an agent.db under the harness HOME {s}\n", .{root});
    return error.TestUnexpectedResult;
}

/// Depth-limited recursive search for a file named `agent.db`.
fn walkForDb(dir_path: []const u8, depth: usize) !?[]u8 {
    if (depth == 0) return null;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const child = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        if (std.mem.eql(u8, entry.name, "agent.db")) {
            return child;
        }
        if (entry.kind == .directory) {
            if (try walkForDb(child, depth - 1)) |found| {
                gpa.free(child);
                return found;
            }
        }
        gpa.free(child);
    }
    return null;
}

/// `SELECT name FROM workspace_items WHERE id = <lit>` → owned, trimmed.
fn storedItemName(db: []const u8, item_id: []const u8) ![]u8 {
    const lit = try sqlLit(item_id);
    defer gpa.free(lit);
    const sql = try std.fmt.allocPrint(gpa, "SELECT name FROM workspace_items WHERE id = {s};", .{lit});
    defer gpa.free(sql);

    const out = try sqliteRun(db, sql);
    defer gpa.free(out);
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    if (trimmed.len == 0) {
        std.debug.print("no workspace_items row for id {s}\n", .{item_id});
        return error.TestUnexpectedResult;
    }
    return gpa.dupe(u8, trimmed);
}

// ============================================================================
// The invariant
// ============================================================================

// POST /api/workspaces creates the default eagerly. Not required for the
// invariant (the list read would heal it) but it is what makes the Projects
// section show the default on first paint instead of only after a refetch.
test "a_new_workspace_already_has_a_default_project" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "default-ws");
    defer gpa.free(ws_id);

    const rows = try listItems(&h, ws_id);
    defer freeItems(rows);

    const default = try theDefault(rows);
    if (!std.mem.eql(u8, default.item_type, "agent")) {
        std.debug.print("the default must be agent mode, got \"{s}\"\n", .{default.item_type});
        return error.TestUnexpectedResult;
    }
    if (!std.mem.eql(u8, default.path, h.temp_dir)) {
        std.debug.print(
            "the default's root must be the server user's home, got \"{s}\" (expected the harness HOME \"{s}\")\n",
            .{ default.path, h.temp_dir },
        );
        return error.TestUnexpectedResult;
    }
}

// The invariant, asserted over the wire: a miss creates, a hit returns. Two
// calls must yield one row and the same id.
test "the_default_project_endpoint_is_idempotent" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "default-ws");
    defer gpa.free(ws_id);

    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/default-project", .{ws_id});
    defer gpa.free(url);

    var first = try h.http(io, .POST, url, .{ .expect = &.{200} });
    defer first.deinit();
    var first_doc = try first.json();
    defer first_doc.deinit();
    const first_item = first_doc.object("item") orelse {
        std.debug.print("first call carried no `item`: {s}\n", .{first.body});
        return error.TestUnexpectedResult;
    };
    const first_id = try gpa.dupe(u8, try objStr(first_item, "id"));
    defer gpa.free(first_id);
    if (first_doc.boolean("created") orelse return error.TestUnexpectedResult) {
        std.debug.print("the default already existed, so created must be false: {s}\n", .{first.body});
        return error.TestUnexpectedResult;
    }

    var second = try h.http(io, .POST, url, .{ .expect = &.{200} });
    defer second.deinit();
    var second_doc = try second.json();
    defer second_doc.deinit();
    const second_item = second_doc.object("item") orelse {
        std.debug.print("second call carried no `item`: {s}\n", .{second.body});
        return error.TestUnexpectedResult;
    };
    const second_id = try gpa.dupe(u8, try objStr(second_item, "id"));
    defer gpa.free(second_id);
    if (!std.mem.eql(u8, first_id, second_id)) {
        std.debug.print("a second call must return the same project: {s} != {s}\n", .{ first_id, second_id });
        return error.TestUnexpectedResult;
    }
    if (second_doc.boolean("created") orelse return error.TestUnexpectedResult) {
        std.debug.print("a second call must not report created: {s}\n", .{second.body});
        return error.TestUnexpectedResult;
    }

    const rows = try listItems(&h, ws_id);
    defer freeItems(rows);
    const defaults = try defaultsOf(rows);
    defer gpa.free(defaults);
    if (defaults.len != 1) {
        const desc = try describeItems(rows);
        defer gpa.free(desc);
        std.debug.print("still exactly one default after two calls, got {d}: {s}\n", .{ defaults.len, desc });
        return error.TestUnexpectedResult;
    }
}

// D12: the LIST read creates the default when the lookup misses. This is the
// enforcement point — both clients already call this endpoint, so neither
// needs a "does the default exist?" branch.
test "reading_the_items_list_heals_a_workspace_with_no_default" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "default-ws");
    defer gpa.free(ws_id);

    // Delete every item, which removes the default too. The workspace itself
    // stays, so this is exactly the "miss" the invariant has to heal.
    {
        const rows = try listItems(&h, ws_id);
        defer freeItems(rows);
        for (rows) |row| try deleteItem(&h, ws_id, row.id);
    }

    // The plain read — no special endpoint, no query flag — brings it back.
    const healed_rows = try listItems(&h, ws_id);
    defer freeItems(healed_rows);
    const default = try theDefault(healed_rows);
    if (!std.mem.eql(u8, default.path, h.temp_dir)) {
        std.debug.print(
            "the healed default must still be rooted at HOME, got \"{s}\" (expected \"{s}\")\n",
            .{ default.path, h.temp_dir },
        );
        return error.TestUnexpectedResult;
    }
}

// The orphan guard — the one way a write-on-read goes wrong. `useCaseList`
// does NOT 404 for an unknown workspace; it returns `[]`.
test "reading_an_unknown_workspace_creates_nothing" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var before = try h.http(io, .GET, "/api/workspaces", .{ .expect = &.{200} });
    defer before.deinit();

    const ghost = "ws_does_not_exist";

    // 200 + [] is preserved on purpose: making this a 404 would be a
    // wire-contract change no caller asked for.
    {
        const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items", .{ghost});
        defer gpa.free(url);
        var r = try h.http(io, .GET, url, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const items = doc.array("items") orelse {
            std.debug.print("ghost items response has no `items` array: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (items.items.len != 0) {
            std.debug.print("an unknown workspace must list nothing, got: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    // The default-project endpoint, by contrast, IS explicit, so it 404s.
    {
        const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/default-project", .{ghost});
        defer gpa.free(url);
        var r = try h.http(io, .POST, url, .{ .expect = &.{404} });
        defer r.deinit();
    }

    var after = try h.http(io, .GET, "/api/workspaces", .{ .expect = &.{200} });
    defer after.deinit();

    // Python compared the PARSED lists.
    if (!std.mem.eql(u8, before.body, after.body)) {
        std.debug.print(
            "reading an unknown workspace must not invent a workspace;\nbefore={s}\nafter ={s}\n",
            .{ before.body, after.body },
        );
        return error.TestUnexpectedResult;
    }
}

// Both clients' fast path is a local find over this response. The field has
// to be on EVERY row, not just the default's, or a client cannot distinguish
// "ordinary project" from "a default it has not seen".
test "every_item_reports_is_default_so_clients_can_find_it" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "default-ws");
    defer gpa.free(ws_id);

    // Python sent a literal "/tmp/helper".
    const helper_path = try harness.harnessPath(gpa, h.temp_dir, &.{"helper"});
    defer gpa.free(helper_path);

    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/agent", .{ws_id});
    defer gpa.free(url);
    {
        const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"helper\",\"path\":\"{s}\"}}", .{helper_path});
        defer gpa.free(body);
        var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
        defer r.deinit();
    }

    const rows = try listItems(&h, ws_id);
    defer freeItems(rows);

    if (rows.len < 2) {
        const desc = try describeItems(rows);
        defer gpa.free(desc);
        std.debug.print("expected the default plus the helper, got: {s}\n", .{desc});
        return error.TestUnexpectedResult;
    }

    // `listItems` already asserted every row carries an `is_default`
    // integer; the count is the remaining assertion.
    var default_count: usize = 0;
    for (rows) |row| {
        if (row.is_default) default_count += 1;
    }
    if (default_count != 1) {
        const desc = try describeItems(rows);
        defer gpa.free(desc);
        std.debug.print("exactly one default per workspace, got {d}: {s}\n", .{ default_count, desc });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// The point of the whole thing: the chat runs in $HOME
// ============================================================================

// A New Chat inside the default project runs with $HOME as its cwd. This is
// the assertion the feature exists for.
test "a_chat_in_the_default_project_resolves_its_cwd_to_home" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "default-ws");
    defer gpa.free(ws_id);

    const default_id = blk: {
        const rows = try listItems(&h, ws_id);
        defer freeItems(rows);
        const d = try theDefault(rows);
        break :blk try gpa.dupe(u8, d.id);
    };
    defer gpa.free(default_id);

    // Exactly what the clients send for a New Chat: a name, a type, and
    // no cwd.
    const task_id = blk: {
        const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/{s}/tasks", .{ ws_id, default_id });
        defer gpa.free(url);
        const body =
            \\{"name": "New Chat", "task_type": "standard"}
        ;
        var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        const got_item = doc.str("workspace_item_id") orelse {
            std.debug.print("task response carries no `workspace_item_id`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, got_item, default_id)) {
            std.debug.print("workspace_item_id = \"{s}\", expected \"{s}\"\n", .{ got_item, default_id });
            return error.TestUnexpectedResult;
        }
        const id = doc.str("id") orelse {
            std.debug.print("task response carries no `id`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        break :blk try gpa.dupe(u8, id);
    };
    defer gpa.free(task_id);

    // The session create, with cwd_session deliberately empty so the server
    // has to resolve it from the project's path.
    {
        const body = try std.fmt.allocPrint(
            gpa,
            "{{\"session_id\":\"{s}\",\"session_name\":\"New Chat\",\"cwd_session\":\"\"}}",
            .{task_id},
        );
        defer gpa.free(body);
        var r = try h.http(io, .POST, "/api/llm/session", .{ .json_body = body, .expect = &.{201} });
        defer r.deinit();
    }

    // The list keys rows by `session_id` (SessionInfoJson), not `id`.
    const cwd = blk: {
        var r = try h.http(io, .GET, "/api/llm/session", .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        const sessions = doc.array("sessions") orelse {
            std.debug.print("session list has no `sessions` array: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        var found: ?[]const u8 = null;
        for (sessions.items) |s| {
            const o = switch (s) {
                .object => |m| m,
                else => continue,
            };
            const sid = switch (o.get("session_id") orelse continue) {
                .string => |x| x,
                else => continue,
            };
            if (!std.mem.eql(u8, sid, task_id)) continue;
            found = switch (o.get("cwd") orelse std.json.Value{ .null = {} }) {
                .string => |c| c,
                else => "",
            };
            break;
        }
        break :blk try gpa.dupe(u8, found orelse {
            std.debug.print("no session row for {s}: {s}\n", .{ task_id, r.body });
            return error.TestUnexpectedResult;
        });
    };
    defer gpa.free(cwd);

    if (!std.mem.eql(u8, cwd, h.temp_dir)) {
        std.debug.print(
            "the chat must run in the server user's home, got \"{s}\" (expected \"{s}\")\n",
            .{ cwd, h.temp_dir },
        );
        return error.TestUnexpectedResult;
    }

    // Stated explicitly because it is the failure that looks like success: a
    // sandbox path is a perfectly valid absolute path, so nothing above would
    // complain.
    const sandbox_suffix = try std.fmt.allocPrint(gpa, ".local/share/pabrik/data/apps/{s}", .{task_id});
    defer gpa.free(sandbox_suffix);
    if (std.mem.endsWith(u8, cwd, sandbox_suffix)) {
        std.debug.print("the agent fell back to a per-session sandbox instead of HOME: \"{s}\"\n", .{cwd});
        return error.TestUnexpectedResult;
    }
}

// A default project whose name was corrupted by the old build heals itself.
// The allocator bug wrote 0xAA poison bytes into the name, which the sidebar
// rendered as `[ 170, 170, … ]`.
test "a_corrupted_default_name_is_repaired_over_the_wire" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "default-ws");
    defer gpa.free(ws_id);

    const default_id = blk: {
        const rows = try listItems(&h, ws_id);
        defer freeItems(rows);
        const d = try theDefault(rows);
        break :blk try gpa.dupe(u8, d.id);
    };
    defer gpa.free(default_id);

    const db = try findAgentDb(h.temp_dir);
    defer gpa.free(db);

    const id_lit = try sqlLit(default_id);
    defer gpa.free(id_lit);

    // `b"\xaa" * 8` bound as a parameter — a BLOB, not TEXT. The CAST is
    // what forces it: a TEXT-affinity column leaves a BLOB alone.
    {
        const sql = try std.fmt.allocPrint(
            gpa,
            "UPDATE workspace_items SET name = CAST(x'aaaaaaaaaaaaaaaa' AS BLOB) WHERE id = {s};",
            .{id_lit},
        );
        defer gpa.free(sql);
        const out = try sqliteRun(db, sql);
        defer gpa.free(out);
    }

    // POSITIVE CONTROL.
    {
        const stored = try storedItemName(db, default_id);
        defer gpa.free(stored);
        if (std.mem.eql(u8, stored, "Project Default")) {
            std.debug.print(
                "precondition: row {s} still reads \"Project Default\" — the UPDATE did not land\n",
                .{default_id},
            );
            return error.TestUnexpectedResult;
        }
    }

    // A plain list read — the same call the sidebar makes — repairs it.
    {
        const rows = try listItems(&h, ws_id);
        defer freeItems(rows);

        var healed: ?ItemRow = null;
        for (rows) |row| {
            if (std.mem.eql(u8, row.id, default_id)) healed = row;
        }
        if (healed == null) {
            std.debug.print("the default item {s} vanished from the list\n", .{default_id});
            return error.TestUnexpectedResult;
        }
        if (!std.mem.eql(u8, healed.?.name, "Project Default")) {
            std.debug.print("the corrupted name should have been repaired, got \"{s}\"\n", .{healed.?.name});
            return error.TestUnexpectedResult;
        }
    }

    // And the repair is persisted, so it does not churn on every read.
    {
        const stored = try storedItemName(db, default_id);
        defer gpa.free(stored);
        if (!std.mem.eql(u8, stored, "Project Default")) {
            std.debug.print("the row was not rewritten: \"{s}\"\n", .{stored});
            return error.TestUnexpectedResult;
        }
    }

    // A real name is left alone — the repair must never clobber a rename.
    {
        const sql = try std.fmt.allocPrint(
            gpa,
            "UPDATE workspace_items SET name = 'Renamed by hand' WHERE id = {s};",
            .{id_lit},
        );
        defer gpa.free(sql);
        const out = try sqliteRun(db, sql);
        defer gpa.free(out);
    }
    {
        const rows = try listItems(&h, ws_id);
        defer freeItems(rows);

        var again: ?ItemRow = null;
        for (rows) |row| {
            if (std.mem.eql(u8, row.id, default_id)) again = row;
        }
        if (again == null) {
            std.debug.print("the default item {s} vanished from the list\n", .{default_id});
            return error.TestUnexpectedResult;
        }
        if (!std.mem.eql(u8, again.?.name, "Renamed by hand")) {
            std.debug.print("a user rename must survive the repair, got \"{s}\"\n", .{again.?.name});
            return error.TestUnexpectedResult;
        }
    }
}

comptime {
    // Body-analysis barrier: an unreferenced helper is never
    // type-checked, so a stdlib rename inside one is invisible until a
    // caller appears.
    _ = createWorkspace;
    _ = listItems;
    _ = defaultsOf;
    _ = describeItems;
    _ = deleteItem;
    _ = theDefault;
    _ = objStr;
    _ = freeItems;
    _ = exitCode;
    _ = requireSqlite3Cli;
    _ = sqliteRun;
    _ = sqlLit;
    _ = findAgentDb;
    _ = walkForDb;
    _ = storedItemName;
}
