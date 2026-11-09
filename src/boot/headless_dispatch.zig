//! `pabrik headless ...` subcommand dispatch. Peeks at argv[1] and returns
//! false when it does not match, so `main` falls through to the regular
//! server boot.

const std = @import("std");
const pabrikcore = @import("pabrikcore");

const headless = @import("../headless/mod.zig");
const cli_flags = @import("../cli/flags.zig");
const db_target = @import("db_target.zig");

/// `pabrik headless {run,sessions,messages,help}`.
pub fn dispatchHeadless(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    init: std.process.Init,
) !bool {
    const args_minimal = init.minimal.args;
    var it = try std.process.Args.Iterator.initAllocator(args_minimal, allocator);
    defer it.deinit();
    _ = it.next(); // argv[0]
    const arg1 = it.next() orelse return false;
    if (!std.mem.eql(u8, arg1, "headless")) return false;

    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(allocator);
    while (it.next()) |a| try rest.append(allocator, a);

    // `--log-file` and the `--database*` family are stripped before the verb
    // parser sees the argv: no verb parser owns either, and the same
    // strip-globals-first shape `pabrikcli`'s main.zig uses.
    var db_request: db_target.Request = .{};
    var without_db: std.ArrayList([]const u8) = .empty;
    defer without_db.deinit(allocator);
    db_target.parseArgs(allocator, rest.items, &db_request, &without_db) catch |err| {
        db_target.reportArgError(rest.items, err);
        return true;
    };

    var log_file: ?[]const u8 = null;
    var verb_argv: std.ArrayList([]const u8) = .empty;
    defer verb_argv.deinit(allocator);
    {
        const log_file_flag = cli_flags.word("log-file");
        var i: usize = 0;
        while (i < without_db.items.len) : (i += 1) {
            if (std.mem.eql(u8, without_db.items[i], log_file_flag)) {
                i += 1;
                if (i >= without_db.items.len) {
                    std.log.err("headless: --log-file requires a value", .{});
                    return true;
                }
                log_file = without_db.items[i];
            } else {
                try verb_argv.append(allocator, without_db.items[i]);
            }
        }
    }

    switch (try headless.parseCommand(verb_argv.items)) {
        .invalid => |f| {
            headless.args.reportFailure(f);
            std.log.err("run `pabrik headless help` for usage", .{});
        },
        .help => {
            const stdout = std.Io.File.stdout();
            var buf: [4096]u8 = undefined;
            var w = stdout.writer(io, &buf);
            try w.interface.writeAll(headless.args.HELP_TEXT);
            try w.interface.flush();
        },
        .run => |a| try runTurn(allocator, io, environment, a, log_file, db_request),
        .sessions => |a| try listSessions(allocator, io, environment, a, log_file, db_request),
        .messages => |a| try listMessages(allocator, io, environment, a, log_file, db_request),
        .documents => |a| try runDocuments(allocator, io, environment, a, log_file, db_request),
        .usage => |a| try runUsage(allocator, io, environment, a, log_file, db_request),
        .message => |a| try runMessage(allocator, io, environment, a, log_file, db_request),
        .group => |a| try runGroup(allocator, io, environment, a, log_file, db_request),
        .storage => |a| try runStorage(allocator, io, environment, a),
        .memories => |a| try runMemories(allocator, io, environment, a, log_file, db_request),
        .mcp_oauth => |a| try runMcpOAuth(allocator, io, environment, a, log_file, db_request),
    }
    return true;
}

