//! At-rest sealing for workspace secret values.
//!
//! ## What this protects, and what it does not
//!
//! A value is sealed with AES-256-GCM under a key held by the operating
//! system's keychain — never a key file. **This protects the database FILE:
//! backups, copies, another local account, a `docker cp`.** It does not protect
//! the account: a process running as the same user can ask the keychain for the
//! key and decrypt, so this is not a boundary against the agent that runs on
//! the same host. What keeps a value away from the model is the substitution
//! path (`secrets_substitution.zig`), not this cipher.
//!
//! Where the host has no keychain at all — headless Linux, a container, CI —
//! there is nothing to seal with, so values are stored in plaintext, on
//! purpose, and the boot log plus the secrets-list state say so. Refusing the
//! write instead would break the feature on exactly the hosts nobody watches.
//!
//! ## The envelope
//!
//! ```text
//! v1:<key_id>:<base64url-nopad(nonce || ciphertext || tag)>
//! ```
//!
//! - AES-256-GCM, 12-byte nonce from the OS CSPRNG per write, 16-byte tag.
//! - **AAD = `v1:<secret_id>`.** The id is immutable and unique, so a row
//!   copied, moved or swapped between secrets fails to open rather than
//!   decrypting into the wrong place. `name` is deliberately NOT in the AAD:
//!   the UI exposes a rename, and a rename must not destroy the value.
//! - `key_id` is the first 8 hex of `SHA-256(key)`, so "sealed with a different
//!   key" is a different error from "this row is corrupt", and a re-key needs
//!   no schema change.
//! - **A value with no `v1:` prefix is legacy plaintext and is read as-is.**
//!   That single rule is why the upgrade cannot brick: an unsealed row is a
//!   valid row, so a half-migrated database, a host that lost its keychain and
//!   a value written while no key was available all keep working.
//!
//! ## Where the key lives in the process
//!
//! One host, one key, so it is a process-global slot filled once at boot
//! (`setKey`) rather than a parameter threaded through every call site. Tests
//! set their own key — which also keeps them off the real keychain.

const std = @import("std");
const sqlite = @import("pabrikcore").sqlite;
const helpers = @import("helpers");

/// Envelope version marker. A stored value either starts with this or is
/// legacy plaintext; there is no third state.
pub const prefix = "v1:";

pub const KEY_LEN: usize = 32;
pub const NONCE_LEN: usize = 12;
pub const TAG_LEN: usize = 16;
pub const KEY_ID_HEX_LEN: usize = 8;

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const SealError = error{
    RandomFailed,
    OutOfMemory,
    UnsupportedPlatform,
};

pub const OpenError = error{
    /// Not an envelope. The caller reads it as legacy plaintext.
    NotSealed,
    /// The envelope does not parse: bad prefix, bad key id, bad base64, or too
    /// short to contain a nonce and a tag.
    Malformed,
    /// Sealed with a key whose id is not ours. Distinct from `Corrupt` because
    /// the remedy is different: the keychain holds the wrong key, versus the
    /// row itself is damaged.
    WrongKey,
    /// GCM authentication failed: the ciphertext, the tag or the AAD changed.
    Corrupt,
    OutOfMemory,
};

/// The process's master key, or null when the host has no keychain. Filled once
/// by `setKey` at boot, before any request or agent runs.
var current_key: ?[KEY_LEN]u8 = null;

/// Record the master key. `null` means "no key on this host": writes go in
/// plaintext and sealed rows cannot be opened.
pub fn setKey(key: ?[KEY_LEN]u8) void {
    current_key = key;
}

/// The key in force, if any. Also the answer to "is this host sealing".
pub fn getKey() ?[KEY_LEN]u8 {
    return current_key;
}

pub fn isSealed(stored: []const u8) bool {
    return std.mem.startsWith(u8, stored, prefix);
}

