// Functional tests for the skills WRITE surface: `POST` (insert) and `PATCH`
// (update). The read/delete surface is covered by `skills_sqlite_test.zig`.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// The body asserted BYTE-EXACT after a create and after a patch.
/// Frontmatter included: `skill_eval` identities are `sha256(body)`, so a
/// handler that trimmed the `---` block would stale every cached verdict.
const BODY = "---\nname: pdf\ndescription: Work with PDFs.\n---\n\nRun `scripts/convert.py`.\n";

// ============================================================================
// HTTP helpers
// ============================================================================

/// `POST /api/workspaces/<ws>/skills` with the exact body the create form
/// sends. Returns the whole response body (owned).
fn createSkillBody(
    h: *Harness,
    ws: []const u8,
    name: []const u8,
    description: []const u8,
    content: []const u8,
    expect: []const u16,
) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = name,
        .description = description,
        .content = content,
    }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/skills", .{ws});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = expect });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `PATCH /api/workspaces/<ws>/skills/<name>` with the exact body the edit
/// form sends — BOTH fields, always, so a one-field edit cannot blank the
/// other. Returns the whole response body (owned).
fn patchSkillBody(
    h: *Harness,
    ws: []const u8,
    name: []const u8,
    description: []const u8,
    content: []const u8,
    expect: []const u16,
) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .description = description,
        .content = content,
    }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/skills/{s}", .{ ws, name });
    defer gpa.free(path);

    var r = try h.http(io, .PATCH, path, .{ .json_body = body, .expect = expect });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `GET /api/workspaces/<ws>/skills/<name>` → the whole body. Owned.
fn detailSkillBody(h: *Harness, ws: []const u8, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/skills/{s}", .{ ws, name });
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{ .expect = &.{ 404, 200 } });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `GET /api/workspaces/<ws>/skills` → the whole body. Owned.
fn listSkillsBody(h: *Harness, ws: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/skills", .{ws});
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
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

// ============================================================================
// Assertion helpers
// ============================================================================

fn parseJson(bytes: []const u8) !harness.Json {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
}

fn rootObject(doc: *const harness.Json, ctx: []const u8) !std.json.ObjectMap {
    return switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("{s}: root is not a JSON object\n", .{ctx});
            return error.TestUnexpectedResult;
        },
    };
}

/// The `skill` object of a create/patch/detail response.
fn skillObject(body: std.json.ObjectMap, ctx: []const u8) !std.json.ObjectMap {
    const v = body.get("skill") orelse {
        std.debug.print("{s}: no `skill` key\n", .{ctx});
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .object => |o| o,
        else => {
            std.debug.print("{s}: `skill` is not an object\n", .{ctx});
            return error.TestUnexpectedResult;
        },
    };
}

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

/// The `error` key of the generic error envelope.
fn expectError(obj: std.json.ObjectMap, want: []const u8, ctx: []const u8) !void {
    try expectStr(obj, "error", want, ctx);
}

/// The `skills` array of a list response.
fn skillsArray(obj: std.json.ObjectMap, ctx: []const u8) !std.json.Array {
    const v = obj.get("skills") orelse {
        std.debug.print("{s}: missing `skills`\n", .{ctx});
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .array => |a| a,
        else => {
            std.debug.print("{s}: `skills` is not an array\n", .{ctx});
            return error.TestUnexpectedResult;
        },
    };
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

// ============================================================================
// Tests
// ============================================================================

// The happy insert, asserted on the wire. `asset_count` is 0 because this
// route writes the body only — a bundled skill's companions arrive through
// the importer.
test "create_inserts_a_skill_and_returns_the_stored_row" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-create");
    defer gpa.free(ws);

    const created_raw = try createSkillBody(&h, ws, "pdf", "Work with PDFs.", BODY, &.{201});
    defer gpa.free(created_raw);
    var doc = try parseJson(created_raw);
    defer doc.deinit();
    const created = try rootObject(&doc, "POST skill");

    const skill = try skillObject(created, "POST skill");
    try expectStr(skill, "name", "pdf", "created skill");
    try expectStr(skill, "description", "Work with PDFs.", "created skill");
    // BYTE-EXACT, frontmatter included.
    try expectStr(skill, "content", BODY, "created skill (body must round-trip byte-exact)");
    try expectInt(skill, "asset_count", 0, "created skill");

    // And it is really there: the next read sees it.
    const detail_raw = try detailSkillBody(&h, ws, "pdf");
    defer gpa.free(detail_raw);
    var ddoc = try parseJson(detail_raw);
    defer ddoc.deinit();
    const detail = try rootObject(&ddoc, "GET created skill");
    const dskill = try skillObject(detail, "GET created skill");
    try expectStr(dskill, "content", BODY, "re-read skill");
}

