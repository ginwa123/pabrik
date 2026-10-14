// Functional tests for the workspace-scoped skills HTTP surface. Zig port of
// `tests/functional/skills_sqlite_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// The skill body asserted BYTE-EXACT by
/// `detail_returns_the_body_and_the_companion_count`.
const BODY = "---\nname: pdf\ndescription: Work with PDFs.\n---\n\nRun `scripts/convert.py`.\n";

// ============================================================================
// sqlite3 CLI helpers
// ============================================================================

fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// Skip unless a `sqlite3` CLI is present and speaks `-json`. `-json` landed
/// in SQLite 3.33 (2020).
fn requireSqlite3Cli() !void {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-json", ":memory:", "SELECT 1 AS probe;" },
    }) catch |err| {
        std.debug.print("sqlite3 CLI unavailable ({s}); skipping DB assertions\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code = exitCode(res.term);
    if (code == null or code.? != 0 or std.mem.indexOf(u8, res.stdout, "\"probe\"") == null) {
        std.debug.print(
            "sqlite3 CLI lacks -json support (rc={?}, out={s}); skipping DB assertions\n",
            .{ code, res.stdout },
        );
        return error.SkipZigTest;
    }
}

/// `sqlite3 -json` prints ZERO BYTES for an empty result set, not `[]`.
fn parseSqliteJson(out: []const u8) !std.json.Parsed(std.json.Value) {
    if (std.mem.trim(u8, out, " \t\r\n").len == 0) {
        return std.json.parseFromSlice(std.json.Value, gpa, "[]", .{});
    }
    return std.json.parseFromSlice(std.json.Value, gpa, out, .{});
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

/// Run one statement against `db_path`, return the CLI's stdout (owned).
/// `.timeout 5000` is the `busy_timeout` the server's WAL connection needs; a
/// bare CLI invocation would otherwise fail with SQLITE_BUSY.
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

/// The agent DB inside the isolated tmpdir HOME (Linux/macOS layout).
fn dbPath(temp_dir: []const u8) ![]u8 {
    const p = try harness.harnessPath(gpa, temp_dir, &.{ ".config", "pabrik", "agent.db" });
    return p;
}

/// Run `sql` against the harness DB, returning the CLI's stdout. The DB
/// must already exist — the server creates it at boot.
fn dbRun(temp_dir: []const u8, sql: []const u8) ![]u8 {
    const db = try dbPath(temp_dir);
    defer gpa.free(db);
    std.Io.Dir.cwd().access(io, db, .{}) catch {
        std.debug.print("database not found at {s}\n", .{db});
        return error.TestUnexpectedResult;
    };
    return sqliteRun(db, sql);
}

/// Insert one `skills` row directly. Written the way
/// `skills_store.upsertSkill` writes it, including the `COALESCE(NULLIF(?,
/// ''), '')` guard (see the file header).
fn seedSkill(temp_dir: []const u8, workspace_id: []const u8, name: []const u8, description: []const u8, content: []const u8) !void {
    const ws_lit = try sqlLit(workspace_id);
    defer gpa.free(ws_lit);
    const name_lit = try sqlLit(name);
    defer gpa.free(name_lit);
    const desc_lit = try sqlLit(description);
    defer gpa.free(desc_lit);
    const content_lit = try sqlLit(content);
    defer gpa.free(content_lit);
    const raw_id = try std.fmt.allocPrint(gpa, "sk_seed_{s}_{s}", .{ workspace_id, name });
    defer gpa.free(raw_id);
    const id_lit = try sqlLit(raw_id);
    defer gpa.free(id_lit);

    const sql = try std.fmt.allocPrint(
        gpa,
        "INSERT INTO skills (id, workspace_id, name, description, content, created_at, updated_at) " ++
            "VALUES ({s}, {s}, {s}, COALESCE(NULLIF({s}, ''), ''), " ++
            "COALESCE(NULLIF({s}, ''), ''), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
        .{ id_lit, ws_lit, name_lit, desc_lit, content_lit },
    );
    defer gpa.free(sql);

    const out = try dbRun(temp_dir, sql);
    defer gpa.free(out);
}

/// The `skills.id` for `<workspace_id>/<name>`, or null when absent.
fn skillIdSql(temp_dir: []const u8, workspace_id: []const u8, name: []const u8) !?[]u8 {
    const ws_lit = try sqlLit(workspace_id);
    defer gpa.free(ws_lit);
    const name_lit = try sqlLit(name);
    defer gpa.free(name_lit);
    const sql = try std.fmt.allocPrint(
        gpa,
        "SELECT id FROM skills WHERE workspace_id = {s} AND name = {s}",
        .{ ws_lit, name_lit },
    );
    defer gpa.free(sql);

    const out = try dbRun(temp_dir, sql);
    defer gpa.free(out);
    var parsed = try parseSqliteJson(out);
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    if (arr.items.len == 0) return null;
    const o = switch (arr.items[0]) {
        .object => |m| m,
        else => return error.TestUnexpectedResult,
    };
    const id = switch (o.get("id") orelse return error.TestUnexpectedResult) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    return try gpa.dupe(u8, id);
}

/// Insert one `skill_assets` row for an existing skill. Fails loudly
/// when the parent skill is missing — the Python `assert row is not None`.
fn seedAsset(temp_dir: []const u8, workspace_id: []const u8, name: []const u8, rel_path: []const u8, content: []const u8) !void {
    const skill_id = (try skillIdSql(temp_dir, workspace_id, name)) orelse {
        std.debug.print("no skills row for {s}/{s}\n", .{ workspace_id, name });
        return error.TestUnexpectedResult;
    };
    defer gpa.free(skill_id);

    const raw_id = try std.fmt.allocPrint(gpa, "sa_seed_{s}_{s}_{s}", .{ workspace_id, name, rel_path });
    defer gpa.free(raw_id);
    const id_lit = try sqlLit(raw_id);
    defer gpa.free(id_lit);
    const skill_lit = try sqlLit(skill_id);
    defer gpa.free(skill_lit);
    const rel_lit = try sqlLit(rel_path);
    defer gpa.free(rel_lit);
    const content_lit = try sqlLit(content);
    defer gpa.free(content_lit);

    const sql = try std.fmt.allocPrint(
        gpa,
        "INSERT INTO skill_assets (id, skill_id, rel_path, content, created_at) " ++
            "VALUES ({s}, {s}, {s}, COALESCE(NULLIF({s}, ''), ''), CURRENT_TIMESTAMP)",
        .{ id_lit, skill_lit, rel_lit, content_lit },
    );
    defer gpa.free(sql);

    const out = try dbRun(temp_dir, sql);
    defer gpa.free(out);
}

/// `SELECT COUNT(*) FROM <table>`.
fn rowCount(temp_dir: []const u8, table: []const u8) !i64 {
    const sql = try std.fmt.allocPrint(gpa, "SELECT COUNT(*) AS n FROM {s}", .{table});
    defer gpa.free(sql);

    const out = try dbRun(temp_dir, sql);
    defer gpa.free(out);
    var parsed = try parseSqliteJson(out);
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    if (arr.items.len != 1) return error.TestUnexpectedResult;
    const o = switch (arr.items[0]) {
        .object => |m| m,
        else => return error.TestUnexpectedResult,
    };
    return switch (o.get("n") orelse return error.TestUnexpectedResult) {
        .integer => |i| i,
        else => return error.TestUnexpectedResult,
    };
}

// ============================================================================
// HTTP + assertion helpers
// ============================================================================

/// Parse OWNED bytes into a `harness.Json`.
fn parseJson(bytes: []const u8) !harness.Json {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
}

/// `POST /api/workspaces {"name": ...}` → the new workspace's id. Owned.
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

/// `GET /api/workspaces/<ws>/skills` → the WHOLE body as OWNED bytes.
fn listSkillsBody(h: *Harness, ws: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/skills", .{ws});
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `GET /api/workspaces/<ws>/skills/<name>` → the WHOLE body. Owned.
fn detailSkillBody(h: *Harness, ws: []const u8, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/skills/{s}", .{ ws, name });
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{ .expect = &.{ 404, 200 } });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `DELETE /api/workspaces/<ws>/skills/<name>` → the WHOLE body. Owned.
fn deleteSkillBody(h: *Harness, ws: []const u8, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/skills/{s}", .{ ws, name });
    defer gpa.free(path);
    var r = try h.http(io, .DELETE, path, .{ .expect = &.{ 200, 404 } });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// The root object of a JSON document.
fn rootObject(doc: *const harness.Json, ctx: []const u8) !std.json.ObjectMap {
    return switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("{s}: root is not a JSON object\n", .{ctx});
            return error.TestUnexpectedResult;
        },
    };
}

/// Python `assert obj[key] == want` for a string field.
fn expectStr(obj: std.json.ObjectMap, key: []const u8, want: []const u8, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: missing `{s}`\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .string => |x| x,
        else => {
            std.debug.print("{s}: `{s}` is not a string\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("{s}: `{s}` = \"{s}\", expected \"{s}\"\n", .{ ctx, key, got, want });
        return error.TestUnexpectedResult;
    }
}

/// Python `assert obj[key] == n` for an integer field.
fn expectInt(obj: std.json.ObjectMap, key: []const u8, want: i64, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: missing `{s}`\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .integer => |x| x,
        else => {
            std.debug.print("{s}: `{s}` is not an integer\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
    if (got != want) {
        std.debug.print("{s}: `{s}` = {d}, expected {d}\n", .{ ctx, key, got, want });
        return error.TestUnexpectedResult;
    }
}

/// Python `assert obj[key] is True` — strict: absent, `null` and any
/// other type all fail, because `None is True` is False in Python too.
fn expectTrue(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: missing `{s}` (must be true)\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .bool => |b| b,
        else => {
            std.debug.print("{s}: `{s}` is not a bool\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
    if (!got) {
        std.debug.print("{s}: `{s}` is false, expected true\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    }
}

/// Python `assert obj[key] is False`.
fn expectFalse(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: missing `{s}` (must be false)\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .bool => |b| b,
        else => {
            std.debug.print("{s}: `{s}` is not a bool\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
    if (got) {
        std.debug.print("{s}: `{s}` is true, expected false\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    }
}

/// Python `assert obj[key] is None` — the key must be present AND null.
fn expectNull(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: `{s}` is absent (expected null)\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    switch (v) {
        .null => {},
        else => {
            std.debug.print("{s}: `{s}` is not null\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    }
}

/// Python `assert key not in obj`.
fn expectKeyAbsent(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) !void {
    if (obj.get(key) != null) {
        const rendered = try renderKeys(obj);
        defer gpa.free(rendered);
        std.debug.print("{s}: must NOT carry `{s}`; keys = [{s}]\n", .{ ctx, key, rendered });
        return error.TestUnexpectedResult;
    }
}

/// Python `set(obj) == {...}` — the object carries EXACTLY these keys.
fn expectExactKeys(obj: std.json.ObjectMap, want: []const []const u8, ctx: []const u8) !void {
    var count: usize = 0;
    var it = obj.iterator();
    while (it.next()) |_| count += 1;
    if (count != want.len) {
        const rendered = try renderKeys(obj);
        defer gpa.free(rendered);
        std.debug.print(
            "{s}: expected exactly {d} keys, got {d} ({s})\n",
            .{ ctx, want.len, count, rendered },
        );
        return error.TestUnexpectedResult;
    }
    for (want) |k| {
        if (obj.get(k) == null) {
            const rendered = try renderKeys(obj);
            defer gpa.free(rendered);
            std.debug.print("{s}: missing `{s}`; keys = [{s}]\n", .{ ctx, k, rendered });
            return error.TestUnexpectedResult;
        }
    }
}

/// Comma-joined keys, sorted — the readable form of Python's `sorted(d)`.
fn renderKeys(obj: std.json.ObjectMap) ![]u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    var it = obj.iterator();
    while (it.next()) |entry| try keys.append(gpa, entry.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, strLessThan);
    return std.mem.join(gpa, ", ", keys.items);
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The `skills` array at `key` of `obj`. Caller owns nothing; the slices
/// borrow the parsed document.
fn skillsArray(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) !std.json.Array {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: missing `{s}`\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .array => |a| a,
        else => {
            std.debug.print("{s}: `{s}` is not an array\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
}

// ============================================================================
// Tests
// ============================================================================

// The three routes moved; the directory-tier collection route is gone.
// `/api/skills` answered by merging `~/.config/pabrik/skills/` with
// `<cwd>/.pabrik/skills/` and had no workspace id to scope either to.
test "skills_are_reachable_only_under_a_workspace" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-routes");
    defer gpa.free(ws);

    {
        const listed_raw = try listSkillsBody(&h, ws);
        defer gpa.free(listed_raw);
        var doc = try parseJson(listed_raw);
        defer doc.deinit();
        const listed = try rootObject(&doc, "GET skills");
        try expectExactKeys(listed, &.{"skills"}, "GET skills");
        const arr = try skillsArray(listed, "skills", "GET skills");
        if (arr.items.len != 0) {
            std.debug.print("a fresh workspace should hold no skills: {s}\n", .{listed_raw});
            return error.TestUnexpectedResult;
        }
    }

    // The old collection route and the old detail route are both gone.
    {
        var r = try h.http(io, .GET, "/api/skills", .{ .expect = &.{404} });
        defer r.deinit();
    }
    {
        var r = try h.http(io, .GET, "/api/skills/pdf", .{ .expect = &.{404} });
        defer r.deinit();
    }
    {
        var r = try h.http(io, .DELETE, "/api/skills", .{
            // `params` values are percent-encoded by the harness; `pdf`
            // has nothing to escape.
            .params = &.{.{ .name = "name", .value = "pdf" }},
            .expect = &.{404},
        });
        defer r.deinit();
    }

    // The sibling eval prefix is untouched by the move — it is a sibling
    // ON PURPOSE, because a literal nested under the `:skill_name` route
    // would be captured as the param.
    {
        var r = try h.http(io, .GET, "/api/skill-evals/summary", .{ .expect = &.{200} });
        defer r.deinit();
    }
}

// `{skills:[{name, description, is_can_auto_improve}]}` — no body, no path,
// no is_global. `is_global` described which of two directories a body was
// read from.
test "list_returns_name_description_and_the_auto_improve_lock" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-list");
    defer gpa.free(ws);

    try seedSkill(h.temp_dir, ws, "pdf", "Work with PDFs.", BODY);
    try seedSkill(h.temp_dir, ws, "zig-trap", "The `std.mem.trimRight` trap.", "body");

    const listed_raw = try listSkillsBody(&h, ws);
    defer gpa.free(listed_raw);
    var doc = try parseJson(listed_raw);
    defer doc.deinit();
    const listed = try rootObject(&doc, "GET skills");

    const arr = try skillsArray(listed, "skills", "GET skills");
    if (arr.items.len != 2) {
        std.debug.print("expected 2 skills, got {d}: {s}\n", .{ arr.items.len, listed_raw });
        return error.TestUnexpectedResult;
    }

    // `rows = {s["name"]: s for s in body["skills"]}` — index by name.
    const want_names = [2][]const u8{ "pdf", "zig-trap" };
    for (want_names) |want_name| {
        const row = findByName(arr, want_name) orelse {
            std.debug.print("no skill named \"{s}\": {s}\n", .{ want_name, listed_raw });
            return error.TestUnexpectedResult;
        };
        if (std.mem.eql(u8, want_name, "pdf")) {
            // `rows["pdf"] == {"name": "pdf", "description": "Work with PDFs.",
            // "is_can_auto_improve": true}`
            try expectExactKeys(row, &.{ "name", "description", "is_can_auto_improve" }, "pdf row");
            try expectStr(row, "name", "pdf", "pdf row");
            try expectStr(row, "description", "Work with PDFs.", "pdf row");
            // A row seeded straight into SQL takes the column default, so a
            // skill that predates the flag reads as auto-improvable.
            try expectTrue(row, "is_can_auto_improve", "pdf row");
        }
        // The list row carries no body: a workspace can hold dozens of
        // skills and the sidebar only renders a picker.
        try expectKeyAbsent(row, "content", "list row");
        try expectKeyAbsent(row, "path", "list row");
        try expectKeyAbsent(row, "is_global", "list row");
    }
}

/// Find the row object whose `name` is `name`. Borrows `arr`.
fn findByName(arr: std.json.Array, name: []const u8) ?std.json.ObjectMap {
    for (arr.items) |item| {
        const o = switch (item) {
            .object => |m| m,
            else => continue,
        };
        const n = switch (o.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, n, name)) return o;
    }
    return null;
}

// `{skill:{name, description, content, asset_count}, error_message:""}`.
test "detail_returns_the_body_and_the_companion_count" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-detail");
    defer gpa.free(ws);
    try seedSkill(h.temp_dir, ws, "pdf", "Work with PDFs.", BODY);
    try seedAsset(h.temp_dir, ws, "pdf", "scripts/convert.py", "print('hi')");

    const detail_raw = try detailSkillBody(&h, ws, "pdf");
    defer gpa.free(detail_raw);
    var doc = try parseJson(detail_raw);
    defer doc.deinit();
    const detail = try rootObject(&doc, "GET skill detail");

    try expectStr(detail, "error_message", "", "detail");

    const skill_v = detail.get("skill") orelse {
        std.debug.print("detail has no `skill`: {s}\n", .{detail_raw});
        return error.TestUnexpectedResult;
    };
    const skill = switch (skill_v) {
        .object => |o| o,
        else => {
            std.debug.print("`skill` is not an object (should exist): {s}\n", .{detail_raw});
            return error.TestUnexpectedResult;
        },
    };
    try expectStr(skill, "name", "pdf", "skill");
    try expectStr(skill, "description", "Work with PDFs.", "skill");
    try expectStr(skill, "content", BODY, "skill (body must round-trip byte-exact)");
    // `skill["content"].startswith("---")` — the frontmatter is part of
    // the body, asserted against the RETURNED string (not the constant),
    // so a handler that stripped the block cannot pass.
    {
        const content_v = skill.get("content") orelse {
            std.debug.print("skill has no `content`: {s}\n", .{detail_raw});
            return error.TestUnexpectedResult;
        };
        const content = switch (content_v) {
            .string => |x| x,
            else => {
                std.debug.print("`content` is not a string: {s}\n", .{detail_raw});
                return error.TestUnexpectedResult;
            },
        };
        if (!std.mem.startsWith(u8, content, "---")) {
            std.debug.print("the frontmatter is not part of the body: {s}\n", .{detail_raw});
            return error.TestUnexpectedResult;
        }
    }
    try expectInt(skill, "asset_count", 1, "skill");
    // No `path`: the body no longer lives at a pathname, and a client
    // that reconstructs one is the path-shaped contract this removes.
    try expectKeyAbsent(skill, "path", "skill");
    try expectKeyAbsent(skill, "is_global", "skill");
}

// A foreign name is NOT 403. A 403 would confirm the name exists, which is
// exactly what the workspace scoping exists to hide.
test "detail_of_a_foreign_workspace_is_404_and_lists_what_does_exist" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_a = try createWorkspace(&h, "skills-scope-a");
    defer gpa.free(ws_a);
    const ws_b = try createWorkspace(&h, "skills-scope-b");
    defer gpa.free(ws_b);
    try seedSkill(h.temp_dir, ws_a, "pdf", "Work with PDFs.", BODY);
    try seedSkill(h.temp_dir, ws_a, "zig-trap", "A trap.", BODY);
    try seedSkill(h.temp_dir, ws_b, "secret-skill", "B's own skill.", BODY);

    const detail_raw = try detailSkillBody(&h, ws_b, "pdf");
    defer gpa.free(detail_raw);
    var doc = try parseJson(detail_raw);
    defer doc.deinit();
    const detail = try rootObject(&doc, "GET foreign skill detail");

    try expectNull(detail, "skill", "foreign detail");

    // A miss must SAY WHY: a non-empty `error_message`.
    {
        const v = detail.get("error_message") orelse {
            std.debug.print("foreign detail has no `error_message`: {s}\n", .{detail_raw});
            return error.TestUnexpectedResult;
        };
        const msg = switch (v) {
            .string => |x| x,
            else => {
                std.debug.print("`error_message` is not a string: {s}\n", .{detail_raw});
                return error.TestUnexpectedResult;
            },
        };
        if (msg.len == 0) {
            std.debug.print("`error_message` is empty: {s}\n", .{detail_raw});
            return error.TestUnexpectedResult;
        }
    }

    // `sorted(detail["available_skills"]) == ["secret-skill"]`
    const avail = try skillsArray(detail, "available_skills", "foreign detail");
    if (avail.items.len != 1) {
        std.debug.print(
            "ws_b must only be told about its OWN skills, got {d} entries: {s}\n",
            .{ avail.items.len, detail_raw },
        );
        return error.TestUnexpectedResult;
    }
    const name = switch (avail.items[0]) {
        .string => |x| x,
        else => {
            std.debug.print("available_skills entry is not a string: {s}\n", .{detail_raw});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqualStrings("secret-skill", name);
}

// `{success, skill_name, error_message}` with no `deleted_from`.
// `deleted_from` named the directory the body was removed from.
test "delete_removes_the_row_and_its_companions" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-delete");
    defer gpa.free(ws);
    try seedSkill(h.temp_dir, ws, "pdf", "Work with PDFs.", BODY);
    try seedAsset(h.temp_dir, ws, "pdf", "scripts/convert.py", "print('hi')");

    {
        const deleted_raw = try deleteSkillBody(&h, ws, "pdf");
        defer gpa.free(deleted_raw);
        var doc = try parseJson(deleted_raw);
        defer doc.deinit();
        const deleted = try rootObject(&doc, "DELETE skill");
        try expectExactKeys(deleted, &.{ "success", "skill_name", "error_message" }, "DELETE skill");
        try expectTrue(deleted, "success", "DELETE skill");
        try expectStr(deleted, "skill_name", "pdf", "DELETE skill");
        try expectStr(deleted, "error_message", "", "DELETE skill");
    }

    {
        const n = try rowCount(h.temp_dir, "skill_assets");
        // PRAGMA foreign_keys is off project-wide, so the declared
        // CASCADE does nothing — orphaned companion rows would collide
        // with a re-import on UNIQUE (skill_id, rel_path).
        if (n != 0) {
            std.debug.print("skill_assets still has {d} rows after DELETE\n", .{n});
            return error.TestUnexpectedResult;
        }
    }

    // Second delete is a miss, not a silent success.
    {
        const again_raw = try deleteSkillBody(&h, ws, "pdf");
        defer gpa.free(again_raw);
        var doc = try parseJson(again_raw);
        defer doc.deinit();
        const again = try rootObject(&doc, "second DELETE skill");
        try expectFalse(again, "success", "second DELETE skill");
        try expectStr(again, "skill_name", "pdf", "second DELETE skill");
        const v = again.get("error_message") orelse {
            std.debug.print("second DELETE has no `error_message`: {s}\n", .{again_raw});
            return error.TestUnexpectedResult;
        };
        const msg = switch (v) {
            .string => |x| x,
            else => return error.TestUnexpectedResult,
        };
        if (msg.len == 0) {
            std.debug.print("second DELETE `error_message` is empty: {s}\n", .{again_raw});
            return error.TestUnexpectedResult;
        }
    }
}

// 404, and the other workspace's row survives.
test "delete_from_a_foreign_workspace_deletes_nothing" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_a = try createWorkspace(&h, "skills-del-a");
    defer gpa.free(ws_a);
    const ws_b = try createWorkspace(&h, "skills-del-b");
    defer gpa.free(ws_b);
    try seedSkill(h.temp_dir, ws_a, "pdf", "Work with PDFs.", BODY);
    const before = try rowCount(h.temp_dir, "skills");

    {
        const raw = try deleteSkillBody(&h, ws_b, "pdf");
        defer gpa.free(raw);
        var doc = try parseJson(raw);
        defer doc.deinit();
        const body = try rootObject(&doc, "foreign DELETE skill");
        try expectFalse(body, "success", "foreign DELETE skill");
        // A foreign name must get the SAME message as one that does not
        // exist — that is the whole point of not 403-ing.
        try expectStr(body, "error_message", "skill not found", "foreign DELETE skill");
    }

    const after = try rowCount(h.temp_dir, "skills");
    if (after != before) {
        std.debug.print("foreign DELETE changed the skills row count: {d} -> {d}\n", .{ before, after });
        return error.TestUnexpectedResult;
    }
}

// The list reflects writes made by the agent tools, not a cached walk. The
// old handlers re-read the directory on every request, so a filesystem change
// showed up immediately.
test "a_skill_created_by_a_tool_is_visible_to_the_next_read" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-add");
    defer gpa.free(ws);

    {
        const listed_raw = try listSkillsBody(&h, ws);
        defer gpa.free(listed_raw);
        var doc = try parseJson(listed_raw);
        defer doc.deinit();
        const listed = try rootObject(&doc, "first GET skills");
        const arr = try skillsArray(listed, "skills", "first GET skills");
        if (arr.items.len != 0) {
            std.debug.print("a fresh workspace should hold no skills: {s}\n", .{listed_raw});
            return error.TestUnexpectedResult;
        }
    }

    try seedSkill(h.temp_dir, ws, "added-by-tool", "Written after the first read.", BODY);

    {
        const listed_raw = try listSkillsBody(&h, ws);
        defer gpa.free(listed_raw);
        var doc = try parseJson(listed_raw);
        defer doc.deinit();
        const listed = try rootObject(&doc, "second GET skills");
        const arr = try skillsArray(listed, "skills", "second GET skills");
        if (arr.items.len != 1) {
            std.debug.print("expected 1 skill, got {d}: {s}\n", .{ arr.items.len, listed_raw });
            return error.TestUnexpectedResult;
        }
        const row = switch (arr.items[0]) {
            .object => |o| o,
            else => {
                std.debug.print("skill row is not an object: {s}\n", .{listed_raw});
                return error.TestUnexpectedResult;
            },
        };
        try expectStr(row, "name", "added-by-tool", "added-by-tool row");
    }
}

// A miss is a 404 that says what the workspace DOES hold.
test "detail_of_an_unknown_name_is_a_clean_404" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-unknown");
    defer gpa.free(ws);

    const detail_raw = try detailSkillBody(&h, ws, "does-not-exist");
    defer gpa.free(detail_raw);
    var doc = try parseJson(detail_raw);
    defer doc.deinit();
    const detail = try rootObject(&doc, "unknown skill detail");

    try expectNull(detail, "skill", "unknown detail");
    try expectStr(detail, "error_message", "skill not found", "unknown detail");
    const avail = try skillsArray(detail, "available_skills", "unknown detail");
    if (avail.items.len != 0) {
        std.debug.print("expected an empty available_skills, got {d}: {s}\n", .{ avail.items.len, detail_raw });
        return error.TestUnexpectedResult;
    }
}

// Guard against a `count`/tiered envelope creeping back in. The old payload
// was `{global_skills, local_skills, cwd}` — two arrays because there were
// two directories.
test "list_response_is_a_plain_array_of_objects" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-shape");
    defer gpa.free(ws);
    try seedSkill(h.temp_dir, ws, "pdf", "Work with PDFs.", BODY);

    const body_raw = try listSkillsBody(&h, ws);
    defer gpa.free(body_raw);
    var doc = try parseJson(body_raw);
    defer doc.deinit();
    const body = try rootObject(&doc, "GET skills");

    // `list(body.keys()) == ["skills"]` — a ONE-KEY object. `expectExactKeys`
    // asserts the set; the count check is what the `list()` form really
    // pins, and it is the same condition.
    try expectExactKeys(body, &.{"skills"}, "GET skills");

    const arr = try skillsArray(body, "skills", "GET skills");
    if (arr.items.len < 1) {
        std.debug.print("expected at least one skill row: {s}\n", .{body_raw});
        return error.TestUnexpectedResult;
    }
    // `isinstance(body["skills"][0], dict)`
    switch (arr.items[0]) {
        .object => {},
        else => {
            std.debug.print("skills[0] is not an object: {s}\n", .{body_raw});
            return error.TestUnexpectedResult;
        },
    }
}

comptime {
    // Body-analysis barrier — see `harness.zig`'s note: an unreferenced
    // function body is never type-checked, so a stdlib rename inside one
    // stays invisible until a caller appears.
    _ = exitCode;
    _ = requireSqlite3Cli;
    _ = parseSqliteJson;
    _ = sqlLit;
    _ = sqliteRun;
    _ = dbPath;
    _ = dbRun;
    _ = seedSkill;
    _ = skillIdSql;
    _ = seedAsset;
    _ = rowCount;
    _ = parseJson;
    _ = createWorkspace;
    _ = listSkillsBody;
    _ = detailSkillBody;
    _ = deleteSkillBody;
    _ = rootObject;
    _ = expectStr;
    _ = expectInt;
    _ = expectTrue;
    _ = expectFalse;
    _ = expectNull;
    _ = expectKeyAbsent;
    _ = expectExactKeys;
    _ = renderKeys;
    _ = skillsArray;
    _ = findByName;
}
