// Functional e2e for the `git_file_stage` SSE push.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const Io = std.Io;

const gpa = testing.allocator;
const io = testing.io;

/// How long the stream may take to deliver the `connected` handshake.
const handshake_timeout_ms: i64 = 3_000;

/// How long a pushed stage event may take to arrive after the POST returns.
const push_timeout_ms: i64 = 5_000;

/// Transfer buffer for the response body reader. NOT `&.{}` — see
/// background_process_sse_test.zig for why an empty slice livelocks.
const transfer_buffer_len = 8 * 1024;

fn nowMs() i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// One parsed SSE frame: the `event:` name plus the joined `data:` lines.
const SseEvent = struct {
    name: []u8,
    data: []u8,

    fn deinit(self: *SseEvent) void {
        gpa.free(self.name);
        gpa.free(self.data);
        self.* = undefined;
    }
};

/// An open SSE connection plus the state the reader thread fills in.
const SseStream = struct {
    client: std.http.Client,
    req: std.http.Client.Request,
    transfer_buffer: [transfer_buffer_len]u8 = undefined,
    body: *std.Io.Reader = undefined,
    status: u16 = 0,
    content_type: []u8 = "",
    stop: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    events: std.ArrayList(SseEvent) = .empty,
    read_error: ?[]u8 = null,

    fn deinit(self: *SseStream) void {
        self.req.deinit();
        self.client.deinit();
        gpa.free(self.content_type);
        for (self.events.items) |*e| e.deinit();
        self.events.deinit(gpa);
        if (self.read_error) |m| gpa.free(m);
        gpa.destroy(self);
    }
};

fn openSse(port: u16, channels: []const u8) !*SseStream {
    const s = try gpa.create(SseStream);
    errdefer gpa.destroy(s);

    // `gpa.create` returns UNINITIALIZED memory — it does NOT run the
    // struct's field default initializers. `s.* = .{...}` applies them all
    // in one shot; `req` is genuinely assigned by `request()` below.
    s.* = .{ .client = .{ .allocator = gpa, .io = io }, .req = undefined };

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/api/events?channels={s}", .{ port, channels });
    defer gpa.free(url);

    s.req = s.client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .extra_headers = &.{
            .{ .name = "Accept", .value = "text/event-stream" },
        },
    }) catch |err| {
        s.client.deinit();
        return err;
    };
    errdefer {
        s.req.deinit();
        s.client.deinit();
    }

    try s.req.sendBodiless();
    var resp = try s.req.receiveHead(&.{});
    s.status = @intFromEnum(resp.head.status);

    // Headers FIRST: `resp.reader()` calls `head.invalidateStrings()`.
    {
        var hit = resp.head.iterateHeaders();
        while (hit.next()) |kv| {
            if (std.ascii.eqlIgnoreCase(kv.name, "content-type")) {
                s.content_type = try gpa.dupe(u8, kv.value);
                break;
            }
        }
    }

    s.body = resp.reader(&s.transfer_buffer);
    return s;
}

/// Read SSE frames from `s` until `stop` is set, the stream ends, or an
/// error occurs. Runs on its own thread.
fn readEvents(s: *SseStream) void {
    defer s.done.store(true, .release);

    const reader = s.body;

    var current_name: ?[]u8 = null;
    defer if (current_name) |n| gpa.free(n);

    var data_lines: std.ArrayList([]u8) = .empty;
    defer {
        for (data_lines.items) |d| gpa.free(d);
        data_lines.deinit(gpa);
    }

    while (!s.stop.load(.acquire)) {
        // `takeDelimiter` — NOT `takeDelimiterExclusive`. The Exclusive
        // variant leaves the `\n` in the buffer, so the next call finds a
        // delimiter at position 0 and returns a ZERO-LENGTH slice, forever.
        const raw_line_opt = reader.takeDelimiter('\n') catch |err| {
            const msg = switch (err) {
                error.ReadFailed => "read failed",
                error.StreamTooLong => "line exceeded the transfer buffer",
            };
            const owned = gpa.dupe(u8, msg) catch return;
            s.mutex.lockUncancelable(io);
            s.read_error = owned;
            s.mutex.unlock(io);
            return;
        };
        if (raw_line_opt == null) {
            const owned = gpa.dupe(u8, "stream ended") catch return;
            s.mutex.lockUncancelable(io);
            s.read_error = owned;
            s.mutex.unlock(io);
            return;
        }
        const line = std.mem.trimEnd(u8, raw_line_opt.?, "\r");

        if (line.len == 0) {
            // Blank line → dispatch whatever we accumulated.
            if (current_name) |name| {
                const joined = std.mem.join(gpa, "\n", data_lines.items) catch "";
                const data: []u8 = @constCast(joined);
                s.mutex.lockUncancelable(io);
                s.events.append(gpa, .{ .name = name, .data = data }) catch {
                    s.mutex.unlock(io);
                    gpa.free(name);
                    gpa.free(data);
                    for (data_lines.items) |d| gpa.free(d);
                    data_lines.clearRetainingCapacity();
                    return;
                };
                s.mutex.unlock(io);
                current_name = null;
            }
            for (data_lines.items) |d| gpa.free(d);
            data_lines.clearRetainingCapacity();
            continue;
        }

        if (std.mem.startsWith(u8, line, "event:")) {
            if (current_name) |old| gpa.free(old);
            current_name = gpa.dupe(u8, std.mem.trim(u8, line["event:".len..], " \t")) catch null;
        } else if (std.mem.startsWith(u8, line, "data:")) {
            const v = gpa.dupe(u8, std.mem.trim(u8, line["data:".len..], " \t")) catch continue;
            data_lines.append(gpa, v) catch {
                gpa.free(v);
                continue;
            };
        }
    }
}

