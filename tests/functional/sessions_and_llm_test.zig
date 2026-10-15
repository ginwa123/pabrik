// Functional tests for sessions + /test/shutdown + LLM stub. Zig port of
// `tests/functional/sessions_and_llm_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// The fixed port the Python original passed for the shutdown test ("fixed
/// port for shutdown test").
const shutdown_test_start_port: u16 = 8090;

/// Python's `llm_harness` fixture: a harness booted with the stub LLM
/// profile so session-create doesn't try to call a real LLM.
fn bootLlmStub() !Harness {
    return Harness.boot(io, gpa, .{ .stub_llm_profile = true });
}

/// `POST /api/workspaces` → the new workspace's id (an owned copy). The
/// Python original had this helper but never called it — every test it wrote
/// is session-scoped, which needs no workspace.
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
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

// GET /health returns 200 with {"status":"ok"}.
test "health_endpoint_returns_ok" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootLlmStub();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/health", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const status = doc.str("status") orelse {
        std.debug.print("/health body has no `status` string: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("ok", status);
}

// POST /api/llm/session creates a session and returns an id.
test "session_create_returns_session_id" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootLlmStub();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .POST, "/api/llm/session", .{
        .json_body = "{\"session_name\":\"test-session\"}",
        .expect = &.{ 201, 500 },
    });
    defer r.deinit();

    // The session may be created (201) or the LLM call may fail causing 500.
    // Either way, a successful 201 has an id.
    if (r.status == 201) {
        var doc = try r.json();
        defer doc.deinit();
        const id = doc.str("id") orelse {
            std.debug.print("session create should return id, got: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        try testing.expect(id.len > 0);
    }
}

// GET /api/llm/session returns 200 with a list (possibly empty).
test "session_list_returns_200" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootLlmStub();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/llm/session", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    // Response shape: `{sessions:[...]}` or a list directly. Accept both,
    // plus the `{data: [...]}` fallback the Python original allowed.
    switch (doc.value().*) {
        .array => {},
        .object => |o| {
            const arr = (o.get("sessions") orelse o.get("data") orelse {
                std.debug.print("session list object has neither `sessions` nor `data`: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            });
            switch (arr) {
                .array => {},
                else => {
                    std.debug.print("session list `sessions`/`data` is not an array: {s}\n", .{r.body});
                    return error.TestUnexpectedResult;
                },
            }
        },
        else => {
            std.debug.print("session list should return a list, got: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    }
}

// GET /api/llm/session/<nonexistent>/messages returns 404 or empty. The
// endpoint may 404 for a non-existent session id, or return an empty messages
// list. Both are acceptable.
test "session_messages_for_nonexistent_returns_404_or_empty" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootLlmStub();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/llm/session/nonexistent_session_id/messages", .{
        .expect = &.{ 200, 404 },
    });
    defer r.deinit();

    if (r.status == 200) {
        var doc = try r.json();
        defer doc.deinit();
        // Only asserted when the body actually carries `messages` —
        // Python's `if isinstance(body, dict) and "messages" in body`.
        if (doc.get("messages") != null) {
            const messages = doc.array("messages") orelse {
                std.debug.print("`messages` present but not an array: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            };
            if (messages.items.len != 0) {
                std.debug.print("expected no messages for a nonexistent session, got {d}: {s}\n", .{ messages.items.len, r.body });
                return error.TestUnexpectedResult;
            }
        }
    }
}

// POST /test/shutdown initiates a graceful shutdown. After it returns, the
// server should stop accepting new connections.
test "test_shutdown_stops_server" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{
        .stub_llm_profile = true,
        .port = shutdown_test_start_port,
    });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // Server is up — health returns 200.
    try testing.expect(h.health(io));

    // Trigger shutdown.
    {
        var r = try h.http(io, .POST, "/test/shutdown", .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        // `"message" in body or "shutdown" in body["message"].lower()`.
        const message = doc.str("message") orelse {
            std.debug.print("unexpected shutdown response: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (std.ascii.indexOfIgnoreCase(message, "shutdown") == null) {
            std.debug.print("shutdown message should mention shutdown, got: {s}\n", .{message});
            return error.TestUnexpectedResult;
        }
    }

    // The server should no longer respond (the detached shutdown thread
    // runs ~300ms after the 200 flushes, so give it a moment).
    std.Io.sleep(io, .fromMilliseconds(500), .awake) catch {};

    if (h.health(io)) {
        std.debug.print("server still responding after /test/shutdown\n", .{});
        return error.TestUnexpectedResult;
    }
}

// Belt-and-suspenders for the safety invariant: assert the real $HOME does
// not contain a `pabrik/` dir newly created by the test.
test "no_state_leaked_to_real_home" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootLlmStub();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const real_agent_db = try std.fs.path.join(gpa, &.{ h.orig_home, ".config", "pabrik", "agent.db" });
    defer gpa.free(real_agent_db);

    // `if os.path.exists(...)` — an absent file passes vacuously, which
    // is the Python behaviour and the safe one (nothing to leak).
    if (std.Io.Dir.cwd().access(io, real_agent_db, .{})) |_| {
        const stat = std.Io.Dir.cwd().statFile(io, real_agent_db, .{}) catch |err| {
            std.debug.print("could not stat {s}: {s}\n", .{ real_agent_db, @errorName(err) });
            return err;
        };
        // File exists in real HOME — its mtime should be well in the
        // past (older than 60s). If the test wrote to it, mtime would
        // be < 60s.
        const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
        const age_s = @divTrunc(now_ms - stat.mtime.toMilliseconds(), 1000);
        if (age_s <= 60) {
            std.debug.print(
                "real HOME agent.db mtime is {d}s old (recently modified) — " ++
                    "the harness may have leaked to the real $HOME. Path: {s}\n",
                .{ age_s, real_agent_db },
            );
            return error.TestUnexpectedResult;
        }
    } else |_| {}

    // The harness's own tempdir DOES have an agent.db — the positive
    // control. Without it, the check above could pass because the
    // server never wrote a database anywhere.
    const temp_agent_db = try std.fs.path.join(gpa, &.{ h.temp_dir, ".config", "pabrik", "agent.db" });
    defer gpa.free(temp_agent_db);
    std.Io.Dir.cwd().access(io, temp_agent_db, .{}) catch |err| {
        std.debug.print(
            "harness tempdir should have its own agent.db at {s} ({s})\n",
            .{ temp_agent_db, @errorName(err) },
        );
        return error.TestUnexpectedResult;
    };
}

comptime {
    // `createWorkspace` is unused by the current tests (the Python original
    // carried it unused too).
    _ = createWorkspace;
    _ = bootLlmStub;
}
