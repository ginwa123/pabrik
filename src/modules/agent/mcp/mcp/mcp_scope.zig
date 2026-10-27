const std = @import("std");

pub const sep: u8 = 0x1f;

pub const max_key_bytes: usize = 512;

pub const Scope = struct {
    owner: []const u8 = "",
    workspace_id: []const u8 = "",

    pub fn isGlobal(self: Scope) bool {
        return self.owner.len == 0 and self.workspace_id.len == 0;
    }

    pub fn keyInto(self: Scope, name: []const u8, out: []u8) ?[]const u8 {
        if (self.isGlobal()) {
            if (out.len < name.len) return null;
            @memcpy(out[0..name.len], name);
            return out[0..name.len];
        }
        return std.fmt.bufPrint(out, "{s}{c}{s}{c}{s}", .{
            self.owner,
            sep,
            self.workspace_id,
            sep,
            name,
        }) catch null;
    }

    pub fn key(self: Scope, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        var buf: [max_key_bytes]u8 = undefined;
        const scoped = self.keyInto(name, &buf) orelse return error.NameTooLong;
        return allocator.dupe(u8, scoped);
    }
};

pub fn matchesName(cached_key: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, cached_key, name)) return true;
    if (cached_key.len <= name.len) return false;
    const tail = cached_key[cached_key.len - name.len ..];
    if (!std.mem.eql(u8, tail, name)) return false;
    return cached_key[cached_key.len - name.len - 1] == sep;
}

test "two tenants declaring the same server name get different keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tenant_a = try (Scope{ .owner = "u_a", .workspace_id = "ws_1" }).key(arena.allocator(), "files");
    const tenant_b = try (Scope{ .owner = "u_b", .workspace_id = "ws_1" }).key(arena.allocator(), "files");
    try std.testing.expect(!std.mem.eql(u8, tenant_a, tenant_b));
}

test "the same tenant asking for the same name twice gets one key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scope = Scope{ .owner = "u_a", .workspace_id = "ws_1" };
    const first = try scope.key(arena.allocator(), "files");
    const second = try scope.key(arena.allocator(), "files");
    try std.testing.expectEqualStrings(first, second);
}

test "one tenant's two workspaces do not share a key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ws_1 = try (Scope{ .owner = "u_a", .workspace_id = "ws_1" }).key(arena.allocator(), "files");
    const ws_2 = try (Scope{ .owner = "u_a", .workspace_id = "ws_2" }).key(arena.allocator(), "files");
    try std.testing.expect(!std.mem.eql(u8, ws_1, ws_2));
}

test "a scope with no owner and no workspace keeps the bare server name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const key = try (Scope{}).key(arena.allocator(), "files");
    try std.testing.expectEqualStrings("files", key);
}

test "a tenant key is found by its server name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const key = try (Scope{ .owner = "u_a", .workspace_id = "ws_1" }).key(arena.allocator(), "files");
    try std.testing.expect(matchesName(key, "files"));
    try std.testing.expect(matchesName("files", "files"));
}

test "a name that merely ends the same way does not match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const key = try (Scope{ .owner = "u_a", .workspace_id = "ws_1" }).key(arena.allocator(), "files");
    try std.testing.expect(!matchesName(key, "iles"));
    try std.testing.expect(!matchesName(key, "file"));
    try std.testing.expect(!matchesName(key, "files2"));
}
