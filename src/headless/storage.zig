//! `pabrik headless storage …` — the object store with no server and no port.
//! Every op goes through the same `Storage` interface the document store will
//! use, so an agent can exercise it without a database, a bucket or a socket.

const std = @import("std");
const pabrikcore = @import("pabrikcore");

const args = @import("args.zig");

const storage_mod = pabrikcore.storage;
const storage = storage_mod.storage;
const fs_backend = storage_mod.fs;

/// Where objects live when neither `--root` nor `PABRIK_STORAGE_ROOT` says.
pub const DEFAULT_ROOT_SUFFIX = ".local/share/pabrik/objects";

/// Resolve the store root: the flag, then the environment, then `$HOME`.
pub fn resolveRoot(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    flag: ?[]const u8,
) ![]u8 {
    if (flag) |root| {
        if (root.len == 0) return error.RootRequired;
        return allocator.dupe(u8, root);
    }
    if (environment.get("PABRIK_STORAGE_ROOT")) |root| {
        if (root.len > 0) return allocator.dupe(u8, root);
    }
    const home = environment.get("HOME") orelse return error.RootRequired;
    return std.fs.path.join(allocator, &.{ home, DEFAULT_ROOT_SUFFIX });
}

const PutDto = struct {
    key: []const u8,
    bytes: usize,
    sha256: []const u8,
};

const GetDto = struct {
    key: []const u8,
    bytes: usize,
    body: []const u8,
};

const StatDto = struct {
    key: []const u8,
    bytes: u64,
};

const DeleteDto = struct {
    key: []const u8,
    deleted: bool,
};

/// Run one op and return the JSON object to print. Caller frees the slice.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    a: args.StorageArgs,
) ![]u8 {
    const root = try resolveRoot(allocator, environment, a.root);
    defer allocator.free(root);

    var backend = try fs_backend.FsStorage.open(io, root);
    defer backend.deinit();

    return runWith(allocator, io, backend.asStorage(), a);
}

/// The op table, over a plain `Storage` so a test can drive it against the
/// in-memory backend without touching the filesystem.
pub fn runWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    s: storage.Storage,
    a: args.StorageArgs,
) ![]u8 {
    switch (a.op) {
        .put => {
            const body = try readBody(allocator, io, a);
            defer allocator.free(body);

            try s.put(a.key, body);

            var digest: [storage.SHA256_HEX_BYTES]u8 = undefined;
            storage.sha256Hex(body, &digest);
            return std.json.Stringify.valueAlloc(allocator, PutDto{
                .key = a.key,
                .bytes = body.len,
                .sha256 = &digest,
            }, .{});
        },

        .get => {
            const body = try s.get(allocator, a.key);
            defer allocator.free(body);
            return std.json.Stringify.valueAlloc(allocator, GetDto{
                .key = a.key,
                .bytes = body.len,
                .body = body,
            }, .{});
        },

        .stat => {
            const info = try s.stat(a.key);
            return std.json.Stringify.valueAlloc(allocator, StatDto{
                .key = a.key,
                .bytes = info.bytes,
            }, .{});
        },

        .delete => {
            try s.delete(a.key);
            return std.json.Stringify.valueAlloc(allocator, DeleteDto{
                .key = a.key,
                .deleted = true,
            }, .{});
        },
    }
}

/// The body for a `put`: `--body-file` wins over `--body` when both are given,
/// because a file is the only way to send bytes a shell would mangle.
fn readBody(
    allocator: std.mem.Allocator,
    io: std.Io,
    a: args.StorageArgs,
) ![]u8 {
    if (a.body_file) |path| {
        return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(storage.MAX_OBJECT_BYTES));
    }
    return allocator.dupe(u8, a.body);
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const memory_backend = storage_mod.memory;

fn parseJson(allocator: std.mem.Allocator, out: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, out, .{});
}

