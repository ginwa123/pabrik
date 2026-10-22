//! The installation the console administers: the database handle and whether
//! `--auth` is on. The host program installs it once, at boot.

const std = @import("std");
const database = @import("databases").database;

const Installed = struct {
    db: *database.Db,
    auth_enabled: bool,
};

var installed: ?Installed = null;

/// Point the console at an installation.
pub fn install(handle: *database.Db, auth_enabled: bool) void {
    installed = .{ .db = handle, .auth_enabled = auth_enabled };
}

/// Forget the installation, for a host that closes its database first.
pub fn uninstall() void {
    installed = null;
}

pub fn isInstalled() bool {
    return installed != null;
}

/// The database the console works on, or null when nothing installed it.
pub fn db() ?*database.Db {
    return if (installed) |i| i.db else null;
}

/// Whether a session decides the owner (`--auth` on) or the operator does.
pub fn authEnabled() bool {
    return if (installed) |i| i.auth_enabled else false;
}

const testing = std.testing;

test "the console reads the installation the host installed" {
    var memory_db: database.Db = .{};
    try memory_db.init(testing.io, ":memory:");
    defer memory_db.deinit();

    try testing.expect(db() == null);
    install(&memory_db, true);
    defer uninstall();

    try testing.expect(isInstalled());
    try testing.expect(db() == &memory_db);
    try testing.expect(authEnabled());
}
