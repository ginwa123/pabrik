// Wire tests for GET /api/system/folder against a real per-platform host. Zig
// port of `tests/functional/system_folder_home_test.py` (same test names,
// same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Fixtures
// ============================================================================

/// Content chosen to exercise every branch of the handler's `jsonEscape`: a
/// quote, a backslash, a tab and a newline.
const TRICKY_CONTENT = "quote \" backslash \\ tab \t newline \nend";

/// A scratch directory to hold the probe fixture tree, mirroring pytest's
/// `tmp_path`. Removed on the way out, whatever the test's outcome.
const Scratch = struct {
    root: []u8,

    fn init() !Scratch {
        return .{ .root = try harness.makeScratchDir(gpa) };
    }

    /// LIFO note: `cleanupExtraDir` READS `root`, so the free is
    /// registered first.
    fn deinit(self: *Scratch) void {
        harness.cleanupExtraDir(io, gpa, self.root);
        gpa.free(self.root);
    }

    fn path(self: *Scratch, parts: []const []const u8) ![]u8 {
        return harness.harnessPath(gpa, self.root, parts);
    }
};

fn writeFileAt(dir: std.Io.Dir, name: []const u8, contents: []const u8) !void {
    var f = try dir.createFile(io, name, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

/// `git init --initial-branch=main --quiet <root>`.
fn gitInit(root: []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        "git",                   "-c",                   "user.email=t@t", "-c", "user.name=t",
        "-c",                    "commit.gpgsign=false", "-C",             root, "init",
        "--initial-branch=main", "--quiet",
    });

    var child = std.process.spawn(io, .{ .argv = argv.items }) catch |err| {
        std.debug.print("git init did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    const term = child.wait(io) catch |err| {
        std.debug.print("git init did not wait: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("git init exited {d}\n", .{code});
            return error.TestUnexpectedResult;
        },
        else => {
            std.debug.print("git init died by signal\n", .{});
            return error.TestUnexpectedResult;
        },
    }
}

/// Python's `probe_root` fixture: a non-empty directory tree to point `path=`
/// at.
fn buildProbeRoot(s: *Scratch) ![]u8 {
    const root = try s.path(&.{"sf-probe"});
    errdefer gpa.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);

    const sub = try std.fs.path.join(gpa, &.{ root, "sub" });
    defer gpa.free(sub);
    try std.Io.Dir.cwd().createDirPath(io, sub);

    const child = try std.fs.path.join(gpa, &.{ sub, "child" });
    defer gpa.free(child);
    try std.Io.Dir.cwd().createDirPath(io, child);

    {
        var dir = try std.Io.Dir.cwd().openDir(io, sub, .{});
        defer dir.close(io);
        // Raw bytes, not text: a text-mode write would apply newline
        // translation, so the `\n` above would come back as `\r\n` on Windows
        // and the content assertion would fail on the one cell this file
        try writeFileAt(dir, "note.txt", TRICKY_CONTENT);
    }
    {
        const hidden = try std.fs.path.join(gpa, &.{ root, ".hidden" });
        defer gpa.free(hidden);
        var f = try std.Io.Dir.cwd().createFile(io, hidden, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "dotfiles are filtered out\n");
    }

    try gitInit(root);
    return root;
}

/// Python's `Path.as_posix()`: the identity on Linux, `C:/…` on Windows.
fn toPosix(path: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, path);
    errdefer gpa.free(out);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

// ============================================================================
// Wire helpers
// ============================================================================

/// Python's `_list`: `GET /api/system/folder?action=list[&path=…]`.
fn listFolder(h: *Harness, path: ?[]const u8) !harness.Response {
    var params: [2]Harness.Param = undefined;
    var n: usize = 1;
    params[0] = .{ .name = "action", .value = "list" };
    if (path) |p| {
        params[1] = .{ .name = "path", .value = p };
        n = 2;
    }
    return h.http(io, .GET, "/api/system/folder", .{
        .params = params[0..n],
        .expect = &.{200},
        .timeout_s = 15.0,
    });
}