// The empty-slice-as-NULL trap, on the wire. `SqliteBackend.exec` binds `""`
// as SQL NULL, and `skills.description` is NOT NULL.
test "create_with_an_empty_description_round_trips_as_empty_not_as_a_500" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-empty-desc");
    defer gpa.free(ws);

    const created_raw = try createSkillBody(&h, ws, "half-written", "", BODY, &.{201});
    defer gpa.free(created_raw);
    var doc = try parseJson(created_raw);
    defer doc.deinit();
    const created = try rootObject(&doc, "POST skill (empty description)");
    const skill = try skillObject(created, "POST skill (empty description)");

    // `""`, not `null` and not a missing key: a null would render a blank
    // list row indistinguishable from a bug.
    try expectStr(skill, "description", "", "created skill");
    try expectStr(skill, "content", BODY, "created skill");
}

// A duplicate name in the SAME workspace is refused, and the stored body is
// not replaced.
test "create_of_a_duplicate_name_is_409_and_does_not_overwrite" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-dupe");
    defer gpa.free(ws);

    {
        const raw = try createSkillBody(&h, ws, "pdf", "first", "first body", &.{201});
        defer gpa.free(raw);
    }

    const dupe_raw = try createSkillBody(&h, ws, "pdf", "second", "second body", &.{409});
    defer gpa.free(dupe_raw);
    var doc = try parseJson(dupe_raw);
    defer doc.deinit();
    const dupe = try rootObject(&doc, "POST duplicate skill");
    // The message names the skill, so the UI can say which row to change.
    try expectError(dupe, "a skill named 'pdf' already exists in this workspace", "duplicate");

    // The duplicate must not have half-applied.
    const detail_raw = try detailSkillBody(&h, ws, "pdf");
    defer gpa.free(detail_raw);
    var ddoc = try parseJson(detail_raw);
    defer ddoc.deinit();
    const detail = try rootObject(&ddoc, "GET after duplicate");
    const skill = try skillObject(detail, "GET after duplicate");
    try expectStr(skill, "content", "first body", "after duplicate");
}

// The same name in a SECOND workspace is not a duplicate. Names are unique
// per workspace, not per database — two workspaces are two different tenants
// and each keeps its own `pdf`.
test "create_of_a_name_that_exists_in_another_workspace_succeeds" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_a = try createWorkspace(&h, "skills-scope-a");
    defer gpa.free(ws_a);
    const ws_b = try createWorkspace(&h, "skills-scope-b");
    defer gpa.free(ws_b);

    {
        const raw = try createSkillBody(&h, ws_a, "pdf", "A's copy", "A's body", &.{201});
        defer gpa.free(raw);
    }

    // A foreign name must NOT be reported as a conflict: a 409 here would
    // confirm the name exists in another workspace, which is the leak the
    // scoping exists to hide.
    const raw = try createSkillBody(&h, ws_b, "pdf", "B's copy", "B's body", &.{201});
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();
    const created = try rootObject(&doc, "POST skill in ws_b");
    const skill = try skillObject(created, "POST skill in ws_b");
    try expectStr(skill, "content", "B's body", "ws_b skill");

    // And A's copy is untouched.
    const a_raw = try detailSkillBody(&h, ws_a, "pdf");
    defer gpa.free(a_raw);
    var adoc = try parseJson(a_raw);
    defer adoc.deinit();
    const a = try rootObject(&adoc, "GET ws_a skill");
    const askill = try skillObject(a, "GET ws_a skill");
    try expectStr(askill, "content", "A's body", "ws_a skill");
}

