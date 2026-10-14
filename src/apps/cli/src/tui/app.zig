//! App: the chat Model that plugs into `tui.Program`.

const std = @import("std");
const tui = @import("root.zig");
const custom_http_client = @import("kabelweb").client;
const transport = @import("transport.zig");
const render_msg = @import("render_msg.zig");

/// Case-insensitive ASCII equality. Avoids a std lib function that may
/// or may not be available depending on Zig patch version.
fn asciiEqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Poll cadence while waiting for the assistant reply (ms).
const POLL_MS: u64 = 500;

pub const Config = struct {
    server: []const u8 = "http://localhost:8081",
    session_id: ?[]const u8 = null,
    cwd: []const u8 = "",
};

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,

    viewport: tui.Viewport,
    input: tui.Input,
    spinner: tui.Spinner,
    status: tui.StatusBar,

    http_client: custom_http_client.Client,

    session_id: ?[]u8 = null,
    is_streaming: bool = false,
    /// IDs of messages already rendered from a prior poll. Used to dedupe
    /// re-polls — the server returns the LAST N messages on every poll, so we
    /// must NOT re-render rows we've already shown.
    seen_ids: std.StringHashMapUnmanaged(void) = .empty,
    /// Milliseconds accumulated since the last poll.
    since_poll_ms: u64 = 0,
    /// Last rendered viewport height (in rows). Recorded at the end
    /// of `App.view` so the scroll bindings (PgUp/PgDn) can step by
    /// `(height - 2)` — the "one screen minus context" convention.
    last_height: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: Config) !App {
        var app = App{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .viewport = tui.Viewport.init(allocator),
            .input = tui.Input.init(allocator),
            .spinner = .{ .label = "thinking" },
            .status = .{},
            .http_client = custom_http_client.Client.init(allocator),
            .seen_ids = .empty,
        };
        if (cfg.session_id) |sid| {
            app.session_id = try allocator.dupe(u8, sid);
        }
        app.status.setLeft("pabrik-tui");
        app.status.setRight(if (cfg.session_id) |sid| sid else "new session");
        try app.viewport.appendLine("pabrik-tui — type a message, Enter to send, Ctrl-C to quit", .{ .fg = .brightBlack });
        return app;
    }

    pub fn deinit(self: *App) void {
        self.viewport.deinit();
        self.input.deinit();
        if (self.session_id) |sid| self.allocator.free(sid);
        // Free each duped key before the hashmap's buckets are freed.
        // Hashmap's `deinit` does NOT free keys (see std/hash_map.zig
        // "Key memory is managed by the caller").
        var it = self.seen_ids.iterator();
        while (it.next()) |entry| {
            self.allocator.free(@constCast(entry.key_ptr.*));
        }
        self.seen_ids.deinit(self.allocator);
        self.http_client.deinit();
    }

    /// Free a Cmd payload previously returned by `update`. The executor must
    /// call this after consuming the command (mirrors Bubble Tea's ownership:
    /// the model allocates, the runtime frees).
    pub fn freeCmd(self: *App, cmd: tui.Cmd) void {
        switch (cmd) {
            .send_msg => |payload| self.allocator.free(payload),
            else => {},
        }
    }

    pub fn update(self: *App, m: tui.Msg) !tui.Cmd {
        switch (m) {
            .key => |k| return self.handleKey(k),
            .tick => |ms| return self.handleTick(ms),
            .resize => return .none,
            .stream_chunk => return .none, // reserved for SSE follow-up
            .stream_done => {
                self.is_streaming = false;
                return .poll_messages;
            },
            .quit => return .none,
        }
    }

    fn handleKey(self: *App, k: tui.Key) !tui.Cmd {
        // Scroll keys are intercepted BEFORE the input widget sees them,
        // otherwise arrow / page keys would route to input-history nav
        // (Up/Down) or be dropped (PageUp/PageDown/wheel).
        switch (k) {
            .ctrl_c, .ctrl_d => return .none, // Program handles quit itself
            .page_up => {
                // One screen minus a 2-row context line — matches less / vim.
                const step = self.last_height -| 2;
                if (step > 0) self.viewport.scrollUp(step);
                return .none;
            },
            .page_down => {
                const step = self.last_height -| 2;
                if (step > 0) self.viewport.scrollDown(step);
                return .none;
            },
            .wheel_up => {
                // 3 visual rows per wheel notch — matches lazygit / k9s.
                self.viewport.scrollUp(3);
                return .none;
            },
            .wheel_down => {
                self.viewport.scrollDown(3);
                return .none;
            },
            else => {},
        }
        const submitted = try self.input.handleKey(k);
        if (submitted) {
            const hist = self.input.history.items;
            const msg_text = hist[hist.len - 1];
            // NOTE: do NOT echo the user message into the viewport here.
            self.is_streaming = true;
            self.spinner.label = "thinking";
            // The executor (tui_main.execCmd) frees the duped payload.
            return .{ .send_msg = try self.allocator.dupe(u8, msg_text) };
        }
        return .none;
    }

    fn handleTick(self: *App, ms: u64) !tui.Cmd {
        if (self.is_streaming) {
            self.spinner.tick();
            self.since_poll_ms += ms;
            if (self.since_poll_ms >= POLL_MS) {
                self.since_poll_ms = 0;
                return .poll_messages;
            }
        }
        return .none;
    }

    /// Called by the command executor after POST /api/llm/session
    /// succeeds; records/creates the session id.
    pub fn onSendOk(self: *App, session_id: []const u8) !void {
        if (self.session_id == null) {
            self.session_id = try self.allocator.dupe(u8, session_id);
            // The right slot is the session label.
            self.status.setRight(session_id);
        }
    }

    /// Called by the command executor after GET .../messages succeeds. `body`
    /// is the raw JSON response; we render each new message via
    /// `renderMessage` and append the styled `[]Line`s to the viewport.
    pub fn onMessages(self: *App, body: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const tmp_allocator = arena.allocator();
        const parsed = std.json.parseFromSlice(std.json.Value, tmp_allocator, body, .{}) catch {
            // Malformed body — keep streaming and let the next poll try
            // again. Never let a bad JSON snapshot wedge the spinner.
            return;
        };
        defer parsed.deinit();

        const root = parsed.value.object.get("messages") orelse return;
        if (root != .array) return;
        const arr = root.array;
        const last_idx: usize = arr.items.len -| 1;

        // Whether an assistant row first seen in THIS poll finished. Set
        // while rendering below, applied after the loop so the decision can
        // never cut the render of the rows that arrived together with it.
        var turn_finished = false;

        // Render every message we haven't seen yet.
        for (arr.items, 0..) |item, idx| {
            if (item != .object) continue;
            const obj = item.object;

            const id = if (obj.get("id")) |c| (if (c == .string) c.string else "") else "";
            // Backend always returns an id for stored rows; for legacy /
            // synthetic messages without id we still render (no dedupe) so we
            // don't drop them silently.
            if (id.len > 0) {
                const gop = try self.seen_ids.getOrPut(self.allocator, id);
                if (gop.found_existing) continue;
                // Replace the borrowed key with an owned copy.
                const owned = try self.allocator.dupe(u8, id);
                gop.key_ptr.* = owned;
            }

            const role = if (obj.get("role")) |c| (if (c == .string) c.string else "") else "";
            const content = if (obj.get("content")) |c| (if (c == .string) c.string else "") else "";
            const tool_name = if (obj.get("tool_name")) |c| (if (c == .string) c.string else "") else "";
            const reasoning_content = if (obj.get("reasoning_content")) |c| (if (c == .string) c.string else "") else "";

            // Only rows new in this poll can end the turn (see above): the
            // agent emits tool calls, so the last DB row of a finished turn
            // is usually the tool result, not the assistant's final reply.
            if (asciiEqIgnoreCase(role, "assistant")) {
                if (obj.get("finish_reason")) |fr_val| {
                    if (fr_val == .string and std.mem.eql(u8, fr_val.string, "stop")) turn_finished = true;
                } else if (idx == last_idx) {
                    turn_finished = true;
                }
            }

            // Skip messages with no renderable content AND no role (defensive
            // — a row like {"id":"x"} shouldn't render as a blank line).
            if (role.len == 0 and content.len == 0) continue;

            const msg_view = render_msg.MessageView{
                .role = role,
                .content = content,
                .tool_name = tool_name,
                .reasoning_content = reasoning_content,
            };
            var iter_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer iter_arena.deinit();
            const iter_allocator = iter_arena.allocator();
            const tmp_lines = render_msg.renderMessage(iter_allocator, msg_view) catch |err| switch (err) {
                error.OutOfMemory => return,
            };
            for (tmp_lines) |line| {
                const duped_text = try self.allocator.dupe(u8, line.text);
                const owned = tui.widgets.Line{ .text = duped_text, .style = line.style };
                try self.viewport.lines.append(self.allocator, owned);
                self.viewport.enforceCap();
            }
        }

        if (self.is_streaming and turn_finished) self.is_streaming = false;
    }

    pub fn view(self: *App, allocator: std.mem.Allocator, width: u16, height: u16) !tui.Frame {
        // Layout: viewport (h-2), spinner-or-blank (1), status (1).
        const vp_h = height -| 3;
        var out = try tui.Frame.init(allocator, width, height);
        errdefer out.deinit(allocator);

        var vp_frame = try self.viewport.render(allocator, width, vp_h);
        defer vp_frame.deinit(allocator);
        @memcpy(out.cells[0..vp_frame.cells.len], vp_frame.cells);

        const mid_y = vp_h;
        if (self.is_streaming) {
            var sp_frame = try self.spinner.render(allocator, width);
            defer sp_frame.deinit(allocator);
            @memcpy(out.cells[@as(usize, mid_y) * width ..][0..sp_frame.cells.len], sp_frame.cells);
        } else {
            var in_frame = try self.input.render(allocator, width);
            defer in_frame.deinit(allocator);
            @memcpy(out.cells[@as(usize, mid_y) * width ..][0..in_frame.cells.len], in_frame.cells);
            out.cursor = .{ .x = in_frame.cursor.?.x, .y = mid_y };
        }

        var st_frame = try self.status.render(allocator, width);
        defer st_frame.deinit(allocator);
        const st_off = @as(usize, height - 1) * width;
        @memcpy(out.cells[st_off..][0..st_frame.cells.len], st_frame.cells);

        // Record the height so scroll bindings can step by
        // (height - 2). Without this, last_height stays 0 and
        // PgUp/PgDn no-op.
        self.last_height = height;
        return out;
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

fn testApp() !App {
    return App.init(testing.allocator, undefined, .{ .server = "http://test" });
}

test "App: init renders welcome line" {
    var app = try testApp();
    defer app.deinit();
    try testing.expectEqual(@as(usize, 1), app.viewport.lines.items.len);
}

test "App: enter submits send_msg cmd and shows prompt" {
    var app = try testApp();
    defer app.deinit();
    _ = try app.update(.{ .key = .{ .rune = 'h' } });
    _ = try app.update(.{ .key = .{ .rune = 'i' } });
    const cmd = try app.update(.{ .key = .enter });
    try testing.expect(cmd == .send_msg);
    try testing.expectEqualStrings("hi", cmd.send_msg);
    try testing.expect(app.is_streaming);
    app.freeCmd(cmd);
}

test "App: tick accumulates to poll_messages" {
    var app = try testApp();
    defer app.deinit();
    app.is_streaming = true;
    // Below POLL_MS → no poll yet.
    var cmd = try app.update(.{ .tick = 100 });
    try testing.expect(cmd == .none);
    // Cross POLL_MS → poll.
    cmd = try app.update(.{ .tick = 450 });
    try testing.expect(cmd == .poll_messages);
}

test "App: spinner ticks while streaming" {
    var app = try testApp();
    defer app.deinit();
    app.is_streaming = true;
    const before = app.spinner.frame_idx;
    _ = try app.update(.{ .tick = 100 });
    try testing.expectEqual(before + 1, app.spinner.frame_idx);
}

test "App: onMessages appends new assistant content and stops streaming" {
    var app = try testApp();
    defer app.deinit();
    app.is_streaming = true;
    const body =
        \\{"messages":[
        \\ {"id":"u1","role":"user","content":"hi"},
        \\ {"id":"a1","role":"assistant","content":"hello!"}
        \\]}
    ;
    try app.onMessages(body);
    try testing.expect(!app.is_streaming); // assistant replied → done
    // welcome + user + assistant = 3 lines
    try testing.expectEqual(@as(usize, 3), app.viewport.lines.items.len);
}

test "App: onMessages ignores already-seen messages" {
    var app = try testApp();
    defer app.deinit();
    const body =
        \\{"messages":[{"id":"a1","role":"assistant","content":"a"}]}
    ;
    try app.onMessages(body);
    try app.onMessages(body); // same count → no new lines
    try testing.expectEqual(@as(usize, 2), app.viewport.lines.items.len);
}

test "App: onMessages flips is_streaming=false when assistant finish_reason=stop appears mid-array" {
    // Round-3 regression: agent emits tool calls, so the LAST DB row is a
    // tool result, not the assistant's final response.
    var app = try testApp();
    defer app.deinit();
    app.is_streaming = true;
    const body =
        \\{"messages":[
        \\ {"id":"u1","role":"user","content":"hai"},
        \\ {"id":"a1","role":"assistant","content":"","finish_reason":"tool_calls"},
        \\ {"id":"t1","role":"tool","tool_name":"read_file","content":"<tool><name>read_file</name><parameters></parameters><success>true</success><data><path>/foo</path></data></tool>"},
        \\ {"id":"a2","role":"assistant","content":"done","finish_reason":"stop"}
        \\]}
    ;
    try app.onMessages(body);
    try testing.expect(!app.is_streaming);
}

test "App: a previous turn's finish_reason=stop does not end the next turn" {
    // User-reported (2026-09-13): "next prompt response not showup in tui".
    // The poll returns the session's last 100 messages, so it contains the
    // PREVIOUS turn's completed reply.
    var app = try testApp();
    defer app.deinit();

    // Turn 1 runs to completion.
    app.is_streaming = true;
    try app.onMessages(
        \\{"messages":[
        \\ {"id":"u1","role":"user","content":"first"},
        \\ {"id":"a1","role":"assistant","content":"FIRST-REPLY","finish_reason":"stop"}
        \\]}
    );
    try testing.expect(!app.is_streaming);

    // Turn 2: the same array plus the newly queued user row. Nothing in here
    // is new except the user row, so the turn must keep going.
    app.is_streaming = true;
    try app.onMessages(
        \\{"messages":[
        \\ {"id":"u1","role":"user","content":"first"},
        \\ {"id":"a1","role":"assistant","content":"FIRST-REPLY","finish_reason":"stop"},
        \\ {"id":"u2","role":"user","content":"second"}
        \\]}
    );
    try testing.expect(app.is_streaming); // ← the regression

    // Turn 2's reply is a NEW stop row → now the turn is over.
    try app.onMessages(
        \\{"messages":[
        \\ {"id":"u1","role":"user","content":"first"},
        \\ {"id":"a1","role":"assistant","content":"FIRST-REPLY","finish_reason":"stop"},
        \\ {"id":"u2","role":"user","content":"second"},
        \\ {"id":"a2","role":"assistant","content":"SECOND-REPLY","finish_reason":"stop"}
        \\]}
    );
    try testing.expect(!app.is_streaming);
}

test "App: turn 2 renders when the first poll of the turn predates the user row" {
    // The queued user row is inserted by the backend worker, so the first
    // poll after Enter can return the previous snapshot unchanged.
    var app = try testApp();
    defer app.deinit();
    const turn1 =
        \\{"messages":[{"id":"a1","role":"assistant","content":"FIRST","finish_reason":"stop"}]}
    ;
    try app.onMessages(turn1);
    app.is_streaming = true;

    // Poll that raced ahead of the insert: not a single new row.
    try app.onMessages(turn1);
    try testing.expect(app.is_streaming);

    // Next poll carries the user row; the turn is still in flight.
    try app.onMessages(
        \\{"messages":[
        \\ {"id":"a1","role":"assistant","content":"FIRST","finish_reason":"stop"},
        \\ {"id":"u2","role":"user","content":"second"}
        \\]}
    );
    try testing.expect(app.is_streaming);
    const rendered = app.viewport.lines.items[app.viewport.lines.items.len - 1].text;
    try testing.expect(std.mem.indexOf(u8, rendered, "second") != null);
}

test "App: legacy rows without finish_reason only end the turn when they are new" {
    // Same shape, but no `finish_reason` field at all: the fallback
    // ("the last row is an assistant row") must also be scoped to new rows.
    var app = try testApp();
    defer app.deinit();
    const legacy_turn1 =
        \\{"messages":[{"id":"a1","role":"assistant","content":"FIRST"}]}
    ;
    try app.onMessages(legacy_turn1); // (rendered while not streaming)

    app.is_streaming = true;
    try app.onMessages(legacy_turn1); // identical snapshot: no news, no stop
    try testing.expect(app.is_streaming);

    try app.onMessages(
        \\{"messages":[
        \\ {"id":"a1","role":"assistant","content":"FIRST"},
        \\ {"id":"a2","role":"assistant","content":"SECOND"}
        \\]}
    );
    try testing.expect(!app.is_streaming);
}

test "App: status bar shows the session id once, and only in the right slot" {
    var app = try testApp();
    defer app.deinit();
    try testing.expectEqualStrings("pabrik-tui", app.status.left[0..app.status.left_len]);
    try testing.expectEqualStrings("new session", app.status.right[0..app.status.right_len]);

    try app.onSendOk("session-1789312894544");
    try testing.expectEqualStrings("pabrik-tui", app.status.left[0..app.status.left_len]);
    // Was stuck at "new session"; the left slot used to render
    // "session session-1789..." because the id already contains "session-".
    try testing.expectEqualStrings("session-1789312894544", app.status.right[0..app.status.right_len]);
}

test "App: onMessages keeps is_streaming=true when no assistant stop seen yet" {
    var app = try testApp();
    defer app.deinit();
    app.is_streaming = true;
    const body =
        \\{"messages":[
        \\ {"id":"u1","role":"user","content":"hai"},
        \\ {"id":"a1","role":"assistant","content":"","finish_reason":"tool_calls"},
        \\ {"id":"t1","role":"tool","tool_name":"read_file","content":"<tool><name>read_file</name><parameters></parameters><success>true</success><data><path>/foo</path></data></tool>"}
        \\]}
    ;
    try app.onMessages(body);
    try testing.expect(app.is_streaming);
}

test "App: onMessages dedupes by message id (regression: <tool> x3 bug)" {
    var app = try testApp();
    defer app.deinit();
    app.is_streaming = true;
    const body =
        \\{"messages":[
        \\ {"id":"u1","role":"user","content":"hi"},
        \\ {"id":"t1","role":"tool","tool_name":"read_file","content":"<tool><name>read_file</name><parameters></parameters><success>true</success><data><path>/a</path><content>x</content></data></tool>"},
        \\ {"id":"a1","role":"assistant","content":"<think>p</think>done"}
        \\]}
    ;
    try app.onMessages(body);
    const first_count = app.viewport.lines.items.len;
    try app.onMessages(body); // re-poll
    try testing.expectEqual(first_count, app.viewport.lines.items.len);
}

test "App: onMessages renders tool card header (no raw <tool> xml)" {
    var app = try testApp();
    defer app.deinit();
    app.is_streaming = true;
    const body =
        \\{"messages":[
        \\ {"id":"t1","role":"tool","tool_name":"read_file","content":"<tool><name>read_file</name><parameters></parameters><success>true</success><data><path>/foo.txt</path><content>x</content></data></tool>"}
        \\]}
    ;
    try app.onMessages(body);
    const lines = app.viewport.lines.items;
    try testing.expect(std.mem.indexOf(u8, lines[lines.len - 1].text, "▶ read_file  /foo.txt  ✓") != null);
    try testing.expect(std.mem.indexOf(u8, lines[lines.len - 1].text, "<tool>") == null);
}

test "App: onMessages strips <think> from assistant content" {
    var app = try testApp();
    defer app.deinit();
    app.is_streaming = true;
    const body =
        \\{"messages":[
        \\ {"id":"a1","role":"assistant","content":"<think>secret plan</think>hello user"}
        \\]}
    ;
    try app.onMessages(body);
    const lines = app.viewport.lines.items;
    try testing.expect(std.mem.indexOf(u8, lines[lines.len - 1].text, "<think>") == null);
    try testing.expectEqualStrings("hello user", lines[lines.len - 1].text);
}

test "App: onMessages renders thinking-only assistant as chip" {
    var app = try testApp();
    defer app.deinit();
    app.is_streaming = true;
    const body =
        \\{"messages":[
        \\ {"id":"a1","role":"assistant","content":"<think>just thinking</think>"}
        \\]}
    ;
    try app.onMessages(body);
    const lines = app.viewport.lines.items;
    try testing.expectEqualStrings("… thinking …", lines[lines.len - 1].text);
}

test "App: onMessages renders user prompt as > bold green" {
    var app = try testApp();
    defer app.deinit();
    app.is_streaming = true;
    const body =
        \\{"messages":[
        \\ {"id":"u1","role":"user","content":"hai"}
        \\]}
    ;
    try app.onMessages(body);
    const last = app.viewport.lines.items[app.viewport.lines.items.len - 1];
    try testing.expectEqualStrings("> hai", last.text);
    try testing.expect(last.style.bold);
    try testing.expectEqual(@as(?tui.Color, .green), last.style.fg);
}

// User-reported regression test — the body shape from the screenshot in the
// design spec.
test "App: handleKey + Enter does NOT immediately echo user message" {
    var app = try testApp();
    defer app.deinit();
    _ = try app.update(.{ .key = .{ .rune = 'h' } });
    _ = try app.update(.{ .key = .{ .rune = 'a' } });
    _ = try app.update(.{ .key = .{ .rune = 'i' } });
    const cmd = try app.update(.{ .key = .enter });
    app.freeCmd(cmd);
    // Welcome line only — the user message will arrive via SSE/poll,
    // not via an immediate local echo. Otherwise we'd render `> hai`
    // twice (once here, once when the server's row is polled).
    try testing.expectEqual(@as(usize, 1), app.viewport.lines.items.len);
}

test "App: PgUp scrolls up; PgDn scrolls back to bottom (round-2 Task 5)" {
    var app = try testApp();
    defer app.deinit();
    // Pre-record the viewport height by calling view once.
    {
        var frame = try app.view(testing.allocator, 80, 20);
        defer frame.deinit(testing.allocator);
    }
    // Fill the viewport with more lines than fit in 20 rows.
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const body = try std.fmt.allocPrint(testing.allocator, "{{\"messages\":[{{\"id\":\"m{d}\",\"role\":\"assistant\",\"content\":\"line {d}\"}}]}}", .{ i, i });
        defer testing.allocator.free(body);
        try app.onMessages(body);
    }
    try testing.expectEqual(@as(usize, 0), app.viewport.scroll_from_bottom);
    _ = try app.update(.{ .key = .page_up });
    try testing.expect(app.viewport.scroll_from_bottom > 0);
    _ = try app.update(.{ .key = .page_down });
    try testing.expectEqual(@as(usize, 0), app.viewport.scroll_from_bottom);
}

