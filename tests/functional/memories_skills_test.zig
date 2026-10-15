// Functional tests for memories + skills. Zig port of
// `tests/functional/memories_skills_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// Python `_seed_skill_row`'s un-formatted default `content`. A default
/// argument is NOT a format string, so Python seeded the literal `%s`
/// placeholders.
const DEFAULT_SKILL_CONTENT = "---\nname: %s\ndescription: %s\n---\n\nbody\n";

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
        std.debug.print("sqlite3 CLI unavailable ({s}); skipping DB-seeding assertions\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code = exitCode(res.term);
    if (code == null or code.? != 0 or std.mem.indexOf(u8, res.stdout, "\"probe\"") == null) {
        std.debug.print(
            "sqlite3 CLI lacks -json support (rc={?}, out={s}); skipping DB-seeding assertions\n",
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

/// Run `sql` against the harness DB, returning the CLI's stdout. The DB
/// must already exist - the server creates it at boot.
fn dbRun(temp_dir: []const u8, sql: []const u8) ![]u8 {
    const db = try harness.harnessPath(gpa, temp_dir, &.{ ".config", "pabrik", "agent.db" });
    defer gpa.free(db);
    std.Io.Dir.cwd().access(io, db, .{}) catch {
        std.debug.print("database not found at {s}\n", .{db});
        return error.TestUnexpectedResult;
    };
    return sqliteRun(db, sql);
}

/// Python `_seed_skill_row`. There is no HTTP create route for skills -
/// `add_skill` is an agent tool - so a test that needs a row to read writes
/// one.
fn seedSkillRow(
    temp_dir: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    description: []const u8,
    content: []const u8,
) !void {
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

// ============================================================================
// Filesystem helpers
// ============================================================================

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Python `Path.read_text(encoding="utf-8")`. Owned; the caller frees.
fn readTextFile(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
}

/// Python `_get_memory_disk_path`. Memories live in
/// $XDG_CONFIG_HOME/pabrik/memories/<name> or
/// $HOME/.config/pabrik/memories/<name> (Windows: %APPDATA%/pabrik).
fn memoryDiskPath(temp_dir: []const u8, name: []const u8) ![]u8 {
    // Check XDG/.config first (current Windows isolation), then APPDATA.
    const config_base = try harness.harnessPath(
        gpa,
        temp_dir,
        &.{ ".config", "pabrik", "memories", name },
    );
    if (pathExists(config_base)) return config_base;
    const appdata_base = try harness.harnessPath(
        gpa,
        temp_dir,
        &.{ "AppData", "Roaming", "pabrik", "memories", name },
    );
    if (pathExists(appdata_base)) {
        gpa.free(config_base);
        return appdata_base;
    }
    // Default for new writes: use the XDG/.config location (matches
    // harness's isolated XDG_CONFIG_HOME on Windows and HOME/.config on
    // Linux).
    gpa.free(appdata_base);
    return config_base;
}

// ============================================================================
// HTTP helpers
// ============================================================================

/// Python `_create_workspace`. Owned.
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

fn freeNames(names: [][]u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

/// Python `_list_memories` -> the set of names. Owned slice of owned
/// strings; free with `freeNames`.
fn listMemoryNames(h: *Harness) ![][]u8 {
    var r = try h.http(io, .GET, "/api/memories", .{ .expect = &.{200} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const arr = doc.array("memories") orelse {
        std.debug.print("GET /api/memories: no `memories` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }
    for (arr.items) |m| {
        const obj = switch (m) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        try out.append(gpa, try gpa.dupe(u8, name));
    }
    return out.toOwnedSlice(gpa);
}

fn namesContain(names: []const []u8, needle: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, needle)) return true;
    }
    return false;
}

/// One entry of `GET /api/workspaces/:ws/skills` — `{name, description}`.
const SkillEntry = struct {
    name: []u8,
    description: ?[]u8,
    /// Every key the entry carries, owned. Backs the "exactly
    /// `{name, description}`" assertion.
    keys: [][]u8,
};

/// `GET /api/workspaces/:workspace_id/skills` — one flat array of `{name,
/// description}`.
const SkillList = struct {
    entries: []SkillEntry,

    fn deinit(self: *SkillList) void {
        for (self.entries) |e| {
            gpa.free(e.name);
            if (e.description) |d| gpa.free(d);
            for (e.keys) |k| gpa.free(k);
            gpa.free(e.keys);
        }
        gpa.free(self.entries);
        self.* = undefined;
    }

    fn find(self: SkillList, name: []const u8) ?*const SkillEntry {
        for (self.entries) |*e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }
};

fn freeSkillEntry(e: SkillEntry) void {
    gpa.free(e.name);
    if (e.description) |d| gpa.free(d);
    for (e.keys) |k| gpa.free(k);
    gpa.free(e.keys);
}

/// Python `_list_skills`, returning OWNED entries.
fn listSkills(h: *Harness, workspace_id: []const u8) !SkillList {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/skills", .{workspace_id});
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const arr = doc.array("skills") orelse {
        std.debug.print("GET {s}: no `skills` array: {s}\n", .{ path, r.body });
        return error.TestUnexpectedResult;
    };

    var entries: std.ArrayList(SkillEntry) = .empty;
    errdefer {
        for (entries.items) |e| freeSkillEntry(e);
        entries.deinit(gpa);
    }
    for (arr.items) |m| {
        const obj = switch (m) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        var keys: std.ArrayList([]u8) = .empty;
        errdefer {
            for (keys.items) |k| gpa.free(k);
            keys.deinit(gpa);
        }
        var kit = obj.iterator();
        while (kit.next()) |kv| try keys.append(gpa, try gpa.dupe(u8, kv.key_ptr.*));

        const desc: ?[]u8 = if (obj.get("description")) |dv| switch (dv) {
            .string => |s| try gpa.dupe(u8, s),
            else => null,
        } else null;
        errdefer if (desc) |d| gpa.free(d);

        try entries.append(gpa, .{
            .name = try gpa.dupe(u8, name),
            .description = desc,
            .keys = try keys.toOwnedSlice(gpa),
        });
    }
    return .{ .entries = try entries.toOwnedSlice(gpa) };
}

/// `POST /api/memories {"name": ..., "content": ...}`. Returns the
/// response body (owned) so the caller can assert on the envelope.
fn createMemory(h: *Harness, name: []const u8, content: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(
        gpa,
        .{ .name = name, .content = content },
        .{},
    );
    defer gpa.free(body);
    var r = try h.http(io, .POST, "/api/memories", .{ .json_body = body, .expect = &.{201} });
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

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Comma-joined, sorted key list, owned. For failure messages.
fn renderKeys(obj: std.json.ObjectMap) ![]u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    var it = obj.iterator();
    while (it.next()) |entry| try keys.append(gpa, entry.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, strLessThan);
    return std.mem.join(gpa, ", ", keys.items);
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

/// Python `assert obj[key] is True`.
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

/// Python `set(obj) == {...}` on a borrowed ObjectMap: the object
/// carries EXACTLY these keys.
fn expectExactKeys(obj: std.json.ObjectMap, want: []const []const u8, ctx: []const u8) !void {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    var it = obj.iterator();
    while (it.next()) |entry| try keys.append(gpa, entry.key_ptr.*);
    return expectKeysExactly(keys.items, want, ctx);
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

/// Python `assert "path" not in skill` / `assert key not in obj` on an
/// OWNED key list.
fn expectKeysExactly(keys: []const []const u8, want: []const []const u8, ctx: []const u8) !void {
    if (keys.len != want.len) {
        const rendered = try renderOwnedKeys(keys);
        defer gpa.free(rendered);
        std.debug.print(
            "{s}: expected exactly {d} keys, got {d} ({s})\n",
            .{ ctx, want.len, keys.len, rendered },
        );
        return error.TestUnexpectedResult;
    }
    for (want) |k| {
        var found = false;
        for (keys) |have| {
            if (std.mem.eql(u8, have, k)) found = true;
        }
        if (found) continue;
        const rendered = try renderOwnedKeys(keys);
        defer gpa.free(rendered);
        std.debug.print("{s}: missing `{s}`; keys = [{s}]\n", .{ ctx, k, rendered });
        return error.TestUnexpectedResult;
    }
}

fn renderOwnedKeys(keys: []const []const u8) ![]u8 {
    var sorted: std.ArrayList([]const u8) = .empty;
    defer sorted.deinit(gpa);
    for (keys) |k| try sorted.append(gpa, k);
    std.mem.sort([]const u8, sorted.items, {}, strLessThan);
    return std.mem.join(gpa, ", ", sorted.items);
}

/// Python `assert r.json().get("success", True) is True` - absent counts
/// as success; present-and-true counts; anything else fails.
fn expectSuccessTrueOrAbsent(doc: *const harness.Json, ctx: []const u8) !void {
    const v = doc.get("success") orelse return;
    const got = switch (v) {
        .bool => |b| b,
        else => {
            std.debug.print("{s}: `success` is not a bool\n", .{ctx});
            return error.TestUnexpectedResult;
        },
    };
    if (!got) {
        std.debug.print("{s}: `success` is false, expected true\n", .{ctx});
        return error.TestUnexpectedResult;
    }
}

comptime {
    // Body-analysis barrier: an unreferenced fn body is never
    // type-checked, so a stdlib rename inside one hides until a caller
    // appears.
    _ = createWorkspace;
    _ = listMemoryNames;
    _ = listSkills;
    _ = seedSkillRow;
    _ = memoryDiskPath;
    _ = createMemory;
    _ = requireSqlite3Cli;
    _ = parseSqliteJson;
}

// ============================================================================
// Test 1: create + list a global memory
// ============================================================================

// POST /api/memories creates a .md file at $HOME/.config/pabrik/memories/<name>.
test "create_global_memory_writes_to_disk" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const body = try createMemory(&h, "test-mem.md", "# Hello\n\nMemory body.");
    defer gpa.free(body);

    var doc: harness.Json = .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{}) };
    defer doc.deinit();
    if (doc.get("memory") == null) {
        std.debug.print("create response has no `memory`: {s}\n", .{body});
        return error.TestUnexpectedResult;
    }
    const mem = doc.object("memory").?;
    try expectStr(mem, "name", "test-mem.md", "created memory");

    // File on disk.
    const mem_path = try memoryDiskPath(h.temp_dir, "test-mem.md");
    defer gpa.free(mem_path);
    if (!pathExists(mem_path)) {
        std.debug.print("memory file not written to {s}\n", .{mem_path});
        return error.TestUnexpectedResult;
    }
    const on_disk = try readTextFile(mem_path);
    defer gpa.free(on_disk);
    if (!std.mem.eql(u8, on_disk, "# Hello\n\nMemory body.")) {
        std.debug.print("memory file content = \"{s}\"\n", .{on_disk});
        return error.TestUnexpectedResult;
    }

    // Listed via the API.
    const listed = try listMemoryNames(&h);
    defer freeNames(listed);
    if (!namesContain(listed, "test-mem.md")) {
        var rendered = std.Io.Writer.Allocating.init(gpa);
        defer rendered.deinit();
        for (listed) |n| rendered.writer.print("{s} ", .{n}) catch {};
        std.debug.print("created memory not in list response: {s}\n", .{rendered.written()});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 2: list 3 memories
// ============================================================================

// Create 3 memories; list shows all 3.
test "list_memories_returns_created" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const names = [_][]const u8{ "alpha.md", "beta.md", "gamma.md" };
    for (names) |name| {
        const content = try std.fmt.allocPrint(gpa, "# {s}\nbody", .{name});
        defer gpa.free(content);
        const body = try createMemory(&h, name, content);
        gpa.free(body);
    }

    const listed = try listMemoryNames(&h);
    defer freeNames(listed);
    for (names) |name| {
        if (!namesContain(listed, name)) {
            var rendered = std.Io.Writer.Allocating.init(gpa);
            defer rendered.deinit();
            for (listed) |n| rendered.writer.print("{s} ", .{n}) catch {};
            std.debug.print("expected {s} in list, got {s}\n", .{ name, rendered.written() });
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 3: update memory overwrites the file
// ============================================================================

// PUT /api/memories/:name with new content overwrites the file.
test "update_memory_overwrites_file" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // Create first.
    {
        const body = try createMemory(&h, "update-me.md", "original");
        gpa.free(body);
    }
    const mem_path = try memoryDiskPath(h.temp_dir, "update-me.md");
    defer gpa.free(mem_path);
    {
        const on_disk = try readTextFile(mem_path);
        defer gpa.free(on_disk);
        if (!std.mem.eql(u8, on_disk, "original")) {
            std.debug.print("pre-update content = \"{s}\", expected \"original\"\n", .{on_disk});
            return error.TestUnexpectedResult;
        }
    }

    // Update.
    const new_content = "# Updated\n\nNew body with unicode: \u{3053}\u{3093}\u{306b}\u{3061}\u{306f}";
    {
        const body = try std.json.Stringify.valueAlloc(
            gpa,
            .{ .content = new_content },
            .{},
        );
        defer gpa.free(body);
        const path = try std.fmt.allocPrint(gpa, "/api/memories/update-me.md", .{});
        defer gpa.free(path);
        var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try expectSuccessTrueOrAbsent(&doc, "PUT /api/memories/update-me.md");
    }

    // File content matches.
    {
        const on_disk = try readTextFile(mem_path);
        defer gpa.free(on_disk);
        if (!std.mem.eql(u8, on_disk, new_content)) {
            const escaped = try harness.debugString(gpa, on_disk);
            defer gpa.free(escaped);
            std.debug.print("post-update content = \"{s}\"\n", .{escaped});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 4: delete memory removes the file
// ============================================================================

// DELETE /api/memories/:name removes the .md file.
test "delete_memory_removes_file" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        const body = try createMemory(&h, "doomed.md", "goodbye");
        gpa.free(body);
    }
    const mem_path = try memoryDiskPath(h.temp_dir, "doomed.md");
    defer gpa.free(mem_path);
    if (!pathExists(mem_path)) {
        std.debug.print("memory file was never written to {s}\n", .{mem_path});
        return error.TestUnexpectedResult;
    }

    {
        const path = try std.fmt.allocPrint(gpa, "/api/memories/doomed.md", .{});
        defer gpa.free(path);
        var r = try h.http(io, .DELETE, path, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try expectSuccessTrueOrAbsent(&doc, "DELETE /api/memories/doomed.md");
    }
    if (pathExists(mem_path)) {
        std.debug.print("memory file not removed after delete: {s}\n", .{mem_path});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 5: local memory under a cwd
// ============================================================================

// POST /api/local-memories with cwd creates the file under that cwd.
test "create_local_memory_under_cwd" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // The Python `item_workspace_path` fixture: a directory OUTSIDE the
    // harness tempdir that the test points the API at.
    const cwd = try harness.makeScratchDir(gpa);
    defer gpa.free(cwd);
    defer harness.cleanupExtraDir(io, gpa, cwd);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = "local-mem.md",
        .content = "# local\nscoped to cwd",
        .cwd = cwd,
    }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/local-memories", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    if (doc.get("memory") == null) {
        std.debug.print("local create response has no `memory`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }

    // File on disk under the requested cwd.
    const mem_path = try harness.harnessPath(gpa, cwd, &.{ ".pabrik", "memories", "local-mem.md" });
    defer gpa.free(mem_path);
    if (!pathExists(mem_path)) {
        std.debug.print("local memory not at {s}\n", .{mem_path});
        return error.TestUnexpectedResult;
    }
    const on_disk = try readTextFile(mem_path);
    defer gpa.free(on_disk);
    if (!std.mem.eql(u8, on_disk, "# local\nscoped to cwd")) {
        std.debug.print("local memory content = \"{s}\"\n", .{on_disk});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 6: skill listing - a seeded row lists under its workspace
// ============================================================================

// A skill is a row in the workspace's `skills` table. It used to be a
// `SKILL.MD` file under `~/.config/pabrik/skills/`, which the API re-walked
// on every request and merged with a project-local copy.
test "skill_list_is_workspace_scoped" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "ms-skills");
    defer gpa.free(ws);

    {
        var empty = try listSkills(&h, ws);
        defer empty.deinit();
        if (empty.entries.len != 0) {
            std.debug.print("expected no skills in a fresh workspace, got {d}\n", .{empty.entries.len});
            return error.TestUnexpectedResult;
        }
    }

    try seedSkillRow(h.temp_dir, ws, "my-skill", "Does a thing.", DEFAULT_SKILL_CONTENT);

    var listed = try listSkills(&h, ws);
    defer listed.deinit();
    if (listed.entries.len != 1) {
        std.debug.print("seeded skill not in list response: {d} entries\n", .{listed.entries.len});
        return error.TestUnexpectedResult;
    }
    const entry = &listed.entries[0];
    if (!std.mem.eql(u8, entry.name, "my-skill")) {
        std.debug.print("listed skill name = \"{s}\", expected \"my-skill\"\n", .{entry.name});
        return error.TestUnexpectedResult;
    }
    const desc = entry.description orelse {
        std.debug.print("listed skill has no description\n", .{});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, desc, "Does a thing.")) {
        std.debug.print("listed skill description = [{s}], expected [Does a thing.]\n", .{desc});
        return error.TestUnexpectedResult;
    }
    try expectKeysExactly(entry.keys, &.{ "name", "description", "is_can_auto_improve" }, "listed skill");
}

// The workspace_id in the URL is the isolation boundary. A skill file used to
// be visible from every workspace that happened to share a machine; a row is
// not.
test "skill_list_does_not_leak_across_workspaces" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_a = try createWorkspace(&h, "ms-skills-a");
    defer gpa.free(ws_a);
    const ws_b = try createWorkspace(&h, "ms-skills-b");
    defer gpa.free(ws_b);

    try seedSkillRow(h.temp_dir, ws_a, "only-in-a", "A's skill.", DEFAULT_SKILL_CONTENT);

    {
        var a_list = try listSkills(&h, ws_a);
        defer a_list.deinit();
        if (a_list.entries.len != 1) {
            std.debug.print("workspace A should list exactly 1 skill, got {d}\n", .{a_list.entries.len});
            return error.TestUnexpectedResult;
        }
        if (!std.mem.eql(u8, a_list.entries[0].name, "only-in-a")) {
            std.debug.print("workspace A skill name = \"{s}\", expected \"only-in-a\"\n", .{a_list.entries[0].name});
            return error.TestUnexpectedResult;
        }
    }
    {
        var b_list = try listSkills(&h, ws_b);
        defer b_list.deinit();
        if (b_list.entries.len != 0) {
            std.debug.print("workspace B must not see workspace A's skill: {d} entries\n", .{b_list.entries.len});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 7: skill detail + delete
// ============================================================================

// GET the body, DELETE the row - both under the workspace. The delete takes
// the name as a PATH SEGMENT now, not as `?name=...&is_global=...&cwd=...`.
test "skill_detail_and_delete" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "ms-skills-delete");
    defer gpa.free(ws);

    const content = "---\nname: to-delete\ndescription: Will be deleted.\n---\n\n# To Delete\n\nBye.\n";
    try seedSkillRow(h.temp_dir, ws, "to-delete", "Will be deleted.", content);

    const detail_path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/skills/to-delete", .{ws});
    defer gpa.free(detail_path);
    var detail_body: []u8 = undefined;
    {
        var r = try h.http(io, .GET, detail_path, .{ .expect = &.{200} });
        defer r.deinit();
        detail_body = try gpa.dupe(u8, r.body);
    }
    defer gpa.free(detail_body);
    {
        var doc: harness.Json = .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, detail_body, .{}) };
        defer doc.deinit();
        const root = try rootObject(&doc, "skill detail");
        if (root.get("skill") == null) {
            std.debug.print("unexpected detail shape: {s}\n", .{detail_body});
            return error.TestUnexpectedResult;
        }
        const skill = switch (root.get("skill").?) {
            .object => |o| o,
            .null => {
                std.debug.print("skill should exist, got: {s}\n", .{detail_body});
                return error.TestUnexpectedResult;
            },
            else => return error.TestUnexpectedResult,
        };
        try expectStr(skill, "name", "to-delete", "skill detail");
        try expectStr(skill, "description", "Will be deleted.", "skill detail");
        // Byte-exact: `skill_eval` identities are sha256(body), so a body
        // that came back trimmed would stale every cached verdict
        // silently.
        try expectStr(skill, "content", content, "skill detail");
        if (std.mem.indexOf(u8, content, "---") != 0) return error.TestUnexpectedResult;
        try expectInt(skill, "asset_count", 0, "skill detail");
        // `path` and `is_global` described a directory; there is no
        // directory.
        try expectKeyAbsent(skill, "path", "skill detail");
        try expectKeyAbsent(skill, "is_global", "skill detail");
        try expectStr(root, "error_message", "", "skill detail");
    }

    {
        var r = try h.http(io, .DELETE, detail_path, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const root = try rootObject(&doc, "skill delete");
        try expectExactKeys(root, &.{ "success", "skill_name", "error_message" }, "skill delete");
        try expectTrue(root, "success", "skill delete");
        try expectStr(root, "skill_name", "to-delete", "skill delete");
        try expectStr(root, "error_message", "", "skill delete");
    }
    {
        var after = try listSkills(&h, ws);
        defer after.deinit();
        if (after.entries.len != 0) {
            std.debug.print("skill row survived delete: {d} entries\n", .{after.entries.len});
            return error.TestUnexpectedResult;
        }
    }

    // A second delete is a miss, not a silent success.
    {
        var r = try h.http(io, .DELETE, detail_path, .{ .expect = &.{404} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const root = try rootObject(&doc, "second delete");
        try expectFalse(root, "success", "second delete");
        const msg = root.get("error_message") orelse return error.TestUnexpectedResult;
        const text = switch (msg) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        if (text.len == 0) {
            std.debug.print("second delete carried an empty error_message\n", .{});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 8: memory and skill namespaces don't collide
// ============================================================================

// A memory named 'foo.md' and a skill named 'foo' are independent rows. The
// memory is a file under `~/.config/pabrik/memories/`; the skill is a row in
// the `skills` table.
test "memory_and_skill_namespaces_dont_collide" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "ms-ns");
    defer gpa.free(ws);

    {
        const body = try createMemory(&h, "ns-foo.md", "# memory foo");
        gpa.free(body);
    }
    try seedSkillRow(h.temp_dir, ws, "ns-foo", "namespace test skill.", DEFAULT_SKILL_CONTENT);

    {
        const mems = try listMemoryNames(&h);
        defer freeNames(mems);
        if (!namesContain(mems, "ns-foo.md")) {
            std.debug.print("memory ns-foo.md missing from list\n", .{});
            return error.TestUnexpectedResult;
        }
    }
    {
        var skills = try listSkills(&h, ws);
        defer skills.deinit();
        if (skills.find("ns-foo") == null) {
            std.debug.print("skill ns-foo missing from list: {d} entries\n", .{skills.entries.len});
            return error.TestUnexpectedResult;
        }
    }

    // Delete one, the other survives.
    {
        const path = try std.fmt.allocPrint(gpa, "/api/memories/ns-foo.md", .{});
        defer gpa.free(path);
        var r = try h.http(io, .DELETE, path, .{ .expect = &.{200} });
        defer r.deinit();
    }
    {
        const mem_path = try memoryDiskPath(h.temp_dir, "ns-foo.md");
        defer gpa.free(mem_path);
        if (pathExists(mem_path)) {
            std.debug.print("memory file survived delete: {s}\n", .{mem_path});
            return error.TestUnexpectedResult;
        }
    }
    {
        var skills = try listSkills(&h, ws);
        defer skills.deinit();
        if (skills.find("ns-foo") == null) {
            std.debug.print(
                "memory delete must not touch the skill row: {d} entries\n",
                .{skills.entries.len},
            );
            return error.TestUnexpectedResult;
        }
    }
}