/// Release a blocked `readEvents` by shutting the socket's read side.
fn releaseReader(s: *SseStream) void {
    s.stop.store(true, .release);
    s.req.connection.?.stream_reader.stream.shutdown(io, .recv) catch {};
}

/// Wait until an event named `want` is in `s.events`, or the deadline
/// passes. Returns true iff the event was seen.
fn waitForEvent(s: *SseStream, want: []const u8, timeout_ms: i64) bool {
    const deadline = nowMs() + timeout_ms;
    while (true) {
        // Snapshot under the lock, then RELEASE it before sleeping —
        // holding the mutex across `Io.sleep` starves the reader.
        s.mutex.lockUncancelable(io);
        const found = blk: {
            for (s.events.items) |e| {
                if (std.mem.eql(u8, e.name, want)) break :blk true;
            }
            break :blk false;
        };
        const finished = s.done.load(.acquire);
        s.mutex.unlock(io);

        if (found) return true;
        if (finished) return false;
        if (nowMs() >= deadline) return false;
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
}

/// The `data:` payload of the first event named `want`, or null.
fn dataForEvent(s: *SseStream, want: []const u8) ?[]const u8 {
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    for (s.events.items) |e| {
        if (std.mem.eql(u8, e.name, want)) return e.data;
    }
    return null;
}

/// A copy of the event names seen so far, for the failure message.
fn seenNames(s: *SseStream) []u8 {
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (s.events.items) |e| out.writer.print("{s} ", .{e.name}) catch break;
    return out.toOwnedSlice() catch |err| {
        out.deinit();
        std.debug.print("could not render the seen-events list: {s}\n", .{@errorName(err)});
        return gpa.dupe(u8, "<unavailable>") catch @panic("dupe of the <unavailable> literal failed");
    };
}

// ============================================================================
// Fixture
// ============================================================================

fn git(cwd: []const u8, args: []const []const u8) !void {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, &.{
        "git",
        "-c",
        "user.email=t@t",
        "-c",
        "user.name=Test Author",
        "-c",
        "commit.gpgsign=false",
    });
    try full.appendSlice(gpa, args);

    var child = try std.process.spawn(io, .{ .argv = full.items, .cwd = .{ .path = cwd } });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("git {s} failed with rc={d}\n", .{ args[args.len - 1], code });
            return error.TestUnexpectedResult;
        },
        else => {
            std.debug.print("git {s} died by signal\n", .{args[args.len - 1]});
            return error.TestUnexpectedResult;
        },
    }
}