test "App: mouse wheel up scrolls by 3 rows; wheel_down back" {
    var app = try testApp();
    defer app.deinit();
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const body = try std.fmt.allocPrint(testing.allocator, "{{\"messages\":[{{\"id\":\"m{d}\",\"role\":\"assistant\",\"content\":\"line {d}\"}}]}}", .{ i, i });
        defer testing.allocator.free(body);
        try app.onMessages(body);
    }
    try testing.expectEqual(@as(usize, 0), app.viewport.scroll_from_bottom);
    _ = try app.update(.{ .key = .wheel_up });
    try testing.expectEqual(@as(usize, 3), app.viewport.scroll_from_bottom);
    _ = try app.update(.{ .key = .wheel_up });
    try testing.expectEqual(@as(usize, 6), app.viewport.scroll_from_bottom);
    _ = try app.update(.{ .key = .wheel_down });
    try testing.expectEqual(@as(usize, 3), app.viewport.scroll_from_bottom);
}

test "App: onMessages renders SSE-delivered user prompt as > bold green" {
    var app = try testApp();
    defer app.deinit();
    const body =
        \\{"messages":[
        \\ {"id":"u1","role":"user","content":"hai"}
        \\]}
    ;
    try app.onMessages(body);
    // welcome + user prompt = 2 lines (the SSE-delivered row IS the source of truth)
    try testing.expectEqual(@as(usize, 2), app.viewport.lines.items.len);
    const last = app.viewport.lines.items[1];
    try testing.expectEqualStrings("> hai", last.text);
    try testing.expect(last.style.bold);
}

