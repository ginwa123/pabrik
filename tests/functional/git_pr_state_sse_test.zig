// Functional e2e for the `git_pr_state` SSE push. The bug this channel
// closes: merging a change request from the PR tab's merge box recoloured the
// PR tab's own badge and told nobody else.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const Io = std.Io;

const gpa = testing.allocator;
const io = testing.io;

/// How long the stream may take to deliver the `connected` handshake.
const handshake_timeout_ms: i64 = 3_000;

/// How long a pushed state event may take to arrive after the POST returns.
const push_timeout_ms: i64 = 5_000;

/// How long the negative case waits before it may conclude "no event".
const quiet_window_ms: i64 = 1_500;

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
        return gpa.dupe(u8, "<unavailable>") catch @panic("OOM in a failure-diagnostic helper");
    };
}

// ============================================================================
// Fixture
// ============================================================================

/// The suite's own scratch directory (the git repo + every fake bin),
/// outside the harness's tempdir namespace.
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

/// `git` in `cwd` with the fixture identity baked in, so the fixture never
/// depends on the machine's global git config.
fn git(cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        "git",                  "-c",          "user.email=t@t",
        "-c",                   "user.name=t", "-c",
        "commit.gpgsign=false",
    });
    try argv.appendSlice(gpa, args);

    var child = try std.process.spawn(io, .{ .argv = argv.items, .cwd = .{ .path = cwd } });
    const term = child.wait(io) catch |err| {
        std.debug.print("git {s} did not wait: {s}\n", .{ args[0], @errorName(err) });
        return error.SkipZigTest;
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("git {s} exited {d}\n", .{ args[0], code });
            return error.TestUnexpectedResult;
        },
        else => {
            std.debug.print("git {s} died by signal\n", .{args[0]});
            return error.TestUnexpectedResult;
        },
    }
}

/// `git init` plus one commit, so `path` is a real worktree: the merge
/// handler's status re-read gates on `git rev-parse --git-dir`.
fn buildRepo(s: *Scratch) ![]u8 {
    const cwd = try s.path(&.{"pr-state-proj"});
    errdefer gpa.free(cwd);

    try std.Io.Dir.cwd().createDirPath(io, cwd);
    try git(s.root, &.{ "init", "--initial-branch=main", "--quiet", cwd });

    {
        const p = try std.fs.path.join(gpa, &.{ cwd, "a.txt" });
        defer gpa.free(p);
        var f = try std.Io.Dir.cwd().createFile(io, p, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "hi\n");
    }
    try git(cwd, &.{ "add", "-A" });
    try git(cwd, &.{ "commit", "--quiet", "-m", "base" });

    return cwd;
}

/// Write an executable `/bin/sh` script at `path`.
fn writeExecScript(path: []const u8, contents: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
    try std.Io.Dir.cwd().setFilePermissions(io, path, .executable_file, .{});
}

/// Put an executable stub named `bin_name` in its OWN bindir inside `s`,
/// so prepending that directory to PATH cannot shadow another command the
/// server needs (`git` in particular — the repo gate runs it).
fn installFakeCli(s: *Scratch, dir_name: []const u8, bin_name: []const u8, body: []const u8) ![]u8 {
    const bindir = try s.path(&.{dir_name});
    errdefer gpa.free(bindir);
    try std.Io.Dir.cwd().createDirPath(io, bindir);

    const bin_path = try std.fs.path.join(gpa, &.{ bindir, bin_name });
    defer gpa.free(bin_path);
    try writeExecScript(bin_path, body);

    return bindir;
}

/// Prepend `prefix` to `PATH` in `std.testing.environ` — the exact block
/// `Harness.boot` copies into the child env. Scoped by `restore`, or every
/// later suite in the same process would spawn the fake CLI.
const PathShadow = struct {
    gpa: std.mem.Allocator,
    saved: std.process.Environ,
    entries: [:null]const ?[*:0]const u8,

    fn install(alloc: std.mem.Allocator, prefix: []const u8) !PathShadow {
        if (comptime @import("builtin").os.tag != .windows) {
            const saved = std.testing.environ;
            const orig = saved.block.slice;

            const entries = try alloc.allocSentinel(?[*:0]const u8, orig.len, null);
            errdefer alloc.free(entries);

            var owned: std.ArrayList([:0]u8) = .empty;
            defer owned.deinit(alloc);
            errdefer for (owned.items) |o| alloc.free(o);

            for (orig, 0..) |maybe, i| {
                const s = std.mem.span(maybe.?);
                if (std.mem.startsWith(u8, s, "PATH=")) {
                    try owned.append(alloc, try std.fmt.allocPrintSentinel(alloc, "PATH={s}{c}{s}", .{
                        prefix,
                        std.fs.path.delimiter,
                        s["PATH=".len..],
                    }, 0));
                } else {
                    try owned.append(alloc, try alloc.dupeZ(u8, s));
                }
                entries[i] = owned.items[owned.items.len - 1].ptr;
            }

            std.testing.environ = .{ .block = .{ .slice = entries } };
            return .{ .gpa = alloc, .saved = saved, .entries = entries };
        } else {
            return error.SkipZigTest;
        }
    }

    fn restore(self: PathShadow) void {
        std.testing.environ = self.saved;
        for (self.entries) |e| self.gpa.free(std.mem.span(e.?));
        self.gpa.free(self.entries);
    }
};