/// What a stored value is.
pub const Kind = enum {
    /// A `v1:` envelope this build can open.
    sealed,
    /// No envelope marker: a value written before this feature existed, or
    /// while this host had no keychain. Read as-is.
    legacy_plaintext,
    /// Shaped like an envelope (`v<digits>:`) but not a version this build
    /// knows. NEVER treated as plaintext — passing a future `v2:…` through as
    /// a credential would hand the provider the envelope text and call the
    /// resulting 401 a credential problem.
    unknown_envelope,
};

pub fn classify(stored: []const u8) Kind {
    if (isSealed(stored)) return .sealed;
    if (looksLikeEnvelope(stored)) return .unknown_envelope;
    return .legacy_plaintext;
}

/// `v<digits>:` — the shape of an envelope from any version.
fn looksLikeEnvelope(stored: []const u8) bool {
    if (stored.len < 3 or stored[0] != 'v') return false;
    var i: usize = 1;
    while (i < stored.len and stored[i] >= '0' and stored[i] <= '9') : (i += 1) {}
    return i > 1 and i < stored.len and stored[i] == ':';
}

/// The `key_id` for a key: the first 8 hex characters of its SHA-256.
pub fn keyIdOf(key: [KEY_LEN]u8) [KEY_ID_HEX_LEN]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&key, &digest, .{});
    return std.fmt.bytesToHex(digest[0 .. KEY_ID_HEX_LEN / 2].*, .lower);
}

/// Build the AAD that binds an envelope to one secret row.
fn aadFor(allocator: std.mem.Allocator, secret_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, prefix ++ "{s}", .{secret_id});
}

/// Seal `plaintext` for the row `secret_id`. The caller owns the result.
///
/// The nonce is fresh per call, so sealing the same value twice produces two
/// different envelopes — a database reader cannot tell whether a rotation
/// actually changed the credential.
pub fn seal(
    allocator: std.mem.Allocator,
    key: [KEY_LEN]u8,
    secret_id: []const u8,
    plaintext: []const u8,
) SealError![]u8 {
    const aad = aadFor(allocator, secret_id) catch return error.OutOfMemory;
    defer allocator.free(aad);

    var nonce: [NONCE_LEN]u8 = undefined;
    helpers.random.fillRandom(&nonce) catch return error.RandomFailed;

    const ciphertext = allocator.alloc(u8, plaintext.len) catch return error.OutOfMemory;
    defer allocator.free(ciphertext);
    var tag: [TAG_LEN]u8 = undefined;
    Aes256Gcm.encrypt(ciphertext, &tag, plaintext, aad, nonce, key);

    // nonce || ciphertext || tag, one buffer, then one base64 pass.
    const blob = allocator.alloc(u8, NONCE_LEN + plaintext.len + TAG_LEN) catch return error.OutOfMemory;
    defer allocator.free(blob);
    @memcpy(blob[0..NONCE_LEN], &nonce);
    @memcpy(blob[NONCE_LEN..][0..plaintext.len], ciphertext);
    @memcpy(blob[NONCE_LEN + plaintext.len ..], &tag);

    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(blob.len);
    const key_id = keyIdOf(key);
    const out = allocator.alloc(u8, prefix.len + KEY_ID_HEX_LEN + 1 + encoded_len) catch
        return error.OutOfMemory;
    errdefer allocator.free(out);

    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..][0..KEY_ID_HEX_LEN], &key_id);
    out[prefix.len + KEY_ID_HEX_LEN] = ':';
    _ = std.base64.url_safe_no_pad.Encoder.encode(
        out[prefix.len + KEY_ID_HEX_LEN + 1 ..],
        blob,
    );
    return out;
}

