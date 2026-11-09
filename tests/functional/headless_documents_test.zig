//! Wire test: `pabrik headless documents …` drives the real folder backend with
//! no port of its own. The workspace comes from HTTP, then every op runs through
//! the binary against the same isolated HOME.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

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

const Run = struct {
    result: harness.RunResult,
    parsed: ?std.json.Parsed(std.json.Value) = null,

    /// The single JSON object the command printed. Parsed once, freed in
    /// `deinit`.
    fn json(self: *Run) !*const std.json.Value {
        if (self.parsed == null) {
            self.parsed = try std.json.parseFromSlice(std.json.Value, gpa, self.result.stdout, .{});
        }
        return &self.parsed.?.value;
    }

    fn deinit(self: *Run) void {
        if (self.parsed) |*p| p.deinit();
        self.result.deinit(gpa);
    }
};

/// One `headless documents` invocation against the harness HOME.
fn documents(h: *Harness, argv: []const []const u8, expect_ok: bool) !Run {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, &.{ "headless", "documents" });
    try full.appendSlice(gpa, argv);

    var result = try harness.runPabrikCommand(io, gpa, h.temp_dir, full.items, 60_000);

    if (expect_ok and result.exit_code != 0) {
        std.debug.print(
            "headless documents failed ({?d})\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
            .{ result.exit_code, result.stdout, result.stderr },
        );
        result.deinit(gpa);
        return error.TestUnexpectedResult;
    }
    return .{ .result = result };
}

fn stringField(value: *const std.json.Value, key: []const u8) ![]const u8 {
    return (value.object.get(key) orelse return error.TestUnexpectedResult).string;
}

fn intField(value: *const std.json.Value, key: []const u8) !i64 {
    return (value.object.get(key) orelse return error.TestUnexpectedResult).integer;
}

test "headless documents: a folder tree round-trips, and deleting a folder keeps its document" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "folders-headless");
    defer gpa.free(ws);

    // 1. A root folder.
    var root_run = try documents(&h, &.{ "folder-create", "--workspace", ws, "--name", "Sales debit note" }, true);
    defer root_run.deinit();
    const root_doc = try root_run.json();
    const root_id = try gpa.dupe(u8, try stringField(root_doc, "id"));
    defer gpa.free(root_id);
    try testing.expect((root_doc.object.get("parent_id") orelse return error.TestUnexpectedResult) == .null);

    // 2. A folder inside it.
    var child_run = try documents(&h, &.{
        "folder-create", "--workspace", ws, "--name", "Split bill", "--parent", root_id,
    }, true);
    defer child_run.deinit();
    const child_doc = try child_run.json();
    const child_id = try gpa.dupe(u8, try stringField(child_doc, "id"));
    defer gpa.free(child_id);
    try testing.expectEqualStrings(root_id, try stringField(child_doc, "parent_id"));

    // 3. A document inside the child folder.
    var doc_run = try documents(&h, &.{
        "doc-create", "--workspace", ws, "--title", "POST split-bill", "--folder", child_id,
    }, true);
    defer doc_run.deinit();
    const doc_doc = try doc_run.json();
    try testing.expectEqualStrings(child_id, try stringField(doc_doc, "folder_id"));

    // 4. One read returns both levels and the placement.
    var list_run = try documents(&h, &.{ "list", "--workspace", ws }, true);
    defer list_run.deinit();
    const list_doc = try list_run.json();
    try testing.expectEqual(@as(i64, 2), try intField(list_doc, "folder_count"));
    try testing.expectEqual(@as(i64, 1), try intField(list_doc, "document_count"));
    try testing.expectEqualStrings(child_id, try stringField(&list_doc.object.get("documents").?.array.items[0], "folder_id"));

    // 5. Delete the child folder: the document survives, one level up (its
    //    grandparent is the root folder, not the root of the sidebar).
    var del_run = try documents(&h, &.{ "folder-delete", "--workspace", ws, "--folder", child_id }, true);
    defer del_run.deinit();
    const del_doc = try del_run.json();
    try testing.expectEqual(@as(i64, 1), try intField(del_doc, "reparented_documents"));

    var after_run = try documents(&h, &.{ "list", "--workspace", ws }, true);
    defer after_run.deinit();
    const after_doc = try after_run.json();
    try testing.expectEqual(@as(i64, 1), try intField(after_doc, "folder_count"));
    try testing.expectEqual(@as(i64, 1), try intField(after_doc, "document_count"));
    const documents_json = (after_doc.object.get("documents") orelse return error.TestUnexpectedResult).array;
    try testing.expectEqual(@as(usize, 1), documents_json.items.len);
    try testing.expectEqualStrings(root_id, try stringField(&documents_json.items[0], "folder_id"));

    // 6. A folder cannot be moved inside itself. The refusal is a non-zero
    //    exit with NOTHING on stdout: a machine caller must never read a
    //    half-written object, and nothing may be written to the row.
    var refused = try documents(&h, &.{
        "folder-move", "--workspace", ws, "--folder", root_id, "--parent", root_id,
    }, false);
    defer refused.deinit();
    try testing.expect(refused.result.exit_code != 0);
    try testing.expectEqualStrings("", refused.result.stdout);

    var final_run = try documents(&h, &.{ "list", "--workspace", ws }, true);
    defer final_run.deinit();
    const final_doc = try final_run.json();
    const folders = (final_doc.object.get("folders") orelse return error.TestUnexpectedResult).array;
    try testing.expectEqual(@as(usize, 1), folders.items.len);
    try testing.expect((folders.items[0].object.get("parent_id") orelse return error.TestUnexpectedResult) == .null);
}

test "headless documents: doc-create --format office stores a spreadsheet, and an unknown format is refused" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "office-headless");
    defer gpa.free(ws);

    const snapshot =
        \\{"sheets":{"s1":{"cellData":{"0":{"0":{"v":"Q3 budget"},"1":{"v":1200}}}}}}
    ;

    var created = try documents(&h, &.{
        "doc-create", "--workspace", ws, "--title", "Budget", "--format", "office", "--content", snapshot,
    }, true);
    defer created.deinit();
    const created_doc = try created.json();
    try testing.expectEqualStrings("office", try stringField(created_doc, "format"));
    const doc_id = try gpa.dupe(u8, try stringField(created_doc, "id"));
    defer gpa.free(doc_id);

    // The format survives a read, so the grid knows which editor to mount.
    var listed = try documents(&h, &.{ "list", "--workspace", ws }, true);
    defer listed.deinit();
    const list_doc = try listed.json();
    const rows = (list_doc.object.get("documents") orelse return error.TestUnexpectedResult).array;
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("office", try stringField(&rows.items[0], "format"));

    // A format the UI cannot render is a non-zero exit with nothing on stdout,
    // and it writes no row.
    var refused = try documents(&h, &.{
        "doc-create", "--workspace", ws, "--title", "Slides", "--format", "slides",
    }, false);
    defer refused.deinit();
    try testing.expect(refused.result.exit_code != 0);
    try testing.expectEqualStrings("", refused.result.stdout);

    var after = try documents(&h, &.{ "list", "--workspace", ws }, true);
    defer after.deinit();
    const after_doc = try after.json();
    try testing.expectEqual(@as(i64, 1), try intField(after_doc, "document_count"));
}