// A name the grammar cannot spell is a 400, not a 500 and not a write. `name`
// is joined onto a materialisation directory by `use_skill`, so `..` and
// `a/b` would escape it. The grammar is the guard.
test "create_of_an_invalid_name_is_400_and_writes_nothing" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-bad-name");
    defer gpa.free(ws);

    for ([_][]const u8{ "..", "a/b", "has space", ".hidden", "trailing." }) |bad| {
        const raw = try createSkillBody(&h, ws, bad, "d", "body", &.{400});
        defer gpa.free(raw);
        var doc = try parseJson(raw);
        defer doc.deinit();
        const body = try rootObject(&doc, "POST invalid name");
        try expectError(body, "name must be 1-128 characters of letters, digits, dot, dash or underscore", "invalid name");
    }

    // Nothing was written on the way to any of those errors.
    const listed_raw = try listSkillsBody(&h, ws);
    defer gpa.free(listed_raw);
    var ldoc = try parseJson(listed_raw);
    defer ldoc.deinit();
    const listed = try rootObject(&ldoc, "GET skills after invalid names");
    const arr = try skillsArray(listed, "GET skills after invalid names");
    if (arr.items.len != 0) {
        std.debug.print("an invalid name still wrote a row: {s}\n", .{listed_raw});
        return error.TestUnexpectedResult;
    }
}

// A blank name is a 400 with a message the form can show.
test "create_with_a_blank_name_is_400" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-blank-name");
    defer gpa.free(ws);

    const raw = try createSkillBody(&h, ws, "   ", "d", "body", &.{400});
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();
    const body = try rootObject(&doc, "POST blank name");
    try expectError(body, "name is required", "blank name");
}

// The happy patch, asserted on the wire. The edit form ALWAYS sends both
// fields, so this is also the proof that the handler forwards both: a handler
// that dropped one would blank it.
test "patch_updates_the_description_and_the_body" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-patch");
    defer gpa.free(ws);
    {
        const raw = try createSkillBody(&h, ws, "pdf", "old description", "old body", &.{201});
        defer gpa.free(raw);
    }

    const patched_raw = try patchSkillBody(&h, ws, "pdf", "new description", "new body", &.{200});
    defer gpa.free(patched_raw);
    var doc = try parseJson(patched_raw);
    defer doc.deinit();
    const patched = try rootObject(&doc, "PATCH skill");
    const skill = try skillObject(patched, "PATCH skill");
    try expectStr(skill, "name", "pdf", "patched skill");
    try expectStr(skill, "description", "new description", "patched skill");
    try expectStr(skill, "content", "new body", "patched skill");

    // And the next read agrees — the response is not a fabricated echo.
    const detail_raw = try detailSkillBody(&h, ws, "pdf");
    defer gpa.free(detail_raw);
    var ddoc = try parseJson(detail_raw);
    defer ddoc.deinit();
    const detail = try rootObject(&ddoc, "GET patched skill");
    const dskill = try skillObject(detail, "GET patched skill");
    try expectStr(dskill, "description", "new description", "re-read patched skill");
    try expectStr(dskill, "content", "new body", "re-read patched skill");
}

// A patch that clears a field is honoured, not treated as "keep".
test "patch_with_an_empty_description_clears_it_rather_than_keeping_it" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-clear-desc");
    defer gpa.free(ws);
    {
        const raw = try createSkillBody(&h, ws, "pdf", "a description", "a body", &.{201});
        defer gpa.free(raw);
    }

    const patched_raw = try patchSkillBody(&h, ws, "pdf", "", "a body", &.{200});
    defer gpa.free(patched_raw);
    var doc = try parseJson(patched_raw);
    defer doc.deinit();
    const patched = try rootObject(&doc, "PATCH skill (clear description)");
    const skill = try skillObject(patched, "PATCH skill (clear description)");
    try expectStr(skill, "description", "", "patched skill");
    // The body was NOT cleared along with it.
    try expectStr(skill, "content", "a body", "patched skill");
}

