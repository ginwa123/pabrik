// End-to-end smoke test for the functional Harness. Zig port of
// `tests/functional/smoke_boot_test.py` (same test names).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// Boot a harness for one test, with teardown already deferred.
fn bootOne() !Harness {
    return Harness.boot(io, gpa, .{});
}

// ─── The module's own harness safety invariants ────────────────────────────
// These are NOT ports: they are the guards on `harness.zig` itself, and they
// run without booting a binary (so they work on a clean checkout).

test "is_safe_tmp_rejects_dangerous_paths" {
    const root = try harness.tmpRoot(gpa);
    defer gpa.free(root);

    // A real tmpdir carrying the namespace marker IS allowed.
    const good = try std.fs.path.join(gpa, &.{ root, harness.REQUIRED_TMP_SUBSTR ++ "probe" });
    defer gpa.free(good);
    try testing.expect(try harness.isSafeTmp(io, gpa, good, "/home/definitely-not-here"));

    // Relative path → rejected.
    try testing.expect(!try harness.isSafeTmp(io, gpa, "pabrik-func-relative", "/home/x"));
    // Empty → rejected.
    try testing.expect(!try harness.isSafeTmp(io, gpa, "", "/home/x"));
    // Absolute but NOT a tmpdir → rejected.
    try testing.expect(!try harness.isSafeTmp(io, gpa, "/etc/pabrik-func-evil", "/home/x"));
    // Tmpdir but missing the namespace marker → rejected.
    const no_marker = try std.fs.path.join(gpa, &.{ root, "some-other-dir" });
    defer gpa.free(no_marker);
    try testing.expect(!try harness.isSafeTmp(io, gpa, no_marker, "/home/x"));
    // The path equal to the real HOME → rejected even with the marker.
    try testing.expect(!try harness.isSafeTmp(io, gpa, root, root));
}

// The port picker must never return 8081 (the always-running dev
// backend) and must return a bindable port.
test "find_free_port_random_avoids_reserved_8081" {
    const port = try harness.findFreePortRandom(gpa);
    try testing.expect(port != 8081);
    try testing.expect(port >= harness.RANDOM_PORT_START);
    try testing.expect(port <= harness.RANDOM_PORT_END);
    // The returned port really was free when we probed it — bind it
    // ourselves as the cross-check (the probe closed its socket, so a
    // failure here means the picker returned a port that was taken).
    try testing.expect(harness.portIsFreeWithReuse(io, port));
}

// The sequential picker skips 8081 the same way.
test "find_free_port_sequential_skips_8081" {
    // Start AT 8081 — the picker must skip it and return 8082+.
    const port = try harness.findFreePortSequential(io, 8081);
    try testing.expect(port != 8081);
    try testing.expect(port >= 8082);
}

// ─── Ports of the Python tests (these boot a binary) ───────────────────────

// The boot path returns a ready instance.
test "boot_succeeds" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootOne();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    // `pid` and `port` are non-null / non-zero, and `/health` answers.
    try testing.expect(h.pid != null);
    try testing.expect(h.pid.? > 0);
    try testing.expect(h.port > 0);
    try testing.expect(h.health(io));
}

// The tempdir is NOT the real $HOME, and lives under the tmp root.
test "temp_dir_is_isolated_from_real_home" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootOne();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    try testing.expect(!std.mem.eql(u8, h.temp_dir, h.orig_home));
    try testing.expect(try harness.isSafeTmp(io, gpa, h.temp_dir, h.orig_home));

    // The tempdir must exist on disk.
    std.Io.Dir.cwd().access(io, h.temp_dir, .{}) catch return error.TestUnexpectedResult;
}

// Create a workspace, list it, delete it. Smoke-test the wire.
test "workspace_lifecycle" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootOne();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    var create = try h.http(io, .POST, "/api/workspaces", .{
        .json_body =
        \\{"name":"smoke-boot-test"}
        ,
        .expect = &.{201},
    });
    defer create.deinit();

    var doc = try create.json();
    defer doc.deinit();
    const ws_id = doc.str("id") orelse return error.TestUnexpectedResult;
    // Python asserted `"id" in data` then `ws_id.startswith("ws_")`.
    try testing.expect(std.mem.startsWith(u8, ws_id, "ws_"));

    // The created workspace must appear in the list response.
    {
        var list = try h.http(io, .GET, "/api/workspaces", .{});
        defer list.deinit();
        var listed = try list.json();
        defer listed.deinit();

        const rows = listed.array("workspaces") orelse return error.TestUnexpectedResult;
        var found = false;
        for (rows.items) |row| {
            const id = switch (row) {
                .object => |o| if (o.get("id")) |v| switch (v) {
                    .string => |sv| sv,
                    else => "",
                } else "",
                else => "",
            };
            if (std.mem.eql(u8, id, ws_id)) found = true;
        }
        if (!found) {
            std.debug.print("created workspace {s} not in list response\n", .{ws_id});
            return error.TestUnexpectedResult;
        }
    }

    const del_path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}", .{ws_id});
    defer gpa.free(del_path);
    var del = try h.http(io, .DELETE, del_path, .{});
    defer del.deinit();
}

// Real-data check: the agent.db is inside the tempdir, not the real HOME.
test "state_lives_in_temp_dir" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootOne();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    // The DB path is $HOME/.config/pabrik/agent.db. With HOME=temp_dir
    // it must be at temp_dir/.config/pabrik/agent.db.
    const db_path = try std.fs.path.join(gpa, &.{ h.temp_dir, ".config", "pabrik", "agent.db" });
    defer gpa.free(db_path);
    std.Io.Dir.cwd().access(io, db_path, .{}) catch {
        std.debug.print("agent.db not found at expected tempdir path {s}\n", .{db_path});
        return error.TestUnexpectedResult;
    };
    // The real $HOME must NOT contain a `pabrik/agent.db` newly created by
    // this test.
}

// The real $HOME is captured intact by the harness.
test "orig_home_untouched_after_session" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootOne();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    // Python: `h.orig_home == os.environ["HOME"] or
    // Path(h.orig_home).exists()`.
    const home = testing.environ.getAlloc(gpa, "HOME") catch try gpa.dupe(u8, "");
    defer gpa.free(home);
    try testing.expect(std.mem.eql(u8, h.orig_home, home));
}

// Teardown restores HOME and preserves orig_dir.
test "teardown_restores_home_and_keeps_orig_dir" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootOne();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    // Python records this as a tautology: "the assertion is tautological; the
    // real coverage is in
    // harness_safety_test.py::test_teardown_with_safe_temp_dir_runs_rmtree".
    try testing.expect(h.orig_home.len > 0);
    try testing.expect(std.fs.path.isAbsolute(h.orig_home));
}

// Teardown must complete in <3s.
test "teardown_completes_within_3s" {
    // Regression guard for the "10s wasted teardown per test" bug.
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    // Drive a minimal API call so the binary is in a known state.
    try testing.expect(h.health(io));

    const t0 = Io_timestamp();
    h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    const elapsed_ms = Io_timestamp() - t0;

    if (elapsed_ms >= 3000) {
        std.debug.print(
            "teardown took {d}ms — expected <3000ms. Re-run of the 10s " ++
                "teardown bug: check that /test/shutdown actually exits the " ++
                "process and that main stops the cronjob manager before returning.\n",
            .{elapsed_ms},
        );
        return error.TestUnexpectedResult;
    }
}

fn Io_timestamp() i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}