test "App: onMessages renders user-reported scenario (tool cards + stripped think)" {
    var app = try testApp();
    defer app.deinit();
    app.is_streaming = true;
    const body =
        \\{"messages":[
        \\ {"id":"u1","role":"user","content":"hai"},
        \\ {"id":"t1","role":"tool","tool_name":"load_memory","content":"<tool><name>load_memory</name><parameters><query>user preferences language</query><limit>5</limit></parameters><success>true</success><data><results><item>lang:id</item></results></data></tool>"},
        \\ {"id":"t2","role":"tool","tool_name":"update_activity","content":"<tool><name>update_activity</name><parameters><thought>2026-04-15 session</thought></parameters><success>true</success><data><activity>ok</activity></data></tool>"},
        \\ {"id":"a1","role":"assistant","content":"<think>The user prefers Indonesian language based on the memory.</think>The user prefers Indonesian language."}
        \\]}
    ;
    try app.onMessages(body);

    // Collect the rendered texts.
    const items = app.viewport.lines.items;
    try testing.expectEqual(@as(usize, 5), items.len); // welcome + u1 + t1 + t2 + a1

    // 1. welcome — unchanged.
    try testing.expect(std.mem.indexOf(u8, items[0].text, "pabrik-tui") != null);

    // 2. user prompt — bold green.
    try testing.expectEqualStrings("> hai", items[1].text);
    try testing.expect(items[1].style.bold);
    try testing.expectEqual(@as(?tui.Color, .green), items[1].style.fg);

    // 3. tool card #1 — no raw XML, header line instead.
    try testing.expect(std.mem.indexOf(u8, items[2].text, "<tool>") == null);
    try testing.expect(std.mem.indexOf(u8, items[2].text, "▶ load_memory") != null);
    try testing.expect(std.mem.indexOf(u8, items[2].text, "✓") != null);

    // 4. tool card #2.
    try testing.expect(std.mem.indexOf(u8, items[3].text, "<tool>") == null);
    try testing.expect(std.mem.indexOf(u8, items[3].text, "▶ update_activity") != null);

    // 5. assistant — think stripped, only the visible text remains.
    try testing.expect(std.mem.indexOf(u8, items[4].text, "<think>") == null);
    try testing.expectEqualStrings("The user prefers Indonesian language.", items[4].text);
}