// A patch that changes nothing is a 409, not a 200.
//
// A 200 here would render a saved-looking pane that saved nothing.
test "patch_with_no_change_is_409" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-noop-patch");
    defer gpa.free(ws);
    {
        const raw = try createSkillBody(&h, ws, "pdf", "same", "same body", &.{201});
        defer gpa.free(raw);
    }

    const patched_raw = try patchSkillBody(&h, ws, "pdf", "same", "same body", &.{409});
    defer gpa.free(patched_raw);
    var doc = try parseJson(patched_raw);
    defer doc.deinit();
    const patched = try rootObject(&doc, "PATCH skill (no change)");
    try expectError(patched, "nothing to change — the skill already holds these values", "no change");
}

// A foreign name is 404, never 403, and nothing is written. A 403 would
// confirm the name exists, which is the one thing workspace scoping exists to
// withhold.
test "patch_from_a_foreign_workspace_is_404_and_changes_nothing" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_a = try createWorkspace(&h, "skills-patch-a");
    defer gpa.free(ws_a);
    const ws_b = try createWorkspace(&h, "skills-patch-b");
    defer gpa.free(ws_b);
    {
        const raw = try createSkillBody(&h, ws_a, "pdf", "A's copy", "A's body", &.{201});
        defer gpa.free(raw);
    }

    const patched_raw = try patchSkillBody(&h, ws_b, "pdf", "stolen", "stolen body", &.{404});
    defer gpa.free(patched_raw);
    var doc = try parseJson(patched_raw);
    defer doc.deinit();
    const patched = try rootObject(&doc, "PATCH foreign skill");
    // The SAME message as a name that does not exist.
    try expectError(patched, "skill not found", "foreign patch");

    const a_raw = try detailSkillBody(&h, ws_a, "pdf");
    defer gpa.free(a_raw);
    var adoc = try parseJson(a_raw);
    defer adoc.deinit();
    const a = try rootObject(&adoc, "GET ws_a after foreign patch");
    const askill = try skillObject(a, "GET ws_a after foreign patch");
    try expectStr(askill, "content", "A's body", "ws_a skill");
}

// An unknown name is a clean 404.
test "patch_of_an_unknown_name_is_404" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-patch-unknown");
    defer gpa.free(ws);

    const patched_raw = try patchSkillBody(&h, ws, "ghost", "d", "body", &.{404});
    defer gpa.free(patched_raw);
    var doc = try parseJson(patched_raw);
    defer doc.deinit();
    const patched = try rootObject(&doc, "PATCH unknown skill");
    try expectError(patched, "skill not found", "unknown patch");
}

// A rename attempt is refused, and the body is left as it was. The name is
// the `use_skill({ name })` argument and the `skill_eval` identity, so a
// rename would break both silently.
test "patch_that_tries_to_rename_is_404_and_leaves_the_body" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-rename");
    defer gpa.free(ws);
    {
        const raw = try createSkillBody(&h, ws, "pdf", "a description", "the body that must survive", &.{201});
        defer gpa.free(raw);
    }

    // The edit form never sends a `name`, so this body is hand-built: it is
    // what a client that tried to rename would put on the wire.
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = "pdf-renamed",
        .description = "a description",
        .content = "never applied",
    }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/skills/pdf", .{ws});
    defer gpa.free(path);

    var r = try h.http(io, .PATCH, path, .{ .json_body = body, .expect = &.{404} });
    defer r.deinit();

    const detail_raw = try detailSkillBody(&h, ws, "pdf");
    defer gpa.free(detail_raw);
    var ddoc = try parseJson(detail_raw);
    defer ddoc.deinit();
    const detail = try rootObject(&ddoc, "GET after rename attempt");
    const skill = try skillObject(detail, "GET after rename attempt");
    try expectStr(skill, "content", "the body that must survive", "after rename attempt");

    // And the new name was not created alongside it.
    const gone_raw = try detailSkillBody(&h, ws, "pdf-renamed");
    defer gpa.free(gone_raw);
    var gdoc = try parseJson(gone_raw);
    defer gdoc.deinit();
    const gone = try rootObject(&gdoc, "GET renamed skill");
    try expectStr(gone, "error_message", "skill not found", "renamed skill");
}