test "headless storage: put then get round-trips the body and reports its digest" {
    const alloc = testing.allocator;
    var store = memory_backend.MemoryStorage.init(alloc);
    defer store.deinit();

    const put_json = try runWith(alloc, testing.io, store.asStorage(), .{
        .op = .put,
        .key = "ws/ws_1/documents/doc_a/abc.md",
        .body = "# Release plan\n",
        .body_given = true,
    });
    defer alloc.free(put_json);

    const put = try parseJson(alloc, put_json);
    defer put.deinit();
    try testing.expectEqual(@as(i64, 15), put.value.object.get("bytes").?.integer);
    try testing.expectEqualStrings(
        "ws/ws_1/documents/doc_a/abc.md",
        put.value.object.get("key").?.string,
    );

    const get_json = try runWith(alloc, testing.io, store.asStorage(), .{
        .op = .get,
        .key = "ws/ws_1/documents/doc_a/abc.md",
    });
    defer alloc.free(get_json);

    const got = try parseJson(alloc, get_json);
    defer got.deinit();
    try testing.expectEqualStrings("# Release plan\n", got.value.object.get("body").?.string);
}

test "headless storage: put reports the sha256 of the body it stored" {
    const alloc = testing.allocator;
    var store = memory_backend.MemoryStorage.init(alloc);
    defer store.deinit();

    const out = try runWith(alloc, testing.io, store.asStorage(), .{
        .op = .put,
        .key = "k.md",
        .body = "abc",
        .body_given = true,
    });
    defer alloc.free(out);

    const parsed = try parseJson(alloc, out);
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        parsed.value.object.get("sha256").?.string,
    );
}

test "headless storage: stat reports the stored size" {
    const alloc = testing.allocator;
    var store = memory_backend.MemoryStorage.init(alloc);
    defer store.deinit();

    try store.asStorage().put("k.md", "twelve bytes");

    const out = try runWith(alloc, testing.io, store.asStorage(), .{ .op = .stat, .key = "k.md" });
    defer alloc.free(out);

    const parsed = try parseJson(alloc, out);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 12), parsed.value.object.get("bytes").?.integer);
}

test "headless storage: delete reports success and the object is gone" {
    const alloc = testing.allocator;
    var store = memory_backend.MemoryStorage.init(alloc);
    defer store.deinit();

    try store.asStorage().put("k.md", "body");

    const out = try runWith(alloc, testing.io, store.asStorage(), .{ .op = .delete, .key = "k.md" });
    defer alloc.free(out);

    const parsed = try parseJson(alloc, out);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("deleted").?.bool);
    try testing.expectEqual(@as(usize, 0), store.count());
}

test "headless storage: get on a missing key surfaces NotFound, not a half object" {
    const alloc = testing.allocator;
    var store = memory_backend.MemoryStorage.init(alloc);
    defer store.deinit();

    try testing.expectError(error.NotFound, runWith(alloc, testing.io, store.asStorage(), .{
        .op = .get,
        .key = "nope.md",
    }));
}

test "headless storage: put reads the body from a file when one is given" {
    const alloc = testing.allocator;
    var store = memory_backend.MemoryStorage.init(alloc);
    defer store.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const file = try tmp.dir.createFile(testing.io, "body.md", .{});
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, "from a file");
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const body_path = try std.fs.path.join(alloc, &.{ path_buf[0..path_len], "body.md" });
    defer alloc.free(body_path);

    const out = try runWith(alloc, testing.io, store.asStorage(), .{
        .op = .put,
        .key = "k.md",
        .body_file = body_path,
        .body_given = true,
    });
    defer alloc.free(out);

    const body = try store.asStorage().get(alloc, "k.md");
    defer alloc.free(body);
    try testing.expectEqualStrings("from a file", body);
}

test "headless storage: resolveRoot prefers the flag, then the environment, then HOME" {
    const alloc = testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", "/home/tester");

    const from_home = try resolveRoot(alloc, &env, null);
    defer alloc.free(from_home);
    try testing.expectEqualStrings("/home/tester/" ++ DEFAULT_ROOT_SUFFIX, from_home);

    try env.put("PABRIK_STORAGE_ROOT", "/srv/objects");
    const from_env = try resolveRoot(alloc, &env, null);
    defer alloc.free(from_env);
    try testing.expectEqualStrings("/srv/objects", from_env);

    const from_flag = try resolveRoot(alloc, &env, "/tmp/flag-root");
    defer alloc.free(from_flag);
    try testing.expectEqualStrings("/tmp/flag-root", from_flag);
}

test "headless storage: resolveRoot refuses when there is no root and no HOME" {
    const alloc = testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try testing.expectError(error.RootRequired, resolveRoot(alloc, &env, null));
    try testing.expectError(error.RootRequired, resolveRoot(alloc, &env, ""));
}
