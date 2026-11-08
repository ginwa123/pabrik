//! The object-store seam for document bodies: metadata stays in the
//! `documents` table, the body lives behind this interface, and
//! `documents.content_key` is the pointer between them.

const std = @import("std");

/// Every failure a backend may report. Backends map their own error sets onto
/// this one so a caller never has to know which store it is talking to.
pub const Error = error{
    /// No object at that key.
    NotFound,
    /// The key is empty, absolute, or contains a traversal segment.
    InvalidKey,
    /// The backend could not complete the operation.
    IoFailed,
    OutOfMemory,
};

pub const Stat = struct {
    bytes: u64,
};

/// Largest object this store accepts. Matches `documents_store.MAX_CONTENT_BYTES`
/// so a body that fits the column also fits the store.
pub const MAX_OBJECT_BYTES: usize = 4 << 20;

/// Longest key accepted. A key is a path, and a path longer than this is a
/// caller bug rather than a document.
pub const MAX_KEY_BYTES: usize = 1024;

/// Length of a lowercase hex SHA-256 digest.
pub const SHA256_HEX_BYTES: usize = 64;

pub const Storage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (ptr: *anyopaque, key: []const u8, body: []const u8) Error!void,
        get: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) Error![]u8,
        delete: *const fn (ptr: *anyopaque, key: []const u8) Error!void,
        stat: *const fn (ptr: *anyopaque, key: []const u8) Error!Stat,
    };

    /// Store `body` at `key`, replacing any object already there.
    pub fn put(self: Storage, key: []const u8, body: []const u8) Error!void {
        return self.vtable.put(self.ptr, key, body);
    }

    /// Read the object at `key`. The returned slice is allocator-owned.
    pub fn get(self: Storage, allocator: std.mem.Allocator, key: []const u8) Error![]u8 {
        return self.vtable.get(self.ptr, allocator, key);
    }

    /// Remove the object at `key`. Absent is `error.NotFound`, not success.
    pub fn delete(self: Storage, key: []const u8) Error!void {
        return self.vtable.delete(self.ptr, key);
    }

    /// Size of the object at `key`, without reading it.
    pub fn stat(self: Storage, key: []const u8) Error!Stat {
        return self.vtable.stat(self.ptr, key);
    }
};

/// Why `key` is unusable, or null when it is fine. A key is a RELATIVE path;
/// rejecting `..`, `.`, empty segments, a leading slash and backslashes is
/// what keeps a filesystem backend inside its root.
pub fn invalidKeyReason(key: []const u8) ?[]const u8 {
    if (key.len == 0) return "key is empty";
    if (key.len > MAX_KEY_BYTES) return "key is longer than the limit";
    if (key[0] == '/') return "key must be relative";
    if (key[key.len - 1] == '/') return "key must not end with a separator";
    if (std.mem.indexOfScalar(u8, key, 0) != null) return "key contains a NUL byte";
    if (std.mem.indexOfScalar(u8, key, '\\') != null) return "key contains a backslash";

    var segments = std.mem.splitScalar(u8, key, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return "key has an empty segment";
        if (std.mem.eql(u8, segment, ".")) return "key has a '.' segment";
        if (std.mem.eql(u8, segment, "..")) return "key has a '..' segment";
    }
    return null;
}