/// Open an envelope produced by `seal`. `error.NotSealed` means the input was
/// never sealed and the caller should use it as-is.
pub fn open(
    allocator: std.mem.Allocator,
    key: [KEY_LEN]u8,
    secret_id: []const u8,
    stored: []const u8,
) OpenError![]u8 {
    switch (classify(stored)) {
        .sealed => {},
        .unknown_envelope => return error.Malformed,
        .legacy_plaintext => return error.NotSealed,
    }

    // v1 : key_id : payload
    var it = std.mem.splitScalar(u8, stored, ':');
    const version = it.next() orelse return error.Malformed;
    if (!std.mem.eql(u8, version, "v1")) return error.Malformed;
    const key_id = it.next() orelse return error.Malformed;
    const payload = it.next() orelse return error.Malformed;
    if (it.next() != null) return error.Malformed;
    if (key_id.len != KEY_ID_HEX_LEN) return error.Malformed;

    // Report a foreign key before touching the ciphertext: the two failures
    // have different remedies, and a GCM tag failure cannot tell them apart.
    const ours = keyIdOf(key);
    if (!std.mem.eql(u8, key_id, &ours)) return error.WrongKey;

    const blob_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload) catch
        return error.Malformed;
    if (blob_len < NONCE_LEN + TAG_LEN) return error.Malformed;

    const blob = allocator.alloc(u8, blob_len) catch return error.OutOfMemory;
    defer allocator.free(blob);
    std.base64.url_safe_no_pad.Decoder.decode(blob, payload) catch return error.Malformed;

    const ciphertext_len = blob_len - NONCE_LEN - TAG_LEN;
    var nonce: [NONCE_LEN]u8 = undefined;
    @memcpy(&nonce, blob[0..NONCE_LEN]);
    var tag: [TAG_LEN]u8 = undefined;
    @memcpy(&tag, blob[NONCE_LEN + ciphertext_len ..]);

    const aad = aadFor(allocator, secret_id) catch return error.OutOfMemory;
    defer allocator.free(aad);

    const plaintext = allocator.alloc(u8, ciphertext_len) catch return error.OutOfMemory;
    errdefer allocator.free(plaintext);
    Aes256Gcm.decrypt(
        plaintext,
        blob[NONCE_LEN..][0..ciphertext_len],
        tag,
        aad,
        nonce,
        key,
    ) catch return error.Corrupt;
    return plaintext;
}

/// Seal if this host has a key; otherwise return a copy of the plaintext.
///
/// The plaintext fallback is the `unavailable` state, not an oversight: see the
/// module header. It is logged once at boot, never per write.
pub fn sealValue(
    allocator: std.mem.Allocator,
    secret_id: []const u8,
    plaintext: []const u8,
) ![]u8 {
    const key = current_key orelse return allocator.dupe(u8, plaintext);
    return seal(allocator, key, secret_id, plaintext);
}

/// The read counterpart: open an envelope, pass legacy plaintext through.
///
/// `error.KeyUnavailable` is deliberately distinct from "no such secret" — a
/// sealed row on a host that lost its keychain is a state the caller must not
/// report as an empty credential.
pub const OpenValueError = error{ KeyUnavailable, Malformed, WrongKey, Corrupt, OutOfMemory };

