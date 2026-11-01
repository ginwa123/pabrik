//! Adapts the workspace secret store to `secrets_substitution.Resolver`, with
//! one query per distinct placeholder name.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const secrets_store = @import("secrets_store.zig");

/// Maps a placeholder name onto this workspace's stored credential. Owns every
/// value it looked up, because the substitution reads them after `resolve`
/// returns.
pub const StoreResolver = struct {
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    /// Empty means no workspace is in scope, which fails every name closed.
    workspace_id: []const u8,
    values: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The most recent name this resolver refused, so the caller can name the
    /// placeholder it could not resolve instead of reporting a bare error.
    missing_name: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        db: *pabrikcore.database.Db,
        workspace_id: []const u8,
    ) StoreResolver {
        return .{ .allocator = allocator, .db = db, .workspace_id = workspace_id };
    }

    pub fn deinit(self: *StoreResolver) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.values.deinit(self.allocator);
        if (self.missing_name) |name| self.allocator.free(name);
    }

    pub fn resolve(self: *StoreResolver, name: []const u8) ?[]const u8 {
        if (self.values.get(name)) |hit| return if (hit.len == 0) null else hit;
        if (self.workspace_id.len == 0) return self.refuse(name);

        const wanted = [_][]const u8{name};
        const rows = secrets_store.loadSecretValues(self.allocator, self.db, self.workspace_id, &wanted) catch
            return self.refuse(name);
        defer secrets_store.freeSecretValueRows(self.allocator, rows);

        for (rows) |row| {
            const key = self.allocator.dupe(u8, row.name) catch return self.refuse(name);
            const value = self.allocator.dupe(u8, row.value) catch {
                self.allocator.free(key);
                return self.refuse(name);
            };
            self.values.put(self.allocator, key, value) catch {
                self.allocator.free(key);
                self.allocator.free(value);
                return self.refuse(name);
            };
        }
        return self.values.get(name) orelse self.refuse(name);
    }

    fn refuse(self: *StoreResolver, name: []const u8) ?[]const u8 {
        if (self.missing_name) |previous| self.allocator.free(previous);
        self.missing_name = self.allocator.dupe(u8, name) catch null;
        return null;
    }

    pub fn lookup(ctx: ?*const anyopaque, name: []const u8) ?[]const u8 {
        const self: *StoreResolver = @ptrCast(@alignCast(@constCast(ctx orelse return null)));
        return self.resolve(name);
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const database = pabrikcore.database;
const test_db = pabrikcore.test_db;
const migration = @import("../migrations/migration.zig");
const workspace_settings_store = @import("workspace_settings_store.zig");

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    workspace_settings_store.installTestKey();
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn placeholder(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ "{", "{SECRETS:", name, "}" ++ "}" });
}

test "credential resolver: a stored name resolves, and a repeated name costs one query" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row = try secrets_store.createSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "API_KEY",
        .value = "sk-live-value",
    });
    defer secrets_store.freeSecretRow(alloc, row);

    var resolver = StoreResolver.init(alloc, &ctx.db, "ws_a");
    defer resolver.deinit();

    try testing.expectEqualStrings("sk-live-value", resolver.resolve("API_KEY").?);
    // Deleting between two calls proves the second answer came from the cache
    // rather than from a fresh row.
    try ctx.db.exec(
        alloc,
        "DELETE FROM workspace_secrets WHERE workspace_id = 'ws_a'",
        &.{},
    );
    try testing.expectEqualStrings("sk-live-value", resolver.resolve("API_KEY").?);
    try testing.expect(resolver.missing_name == null);
}

test "credential resolver: a name this workspace does not store is recorded, not blanked" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // The same NAME in another workspace must not answer: resolution is
    // scoped to the workspace the caller asked for.
    const other = try secrets_store.createSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_other",
        .name = "API_KEY",
        .value = "sk-other-workspace",
    });
    defer secrets_store.freeSecretRow(alloc, other);

    var resolver = StoreResolver.init(alloc, &ctx.db, "ws_a");
    defer resolver.deinit();

    try testing.expect(resolver.resolve("API_KEY") == null);
    try testing.expectEqualStrings("API_KEY", resolver.missing_name.?);
}

test "credential resolver: no workspace in scope resolves nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row = try secrets_store.createSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "API_KEY",
        .value = "sk-live-value",
    });
    defer secrets_store.freeSecretRow(alloc, row);

    var resolver = StoreResolver.init(alloc, &ctx.db, "");
    defer resolver.deinit();

    try testing.expect(resolver.resolve("API_KEY") == null);
    try testing.expectEqualStrings("API_KEY", resolver.missing_name.?);
}

test "credential resolver: the placeholder round trip through lookup uses the same values" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row = try secrets_store.createSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "API_KEY",
        .value = "sk-live-value",
    });
    defer secrets_store.freeSecretRow(alloc, row);

    var resolver = StoreResolver.init(alloc, &ctx.db, "ws_a");
    defer resolver.deinit();

    try testing.expectEqualStrings("sk-live-value", StoreResolver.lookup(&resolver, "API_KEY").?);
    try testing.expect(StoreResolver.lookup(&resolver, "NOT_STORED") == null);
    try testing.expectEqualStrings("NOT_STORED", resolver.missing_name.?);

    // `lookup` with no context is a miss rather than a crash: an unset resolver
    // cannot be allowed to resolve anything.
    try testing.expect(StoreResolver.lookup(null, "API_KEY") == null);
}