// ============================================================================
// The fake forge CLI
// ============================================================================

/// The head commit every test promises to be merging, mirrored in the
/// payload below (the merge box sends `head_sha` as a guard).
const HEAD_SHA = "4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e";
const TITLE = "fix(chatview): land where the reader left it (#891)";

/// `gh` as the merge box uses it: `pr view` answers `view_json`, and `pr
/// merge` records its argv (one arg per line) and exits 0.
fn ghScript(argv_path: []const u8, view_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\#!/bin/sh
        \\case "$1-$2" in
        \\  pr-view|mr-view)
        \\    for a in "$@"; do echo "$a"; done > '{s}.view'
        \\    cat <<'EOF'
        \\{s}
        \\EOF
        \\    ;;
        \\  pr-merge|mr-merge)
        \\    for a in "$@"; do echo "$a"; done > '{s}'
        \\    exit 0
        \\    ;;
        \\  *)
        \\    echo "unexpected argv: $@" >&2
        \\    exit 7
        \\    ;;
        \\esac
    , .{ argv_path, view_json, argv_path });
}

/// #891 as the forge reports it AFTER the merge landed. `headRefName` is the
/// branch the SSE payload must carry — it is half of the frontend's cache key.
const GH_MERGED_JSON =
    \\{"number": 891, "title": "Scroll restore", "url": "https://github.com/ginwa123/pabrik/pull/891", "state": "MERGED", "mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN", "headRefName": "worktree/add-a-button", "baseRefName": "main", "createdAt": "2026-10-11T00:00:00Z", "updatedAt": "2026-10-11T01:00:00Z", "mergedAt": "2026-10-11T01:00:00Z", "closedAt": null, "author": {"login": "ginwa123"}, "additions": 97, "deletions": 77, "changedFiles": 5, "headRefOid": "4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e"}
;

/// #891 still OPEN — the merge-queue / armed-auto-merge shape. The command
/// was accepted; the change request has not merged, so nothing moved and no
/// state event may be emitted.
const GH_OPEN_JSON =
    \\{"number": 891, "title": "Scroll restore", "url": "https://github.com/ginwa123/pabrik/pull/891", "state": "OPEN", "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefName": "worktree/add-a-button", "baseRefName": "main", "createdAt": "2026-10-11T00:00:00Z", "updatedAt": "2026-10-11T00:30:00Z", "mergedAt": null, "closedAt": null, "author": {"login": "ginwa123"}, "additions": 97, "deletions": 77, "changedFiles": 5, "headRefOid": "4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e"}
;

