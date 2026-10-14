// Wire-level regression tests for system-folder path validation. Zig port of
// `tests/functional/system_folder_path_validation_test.py` (same test name).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

const Param = harness.Harness.Param;

const FOLDER_ROUTE = "/api/system/folder";

const HEX = "0123456789ABCDEF";

/// Percent-encode the query-shape characters of `s` into a fresh
/// allocation. See the header for why this is narrower than
/// `urlencode`.
fn encodeQueryValue(s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (s) |c| {
        switch (c) {
            ' ', '&', '=', '#', '%', '?' => {
                try out.append(gpa, '%');
                try out.append(gpa, HEX[c >> 4]);
                try out.append(gpa, HEX[c & 0x0F]);
            },
            else => try out.append(gpa, c),
        }
    }
    return out.toOwnedSlice(gpa);
}

/// `"/api/system/folder?action=list&path=relative/path"` — owned.
fn folderTarget(params: []const Param) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, FOLDER_ROUTE);
    for (params, 0..) |p, i| {
        try out.append(gpa, if (i == 0) '?' else '&');
        try out.appendSlice(gpa, p.name);
        try out.append(gpa, '=');
        const v = try encodeQueryValue(p.value);
        defer gpa.free(v);
        try out.appendSlice(gpa, v);
    }
    return out.toOwnedSlice(gpa);
}

/// GET the folder route with `params` and return the response with the
/// status already asserted against `expect`.
fn folderGet(h: *Harness, params: []const Param, expect: []const u16) !harness.Response {
    const target = try folderTarget(params);
    defer gpa.free(target);
    return h.http(io, .GET, target, .{ .expect = expect });
}

/// Assert the server is still up. Python spelled this `assert
/// harness.health()`, and the failure message named the offending
/// params — keep that.
fn expectAlive(h: *Harness, context: []const u8) !void {
    if (h.health(io)) return;
    std.debug.print("server died after {s}\n", .{context});
    return error.TestUnexpectedResult;
}

/// `400 path must be absolute` + `details == "InvalidPath"`.
fn expectInvalidPath(r: *harness.Response, context: []const u8) !void {
    var doc = try r.json();
    defer doc.deinit();

    const err = doc.str("error") orelse {
        std.debug.print("{s}: 400 body has no `error`: {s}\n", .{ context, r.body });
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, err, "path must be absolute")) {
        std.debug.print(
            "{s}: error = \"{s}\", expected \"path must be absolute\"\n",
            .{ context, err },
        );
        return error.TestUnexpectedResult;
    }
    const details = doc.str("details") orelse {
        std.debug.print("{s}: 400 body has no `details`: {s}\n", .{ context, r.body });
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, details, "InvalidPath")) {
        std.debug.print("{s}: details = \"{s}\", expected \"InvalidPath\"\n", .{ context, details });
        return error.TestUnexpectedResult;
    }
}

// Non-absolute cwd values must not reach an open*Absolute assertion.
test "relative_base_path_returns_400_without_killing_server" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // The four InvalidPath cases, in the Python file's order.
    const cases = [_]struct { label: []const u8, params: []const Param }{
        .{
            .label = "action=list path=relative/path",
            .params = &.{
                .{ .name = "action", .value = "list" },
                .{ .name = "path", .value = "relative/path" },
            },
        },
        .{
            .label = "action=search path=relative/path q=component",
            .params = &.{
                .{ .name = "action", .value = "search" },
                .{ .name = "path", .value = "relative/path" },
                .{ .name = "q", .value = "component" },
            },
        },
        .{
            .label = "action=read path=relative/path file=README.md",
            .params = &.{
                .{ .name = "action", .value = "read" },
                .{ .name = "path", .value = "relative/path" },
                .{ .name = "file", .value = "README.md" },
            },
        },
        .{
            .label = "action=list path=(empty)",
            .params = &.{
                .{ .name = "action", .value = "list" },
                .{ .name = "path", .value = "" },
            },
        },
    };

    for (cases) |c| {
        var r = try folderGet(&h, c.params, &.{400});
        defer r.deinit();
        try expectInvalidPath(&r, c.label);
        try expectAlive(&h, c.label);
    }

    // An EMPTY search path is rejected earlier, by the action's own
    // "path required" guard rather than the shared InvalidPath guard.
    {
        var r = try folderGet(&h, &.{
            .{ .name = "action", .value = "search" },
            .{ .name = "path", .value = "" },
        }, &.{400});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const err = doc.str("error") orelse {
            std.debug.print("empty search: 400 body has no `error`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, err, "path required")) {
            std.debug.print("empty search: error = \"{s}\", expected \"path required\"\n", .{err});
            return error.TestUnexpectedResult;
        }
        try expectAlive(&h, "rejecting an empty search path");
    }

    // A DRIVE-RELATIVE file (`C:foo` — resolved against the process CWD, not
    // the base) must be refused, not opened.
    const pid: u32 = if (h.pid) |p| p else 0;
    const foreign_file = try std.fmt.allocPrint(gpa, "C:pabrik-relative-{d}.txt", .{pid});
    defer gpa.free(foreign_file);

    {
        var r = try folderGet(&h, &.{
            .{ .name = "action", .value = "read" },
            .{ .name = "path", .value = h.temp_dir },
            .{ .name = "file", .value = foreign_file },
        }, &.{403});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const err = doc.str("error") orelse {
            std.debug.print("drive-relative read: 403 body has no `error`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, err, "Cannot open file")) {
            std.debug.print("drive-relative read: error = \"{s}\", expected \"Cannot open file\"\n", .{err});
            return error.TestUnexpectedResult;
        }
        try expectAlive(&h, "a drive-relative read path");
    }
}