/// A folder-listing response parsed into an owned `harness.Json` plus the
/// body it borrows from. Bundled so a caller cannot deinit one and forget
/// the other.
const Doc = struct {
    resp: harness.Response,
    json: harness.Json,

    fn deinit(self: *Doc) void {
        self.json.deinit();
        self.resp.deinit();
        self.* = undefined;
    }

    fn body(self: *const Doc) []const u8 {
        return self.resp.body;
    }
};

fn parseDoc(resp: harness.Response) !Doc {
    var d = Doc{ .resp = resp, .json = undefined };
    errdefer d.resp.deinit();
    d.json = try resp.json();
    return d;
}

/// `action=list` for `path`, parsed.
fn listFolderDoc(h: *Harness, path: ?[]const u8) !Doc {
    return parseDoc(try listFolder(h, path));
}

/// The entry in `entries` whose `name` is exactly `name`.
fn findEntry(entries: std.json.Array, name: []const u8) ?std.json.ObjectMap {
    for (entries.items) |item| {
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

fn entriesHaveName(entries: std.json.Array, name: []const u8) bool {
    return findEntry(entries, name) != null;
}

fn entriesOf(doc: *const Doc) !std.json.Array {
    return doc.json.array("entries") orelse {
        std.debug.print("folder response has no `entries` array: {s}\n", .{doc.body()});
        return error.TestUnexpectedResult;
    };
}

/// Assert an entry flag is present AND a boolean with the expected value.
fn expectObjBool(o: std.json.ObjectMap, key: []const u8, want: bool) !void {
    const got = switch (o.get(key) orelse {
        std.debug.print("entry is missing `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    }) {
        .bool => |b| b,
        else => {
            std.debug.print("`{s}` is not a bool\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
    if (got != want) {
        std.debug.print("`{s}` = {}, expected {}\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

fn expectEqualStr(doc: *const Doc, key: []const u8, want: []const u8) !void {
    const got = doc.json.str(key) orelse {
        std.debug.print("response has no string `{s}`: {s}\n", .{ key, doc.body() });
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("`{s}` = \"{s}\", expected \"{s}\"\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Tests
// ============================================================================

// The call the sidebar, the kanban picker and Android all make first. On
// native Windows (cmd/pwsh) `HOME` is unset — `getHomeDirectory` falls back
// to USERPROFILE then HOMEDRIVE+HOMEPATH.
test "action_list_with_no_path_reports_the_server_home" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var doc = try listFolderDoc(&h, null);
    defer doc.deinit();

    try expectEqualStr(&doc, "home", h.temp_dir);
    try expectEqualStr(&doc, "absolute", h.temp_dir);
    // Home itself is the root of the relative tree.
    try expectEqualStr(&doc, "path", "/");

    // `getParentPath` refuses to go above home, so there is no parent key
    // here. Asserted rather than assumed: a client that renders an "up"
    // button reads this key.
    if (doc.json.get("parent") != null) {
        std.debug.print("home must not carry a `parent`: {s}\n", .{doc.body()});
        return error.TestUnexpectedResult;
    }

    const entries = try entriesOf(&doc);
    _ = entries;

    if (!h.health(io)) {
        std.debug.print("server died while listing home\n", .{});
        return error.TestUnexpectedResult;
    }
}

// `?path=<home>` must be indistinguishable from the no-path form. This is the
// round-trip the frontend relies on: it renders `absolute` back into the next
// request.
test "explicit_home_path_matches_the_implicit_listing" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var implicit = try listFolderDoc(&h, null);
    defer implicit.deinit();
    var explicit = try listFolderDoc(&h, h.temp_dir);
    defer explicit.deinit();

    try expectEqualStr(&implicit, "home", h.temp_dir);
    try expectEqualStr(&explicit, "home", h.temp_dir);
    try expectEqualStr(&implicit, "absolute", h.temp_dir);
    try expectEqualStr(&explicit, "absolute", h.temp_dir);
    try expectEqualStr(&implicit, "path", "/");
    try expectEqualStr(&explicit, "path", "/");

    if (!h.health(io)) {
        std.debug.print("server died comparing the two listings\n", .{});
        return error.TestUnexpectedResult;
    }
}

// The "do not go above home" guard, on the wire. `getParentPath` compares the
// requested path against home so it can refuse to hand out a parent that sits
// ABOVE home.
test "home_spelled_with_forward_slashes_has_no_parent_above_it" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const spelled = try toPosix(h.temp_dir);
    defer gpa.free(spelled);

    var doc = try listFolderDoc(&h, spelled);
    defer doc.deinit();

    try expectEqualStr(&doc, "home", h.temp_dir);
    // The server echoes the path it was given.
    try expectEqualStr(&doc, "absolute", spelled);

    if (doc.json.get("parent") != null) {
        std.debug.print(
            "home has no parent above it; a parent for \"{s}\" means the guard failed to match it against home \"{s}\": {s}\n",
            .{ spelled, h.temp_dir, doc.body() },
        );
        return error.TestUnexpectedResult;
    }

    if (!h.health(io)) {
        std.debug.print("server died on the forward-slash spelling of home\n", .{});
        return error.TestUnexpectedResult;
    }
}

// The picker's actual walk: list, click an entry, list again.
// `FolderExplorer.vue` expands by sending back `entry.path` verbatim, so that
// value has to be a path the handler accepts on the NEXT call.
test "listing_a_subdirectory_navigates_by_entry_path" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const probe_root = try buildProbeRoot(&s);
    defer gpa.free(probe_root);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var doc = try listFolderDoc(&h, probe_root);
    defer doc.deinit();

    const entries = try entriesOf(&doc);
    if (!entriesHaveName(entries, "sub")) {
        std.debug.print("`sub` missing from the listing: {s}\n", .{doc.body()});
        return error.TestUnexpectedResult;
    }
    if (entriesHaveName(entries, ".hidden")) {
        std.debug.print("dotfiles are filtered before they reach the wire: {s}\n", .{doc.body()});
        return error.TestUnexpectedResult;
    }

    const sub_entry = findEntry(entries, "sub").?;
    try expectObjBool(sub_entry, "is_directory", true);
    try expectObjBool(sub_entry, "is_symlink", false);

    const expected_sub = try harness.harnessPath(gpa, probe_root, &.{"sub"});
    defer gpa.free(expected_sub);
    const sub_path = switch (sub_entry.get("path") orelse {
        std.debug.print("`sub` entry carries no `path`: {s}\n", .{doc.body()});
        return error.TestUnexpectedResult;
    }) {
        .string => |p| p,
        else => {
            std.debug.print("`sub` entry `path` is not a string: {s}\n", .{doc.body()});
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, sub_path, expected_sub)) {
        std.debug.print("`sub` path = \"{s}\", expected \"{s}\"\n", .{ sub_path, expected_sub });
        return error.TestUnexpectedResult;
    }

    // The value above must be accepted verbatim on the next call.
    var nested = try listFolderDoc(&h, sub_path);
    defer nested.deinit();

    const nested_entries = try entriesOf(&nested);
    if (nested_entries.items.len != 2 or
        !entriesHaveName(nested_entries, "note.txt") or
        !entriesHaveName(nested_entries, "child"))
    {
        std.debug.print("expected exactly note.txt and child, got: {s}\n", .{nested.body()});
        return error.TestUnexpectedResult;
    }
    try expectEqualStr(&nested, "parent", probe_root);

    if (!h.health(io)) {
        std.debug.print("server died navigating to \"{s}\"\n", .{sub_path});
        return error.TestUnexpectedResult;
    }
}

// A camelCase `isDirectory` reads as undefined and every row becomes a
// file.
test "entries_serialize_snake_case_flags" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const probe_root = try buildProbeRoot(&s);
    defer gpa.free(probe_root);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var doc = try listFolderDoc(&h, probe_root);
    defer doc.deinit();

    const entries = try entriesOf(&doc);
    if (entries.items.len == 0) {
        std.debug.print("expected at least one entry: {s}\n", .{doc.body()});
        return error.TestUnexpectedResult;
    }
    for (entries.items) |item| {
        const o = switch (item) {
            .object => |m| m,
            else => {
                std.debug.print("entry is not an object: {s}\n", .{doc.body()});
                return error.TestUnexpectedResult;
            },
        };
        for ([_][]const u8{ "name", "path" }) |key| {
            if (o.get(key) == null) {
                std.debug.print("entry is missing `{s}`: {s}\n", .{ key, doc.body() });
                return error.TestUnexpectedResult;
            }
        }
        // Both flags must be present AND booleans — a camelCase
        // `isDirectory` reads as `undefined`, which is why the type check
        // matters as much as the presence check.
        for ([_][]const u8{ "is_directory", "is_symlink" }) |key| {
            switch (o.get(key) orelse {
                std.debug.print("entry is missing `{s}`: {s}\n", .{ key, doc.body() });
                return error.TestUnexpectedResult;
            }) {
                .bool => {},
                else => {
                    std.debug.print("`{s}` is not a bool: {s}\n", .{ key, doc.body() });
                    return error.TestUnexpectedResult;
                },
            }
        }
    }
}

// `action=read` escapes the body through the same `jsonEscape`.
test "read_returns_content_that_survives_json_escaping" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const probe_root = try buildProbeRoot(&s);
    defer gpa.free(probe_root);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const sub = try harness.harnessPath(gpa, probe_root, &.{"sub"});
    defer gpa.free(sub);

    var doc = parseDoc(try h.http(io, .GET, "/api/system/folder", .{
        .params = &.{
            .{ .name = "path", .value = sub },
            .{ .name = "action", .value = "read" },
            .{ .name = "file", .value = "note.txt" },
        },
        .expect = &.{200},
        .timeout_s = 15.0,
    })) catch |err| {
        std.debug.print("action=read failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer doc.deinit();

    try expectEqualStr(&doc, "encoding", "utf-8");
    try expectEqualStr(&doc, "content", TRICKY_CONTENT);
}

// `action=search` serializes entries through the SAME escaping. It used to
// carry a byte-identical copy of the list branch's loop; this pins that the
// two shapes still agree on the wire.
test "search_hits_survive_json_escaping" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const probe_root = try buildProbeRoot(&s);
    defer gpa.free(probe_root);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var doc = parseDoc(try h.http(io, .GET, "/api/system/folder", .{
        .params = &.{
            .{ .name = "path", .value = probe_root },
            .{ .name = "action", .value = "search" },
            .{ .name = "q", .value = "note" },
            .{ .name = "limit", .value = "50" },
        },
        .expect = &.{200},
        .timeout_s = 15.0,
    })) catch |err| {
        std.debug.print("action=search failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer doc.deinit();

    const entries = try entriesOf(&doc);

    var hits: usize = 0;
    var hit: ?std.json.ObjectMap = null;
    for (entries.items) |item| {
        const o = switch (item) {
            .object => |m| m,
            else => continue,
        };
        const n = switch (o.get("name") orelse continue) {
            .string => |x| x,
            else => continue,
        };
        if (std.mem.eql(u8, n, "note.txt")) {
            hits += 1;
            hit = o;
        }
    }
    if (hits != 1) {
        std.debug.print("expected exactly one `note.txt` hit, got {d}: {s}\n", .{ hits, doc.body() });
        return error.TestUnexpectedResult;
    }

    const expected = try harness.harnessPath(gpa, probe_root, &.{ "sub", "note.txt" });
    defer gpa.free(expected);
    const got = switch (hit.?.get("path") orelse {
        std.debug.print("the hit carries no `path`: {s}\n", .{doc.body()});
        return error.TestUnexpectedResult;
    }) {
        .string => |p| p,
        else => {
            std.debug.print("the hit's `path` is not a string: {s}\n", .{doc.body()});
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, got, expected)) {
        std.debug.print("hit path = \"{s}\", expected \"{s}\"\n", .{ got, expected });
        return error.TestUnexpectedResult;
    }
    try expectObjBool(hit.?, "is_directory", false);
}

// The no-action shape has no `entries` key and that is load-bearing.
test "request_without_an_action_returns_location_only" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var listed = try listFolderDoc(&h, h.temp_dir);
        defer listed.deinit();
        if (listed.json.get("entries") == null) {
            std.debug.print("action=list must still return entries: {s}\n", .{listed.body()});
            return error.TestUnexpectedResult;
        }
    }

    var doc = parseDoc(try h.http(io, .GET, "/api/system/folder", .{
        .params = &.{
            .{ .name = "path", .value = h.temp_dir },
        },
        .expect = &.{200},
        .timeout_s = 15.0,
    })) catch |err| {
        std.debug.print("the no-action request failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer doc.deinit();

    if (doc.json.get("entries") != null) {
        std.debug.print("the no-action shape must not carry `entries`: {s}\n", .{doc.body()});
        return error.TestUnexpectedResult;
    }
    try expectEqualStr(&doc, "home", h.temp_dir);
}

// 400, not a crash and not a wrong directory. On Windows `C:notes.txt` parses
// as a path but is drive-RELATIVE, so it must not be joined onto a base and
// opened — that would read the wrong file.
test "drive_relative_and_relative_paths_are_rejected" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const bad = [_][]const u8{ "relative/path", "C:notes.txt", "C|notes.txt" };
    for (bad) |path| {
        var r = try h.http(io, .GET, "/api/system/folder", .{
            .params = &.{
                .{ .name = "path", .value = path },
                .{ .name = "action", .value = "list" },
            },
            .expect = &.{400},
            .timeout_s = 15.0,
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        const message = doc.str("error") orelse {
            std.debug.print("400 body carries no `error` for path=\"{s}\": {s}\n", .{ path, r.body });
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, message, "path must be absolute")) {
            std.debug.print("path=\"{s}\" gave error \"{s}\", expected \"path must be absolute\"\n", .{ path, message });
            return error.TestUnexpectedResult;
        }
        if (!h.health(io)) {
            std.debug.print("server died on path=\"{s}\"\n", .{path});
            return error.TestUnexpectedResult;
        }
    }
}

// `listDirectory` maps every open failure to InvalidPath -> 403.
test "a_missing_directory_is_403_not_500" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const probe_root = try buildProbeRoot(&s);
    defer gpa.free(probe_root);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const missing = try harness.harnessPath(gpa, probe_root, &.{ "definitely", "not", "here" });
    defer gpa.free(missing);

    var r = try h.http(io, .GET, "/api/system/folder", .{
        .params = &.{
            .{ .name = "path", .value = missing },
            .{ .name = "action", .value = "list" },
        },
        .expect = &.{403},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const message = doc.str("error") orelse {
        std.debug.print("403 body carries no `error`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, message, "Directory not found")) {
        std.debug.print("error = \"{s}\", expected \"Directory not found\"\n", .{message});
        return error.TestUnexpectedResult;
    }
    if (!h.health(io)) {
        std.debug.print("server died on the missing directory\n", .{});
        return error.TestUnexpectedResult;
    }
}

comptime {
    // Body-analysis barrier: an unreferenced helper is never
    // type-checked, so a stdlib rename inside one is invisible until a
    // caller appears.
    _ = Scratch.init;
    _ = Scratch.deinit;
    _ = Scratch.path;
    _ = writeFileAt;
    _ = gitInit;
    _ = buildProbeRoot;
    _ = toPosix;
    _ = listFolder;
    _ = listFolderDoc;
    _ = parseDoc;
    _ = Doc.deinit;
    _ = Doc.body;
    _ = findEntry;
    _ = entriesHaveName;
    _ = entriesOf;
    _ = expectEqualStr;
    _ = expectObjBool;
}
