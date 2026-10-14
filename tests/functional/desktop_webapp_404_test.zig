// Functional tests for the desktop `--static-dir` 404 bug. Zig port of
// `tests/functional/desktop_webapp_404_test.py` (same test names, same
// order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// The stand-in app shell the desktop would have extracted.
const HTML = "<!DOCTYPE html><html><body>pabrik app shell</body></html>";

/// Write `contents` to the absolute `path`, creating/truncating it.
fn writeFileAt(path: []const u8, contents: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

/// Minimal stand-in for the extracted webapp dir.
fn makeWebapp(root: []const u8) !void {
    const assets = try std.fs.path.join(gpa, &.{ root, "assets" });
    defer gpa.free(assets);
    try std.Io.Dir.cwd().createDirPath(io, assets);

    {
        const p = try std.fs.path.join(gpa, &.{ root, "index.html" });
        defer gpa.free(p);
        try writeFileAt(p, HTML);
    }
    {
        const p = try std.fs.path.join(gpa, &.{ root, ".pabrik-webapp-complete" });
        defer gpa.free(p);
        try writeFileAt(p, "test-hash");
    }
    {
        const p = try std.fs.path.join(gpa, &.{ assets, "app.js" });
        defer gpa.free(p);
        try writeFileAt(p, "console.log('pabrik');");
    }
}

/// True when `/` returns the SPA shell — the desktop's readiness test. Python
/// `h_serves_app`: `GET /` accepting `(200, 404)`, then `status == 200 and
/// "<" in body`.
fn servesApp(h: *Harness) !bool {
    var r = try h.http(io, .GET, "/", .{ .expect = &.{ 200, 404 } });
    defer r.deinit();
    return r.status == 200 and std.mem.indexOf(u8, r.text(), "<") != null;
}

// The bug, at the wire level. A daemon whose --static-dir was removed keeps
// answering /health with 200 while answering / with 404. That asymmetry is
// why the old health-only attach probe let the desktop open a 404 window.
test "static_dir_404s_when_the_dir_is_deleted_health_stays_200" {
    try harness.requirePabrikBin(io, gpa);

    const scratch = try harness.makeScratchDir(gpa);
    // DEFER ORDER IS LIFO: `free` is registered first so it runs LAST.
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const webapp_dir = try std.fs.path.join(gpa, &.{ scratch, "desktop-webapp" });
    defer gpa.free(webapp_dir);
    try makeWebapp(webapp_dir);

    // `extra_args` borrows, so the argv slice must outlive the boot.
    const args = [_][]const u8{ "--static-dir", webapp_dir };

    var h = try Harness.boot(io, gpa, .{
        .stub_llm_profile = true,
        .extra_args = &args,
    });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // 1. Healthy and serving the app.
    {
        var r = try h.http(io, .GET, "/", .{});
        defer r.deinit();
        if (std.mem.indexOf(u8, r.text(), "pabrik app shell") == null) {
            std.debug.print("GET / did not serve the app shell: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
    {
        var r = try h.http(io, .GET, "/index.html", .{});
        defer r.deinit();
    }
    {
        var r = try h.http(io, .GET, "/assets/app.js", .{});
        defer r.deinit();
    }
    {
        var r = try h.http(io, .GET, "/health", .{});
        defer r.deinit();
    }

    // 2. Delete the directory out from under the running daemon. This
    //    is exactly what the old desktop did at window close.
    std.Io.Dir.cwd().deleteTree(io, webapp_dir) catch |err| {
        std.debug.print("could not delete the static dir: {s}\n", .{@errorName(err)});
        return err;
    };

    // 3. The app is gone...
    {
        var r = try h.http(io, .GET, "/", .{ .expect = &.{404} });
        defer r.deinit();
        if (std.mem.indexOf(u8, r.text(), "Not Found") == null) {
            std.debug.print("expected a Not Found body, got: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
    {
        var r = try h.http(io, .GET, "/index.html", .{ .expect = &.{404} });
        defer r.deinit();
    }

    // ...but health still says everything is fine. This is the trap.
    {
        var r = try h.http(io, .GET, "/health", .{});
        defer r.deinit();
    }

    // 4. Restoring the dir restores the app (proving the daemon itself
    //    never died — only its static dir went away).
    try makeWebapp(webapp_dir);
    {
        var r = try h.http(io, .GET, "/", .{});
        defer r.deinit();
        if (std.mem.indexOf(u8, r.text(), "pabrik app shell") == null) {
            std.debug.print("GET / after restore did not serve the app shell: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
}

// The fix's invariant: reopening the app keeps serving it. Models two desktop
// launches against the same persistent webapp dir — the dir is never deleted,
// so the second launch's webview gets the app instead of `404 Not Found`.
test "persistent_static_dir_survives_a_restart" {
    try harness.requirePabrikBin(io, gpa);

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const webapp_dir = try std.fs.path.join(gpa, &.{ scratch, "desktop-webapp" });
    defer gpa.free(webapp_dir);
    try makeWebapp(webapp_dir);

    const args = [_][]const u8{ "--static-dir", webapp_dir };

    // Each launch gets its OWN block so its `defer` tears the harness
    // down before the next one boots — two live `pabrik` children would
    // otherwise be racing for the same tempdir.
    {
        var first = try Harness.boot(io, gpa, .{
            .stub_llm_profile = true,
            .extra_args = &args,
        });
        defer first.deinit(io) catch |err| {
            std.debug.print("teardown: {s}\n", .{@errorName(err)});
        };
        if (!try servesApp(&first)) return error.TestUnexpectedResult;
    }

    // Close/reopen: the dir must still be there, untouched.
    {
        const index = try std.fs.path.join(gpa, &.{ webapp_dir, "index.html" });
        defer gpa.free(index);
        std.Io.Dir.cwd().access(io, index, .{}) catch {
            std.debug.print("index.html vanished across the restart: {s}\n", .{index});
            return error.TestUnexpectedResult;
        };
    }

    {
        var second = try Harness.boot(io, gpa, .{
            .stub_llm_profile = true,
            .extra_args = &args,
        });
        defer second.deinit(io) catch |err| {
            std.debug.print("teardown: {s}\n", .{@errorName(err)});
        };
        if (!try servesApp(&second)) return error.TestUnexpectedResult;
    }
}

// A pabrik with no --static-dir looks identical to the broken daemon. Nothing
// about `/health` distinguishes it, so an attach decision based on health
// alone cannot tell a usable server from a useless one.
test "without_static_dir_health_is_200_but_root_is_404" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var r = try h.http(io, .GET, "/health", .{});
        defer r.deinit();
    }
    var r = try h.http(io, .GET, "/", .{ .expect = &.{404} });
    defer r.deinit();
    if (std.mem.indexOf(u8, r.text(), "Not Found") == null) {
        std.debug.print("expected a Not Found body, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}
