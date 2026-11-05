const std = @import("std");
const json_text = @import("json_text.zig");
const server_url = @import("server_url.zig");
const startup = @import("startup.zig");

pub const page = @embedFile("connect_page.html");

pub const bind_connect = "pabrikConnect";
pub const bind_use_local = "pabrikUseLocal";
pub const bind_quit = "pabrikQuit";

pub const message = struct {
    pub const save_failed = "This computer could not save the server address.";
};

pub const Effects = struct {
    ctx: *anyopaque,
    save: *const fn (ctx: *anyopaque, base_url: []const u8) bool,
    forget: *const fn (ctx: *anyopaque) void,
    local_url: *const fn (ctx: *anyopaque) ?[]const u8,
};

pub const Outcome = union(enum) {
    connected: []const u8,
    failed: []const u8,

    pub fn deinit(self: Outcome, allocator: std.mem.Allocator) void {
        switch (self) {
            .connected => |url| allocator.free(url),
            .failed => {},
        }
    }
};

pub fn connect(allocator: std.mem.Allocator, effects: Effects, raw: []const u8) !Outcome {
    switch (try server_url.normalize(allocator, raw)) {
        .rejected => |reason| return .{ .failed = reason },
        .applied => |url| {
            if (!effects.save(effects.ctx, url)) {
                allocator.free(url);
                return .{ .failed = message.save_failed };
            }
            return .{ .connected = url };
        },
    }
}

pub fn useLocal(effects: Effects) Outcome {
    effects.forget(effects.ctx);
    const url = effects.local_url(effects.ctx) orelse
        return .{ .failed = startup.Reason.no_local_server.note() };
    return .{ .connected = url };
}

pub fn writeReply(allocator: std.mem.Allocator, outcome: Outcome) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    switch (outcome) {
        .connected => try out.appendSlice(allocator, "{\"ok\":true}"),
        .failed => |reason| {
            try out.appendSlice(allocator, "{\"ok\":false,\"message\":");
            try json_text.appendQuoted(&out, allocator, reason);
            try out.append(allocator, '}');
        },
    }
    return try out.toOwnedSlice(allocator);
}

pub fn firstArgument(allocator: std.mem.Allocator, request: []const u8) !?[]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), request, .{}) catch
        return null;
    const arguments = switch (parsed) {
        .array => |items| items,
        else => return null,
    };
    if (arguments.items.len == 0) return null;
    const first = switch (arguments.items[0]) {
        .string => |text| text,
        else => return null,
    };
    return try allocator.dupe(u8, first);
}

pub fn renderPage(allocator: std.mem.Allocator, prefill: []const u8, note: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var rest: []const u8 = page;
    while (std.mem.indexOf(u8, rest, "{{")) |start| {
        try out.appendSlice(allocator, rest[0..start]);
        const after = rest[start..];
        const closing = std.mem.indexOf(u8, after, "}}") orelse {
            try out.appendSlice(allocator, after);
            return try out.toOwnedSlice(allocator);
        };
        const token = after[0 .. closing + 2];
        if (std.mem.eql(u8, token, "{{PREFILL}}")) {
            try appendHtmlEscaped(&out, allocator, prefill);
        } else if (std.mem.eql(u8, token, "{{NOTE}}")) {
            try appendHtmlEscaped(&out, allocator, note);
        } else {
            try out.appendSlice(allocator, token);
        }
        rest = after[closing + 2 ..];
    }
    try out.appendSlice(allocator, rest);
    return try out.toOwnedSlice(allocator);
}

fn appendHtmlEscaped(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&#34;"),
            '\'' => try out.appendSlice(allocator, "&#39;"),
            else => try out.append(allocator, c),
        }
    }
}

const testing = std.testing;

const Fake = struct {
    saved: ?[]u8 = null,
    saves: usize = 0,
    forgets: usize = 0,
    local: ?[]u8 = null,
    write_ok: bool = true,

    fn effects(self: *Fake) Effects {
        return .{
            .ctx = self,
            .save = save,
            .forget = forget,
            .local_url = localUrl,
        };
    }

    fn save(ctx: *anyopaque, base_url: []const u8) bool {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (!self.write_ok) return false;
        if (self.saved) |old| testing.allocator.free(old);
        self.saved = testing.allocator.dupe(u8, base_url) catch return false;
        self.saves += 1;
        return true;
    }

    fn forget(ctx: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.forgets += 1;
        if (self.saved) |old| {
            testing.allocator.free(old);
            self.saved = null;
        }
    }

    fn localUrl(ctx: *anyopaque) ?[]const u8 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const local = self.local orelse return null;
        return testing.allocator.dupe(u8, local) catch null;
    }

    fn deinit(self: *Fake) void {
        if (self.saved) |old| testing.allocator.free(old);
        if (self.local) |local| testing.allocator.free(local);
    }
};