/// The body the merge box sends — built the same way, so a field rename on
/// either side fails here rather than in the browser.
fn mergeBody(repo: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{{\"path\":\"{s}\",\"pr\":\"891\",\"provider\":\"github\",\"method\":\"squash\",\"title\":\"{s}\",\"body\":\"\",\"delete_branch\":false,\"head_sha\":\"{s}\"}}",
        .{ repo, TITLE, HEAD_SHA },
    );
}

/// Boot a harness with the fake `gh` on PATH and a real repo, all cleaned up
/// on the way out. The caller owns `scratch`, `repo` and `shadow`.
fn bootWithFakeGh(s: *Scratch, repo: *[]u8, shadow: *PathShadow, view_json: []const u8) !Harness {
    repo.* = try buildRepo(s);

    const argv_path = try s.path(&.{"gh-argv"});
    defer gpa.free(argv_path);
    const script = try ghScript(argv_path, view_json);
    defer gpa.free(script);
    const bindir = try installFakeCli(s, "bin-ok", "gh", script);
    defer gpa.free(bindir);

    // The child inherits `std.testing.environ`, so PATH must be shadowed
    // BEFORE the server boots.
    shadow.* = try PathShadow.install(gpa, bindir);

    return Harness.boot(io, gpa, .{});
}

// ============================================================================
// Tests
// ============================================================================

// GET /api/events?channels=git_pr_state returns 200 SSE + connected.
test "git_pr_state_channel_handshake" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const s = try openSse(h.port, "git_pr_state");
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

// POST /api/git/pr/merge pushes `event: git_pr_state_merged` carrying the
// action, the cwd and the head branch — the pair the badges' cache is keyed on.
test "merge_pushes_git_pr_state_merged_event" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();

    var repo: []u8 = undefined;
    defer gpa.free(repo);
    var shadow: PathShadow = undefined;
    defer shadow.restore();

    var h = try bootWithFakeGh(&s, &repo, &shadow, GH_MERGED_JSON);
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // Subscribe BEFORE the POST: the emit is synchronous with the handler, so
    // a stream opened afterwards would miss the frame entirely.
    const stream = try openSse(h.port, "git_pr_state");
    defer stream.deinit();
    const reader = try std.Thread.spawn(.{}, readEvents, .{stream});
    defer reader.join();
    try testing.expect(waitForEvent(stream, "connected", handshake_timeout_ms));

    const body = try mergeBody(repo);
    defer gpa.free(body);
    {
        var r = try h.http(io, .POST, "/api/git/pr/merge", .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
    }

    const got = waitForEvent(stream, "git_pr_state_merged", push_timeout_ms);
    releaseReader(stream);

    if (!got) {
        const names = seenNames(stream);
        defer gpa.free(names);
        std.debug.print("expected 'git_pr_state_merged' within 5s; saw: [{s}]\n", .{names});
        return error.TestUnexpectedResult;
    }

    const data = dataForEvent(stream, "git_pr_state_merged") orelse return error.NoPayload;
    // Arena, not `gpa`: `parseFromSliceLeaky` deliberately does not free its
    // allocations, and `testing.allocator` reports every one of them as a leak.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), data, .{}) catch return error.BadPayload;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.BadPayload,
    };
    try testing.expectEqualStrings("merged", obj.get("action").?.string);
    // The cwd the forge command ran in, and the head branch the frontend's
    // cache key is built from — a badge cannot re-read the right entry without
    // both.
    try testing.expectEqualStrings(repo, obj.get("cwd").?.string);
    try testing.expectEqualStrings("worktree/add-a-button", obj.get("branch").?.string);
}

// An accepted-but-not-merged command (merge queue / armed auto-merge) leaves
// the change request OPEN, so no state event may be pushed — the badges must
// not be told to re-colour for a merge that did not happen.
test "pending_merge_pushes_no_state_event" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();

    var repo: []u8 = undefined;
    defer gpa.free(repo);
    var shadow: PathShadow = undefined;
    defer shadow.restore();

    var h = try bootWithFakeGh(&s, &repo, &shadow, GH_OPEN_JSON);
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const stream = try openSse(h.port, "git_pr_state");
    defer stream.deinit();
    const reader = try std.Thread.spawn(.{}, readEvents, .{stream});
    defer reader.join();

    // THE POSITIVE CONTROL. Without it, "no event" also passes on a stream that
    // never connected at all — the absence assertion would be vacuous.
    if (!waitForEvent(stream, "connected", handshake_timeout_ms)) {
        const names = seenNames(stream);
        defer gpa.free(names);
        releaseReader(stream);
        std.debug.print("the stream never connected, so the silence below proves nothing; saw: [{s}]\n", .{names});
        return error.TestUnexpectedResult;
    }

    const body = try mergeBody(repo);
    defer gpa.free(body);
    {
        var r = try h.http(io, .POST, "/api/git/pr/merge", .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        // The response proves the merge path RAN (and answered `pending`), so
        // the silence is about the event, not about a request that never
        // reached the handler.
        if (doc.boolean("pending") != true) {
            std.debug.print("expected pending=true from an OPEN re-read: {s}\n", .{r.body});
            releaseReader(stream);
            return error.TestUnexpectedResult;
        }
    }

    const saw_merged = waitForEvent(stream, "git_pr_state_merged", quiet_window_ms);
    releaseReader(stream);
    if (saw_merged) {
        std.debug.print("a pending merge pushed git_pr_state_merged — the change request is still open\n", .{});
        return error.TestUnexpectedResult;
    }
}
