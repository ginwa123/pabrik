const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const SystemFolder = pabrikcore.system_folder.SystemFolder;
const SystemFolderError = pabrikcore.system_folder.SystemFolderError;
const FolderEntry = pabrikcore.system_folder.FolderEntry;

/// Escape special characters for JSON string values
fn jsonEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);
    for (value) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => try result.append(allocator, c),
        }
    }
    return try result.toOwnedSlice(allocator);
}

/// Serialize entries into the JSON array literal used on the wire:
/// `[{"name":...,"path":...,"is_directory":...,"is_symlink":...},...]`.
pub fn buildEntriesJson(allocator: std.mem.Allocator, entries: []const FolderEntry) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (entries, 0..) |entry, i| {
        if (i > 0) try out.append(allocator, ',');
        const escaped_name = jsonEscape(allocator, entry.name) catch "";
        defer allocator.free(escaped_name);
        const escaped_path = jsonEscape(allocator, entry.path) catch "";
        defer allocator.free(escaped_path);
        try out.appendSlice(allocator, "{\"name\":\"");
        try out.appendSlice(allocator, escaped_name);
        try out.appendSlice(allocator, "\",\"path\":\"");
        try out.appendSlice(allocator, escaped_path);
        try out.appendSlice(allocator, "\",\"is_directory\":");
        try out.appendSlice(allocator, if (entry.is_directory) "true" else "false");
        try out.appendSlice(allocator, ",\"is_symlink\":");
        try out.appendSlice(allocator, if (entry.is_symlink) "true" else "false");
        try out.append(allocator, '}');
    }
    return out.toOwnedSlice(allocator);
}

/// Render the `{path, absolute, home[, parent][, entries]}` body.
fn printFolderJson(
    allocator: std.mem.Allocator,
    relative: []const u8,
    absolute: []const u8,
    home: []const u8,
    parent: ?[]const u8,
    entries_json: ?[]const u8,
) ![]u8 {
    const esc_rel = try jsonEscape(allocator, relative);
    defer allocator.free(esc_rel);
    const esc_abs = try jsonEscape(allocator, absolute);
    defer allocator.free(esc_abs);
    const esc_home = try jsonEscape(allocator, home);
    defer allocator.free(esc_home);

    if (parent) |pr| {
        const esc_parent = try jsonEscape(allocator, pr);
        defer allocator.free(esc_parent);
        if (entries_json) |entries| {
            return std.fmt.allocPrint(allocator,
                "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"parent\":\"{s}\",\"entries\":[{s}]}}",
                .{ esc_rel, esc_abs, esc_home, esc_parent, entries });
        }
        return std.fmt.allocPrint(allocator,
            "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"parent\":\"{s}\"}}",
            .{ esc_rel, esc_abs, esc_home, esc_parent });
    }
    if (entries_json) |entries| {
        return std.fmt.allocPrint(allocator,
            "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"entries\":[{s}]}}",
            .{ esc_rel, esc_abs, esc_home, entries });
    }
    return std.fmt.allocPrint(allocator,
        "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\"}}",
        .{ esc_rel, esc_abs, esc_home });
}

/// `action=list` body -- always carries `entries`.
pub fn buildFolderListJson(
    allocator: std.mem.Allocator,
    relative: []const u8,
    absolute: []const u8,
    home: []const u8,
    parent: ?[]const u8,
    entries_json: []const u8,
) ![]u8 {
    return printFolderJson(allocator, relative, absolute, home, parent, entries_json);
}

/// Body for a request with no `action` (or an unknown one) -- that shape
/// has no `entries` key. Kept byte-compatible with the pre-refactor
/// response so an existing client cannot notice the change.
pub fn buildFolderInfoJson(
    allocator: std.mem.Allocator,
    relative: []const u8,
    absolute: []const u8,
    home: []const u8,
    parent: ?[]const u8,
) ![]u8 {
    return printFolderJson(allocator, relative, absolute, home, parent, null);
}

