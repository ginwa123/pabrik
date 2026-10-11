//! `pabrik headless ...` subcommand dispatch.
//!
//! Peeks at argv[1] and returns false when it does not match, so `main`
//! falls through to the regular server boot. Return true means handled
//! (main must exit).
//!
//! This lives beside `dispatchServiceSubcommand` and `dispatchCreateAdmin`
//! rather than inside either of them because headless mode is a different
//! KIND of subcommand: `service` and `create-admin` are short-lived
//! utilities that touch the DB and exit, while `headless` boots the whole
//! backend and runs a turn. Sharing a dispatcher would mean one function
//! with two unrelated lifetimes.

const std = @import("std");
const pabrikcore = @import("pabrikcore");

const headless = @import("../headless/mod.zig");

/// `pabrik headless {run,sessions,messages,help}`.
///
/// Returns true when the subcommand was recognised and handled — including
/// when it failed, because a failed headless run has already reported
/// itself and the process should exit non-zero rather than fall through
/// to booting a server.
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

    // `--log-file` is a global flag, so it is pulled out before the verb
    // parser sees the argv — the same strip-globals-first shape
    // `pabrikcli`'s main.zig uses.
    var log_file: ?[]const u8 = null;
    var verb_argv: std.ArrayList([]const u8) = .empty;
    defer verb_argv.deinit(allocator);
    {
        var i: usize = 0;
        while (i < rest.items.len) : (i += 1) {
            if (std.mem.eql(u8, rest.items[i], "--log-file")) {
                i += 1;
                if (i >= rest.items.len) {
                    std.log.err("headless: --log-file requires a value", .{});
                    return true;
                }
                log_file = rest.items[i];
            } else {
                try verb_argv.append(allocator, rest.items[i]);
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
        .run => |a| try runTurn(allocator, io, environment, a, log_file),
        .sessions => |a| try listSessions(allocator, io, environment, a, log_file),
        .messages => |a| try listMessages(allocator, io, environment, a, log_file),
    }
    return true;
}

/// Boot the backend, run one turn, print the result, tear down.
///
/// The teardown is a `defer` rather than an inline sequence so an error
/// return from any phase still releases the DB handle and the scheduler.
fn runTurn(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    a: headless.args.RunArgs,
    log_file: ?[]const u8,
) !void {
    // Declared HERE, not returned by value: `App.db` / `.event_bus`
    // point into this struct, so it must live in the
    // caller's frame. See the `boot.zig` module header.
    var backend: headless.boot.Backend = undefined;
    headless.boot.boot(&backend, allocator, io, environment, .{ .log_file = log_file }) catch |err| {
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
    //
    // `finish`, not `std.process.exit` + `defer deinit`: the routine
    // scheduler is still parked in a 5s sleep holding `*ctx`, so unwinding
    // would free the context under it. See `Backend.finish`.
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
) !void {
    // Declared HERE, not returned by value: `App.db` / `.event_bus`
    // point into this struct, so it must live in the
    // caller's frame. See the `boot.zig` module header.
    var backend: headless.boot.Backend = undefined;
    headless.boot.boot(&backend, allocator, io, environment, .{ .log_file = log_file }) catch |err| {
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
) !void {
    // Declared HERE, not returned by value: `App.db` / `.event_bus`
    // point into this struct, so it must live in the
    // caller's frame. See the `boot.zig` module header.
    var backend: headless.boot.Backend = undefined;
    headless.boot.boot(&backend, allocator, io, environment, .{ .log_file = log_file }) catch |err| {
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
        try w.writeByte('}');
    }
    try w.writeAll("]}\n");

    try writeStdout(io, out.written());
    backend.finish(0);
}

/// Write `s` as a quoted, escaped JSON string.
///
/// Hand-rolled rather than `std.json.fmt` because the formatter's `{s}`
/// verb does not accept a `Formatter` value — and because every field
/// written here is free text (an assistant reply, a session name, a cwd)
/// that can contain a quote, a backslash or a newline. An unescaped
/// newline in the assistant text would produce a stdout blob that no JSON
/// parser accepts, which is the one thing this command promises not to do.
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