fn writeFileAt(dir: std.Io.Dir, name: []const u8, contents: []const u8) !void {
    var f = try dir.createFile(io, name, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

/// Build `stage-proj`: one commit, then one MODIFIED (unstaged) file and one
/// UNTRACKED file — the exact rows the `+` button sits on.
fn buildStageRepo(scratch: []const u8) ![]u8 {
    const repo = try std.fs.path.join(gpa, &.{ scratch, "stage-proj" });
    errdefer gpa.free(repo);

    try std.Io.Dir.cwd().createDirPath(io, repo);
    var repo_dir = try std.Io.Dir.cwd().openDir(io, repo, .{});
    defer repo_dir.close(io);

    try git(scratch, &.{ "init", "--initial-branch=main", "--quiet", repo });
    try git(repo, &.{ "config", "user.email", "t@t" });
    try git(repo, &.{ "config", "user.name", "Test Author" });
    try git(repo, &.{ "config", "commit.gpgsign", "false" });

    try writeFileAt(repo_dir, "tracked.txt", "one\n");
    try git(repo, &.{ "add", "-A" });
    try git(repo, &.{ "commit", "--quiet", "-m", "first" });

    // Modified but NOT staged — the Changes row.
    try writeFileAt(repo_dir, "tracked.txt", "two\n");
    // Untracked — the Untracked row.
    try writeFileAt(repo_dir, "loose.txt", "brand new\n");

    return repo;
}

/// Boot a harness plus the fixture repo, with both cleaned up on the way
/// out. DEFER ORDER IS LIFO AND LOADS-BEARING: `free(scratch)` is
/// registered BEFORE `cleanupExtraDir(scratch)`.
fn bootWithRepo(h: *Harness, scratch: *[]u8, repo: *[]u8) !void {
    try harness.requirePabrikBin(io, gpa);
    h.* = try Harness.boot(io, gpa, .{});

    scratch.* = harness.makeScratchDir(gpa) catch |err| {
        h.deinit(io) catch {};
        return err;
    };
    repo.* = buildStageRepo(scratch.*) catch |err| {
        harness.cleanupExtraDir(io, gpa, scratch.*);
        h.deinit(io) catch {};
        return err;
    };
}

/// POST /api/git/stage or /api/git/unstage. Caller owns the Response.
fn postStage(
    h: *Harness,
    endpoint: []const u8,
    repo: []const u8,
    file: []const u8,
    expect: []const u16,
) !harness.Response {
    const url = try std.fmt.allocPrint(
        gpa,
        "/api/git/{s}?path={s}&files={s}",
        .{ endpoint, repo, file },
    );
    defer gpa.free(url);
    return h.http(io, .POST, url, .{ .expect = expect, .timeout_s = 20.0 });
}

// ============================================================================
// Tests
// ============================================================================

// GET /api/events?channels=git_file_stage returns 200 SSE + connected.
test "git_file_stage_channel_handshake" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const s = try openSse(h.port, "git_file_stage");
    defer s.deinit();

    try testing.expectEqual(@as(u16, 200), s.status);
    if (std.mem.indexOf(u8, s.content_type, "text/event-stream") == null) {
        std.debug.print("expected SSE content-type, got '{s}'\n", .{s.content_type});
        return error.TestUnexpectedResult;
    }

    const reader = try std.Thread.spawn(.{}, readEvents, .{s});
    defer reader.join();

    const got = waitForEvent(s, "connected", handshake_timeout_ms);
    releaseReader(s);

    if (!got) {
        const names = seenNames(s);
        defer gpa.free(names);
        s.mutex.lockUncancelable(io);
        const reason = if (s.read_error) |m| m else "";
        s.mutex.unlock(io);
        if (reason.len > 0) {
            std.debug.print("expected 'connected' within 3s, stream reported: {s}\n", .{reason});
        } else {
            std.debug.print("expected 'connected' within 3s; saw: [{s}]\n", .{names});
        }
        return error.TestUnexpectedResult;
    }
}

// POST /api/git/stage pushes `event: git_file_staged` with the path, the
// cwd and `failed: false` — the payload the panel's row move reads.
test "stage_pushes_git_file_staged_event" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var repo: []u8 = undefined;
    try bootWithRepo(&h, &scratch, &repo);
    defer {
        gpa.free(repo);
        harness.cleanupExtraDir(io, gpa, scratch);
        gpa.free(scratch);
        h.deinit(io) catch {};
    }

    // Subscribe BEFORE the POST: the emit is synchronous with the handler,
    // so a stream opened afterwards would miss the frame entirely.
    const s = try openSse(h.port, "git_file_stage");
    defer s.deinit();
    const reader = try std.Thread.spawn(.{}, readEvents, .{s});
    defer reader.join();
    try testing.expect(waitForEvent(s, "connected", handshake_timeout_ms));

    {
        var r = try postStage(&h, "stage", repo, "tracked.txt", &.{200});
        defer r.deinit();
    }

    const got = waitForEvent(s, "git_file_staged", push_timeout_ms);
    releaseReader(s);

    if (!got) {
        const names = seenNames(s);
        defer gpa.free(names);
        std.debug.print("expected 'git_file_staged' within 5s; saw: [{s}]\n", .{names});
        return error.TestUnexpectedResult;
    }

    const data = dataForEvent(s, "git_file_staged") orelse return error.NoPayload;
    // Arena, not `gpa`: `parseFromSliceLeaky` deliberately does not free its
    // allocations, and `testing.allocator` reports every one of them as a
    // leak. The arena is dropped wholesale at the end of the test.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), data, .{}) catch return error.BadPayload;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.BadPayload,
    };
    try testing.expectEqualStrings("staged", obj.get("action").?.string);
    try testing.expectEqualStrings("tracked.txt", obj.get("path").?.string);
    try testing.expectEqualStrings(repo, obj.get("cwd").?.string);
    // A successful `git add` must report `failed: false` — the panel only
    // moves a row when this is false.
    try testing.expect(!obj.get("failed").?.bool);
}