/// System folder endpoint GET /api/system/folder GET
/// /api/system/folder?path=/some/relative/path GET
/// /api/system/folder?path=/some/relative/path&action=list GET
pub fn systemFolderHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const path_param = req.query.get("path");
    const action = req.query.get("action");
    const do_list = std.mem.eql(u8, action orelse "", "list");

    if (path_param) |p| {
        if (p.len == 0 and std.mem.eql(u8, action orelse "", "search")) {
            return res.jsonResponse( .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "path required" }) });
        }
    }

    const di = try pabrikcore.getSingleton();
    const environment = di.environment;


    const home = SystemFolder.getHomeDirectory(allocator, environment) catch |err| {
        return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeSystemFolderErrorResponse(allocator, "Failed to get home directory", err) });
    };

    const target_path: []u8 = if (path_param) |p|
        SystemFolder.resolvePath(allocator, p, environment) catch |err| {
            return res.jsonResponse( .{ .status_code = 400, .data = try http_response.makeSystemFolderErrorResponse(allocator, "Invalid path", err) });
        }
    else blk: {
        const dup = allocator.dupe(u8, home) catch {
            return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }) });
        };
        break :blk dup;
    };

    if (!std.fs.path.isAbsolute(target_path)) {
        if (path_param != null) {
            return res.jsonResponse( .{ .status_code = 400, .data = try http_response.makeSystemFolderErrorResponse(allocator, "path must be absolute", SystemFolderError.InvalidPath) });
        }
        return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeSystemFolderErrorResponse(allocator, "home directory must be absolute", SystemFolderError.InvalidPath) });
    }

    const relative = SystemFolder.getRelativePathFromHome(allocator, target_path, home) catch |err| {
        return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeSystemFolderErrorResponse(allocator, "Failed to compute relative path", err) });
    };

    const parent_opt = SystemFolder.getParentPath(allocator, target_path, environment) catch null;
    const parent_relative = if (parent_opt) |parent|
        SystemFolder.getRelativePathFromHome(allocator, parent, home) catch null
    else
        null;

    if (do_list) {
        const entries = SystemFolder.listDirectory(allocator, ctx.io, target_path) catch |err| {
            const err_msg: []const u8 = switch (err) {
                SystemFolderError.InvalidPath => "Directory not found",
                SystemFolderError.AccessDenied => "Access denied",
                SystemFolderError.NotDirectory => "Not a directory",
                else => @errorName(err),
            };
            return res.jsonResponse( .{ .status_code = 403, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = err_msg }) });
        };
        defer {
            for (entries) |entry| {
                allocator.free(entry.name);
                allocator.free(entry.path);
            }
            allocator.free(entries);
        }

        // Build entries JSON via the shared serializer (the search
        // branch below uses the same one).
        const entries_json = try buildEntriesJson(allocator, entries);
        defer allocator.free(entries_json);

        return res.jsonResponse(.{ .status_code = 200, .data = try buildFolderListJson(
            allocator,
            relative,
            target_path,
            home,
            parent_relative,
            entries_json,
        ) });
    }

 // Recursive server-side search for the ChatView `@` picker: GET
 // /api/system/folder?action=search&path=<root>&q=comp&limit=50 Same route as
 // list (no new main.zig registration); same entry shape ({name, path,
    const do_search = std.mem.eql(u8, action orelse "", "search");
    if (do_search) {
        const q = req.query.get("q") orelse "";
        const limit = SystemFolder.parseSearchLimit(req.query.get("limit"));
        const max_depth = SystemFolder.parseSearchMaxDepth(req.query.get("max_depth"));

        const entries = SystemFolder.searchFiles(allocator, ctx.io, target_path, q, limit, max_depth) catch |err| {
            const err_msg: []const u8 = switch (err) {
                SystemFolderError.InvalidPath => "Directory not found",
                SystemFolderError.AccessDenied => "Access denied",
                SystemFolderError.NotDirectory => "Not a directory",
                else => @errorName(err),
            };
            return res.jsonResponse( .{ .status_code = 403, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = err_msg }) });
        };
        defer {
            for (entries) |entry| {
                allocator.free(entry.name);
                allocator.free(entry.path);
            }
            allocator.free(entries);
        }

        // Build entries JSON via the same serializer the list branch
        // uses -- SAME wire shape for both.
        const search_entries_json = try buildEntriesJson(allocator, entries);
        defer allocator.free(search_entries_json);

        return res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
            "{{\"entries\":[{s}]}}",
            .{search_entries_json}) });
    }

    // Handle read/write actions - read file content
    const do_read_write = std.mem.eql(u8, action orelse "", "read") or std.mem.eql(u8, action orelse "", "write");
    if (do_read_write) {
        const file_name = req.query.get("file") orelse "";

        // Use native absolute-path semantics. A Windows-looking path on
        // POSIX (or a drive-relative `C:file` on Windows) is not absolute
        // and must be joined to the already-validated base path.
        const is_abs = std.fs.path.isAbsolute(file_name);
        const full_path: []u8 = if (is_abs)
            allocator.dupe(u8, file_name) catch return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }) })
        else
            std.fs.path.join(allocator, &.{ target_path, file_name }) catch return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to build path" }) });
        defer allocator.free(full_path);

        if (!std.fs.path.isAbsolute(full_path)) {
            return res.jsonResponse( .{ .status_code = 403, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Cannot open file" }) });
        }

        // Read file using std.Io.Dir.openFileAbsolute
        const file = std.Io.Dir.openFileAbsolute(ctx.io, full_path, .{}) catch return res.jsonResponse( .{ .status_code = 403, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Cannot open file" }) });
        defer file.close(ctx.io);

        var read_buf: [8192]u8 = undefined;
        var reader = file.reader(ctx.io, &read_buf);
        const file_content_init = reader.interface.allocRemaining(allocator, .limited(1024 * 1024 * 10)) catch return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to read file" }) });
        defer allocator.free(file_content_init);

        // Escape content for JSON
        const escaped_content = jsonEscape(allocator, file_content_init) catch file_content_init;
        defer allocator.free(escaped_content);

        // Return as JSON with plain text content
        return res.jsonResponse( .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
            "{{\"content\":\"{s}\",\"encoding\":\"utf-8\"}}",
            .{ escaped_content }) });
    }

    // No recognised action: return the location WITHOUT an `entries`
    // key -- that shape predates the list/search split, so keep it.
    return res.jsonResponse(.{ .status_code = 200, .data = try buildFolderInfoJson(
        allocator,
        relative,
        target_path,
        home,
        parent_relative,
    ) });
}