// The list reflects a create made over HTTP. The old handlers re-read a
// directory on every request, so a filesystem change showed up immediately.
test "a_skill_created_over_http_is_visible_to_the_next_list" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-create-then-list");
    defer gpa.free(ws);

    {
        const listed_raw = try listSkillsBody(&h, ws);
        defer gpa.free(listed_raw);
        var doc = try parseJson(listed_raw);
        defer doc.deinit();
        const listed = try rootObject(&doc, "first GET skills");
        const arr = try skillsArray(listed, "first GET skills");
        if (arr.items.len != 0) {
            std.debug.print("a fresh workspace should hold no skills: {s}\n", .{listed_raw});
            return error.TestUnexpectedResult;
        }
    }

    {
        const raw = try createSkillBody(&h, ws, "created-over-http", "Written over the wire.", BODY, &.{201});
        defer gpa.free(raw);
    }

    const listed_raw = try listSkillsBody(&h, ws);
    defer gpa.free(listed_raw);
    var doc = try parseJson(listed_raw);
    defer doc.deinit();
    const listed = try rootObject(&doc, "second GET skills");
    const arr = try skillsArray(listed, "second GET skills");
    if (arr.items.len != 1) {
        std.debug.print("expected 1 skill, got {d}: {s}\n", .{ arr.items.len, listed_raw });
        return error.TestUnexpectedResult;
    }
    const row = findByName(arr, "created-over-http") orelse {
        std.debug.print("no skill named created-over-http: {s}\n", .{listed_raw});
        return error.TestUnexpectedResult;
    };
    try expectStr(row, "description", "Written over the wire.", "list row");
}

// A patch is visible to the list too. The description is the list row's
// second line, so an edit that changed it has to show up there or the two
// halves disagree about the same skill.
test "a_patch_is_visible_to_the_next_list" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-patch-then-list");
    defer gpa.free(ws);
    {
        const raw = try createSkillBody(&h, ws, "pdf", "old description", "body", &.{201});
        defer gpa.free(raw);
    }
    {
        const raw = try patchSkillBody(&h, ws, "pdf", "new description", "body", &.{200});
        defer gpa.free(raw);
    }

    const listed_raw = try listSkillsBody(&h, ws);
    defer gpa.free(listed_raw);
    var doc = try parseJson(listed_raw);
    defer doc.deinit();
    const listed = try rootObject(&doc, "GET skills after patch");
    const arr = try skillsArray(listed, "GET skills after patch");
    const row = findByName(arr, "pdf") orelse {
        std.debug.print("no skill named pdf: {s}\n", .{listed_raw});
        return error.TestUnexpectedResult;
    };
    try expectStr(row, "description", "new description", "list row after patch");
}

// The write routes are scoped, and the OLD collection route is still gone. A
// bare `/api/skills` has no workspace to scope to, which is why it was
// removed.
test "the_write_routes_are_reachable_only_under_a_workspace" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "skills-write-scope");
    defer gpa.free(ws);

    // The old collection route answers neither verb.
    {
        var r = try h.http(io, .POST, "/api/skills", .{
            .json_body = "{\"name\":\"pdf\",\"content\":\"x\"}",
            .expect = &.{404},
        });
        defer r.deinit();
    }
    {
        var r = try h.http(io, .PATCH, "/api/skills/pdf", .{
            .json_body = "{\"content\":\"x\"}",
            .expect = &.{404},
        });
        defer r.deinit();
    }

    // The workspace-scoped pair does.
    {
        const raw = try createSkillBody(&h, ws, "scoped", "d", "body", &.{201});
        defer gpa.free(raw);
    }
    {
        const raw = try patchSkillBody(&h, ws, "scoped", "d2", "body2", &.{200});
        defer gpa.free(raw);
    }
}

comptime {
    // Body-analysis barrier — see `harness.zig`'s note: an unreferenced
    // function body is never type-checked, so a stdlib rename inside one
    // stays invisible until a caller appears.
    _ = createSkillBody;
    _ = patchSkillBody;
    _ = detailSkillBody;
    _ = listSkillsBody;
    _ = createWorkspace;
    _ = parseJson;
    _ = rootObject;
    _ = skillObject;
    _ = expectStr;
    _ = expectInt;
    _ = expectError;
    _ = skillsArray;
    _ = findByName;
}
