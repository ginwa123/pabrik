//! Where the workspace-secrets master key comes from.
//!
//! **The key lives in the operating system's keychain, and nowhere else.** Not
//! in a file, not even a `0600` one — reviewer decision, 2026-10-11: a cipher
//! whose key sits in the file it protects is a ceremony, and the whole point of
//! `secrets_at_rest` is that a copied `agent.db` is inert.
//!
//! ## Why the app READS the keychain but does not WRITE it
//!
//! Provisioning is an explicit act by the user, with the exact command printed
//! in the boot log when no key is found:
//!
//! ```sh
//! secret-tool store --label="pabrik secrets master key" \
//!   service pabrik account secrets-master-key
//! ```
//!
//! Writing it from here would mean handing the key to a child process, and
//! neither CLI takes it safely: `secret-tool store` reads stdin only (which
//! `helpers.run_captured` does not feed), and `security add-generic-password -w`
//! takes it as an ARGUMENT, where `ps` shows it to every local user for the
//! duration. A server that cannot store key material safely should not try.
//!
//! ## Platform coverage, stated honestly
//!
//! - **Linux**: freedesktop Secret Service via `secret-tool` (libsecret).
//!   Absent on most headless boxes, which is exactly when the caller reports
//!   `unavailable` and values stay in plaintext, visibly.
//! - **macOS**: Keychain via `security find-generic-password`.
//! - **Windows**: NOT implemented — `cmdkey` can write a credential but cannot
//!   read one back, so Credential Manager support needs `advapi32.CredReadW`
//!   bindings that cannot be exercised from here. Windows therefore reports
//!   `unsupported_platform` and stays on plaintext until that lands. This is a
//!   deviation from the plan and is called out in the PR rather than papered
//!   over with a half-working path.

const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("helpers");

/// Must match `secrets_at_rest.KEY_LEN`. Duplicated rather than imported so
/// this module stays a leaf with no dependency on the cipher.
pub const KEY_LEN: usize = 32;

/// Keychain coordinates. `service`/`account` are what the provisioning command
/// in the module header uses, so the two cannot drift.
pub const service = "pabrik";
pub const account = "secrets-master-key";

/// The command that provisions the key on this platform, or null when the
/// platform has no supported keychain. Logged verbatim when the key is missing,
/// so the fix is one paste away instead of a documentation hunt.
pub fn provisionCommand() ?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => "secret-tool store --label=\"pabrik secrets master key\" service pabrik account secrets-master-key",
        .macos => "security add-generic-password -s pabrik -a secrets-master-key -w",
        else => null,
    };
}

/// Why no key is in force. Every variant is a state the caller reports, not an
/// error it hides: "we could not get the key" and "there is no key here" both
/// end in plaintext storage, and both are said out loud.
pub const Unavailable = enum {
    /// A key is loaded; this is the "no problem" value.
    none,
    /// No supported keychain exists on this platform (Windows, today).
    unsupported_platform,
    /// The platform has a keychain tool, but it is not installed — a headless
    /// box with no D-Bus session, which is the common case for a server.
    tool_missing,
    /// The tool ran and failed, or the answer was not a 64-hex-character key.
    lookup_failed,
    /// The tool ran and answered "nothing stored under this name".
    not_provisioned,

    pub fn describe(self: Unavailable) []const u8 {
        return switch (self) {
            .none => "master key loaded from the OS keychain",
            .unsupported_platform => "this platform has no supported keychain yet, so values are stored in plaintext",
            .tool_missing => "no OS keychain tool on this host (headless or no D-Bus session), so values are stored in plaintext",
            .lookup_failed => "the OS keychain could not be read, so values are stored in plaintext",
            .not_provisioned => "no master key is stored in the OS keychain yet, so values are stored in plaintext",
        };
    }
};

pub const Status = struct {
    /// The key, when the keychain answered with one.
    key: ?[KEY_LEN]u8 = null,
    unavailable: Unavailable = .none,

    pub fn sealed(self: Status) bool {
        return self.key != null;
    }
};

/// Parse a 64-hex-character key, tolerating surrounding whitespace and the
/// trailing newline every CLI adds.
///
/// Pure, so it is unit-testable without a keychain — which matters, because the
/// alternative is a test that depends on the developer's session keyring.
pub fn parseKey(raw: []const u8) ?[KEY_LEN]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len != KEY_LEN * 2) return null;
    var key: [KEY_LEN]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, trimmed) catch return null;
    return key;
}