/// Whether `value` is safe to use as ONE path segment of a key.
pub fn isSafeSegment(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.mem.indexOfScalar(u8, value, '/') != null) return false;
    if (std.mem.indexOfScalar(u8, value, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return false;
    if (std.mem.eql(u8, value, ".")) return false;
    if (std.mem.eql(u8, value, "..")) return false;
    return true;
}

/// The key a document body lives at:
/// `ws/{workspace_id}/documents/{document_id}/{sha256}.md`. Workspace-prefixed
/// so a tenant delete is a prefix op; content-addressed so the object is immutable.
pub fn documentKey(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    document_id: []const u8,
    sha256_hex: []const u8,
) Error![]u8 {
    if (!isSafeSegment(workspace_id)) return error.InvalidKey;
    if (!isSafeSegment(document_id)) return error.InvalidKey;
    if (sha256_hex.len != SHA256_HEX_BYTES) return error.InvalidKey;
    return std.fmt.allocPrint(
        allocator,
        "ws/{s}/documents/{s}/{s}.md",
        .{ workspace_id, document_id, sha256_hex },
    ) catch return error.OutOfMemory;
}

/// Lowercase hex SHA-256 of `body`, into `out`.
pub fn sha256Hex(body: []const u8, out: *[SHA256_HEX_BYTES]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    out.* = std.fmt.bytesToHex(digest, .lower);
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "invalidKeyReason: a plain relative path is accepted" {
    try testing.expect(invalidKeyReason("ws/ws_1/documents/doc_a/abc.md") == null);
    try testing.expect(invalidKeyReason("a") == null);
    try testing.expect(invalidKeyReason("a/b/c") == null);
}

test "invalidKeyReason: an empty key is rejected" {
    try testing.expect(invalidKeyReason("") != null);
}

test "invalidKeyReason: an absolute key is rejected" {
    try testing.expect(invalidKeyReason("/etc/passwd") != null);
}

test "invalidKeyReason: every traversal segment is rejected" {
    try testing.expect(invalidKeyReason("..") != null);
    try testing.expect(invalidKeyReason(".") != null);
    try testing.expect(invalidKeyReason("a/../b") != null);
    try testing.expect(invalidKeyReason("a/./b") != null);
    try testing.expect(invalidKeyReason("../a") != null);
    try testing.expect(invalidKeyReason("a/..") != null);
}

test "invalidKeyReason: empty segments and a trailing separator are rejected" {
    try testing.expect(invalidKeyReason("a//b") != null);
    try testing.expect(invalidKeyReason("a/") != null);
}

test "invalidKeyReason: a backslash or NUL byte is rejected" {
    try testing.expect(invalidKeyReason("a\\b") != null);
    try testing.expect(invalidKeyReason("a\x00b") != null);
}

test "invalidKeyReason: a key past the length limit is rejected" {
    const long = "a" ** (MAX_KEY_BYTES + 1);
    try testing.expect(invalidKeyReason(long) != null);
    const at_limit = "a" ** MAX_KEY_BYTES;
    try testing.expect(invalidKeyReason(at_limit) == null);
}

test "isSafeSegment: a generated id is safe and a path is not" {
    try testing.expect(isSafeSegment("doc_1794073764996_1234_0"));
    try testing.expect(isSafeSegment("ws_1785055733544_28e79c9db8950100"));
    try testing.expect(!isSafeSegment(""));
    try testing.expect(!isSafeSegment("a/b"));
    try testing.expect(!isSafeSegment(".."));
    try testing.expect(!isSafeSegment("."));
}

test "documentKey: the key is workspace-prefixed and content-addressed" {
    const alloc = testing.allocator;
    const digest = "a" ** SHA256_HEX_BYTES;
    const key = try documentKey(alloc, "ws_1", "doc_a", digest);
    defer alloc.free(key);
    try testing.expectEqualStrings("ws/ws_1/documents/doc_a/" ++ ("a" ** SHA256_HEX_BYTES) ++ ".md", key);
    try testing.expect(invalidKeyReason(key) == null);
}

test "documentKey: two bodies with different digests get different keys" {
    const alloc = testing.allocator;
    const first = try documentKey(alloc, "ws_1", "doc_a", "a" ** SHA256_HEX_BYTES);
    defer alloc.free(first);
    const second = try documentKey(alloc, "ws_1", "doc_a", "b" ** SHA256_HEX_BYTES);
    defer alloc.free(second);
    try testing.expect(!std.mem.eql(u8, first, second));
}

test "documentKey: a workspace or document id carrying a separator is rejected" {
    const alloc = testing.allocator;
    const digest = "a" ** SHA256_HEX_BYTES;
    try testing.expectError(error.InvalidKey, documentKey(alloc, "ws/1", "doc_a", digest));
    try testing.expectError(error.InvalidKey, documentKey(alloc, "ws_1", "doc/../a", digest));
    try testing.expectError(error.InvalidKey, documentKey(alloc, "", "doc_a", digest));
    try testing.expectError(error.InvalidKey, documentKey(alloc, "ws_1", "", digest));
}

test "documentKey: a digest of the wrong length is rejected" {
    const alloc = testing.allocator;
    try testing.expectError(error.InvalidKey, documentKey(alloc, "ws_1", "doc_a", "abc"));
    try testing.expectError(error.InvalidKey, documentKey(alloc, "ws_1", "doc_a", ""));
}

test "sha256Hex: the empty body hashes to the published digest" {
    var out: [SHA256_HEX_BYTES]u8 = undefined;
    sha256Hex("", &out);
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &out,
    );
}

test "sha256Hex: the abc vector matches the published digest" {
    var out: [SHA256_HEX_BYTES]u8 = undefined;
    sha256Hex("abc", &out);
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &out,
    );
}

test "sha256Hex: identical bodies hash identically and one changed byte does not" {
    var a: [SHA256_HEX_BYTES]u8 = undefined;
    var b: [SHA256_HEX_BYTES]u8 = undefined;
    var c: [SHA256_HEX_BYTES]u8 = undefined;
    sha256Hex("# Release plan\n", &a);
    sha256Hex("# Release plan\n", &b);
    sha256Hex("# Release plan.", &c);
    try testing.expectEqualStrings(&a, &b);
    try testing.expect(!std.mem.eql(u8, &a, &c));
}