pub fn openValue(
    allocator: std.mem.Allocator,
    secret_id: []const u8,
    stored: []const u8,
) OpenValueError![]u8 {
    switch (classify(stored)) {
        .legacy_plaintext => return allocator.dupe(u8, stored),
        .unknown_envelope => return error.Malformed,
        .sealed => {},
    }
    const key = current_key orelse return error.KeyUnavailable;
    return open(allocator, key, secret_id, stored) catch |err| switch (err) {
        error.NotSealed => unreachable, // checked above
        error.Malformed => error.Malformed,
        error.WrongKey => error.WrongKey,
        error.Corrupt => error.Corrupt,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Seal every legacy plaintext row. Returns how many rows were sealed (0 when
/// there is no key, or when nothing needed sealing).
///
/// WHY AT BOOT AND NOT IN A MIGRATION: the migration chain must stay runnable
/// on a host where no key can be obtained — `migration_103.up` is pure
/// `db.exec` — and a migration that needed the keychain would fail a headless
/// boot. Here, no key simply means no work.
///
/// `PRAGMA secure_delete = ON` (applied at every open, see `boot/db_config`)
/// is what makes this an in-place erasure: SQLite zeroes the old record's bytes
/// as the UPDATE replaces them, so the plaintext does not merely move to a free
/// page. `compactAfterSeal` then handles what predates that pragma.
pub fn sealLegacyRows(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
) !usize {
    const key = current_key orelse return 0;

    // Collect first, update second: rewriting rows while the SELECT's cursor is
    // still open is how a "seal everything" loop seals a moving target.
    const Row = struct { id: []u8, value: []u8 };
    var rows: std.ArrayList(Row) = .empty;
    defer {
        for (rows.items) |r| {
            allocator.free(r.id);
            allocator.free(r.value);
        }
        rows.deinit(allocator);
    }

    var q = try db.query(
        allocator,
        "SELECT id, value FROM workspace_secrets WHERE value NOT LIKE 'v1:%'",
        &[_][]const u8{},
    );
    defer q.deinit();
    while (try q.next()) |r| {
        defer r.deinit(allocator);
        try rows.append(allocator, .{
            .id = try allocator.dupe(u8, r.values[0]),
            .value = try allocator.dupe(u8, r.values[1]),
        });
    }
    if (rows.items.len == 0) return 0;

    var sealed_count: usize = 0;
    try db.exec(allocator, "BEGIN IMMEDIATE", &[_][]const u8{});
    var committed = false;
    defer if (!committed) db.exec(allocator, "ROLLBACK", &[_][]const u8{}) catch {};

    for (rows.items) |row| {
        const envelope = try seal(allocator, key, row.id, row.value);
        defer allocator.free(envelope);
        db.exec(
            allocator,
            "UPDATE workspace_secrets SET value = ? WHERE id = ?",
            &[_][]const u8{ envelope, row.id },
        ) catch |err| {
            std.log.warn("secrets_at_rest: could not seal {s}: {s}", .{ row.id, @errorName(err) });
            continue;
        };
        sealed_count += 1;
    }

    try db.exec(allocator, "COMMIT", &[_][]const u8{});
    committed = true;
    return sealed_count;
}

/// Make the file on disk match the claim that the values are sealed.
///
/// `wal_checkpoint(TRUNCATE)` rewrites the WAL into the database and truncates
/// it to zero, so no frame holding a pre-seal value survives. It is cheap and
/// always runs.
///
/// `VACUUM` rewrites the whole file, which is what purges pages that were freed
/// BEFORE `secure_delete` was switched on — the only way old plaintext can
/// still be in the file. It is skipped above `vacuum_max_bytes` because it
/// costs a full rewrite plus a second copy on disk, and a multi-gigabyte
/// `agent.db` would make every boot pay minutes for it. When it is skipped the
/// log says so, and says what to run.
pub const vacuum_max_bytes: u64 = 256 * 1024 * 1024;

pub fn compactAfterSeal(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    db_path: []const u8,
    io: std.Io,
) void {
    db.exec(allocator, "PRAGMA wal_checkpoint(TRUNCATE)", &[_][]const u8{}) catch |err| {
        std.log.warn("secrets_at_rest: WAL checkpoint failed ({s}); pre-seal values may remain in the WAL", .{@errorName(err)});
    };

    const size: u64 = blk: {
        var dir = std.Io.Dir.openDirAbsolute(io, std.fs.path.dirname(db_path) orelse ".", .{}) catch break :blk 0;
        defer dir.close(io);
        const stat = dir.statFile(io, std.fs.path.basename(db_path), .{}) catch break :blk 0;
        break :blk stat.size;
    };

    if (size > vacuum_max_bytes) {
        std.log.warn(
            "secrets_at_rest: agent.db is {d} MiB, so VACUUM was skipped; pages freed before secure_delete was enabled can still hold old plaintext. Run `sqlite3 {s} 'VACUUM'` when convenient.",
            .{ size / (1024 * 1024), db_path },
        );
        return;
    }

    db.exec(allocator, "VACUUM", &[_][]const u8{}) catch |err| {
        std.log.warn("secrets_at_rest: VACUUM failed ({s}); pages freed before secure_delete may still hold old plaintext", .{@errorName(err)});
    };
}

// ============================================================================
// Tests
// ============================================================================
//
// Every test sets its own key, so the suite never touches the real keychain —
// and `setKey(null)` is how the "no key on this host" path is exercised.

const testing = std.testing;

const test_key: [KEY_LEN]u8 = blk: {
    var k: [KEY_LEN]u8 = undefined;
    for (&k, 0..) |*b, i| b.* = @intCast(i);
    break :blk k;
};

test "seal/open round-trips, and the envelope carries no plaintext" {
    const alloc = testing.allocator;
    const plaintext = "ghp_a_very_secret_token_value";

    const envelope = try seal(alloc, test_key, "sec_1", plaintext);
    defer alloc.free(envelope);

    // The shape: v1:<8 hex>:<payload>
    try testing.expect(isSealed(envelope));
    // Exactly two separators: `v1`, the key id, then the payload (the base64url
    // alphabet has no `:` in it).
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, envelope, ":"));
    // The key id is derived from the key, so it is asserted against the same
    // derivation rather than against a literal that a different key would move.
    const expected_id = keyIdOf(test_key);
    try testing.expectEqualStrings(&expected_id, envelope[prefix.len..][0..KEY_ID_HEX_LEN]);
    try testing.expectEqual(@as(u8, ':'), envelope[prefix.len + KEY_ID_HEX_LEN]);

    // The whole point: the value is not in there.
    try testing.expect(std.mem.indexOf(u8, envelope, plaintext) == null);
    try testing.expect(std.mem.indexOf(u8, envelope, "ghp_") == null);

    const opened = try open(alloc, test_key, "sec_1", envelope);
    defer alloc.free(opened);
    try testing.expectEqualStrings(plaintext, opened);
}

test "the nonce is fresh per write, so the same value seals differently twice" {
    const alloc = testing.allocator;
    const plaintext = "same-value-both-times";

    const a = try seal(alloc, test_key, "sec_1", plaintext);
    defer alloc.free(a);
    const b = try seal(alloc, test_key, "sec_1", plaintext);
    defer alloc.free(b);

    // A fixed nonce would make these identical, which is what lets a database
    // reader tell that a rotation did not actually change the credential.
    try testing.expect(!std.mem.eql(u8, a, b));

    const opened_a = try open(alloc, test_key, "sec_1", a);
    defer alloc.free(opened_a);
    const opened_b = try open(alloc, test_key, "sec_1", b);
    defer alloc.free(opened_b);
    try testing.expectEqualStrings(plaintext, opened_a);
    try testing.expectEqualStrings(plaintext, opened_b);
}

test "a flipped ciphertext byte fails to open instead of decrypting to rubbish" {
    const alloc = testing.allocator;
    const envelope = try seal(alloc, test_key, "sec_1", "value");
    defer alloc.free(envelope);

    const tampered = try alloc.dupe(u8, envelope);
    defer alloc.free(tampered);
    // Flip a bit in the payload, past the version and key id.
    tampered[tampered.len - 6] = if (tampered[tampered.len - 6] == 'A') 'B' else 'A';

    try testing.expectError(error.Corrupt, open(alloc, test_key, "sec_1", tampered));
}

test "an envelope is bound to its row id, so moving it to another secret fails" {
    const alloc = testing.allocator;
    const envelope = try seal(alloc, test_key, "sec_1", "value");
    defer alloc.free(envelope);

    // A row copied, moved or swapped by someone with write access to the file
    // must not decrypt into the wrong secret.
    try testing.expectError(error.Corrupt, open(alloc, test_key, "sec_2", envelope));
}

test "a foreign key is reported as WrongKey, not as a corrupt row" {
    const alloc = testing.allocator;
    const envelope = try seal(alloc, test_key, "sec_1", "value");
    defer alloc.free(envelope);

    var other_key: [KEY_LEN]u8 = undefined;
    @memset(&other_key, 7);
    // The two failures have different remedies — the keychain holds the wrong
    // key, versus the row is damaged — so they must not collapse into one.
    try testing.expectError(error.WrongKey, open(alloc, other_key, "sec_1", envelope));
}

test "malformed envelopes are rejected, not guessed at" {
    const alloc = testing.allocator;
    const id = keyIdOf(test_key);

    // These carry OUR key id on purpose: a foreign id is reported as WrongKey
    // before the payload is ever parsed (that is its own test), so a case that
    // used one here would prove nothing about the payload checks.
    const owned = [_][]u8{
        try std.fmt.allocPrint(alloc, "v1:{s}", .{id}), // no payload field
        try std.fmt.allocPrint(alloc, "v1:{s}:", .{id}), // empty payload
        try std.fmt.allocPrint(alloc, "v1:{s}:!!!!", .{id}), // not base64
        try std.fmt.allocPrint(alloc, "v1:{s}:AAAA", .{id}), // too short for a nonce and a tag
        try std.fmt.allocPrint(alloc, "v1:{s}:AAAA:extra", .{id}), // a fourth field
    };
    defer for (owned) |stored| alloc.free(stored);
    for (owned) |stored| {
        try testing.expectError(error.Malformed, open(alloc, test_key, "sec_1", stored));
    }

    // Shapes that fail before the key id can matter.
    const shapes = [_][]const u8{
        "v1:", // no key id, no payload
        "v1:b38d9170", // no payload field
        "v1:short:x", // key id is not 8 characters
        "v2:b38d9170:AAAA", // unknown version
    };
    for (shapes) |stored| {
        try testing.expectError(error.Malformed, open(alloc, test_key, "sec_1", stored));
    }
}

test "classify separates legacy plaintext from a future envelope version" {
    const alloc = testing.allocator;
    const envelope = try seal(alloc, test_key, "sec_1", "value");
    defer alloc.free(envelope);

    try testing.expectEqual(Kind.sealed, classify(envelope));
    try testing.expectEqual(Kind.legacy_plaintext, classify("ghp_a_plain_token"));
    try testing.expectEqual(Kind.legacy_plaintext, classify(""));
    try testing.expectEqual(Kind.legacy_plaintext, classify("v1"));
    try testing.expectEqual(Kind.legacy_plaintext, classify("version: 1"));

    // A version this build does not know is an ERROR, not plaintext: the whole
    // point is that envelope text must never be substituted as a credential.
    try testing.expectEqual(Kind.unknown_envelope, classify("v2:b38d9170:AAAA"));
    try testing.expectEqual(Kind.unknown_envelope, classify("v10:x:y"));
    try testing.expectError(error.Malformed, open(alloc, test_key, "sec_1", "v2:b38d9170:AAAA"));
    try testing.expectError(error.Malformed, openValue(alloc, "sec_1", "v2:b38d9170:AAAA"));
}

test "legacy plaintext passes through both helpers untouched" {
    const alloc = testing.allocator;

    // No prefix means a row written before this feature existed, or written
    // while the host had no keychain. It must stay readable — that single rule
    // is why the upgrade cannot brick.
    try testing.expectError(error.NotSealed, open(alloc, test_key, "sec_1", "plain-value"));

    const passed = try openValue(alloc, "sec_1", "plain-value");
    defer alloc.free(passed);
    try testing.expectEqualStrings("plain-value", passed);
}

test "with no key set, writes stay plaintext and sealed rows report KeyUnavailable" {
    const alloc = testing.allocator;
    defer setKey(null);

    setKey(null);
    const stored = try sealValue(alloc, "sec_1", "no-keychain-here");
    defer alloc.free(stored);
    // The unavailable state, stated rather than silent: the boot log and the
    // secrets-list state carry the reason.
    try testing.expectEqualStrings("no-keychain-here", stored);
    try testing.expect(!isSealed(stored));

    // A sealed row on a host that lost its keychain is NOT an empty credential.
    setKey(test_key);
    const envelope = try seal(alloc, test_key, "sec_1", "value");
    defer alloc.free(envelope);
    setKey(null);
    try testing.expectError(error.KeyUnavailable, openValue(alloc, "sec_1", envelope));

    // ...and with the key back, the same row opens.
    setKey(test_key);
    const opened = try openValue(alloc, "sec_1", envelope);
    defer alloc.free(opened);
    try testing.expectEqualStrings("value", opened);
}

test "sealValue under a key produces an envelope, and openValue reads it back" {
    const alloc = testing.allocator;
    defer setKey(null);
    setKey(test_key);

    const stored = try sealValue(alloc, "sec_7", "round-trip-me");
    defer alloc.free(stored);
    try testing.expect(isSealed(stored));

    const opened = try openValue(alloc, "sec_7", stored);
    defer alloc.free(opened);
    try testing.expectEqualStrings("round-trip-me", opened);
}

/// Minimal `workspace_secrets` fixture. Spelled out here rather than imported
/// from the migrations: this module is a leaf, and a test that borrowed the
/// migration would pass even if the migration shipped a different table.
const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE workspace_secrets (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT NOT NULL,
        \\  name TEXT NOT NULL,
        \\  value TEXT NOT NULL,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

fn storedValue(ctx: *TestCtx, id: []const u8) ![]u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, "SELECT value FROM workspace_secrets WHERE id = ?", &[_][]const u8{id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

test "sealLegacyRows seals every plaintext row and leaves sealed ones alone" {
    const alloc = testing.allocator;
    defer setKey(null);
    setKey(test_key);

    var ctx = try setupDb();
    defer teardown(&ctx);

    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value) VALUES
        \\  ('sec_a', 'ws_1', 'ALPHA', 'plain-a'),
        \\  ('sec_b', 'ws_1', 'BETA', 'plain-b')
    , &.{});

    // A row that is already sealed must not be re-sealed (which would double
    // the envelope and lose the value).
    const already = try seal(alloc, test_key, "sec_c", "already-sealed");
    defer alloc.free(already);
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value) VALUES ('sec_c', 'ws_1', 'GAMMA', ?)
    , &[_][]const u8{already});

    const count = try sealLegacyRows(alloc, &ctx.db);
    try testing.expectEqual(@as(usize, 2), count);

    for ([_][]const u8{ "sec_a", "sec_b" }) |id| {
        const stored = try storedValue(&ctx, id);
        defer alloc.free(stored);
        try testing.expect(isSealed(stored));
        // The raw column no longer contains the plaintext...
        try testing.expect(std.mem.indexOf(u8, stored, "plain-") == null);
        // ...and the value still round-trips.
        const opened = try openValue(alloc, id, stored);
        defer alloc.free(opened);
        try testing.expectEqualStrings(if (std.mem.eql(u8, id, "sec_a")) "plain-a" else "plain-b", opened);
    }

    const untouched = try storedValue(&ctx, "sec_c");
    defer alloc.free(untouched);
    try testing.expectEqualStrings(already, untouched);

    // Idempotent: a second pass has nothing to do.
    try testing.expectEqual(@as(usize, 0), try sealLegacyRows(alloc, &ctx.db));
}