/// Read the master key out of the OS keychain.
///
/// Never fails: every failure mode is a `Status` whose `unavailable` says which
/// one it was. A boot path that cannot get a key must still start — with the
/// state visible — rather than refuse to serve.
pub fn load(allocator: std.mem.Allocator, io: std.Io) Status {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .linux => &[_][]const u8{
            "secret-tool", "lookup", "service", service, "account", account,
        },
        .macos => &[_][]const u8{
            "security", "find-generic-password", "-s", service, "-a", account, "-w",
        },
        else => return .{ .unavailable = .unsupported_platform },
    };

    var result = helpers.run_captured.run(allocator, io, argv, .{ .timeout_ms = 5_000 }) catch |err| {
        return .{
            .unavailable = switch (err) {
                // The tool is simply not on PATH — the normal headless case, not a
                // fault worth waking anyone up for.
                error.FileNotFound => .tool_missing,
                else => .lookup_failed,
            },
        };
    };
    defer result.deinit(allocator);

    if (result.timed_out) return .{ .unavailable = .lookup_failed };

    const exited_ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok) {
        // `secret-tool lookup` exits non-zero with empty output when nothing is
        // stored, which is "not provisioned", not "broken".
        const stderr_quiet = std.mem.trim(u8, result.stderr, " \t\r\n").len == 0;
        return .{ .unavailable = if (stderr_quiet) .not_provisioned else .lookup_failed };
    }

    const key = parseKey(result.stdout) orelse {
        if (std.mem.trim(u8, result.stdout, " \t\r\n").len == 0) {
            return .{ .unavailable = .not_provisioned };
        }
        return .{ .unavailable = .lookup_failed };
    };
    return .{ .key = key };
}

// ============================================================================
// Tests
// ============================================================================
//
// `load` is deliberately NOT unit-tested: it spawns a keychain CLI, and on a
// developer machine with an unlocked keyring that would read (and depend on)
// the real session keychain. What is testable without a keychain is the parse
// and the descriptions, which is where the bugs actually live.

const testing = std.testing;

test "parseKey accepts 64 hex characters, with the whitespace every CLI adds" {
    const hex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

    const plain = parseKey(hex) orelse return error.ShouldParse;
    try testing.expectEqual(@as(u8, 0x00), plain[0]);
    try testing.expectEqual(@as(u8, 0xff), plain[31]);

    // `secret-tool` and `security` both end their answer with a newline; a
    // trailing newline that failed the parse would silently downgrade every
    // host to plaintext.
    const newline = parseKey(hex ++ "\n") orelse return error.ShouldParse;
    try testing.expectEqualSlices(u8, &plain, &newline);
    const padded = parseKey("  " ++ hex ++ " \r\n") orelse return error.ShouldParse;
    try testing.expectEqualSlices(u8, &plain, &padded);
}

test "parseKey rejects anything that is not a 64-hex key" {
    const hex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

    try testing.expect(parseKey("") == null);
    try testing.expect(parseKey("\n") == null);
    // 32 bytes is the key length; 32 CHARACTERS is half a key, and accepting it
    // would mean silently keying AES with a zero-padded half-key.
    try testing.expect(parseKey(hex[0..32]) == null);
    try testing.expect(parseKey(hex ++ "00") == null);
    // Uppercase hex is not what we store, and `hexToBytes` rejects it.
    try testing.expect(parseKey("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF") == null);
    // A base64 answer (what a hand-provisioned macOS keychain entry might hold).
    try testing.expect(parseKey("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=") == null);
    // The error message from a keychain that has nothing stored.
    try testing.expect(parseKey("security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.\n") == null);
}

test "every unavailable reason explains itself, and none is the empty string" {
    // These strings are the only thing a user sees when the key is missing, so
    // a blank or a Zig error name would be a dead end.
    inline for (std.meta.fields(Unavailable)) |field| {
        const reason: Unavailable = @enumFromInt(field.value);
        const text = reason.describe();
        try testing.expect(text.len > 0);
        try testing.expect(!std.mem.startsWith(u8, text, "error."));
        // Each says what happens to the values, which is the question that
        // actually matters to the reader.
        if (reason != .none) {
            try testing.expect(std.mem.indexOf(u8, text, "plaintext") != null);
        }
    }
}

test "Status.sealed is true only when a key is present" {
    const with_key = Status{ .key = [_]u8{0} ** KEY_LEN };
    try testing.expect(with_key.sealed());
    try testing.expect(!(Status{ .unavailable = .tool_missing }).sealed());
}