test "a typed address is normalized, saved, and becomes the server" {
    var fake: Fake = .{};
    defer fake.deinit();

    const outcome = try connect(testing.allocator, fake.effects(), "  Pabrik.Example.com/pabrik/ ");
    defer outcome.deinit(testing.allocator);

    try testing.expectEqualStrings("https://pabrik.example.com/pabrik", outcome.connected);
    try testing.expectEqualStrings("https://pabrik.example.com/pabrik", fake.saved.?);
}

test "a rejected address is never saved" {
    var fake: Fake = .{};
    defer fake.deinit();

    const outcome = try connect(testing.allocator, fake.effects(), "ftp://pabrik.example.com");
    defer outcome.deinit(testing.allocator);

    try testing.expectEqualStrings(server_url.message.scheme, outcome.failed);
    try testing.expectEqual(@as(?[]u8, null), fake.saved);
    try testing.expectEqual(@as(usize, 0), fake.saves);
}

test "a write the computer refuses is reported instead of adopted" {
    var fake: Fake = .{ .write_ok = false };
    defer fake.deinit();

    const outcome = try connect(testing.allocator, fake.effects(), "https://pabrik.example.com");
    defer outcome.deinit(testing.allocator);

    try testing.expectEqualStrings(message.save_failed, outcome.failed);
    try testing.expectEqual(@as(?[]u8, null), fake.saved);
}

test "use local server forgets the remote address and opens the local one" {
    var fake: Fake = .{ .local = try testing.allocator.dupe(u8, "http://127.0.0.1:8081/") };
    defer fake.deinit();
    _ = Fake.save(fake.effects().ctx, "https://pabrik.example.com");

    const outcome = useLocal(fake.effects());
    defer outcome.deinit(testing.allocator);

    try testing.expectEqualStrings("http://127.0.0.1:8081/", outcome.connected);
    try testing.expectEqual(@as(?[]u8, null), fake.saved);
    try testing.expectEqual(@as(usize, 1), fake.forgets);
}

test "use local server with nothing local still forgets the remote address" {
    var fake: Fake = .{};
    defer fake.deinit();
    _ = Fake.save(fake.effects().ctx, "https://pabrik.example.com");

    const outcome = useLocal(fake.effects());
    defer outcome.deinit(testing.allocator);

    try testing.expectEqualStrings(startup.Reason.no_local_server.note(), outcome.failed);
    try testing.expectEqual(@as(?[]u8, null), fake.saved);
}

test "the reply tells the page the connection was adopted" {
    const outcome: Outcome = .{ .connected = try testing.allocator.dupe(u8, "https://pabrik.example.com") };
    defer outcome.deinit(testing.allocator);

    const reply = try writeReply(testing.allocator, outcome);
    defer testing.allocator.free(reply);

    try testing.expectEqualStrings("{\"ok\":true}", reply);
}

test "the reply hands the page the sentence a person should read" {
    const outcome: Outcome = .{ .failed = server_url.message.credentials };

    const reply = try writeReply(testing.allocator, outcome);
    defer testing.allocator.free(reply);

    try testing.expectEqualStrings(
        "{\"ok\":false,\"message\":\"Remove the username and password from the address.\"}",
        reply,
    );
}

test "the typed address arrives as the first bound argument" {
    const argument = try firstArgument(testing.allocator, "[\"https://pabrik.example.com\"]");
    defer if (argument) |text| testing.allocator.free(text);

    try testing.expectEqualStrings("https://pabrik.example.com", argument.?);
}

test "a bind request carrying no string yields no address" {
    try testing.expectEqual(@as(?[]u8, null), try firstArgument(testing.allocator, "[]"));
    try testing.expectEqual(@as(?[]u8, null), try firstArgument(testing.allocator, "[42]"));
    try testing.expectEqual(@as(?[]u8, null), try firstArgument(testing.allocator, "not json"));
    try testing.expectEqual(@as(?[]u8, null), try firstArgument(testing.allocator, ""));
}

test "the picker shows the server that is in use" {
    const html = try renderPage(testing.allocator, "https://pabrik.example.com", "");
    defer testing.allocator.free(html);

    try testing.expect(std.mem.indexOf(u8, html, "value=\"https://pabrik.example.com\"") != null);
}

test "a saved address cannot inject markup into the picker" {
    const html = try renderPage(testing.allocator, "\"><script>alert(1)</script>", "");
    defer testing.allocator.free(html);

    try testing.expect(std.mem.indexOf(u8, html, "<script>alert(1)</script>") == null);
    try testing.expect(std.mem.indexOf(u8, html, "&#34;&gt;&lt;script&gt;") != null);
}

test "the picker explains why it opened" {
    const reason = startup.Reason.no_local_server.note();
    const html = try renderPage(testing.allocator, "", reason);
    defer testing.allocator.free(html);

    try testing.expect(std.mem.indexOf(u8, html, reason) != null);
}

test "every function the page calls is a function the desktop binds" {
    const names = [_][]const u8{ bind_connect, bind_use_local, bind_quit };
    for (names) |name| {
        try testing.expect(std.mem.indexOf(u8, page, name) != null);
    }
}