test "sealLegacyRows is a no-op with no key, and the rows stay readable" {
    const alloc = testing.allocator;
    defer setKey(null);
    setKey(null);

    var ctx = try setupDb();
    defer teardown(&ctx);
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value) VALUES ('sec_a', 'ws_1', 'ALPHA', 'plain-a')
    , &.{});

    try testing.expectEqual(@as(usize, 0), try sealLegacyRows(alloc, &ctx.db));

    const stored = try storedValue(&ctx, "sec_a");
    defer alloc.free(stored);
    try testing.expectEqualStrings("plain-a", stored);
}

test "after sealing, the plaintext is gone from the database FILE" {
    // THE assertion that proves "encrypted at rest" rather than "round-trips".
    // Everything above tests the cipher in memory; this reads the bytes SQLite
    // actually left on disk, which is the thing a copied `agent.db` contains.
    const alloc = testing.allocator;
    defer setKey(null);
    setKey(test_key);

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const db_path = try std.fs.path.join(alloc, &.{ path_buf[0..dir_len], "sealed.db" });
    defer alloc.free(db_path);
    const db_path_z = try alloc.dupeZ(u8, db_path);
    defer alloc.free(db_path_z);

    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, db_path_z);
    // The same pragma the real boot path applies, because it is half of why
    // the UPDATE below erases in place instead of leaving the old bytes behind.
    try db.exec(alloc, "PRAGMA secure_delete = ON", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_secrets (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT NOT NULL,
        \\  name TEXT NOT NULL,
        \\  value TEXT NOT NULL,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    const sentinel = "SENTINEL-plaintext-that-must-not-survive";
    try db.exec(alloc,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value)
        \\VALUES ('sec_s', 'ws_1', 'S', ?)
    , &[_][]const u8{sentinel});

    // Read the database AND its two sidecars, because that is what a copied
    // `agent.db` actually is: a fresh write lives in `-wal` until a
    // checkpoint, so searching only the main file would miss the newest value —
    // and would have made the control below pass for the wrong reason.
    const read_file_bytes = struct {
        fn go(io_: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator) ![]u8 {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            for ([_][]const u8{ "sealed.db", "sealed.db-wal", "sealed.db-shm" }) |name| {
                const bytes = dir.readFileAlloc(io_, name, gpa, std.Io.Limit.limited(std.math.maxInt(usize))) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                defer gpa.free(bytes);
                try out.appendSlice(gpa, bytes);
            }
            return out.toOwnedSlice(gpa);
        }
    }.go;

    // POSITIVE CONTROL: the plaintext IS on disk before sealing. Without this,
    // the assertion below would pass on a search that finds nothing because it
    // is looking in the wrong place — which is exactly the bug this control
    // caught on its first run.
    const before = try read_file_bytes(io, tmp.dir, alloc);
    defer alloc.free(before);
    try testing.expect(std.mem.indexOf(u8, before, sentinel) != null);

    try testing.expectEqual(@as(usize, 1), try sealLegacyRows(alloc, &db));
    compactAfterSeal(alloc, &db, db_path, io);

    const after = try read_file_bytes(io, tmp.dir, alloc);
    defer alloc.free(after);
    try testing.expect(std.mem.indexOf(u8, after, sentinel) == null);
    // And the row still reads back, so the plaintext is gone because it is
    // sealed, not because it was lost.
    var q = try db.query(alloc, "SELECT value FROM workspace_secrets WHERE id = 'sec_s'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expect(isSealed(row.values[0]));
}

test "keyIdOf is stable, key-derived, and 8 hex characters" {
    const id_a = keyIdOf(test_key);
    const id_b = keyIdOf(test_key);
    try testing.expectEqualStrings(&id_a, &id_b);
    try testing.expectEqual(@as(usize, KEY_ID_HEX_LEN), id_a.len);
    for (id_a) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }

    var other: [KEY_LEN]u8 = undefined;
    @memset(&other, 9);
    try testing.expect(!std.mem.eql(u8, &id_a, &keyIdOf(other)));
}