// ===== Tests merged from system_folder_search_test.zig (2026-09-11 flatten)
// ===== Static-contract tests for `action=search` on GET /api/system/folder
// (plan: docs/superpowers/plans/2026-09-08-chatview-search-files-perf.md,

const testing = std.testing;

// ===== Behavioural tests: the Windows wire format ========================
// These guard the wire format: none of them would notice if the response body
// stopped being valid JSON.

/// Parse a built body and return the value, so a body that is not JSON
/// fails the test instead of silently comparing as text.
fn parseBody(allocator: std.mem.Allocator, body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, body, .{});
}

test "buildFolderListJson: Windows backslash paths round-trip through JSON" {
    const allocator = testing.allocator;
    const entries = try allocator.dupe(FolderEntry, &.{
        .{ .name = try allocator.dupe(u8, "Documents"), .path = try allocator.dupe(u8, "C:\\Users\\ginwa\\Documents"), .is_directory = true, .is_symlink = false },
    });
    defer {
        for (entries) |e| {
            allocator.free(e.name);
            allocator.free(e.path);
        }
        allocator.free(entries);
    }
    const entries_json = try buildEntriesJson(allocator, entries);
    defer allocator.free(entries_json);

    const body = try buildFolderListJson(
        allocator,
        "/Documents",
        "C:\\Users\\ginwa\\Documents",
        "C:\\Users\\ginwa",
        "/",
        entries_json,
    );
    defer allocator.free(body);

    // The raw text must carry DOUBLED backslashes — this is the exact
    // property that was lost before, and `std.json` below is what proves
    // the doubling was necessary in the first place.
    try testing.expect(std.mem.indexOf(u8, body, "C:\\\\Users\\\\ginwa") != null);

    const parsed = try parseBody(allocator, body);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("/Documents", obj.get("path").?.string);
    try testing.expectEqualStrings("C:\\Users\\ginwa\\Documents", obj.get("absolute").?.string);
    try testing.expectEqualStrings("C:\\Users\\ginwa", obj.get("home").?.string);
    try testing.expectEqualStrings("/", obj.get("parent").?.string);

    const rows = obj.get("entries").?.array;
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("Documents", rows.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("C:\\Users\\ginwa\\Documents", rows.items[0].object.get("path").?.string);
    try testing.expectEqual(true, rows.items[0].object.get("is_directory").?.bool);
    try testing.expectEqual(false, rows.items[0].object.get("is_symlink").?.bool);
}

test "buildFolderListJson: a raw (unescaped) interpolation would not be JSON" {
    // The control for the test above. Same values, interpolated the way
    // the handler used to, MUST fail to parse — otherwise the escaping
    // assertion above proves nothing.
    var bad = std.ArrayList(u8).empty;
    defer bad.deinit(testing.allocator);
    try bad.appendSlice(testing.allocator,
        "{\"path\":\"/Documents\",\"absolute\":\"C:\\Users\\ginwa\",\"home\":\"C:\\Users\\ginwa\"}");
    // Any parse failure is the point — the exact error type is a stdlib
    // detail (`\U` is an invalid escape), not the contract.
    if (parseBody(testing.allocator, bad.items)) |ok| {
        var parsed = ok;
        defer parsed.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "buildFolderListJson: UNC home round-trips (redirected Windows profile)" {
    const allocator = testing.allocator;
    const body = try buildFolderListJson(
        allocator,
        "/Documents",
        "\\\\fileserver\\share\\ginwa\\Documents",
        "\\\\fileserver\\share\\ginwa",
        "/",
        "",
    );
    defer allocator.free(body);

    const parsed = try parseBody(allocator, body);
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "\\\\fileserver\\share\\ginwa",
        parsed.value.object.get("home").?.string,
    );
    try testing.expectEqualStrings(
        "\\\\fileserver\\share\\ginwa\\Documents",
        parsed.value.object.get("absolute").?.string,
    );
}

test "buildFolderInfoJson: no-action body keeps its shape (no entries key)" {
    const allocator = testing.allocator;

    const with_parent = try buildFolderInfoJson(
        allocator,
        "/Documents",
        "C:\\Users\\ginwa\\Documents",
        "C:\\Users\\ginwa",
        "/",
    );
    defer allocator.free(with_parent);
    {
        const parsed = try parseBody(allocator, with_parent);
        defer parsed.deinit();
        try testing.expectEqualStrings("/Documents", parsed.value.object.get("path").?.string);
        try testing.expectEqualStrings("C:\\Users\\ginwa", parsed.value.object.get("home").?.string);
        try testing.expectEqualStrings("/", parsed.value.object.get("parent").?.string);
        try testing.expect(parsed.value.object.get("entries") == null);
    }

    // The home root: `getParentPath` returns null there, so the body has
    // no `parent` key at all. Asserted separately so adding one later is
    // a deliberate wire change.
    const at_home = try buildFolderInfoJson(
        allocator,
        "/",
        "C:\\Users\\ginwa",
        "C:\\Users\\ginwa",
        null,
    );
    defer allocator.free(at_home);
    const parsed = try parseBody(allocator, at_home);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("parent") == null);
    try testing.expect(parsed.value.object.get("entries") == null);
    try testing.expectEqualStrings("C:\\Users\\ginwa", parsed.value.object.get("absolute").?.string);
}

test "buildEntriesJson: empty entry list renders an empty array" {
    const allocator = testing.allocator;
    const json = try buildEntriesJson(allocator, &.{});
    defer allocator.free(json);
    try testing.expectEqualStrings("", json);

    const body = try buildFolderListJson(allocator, "/", "/home/u", "/home/u", null, json);
    defer allocator.free(body);
    const parsed = try parseBody(allocator, body);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("entries").?.array.items.len);
}