// POST /api/git/unstage pushes `event: git_file_unstaged`.
test "unstage_pushes_git_file_unstaged_event" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var repo: []u8 = undefined;
    try bootWithRepo(&h, &scratch, &repo);
    defer {
        gpa.free(repo);
        harness.cleanupExtraDir(io, gpa, scratch);
        gpa.free(scratch);
        h.deinit(io) catch {};
    }

    // Stage first so there is something in the index to unstage.
    {
        var r = try postStage(&h, "stage", repo, "tracked.txt", &.{200});
        defer r.deinit();
    }

    const s = try openSse(h.port, "git_file_stage");
    defer s.deinit();
    const reader = try std.Thread.spawn(.{}, readEvents, .{s});
    defer reader.join();
    try testing.expect(waitForEvent(s, "connected", handshake_timeout_ms));

    {
        var r = try postStage(&h, "unstage", repo, "tracked.txt", &.{200});
        defer r.deinit();
    }

    const got = waitForEvent(s, "git_file_unstaged", push_timeout_ms);
    releaseReader(s);

    if (!got) {
        const names = seenNames(s);
        defer gpa.free(names);
        std.debug.print("expected 'git_file_unstaged' within 5s; saw: [{s}]\n", .{names});
        return error.TestUnexpectedResult;
    }

    const data = dataForEvent(s, "git_file_unstaged") orelse return error.NoPayload;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), data, .{}) catch return error.BadPayload;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.BadPayload,
    };
    try testing.expectEqualStrings("unstaged", obj.get("action").?.string);
    try testing.expectEqualStrings("tracked.txt", obj.get("path").?.string);
    try testing.expect(!obj.get("failed").?.bool);
}

// A stage request for a path git refuses still answers 200 and pushes an
// event carrying `failed: true` — the panel must NOT move that row.
test "failed_stage_pushes_failed_true" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var repo: []u8 = undefined;
    try bootWithRepo(&h, &scratch, &repo);
    defer {
        gpa.free(repo);
        harness.cleanupExtraDir(io, gpa, scratch);
        gpa.free(scratch);
        h.deinit(io) catch {};
    }

    const s = try openSse(h.port, "git_file_stage");
    defer s.deinit();
    const reader = try std.Thread.spawn(.{}, readEvents, .{s});
    defer reader.join();
    try testing.expect(waitForEvent(s, "connected", handshake_timeout_ms));

    // A path that does not exist: `git add` exits non-zero, so the handler
    // records it as failed. The HTTP response is still 200 (the batch
    // contract reports per-file failures in the body, not the status).
    {
        var r = try postStage(&h, "stage", repo, "does-not-exist.txt", &.{200});
        defer r.deinit();
    }

    const got = waitForEvent(s, "git_file_staged", push_timeout_ms);
    releaseReader(s);

    if (!got) {
        const names = seenNames(s);
        defer gpa.free(names);
        std.debug.print("expected 'git_file_staged' within 5s; saw: [{s}]\n", .{names});
        return error.TestUnexpectedResult;
    }

    const data = dataForEvent(s, "git_file_staged") orelse return error.NoPayload;
    // Arena, not `gpa`: `parseFromSliceLeaky` deliberately does not free its
    // allocations, and `testing.allocator` reports every one of them as a
    // leak. The arena is dropped wholesale at the end of the test.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), data, .{}) catch return error.BadPayload;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.BadPayload,
    };
    try testing.expectEqualStrings("does-not-exist.txt", obj.get("path").?.string);
    try testing.expect(obj.get("failed").?.bool);
}