/// Boot the backend, run one turn, print the result, tear down. The teardown
/// is a `defer` rather than an inline sequence so an error return from any
/// phase still releases the DB handle and the scheduler.
fn runTurn(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    a: headless.args.RunArgs,
    log_file: ?[]const u8,
    db_request: db_target.Request,
) !void {
    // Declared HERE, not returned by value: `App.db` / `.event_bus`
    // point into this struct, so it must live in the
    // caller's frame. See the `boot.zig` module header.
    var backend: headless.boot.Backend = undefined;
    headless.boot.boot(&backend, allocator, io, environment, .{ .log_file = log_file, .db_request = db_request }) catch |err| {
        std.log.err("headless: boot failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    const result = headless.run.run(allocator, &backend, a) catch |err| {
        std.log.err("headless: turn failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    if (a.quiet) {
        try w.writeAll(result.assistant_text);
        try w.writeByte('\n');
    } else {
        try w.writeAll("{\"session_id\":");
        try writeJsonString(w, result.session_id);
        try w.print(",\"finish_reason\":", .{});
        try writeJsonString(w, result.finish_reason);
        try w.print(",\"iterations\":{d},\"timed_out\":{s},\"error\":", .{
            result.iterations,
            if (result.timed_out) "true" else "false",
        });
        if (result.error_name) |e| {
            try writeJsonString(w, e);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\"assistant\":");
        try writeJsonString(w, result.assistant_text);
        try w.writeAll("}\n");
    }

    try writeStdout(io, out.written());

    // A turn that produced nothing is a failure the caller needs to hear
    // about, so the exit code says so even though the JSON printed fine.
    if (result.timed_out or result.error_name != null or result.assistant_text.len == 0) {
        backend.finish(1);
    }
    backend.finish(0);
}

fn listSessions(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    a: headless.args.SessionsArgs,
    log_file: ?[]const u8,
    db_request: db_target.Request,
) !void {
    // Declared HERE, not returned by value: `App.db` / `.event_bus`
    // point into this struct, so it must live in the
    // caller's frame. See the `boot.zig` module header.
    var backend: headless.boot.Backend = undefined;
    headless.boot.boot(&backend, allocator, io, environment, .{ .log_file = log_file, .db_request = db_request }) catch |err| {
        std.log.err("headless: boot failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    var result = try headless.sessions.listSessions(allocator, &backend, a);
    defer headless.sessions.freeSessions(allocator, &result);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    try w.print("{{\"total\":{d},\"sessions\":[", .{result.total});
    for (result.sessions, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try writeJsonString(w, s.id);
        try w.writeAll(",\"name\":");
        try writeJsonString(w, s.name);
        try w.writeAll(",\"cwd\":");
        try writeJsonString(w, s.cwd);
        try w.writeAll(",\"created_at\":");
        try writeJsonString(w, s.created_at);
        try w.writeByte('}');
    }
    try w.writeAll("]}\n");

    try writeStdout(io, out.written());
    backend.finish(0);
}

fn listMessages(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    a: headless.args.MessagesArgs,
    log_file: ?[]const u8,
    db_request: db_target.Request,
) !void {
    // Declared HERE, not returned by value: `App.db` / `.event_bus`
    // point into this struct, so it must live in the
    // caller's frame. See the `boot.zig` module header.
    var backend: headless.boot.Backend = undefined;
    headless.boot.boot(&backend, allocator, io, environment, .{ .log_file = log_file, .db_request = db_request }) catch |err| {
        std.log.err("headless: boot failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    var result = headless.sessions.listMessages(allocator, &backend, a) catch |err| {
        std.log.err("headless: could not read session '{s}': {s}", .{ a.session_id, @errorName(err) });
        std.process.exit(1);
    };
    defer headless.sessions.freeMessages(allocator, &result);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\"session_id\":");
    try writeJsonString(w, result.session_id);
    try w.print(",\"has_more\":{s},\"messages\":[", .{if (result.has_more) "true" else "false"});
    for (result.messages, 0..) |m, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try writeJsonString(w, m.id);
        try w.writeAll(",\"role\":");
        try writeJsonString(w, m.role);
        try w.writeAll(",\"content\":");
        try writeJsonString(w, m.content);
        try w.writeAll(",\"tool_name\":");
        try writeJsonString(w, m.tool_name);
        try w.writeAll(",\"finish_reason\":");
        try writeJsonString(w, m.finish_reason);
        try w.writeAll(",\"created_at\":");
        try writeJsonString(w, m.created_at);
        try w.print(",\"is_feed_to_llm\":{s}", .{if (m.is_feed_to_llm) "true" else "false"});
        try w.writeByte('}');
    }
    try w.writeAll("]}\n");

    try writeStdout(io, out.written());
    backend.finish(0);
}

/// Boot the backend, run one document-folder op, print its JSON, tear down.
fn runDocuments(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    a: headless.args.DocumentsArgs,
    log_file: ?[]const u8,
    db_request: db_target.Request,
) !void {
    // Declared HERE, not returned by value: `App.db` / `.event_bus`
    // point into this struct, so it must live in the caller's frame.
    var backend: headless.boot.Backend = undefined;
    headless.boot.boot(&backend, allocator, io, environment, .{ .log_file = log_file, .db_request = db_request }) catch |err| {
        std.log.err("headless: boot failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    const json = headless.documents.run(allocator, &backend, a) catch |err| {
        // stdout is the machine channel: a failure never prints a half object.
        std.log.err("headless: documents {s} failed: {s}", .{ @tagName(a.op), @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(json);

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(json);
    try w.interface.writeAll("\n");
    try w.interface.flush();

    backend.finish(0);
}

/// Run one object-store op and print its JSON. Deliberately does NOT boot the
/// backend: the storage layer must work with no database, so a broken
/// `agent.db` cannot stop an operator from inspecting the store.
fn runStorage(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    a: headless.args.StorageArgs,
) !void {
    const json = headless.storage.run(allocator, io, environment, a) catch |err| {
        std.log.err("headless: storage {s} failed: {s}", .{ @tagName(a.op), @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(json);

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(json);
    try w.interface.writeAll("\n");
    try w.interface.flush();

    std.process.exit(0);
}

fn runUsage(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    a: headless.args.UsageArgs,
    log_file: ?[]const u8,
    db_request: db_target.Request,
) !void {
    var backend: headless.boot.Backend = undefined;
    headless.boot.boot(&backend, allocator, io, environment, .{ .log_file = log_file, .db_request = db_request }) catch |err| {
        std.log.err("headless: boot failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    const json = headless.usage.run(allocator, &backend, a) catch |err| {
        switch (err) {
            error.InvalidRange => std.log.err("headless: usage range must be {s}", .{headless.usage.range_hint}),
            else => std.log.err("headless: usage failed: {s}", .{@errorName(err)}),
        }
        std.process.exit(1);
    };
    defer allocator.free(json);

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(json);
    try w.interface.writeAll("\n");
    try w.interface.flush();

    backend.finish(0);
}

/// Boot the backend, run one single-message op, print its JSON, tear down.
fn runMessage(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    a: headless.args.MessageArgs,
    log_file: ?[]const u8,
    db_request: db_target.Request,
) !void {
    // Declared HERE, not returned by value: `App.db` / `.event_bus`
    // point into this struct, so it must live in the caller's frame.
    var backend: headless.boot.Backend = undefined;
    headless.boot.boot(&backend, allocator, io, environment, .{ .log_file = log_file, .db_request = db_request }) catch |err| {
        std.log.err("headless: boot failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    const json = headless.messages_admin.run(allocator, io, &backend, a) catch |err| {
        // stdout is the machine channel: a failure never prints a half object.
        std.log.err("headless: message {s} failed: {s}", .{ @tagName(a.op), @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(json);

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(json);
    try w.interface.writeAll("\n");
    try w.interface.flush();

    backend.finish(0);
}

/// Boot the backend, run one multi-agent op, print its JSON, tear down.
fn runGroup(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    a: headless.args.GroupArgs,
    log_file: ?[]const u8,
    db_request: db_target.Request,
) !void {
    // Declared HERE, not returned by value: `App.db` / `.event_bus`
    // point into this struct, so it must live in the caller's frame.
    var backend: headless.boot.Backend = undefined;
    headless.boot.boot(&backend, allocator, io, environment, .{ .log_file = log_file, .db_request = db_request }) catch |err| {
        std.log.err("headless: boot failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    const json = headless.group.run(allocator, &backend, a) catch |err| {
        // stdout is the machine channel: a failure never prints a half object.
        std.log.err("headless: group {s} failed: {s}", .{ @tagName(a.op), @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(json);

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(json);
    try w.interface.writeAll("\n");
    try w.interface.flush();

    backend.finish(0);
}

/// Boot the backend, run one memories op, print its JSON, tear down.
fn runMemories(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    a: headless.args.MemoriesArgs,
    log_file: ?[]const u8,
    db_request: db_target.Request,
) !void {
    var backend: headless.boot.Backend = undefined;
    headless.boot.boot(&backend, allocator, io, environment, .{ .log_file = log_file, .db_request = db_request }) catch |err| {
        std.log.err("headless: boot failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    const json = headless.memories.run(allocator, &backend, a) catch |err| {
        std.log.err("headless: memories {s} failed: {s}", .{ @tagName(a.op), @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(json);

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(json);
    try w.interface.writeAll("\n");
    try w.interface.flush();

    backend.finish(0);
}

/// Write `s` as a quoted, escaped JSON string.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    const hex = "0123456789abcdef";
                    try w.writeAll("\\u00");
                    try w.writeByte(hex[c >> 4]);
                    try w.writeByte(hex[c & 0xf]);
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

/// Flush `bytes` to stdout in one write.
fn writeStdout(io: std.Io, bytes: []const u8) !void {
    const stdout = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = stdout.writer(io, &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn runMcpOAuth(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    a: headless.args.McpOAuthArgs,
    log_file: ?[]const u8,
    db_request: db_target.Request,
) !void {
    var backend: headless.boot.Backend = undefined;
    headless.boot.boot(&backend, allocator, io, environment, .{ .log_file = log_file, .db_request = db_request }) catch |err| {
        std.log.err("headless: boot failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    const json = headless.mcp_oauth.run(allocator, &backend, a) catch |err| {
        std.log.err("headless: mcp-oauth {s} failed: {s}", .{ @tagName(a.op), @errorName(err) });
        backend.finish(1);
    };
    defer allocator.free(json);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll(json);
    try out.writer.writeByte('\n');
    try writeStdout(io, out.written());
    backend.finish(0);
}