test "App: view produces full-height frame with status bar" {
    var app = try testApp();
    defer app.deinit();
    var f = try app.view(testing.allocator, 40, 10);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 40), f.width);
    try testing.expectEqual(@as(u16, 10), f.height);
    // Status bar row has the brightBlack background bar.
    try testing.expect(f.get(0, 9).bg != null);
}

test "App: Config cwd defaults to empty" {
    const cfg = Config{};
    try testing.expectEqualStrings("", cfg.cwd);
}

test "App: init dupes cwd from Config" {
    var app = try App.init(testing.allocator, undefined, .{ .server = "http://test", .cwd = "/tmp/proj" });
    defer app.deinit();
    try testing.expectEqualStrings("/tmp/proj", app.cfg.cwd);
}

// ===== Tests merged from tdd_round2_test.zig (2026-09-29 flatten) =====
// Section 3 of tdd_round2_test.zig: the `app.onMessages` regression tests
// (role-detection robustness).

// ============================================================================
// 3. app.onMessages — role heuristic robustness
// ============================================================================

fn testAppForOnMessages() !App {
    return App.init(testing.allocator, undefined, .{ .server = "http://test" });
}

test "onMessages: assistant role stops streaming regardless of case" {
    var app = try testAppForOnMessages();
    defer app.deinit();
    app.is_streaming = true;
    const body = "{\"messages\":[{\"role\":\"ASSISTANT\",\"content\":\"done\"}]}";
    try app.onMessages(body);
    try testing.expect(!app.is_streaming);
}

test "onMessages: malformed JSON body is ignored, not a crash" {
    var app = try testAppForOnMessages();
    defer app.deinit();
    app.is_streaming = true;
    try app.onMessages("this is not json {{{");
    // State unchanged; still waiting for the reply.
    try testing.expect(app.is_streaming);
}

test "onMessages: non-object message entries are skipped" {
    var app = try testAppForOnMessages();
    defer app.deinit();
    const body = "{\"messages\":[\"junk\",42,null,{\"role\":\"assistant\",\"content\":\"ok\"}]}";
    try app.onMessages(body);
    // welcome + the one valid assistant message
    try testing.expectEqual(@as(usize, 2), app.viewport.lines.items.len);
}
