//! Which backend the console opens: the server's policy from
//! `src/boot/db_target.zig`, copied so the console links nothing but
//! `databases`. The flag and variable names are the server's on purpose.

const std = @import("std");
const dialect = @import("dialect");

pub const env_backend = "PABRIK_DATABASE";
pub const env_conninfo = "PABRIK_DATABASE_CONNINFO";

pub const Backend = enum {
    sqlite,
    postgres,

    pub fn text(self: Backend) []const u8 {
        return @tagName(self);
    }

    pub fn fromText(typed: []const u8) ?Backend {
        inline for (@typeInfo(Backend).@"enum".fields) |f| {
            if (std.mem.eql(u8, f.name, typed)) return @field(Backend, f.name);
        }
        return null;
    }

    /// The backend `-Ddb_used` compiled in. One build opens one backend, the
    /// same rule the server's `Backend.compiled()` follows.
    pub fn compiled() Backend {
        return if (dialect.is_postgres) .postgres else .sqlite;
    }
};

pub const Error = error{
    UnknownBackend,
    BackendNotCompiled,
};

/// The backend to open: the request, else the one this build compiled in.
/// Naming a backend the build left out is a refusal, not a fallback.
pub fn resolve(requested: ?[]const u8) Error!Backend {
    const asked: ?[]const u8 = if (requested) |raw| blk: {
        const trimmed = std.mem.trim(u8, raw, " \t");
        break :blk if (trimmed.len == 0) null else trimmed;
    } else null;

    const backend = if (asked) |text|
        Backend.fromText(text) orelse return error.UnknownBackend
    else
        Backend.compiled();

    if (backend != Backend.compiled()) return error.BackendNotCompiled;
    return backend;
}

/// The `-Ddb_used` list that would compile `backend` in — the rebuild a refusal
/// message should name.
pub fn buildList(backend: Backend) []const u8 {
    return if (backend == .postgres) "sqlite,postgres" else "sqlite";
}

const testing = std.testing;

test "the compiled backend is the one the build selected" {
    if (dialect.is_postgres) {
        try testing.expectEqual(Backend.postgres, Backend.compiled());
    } else {
        try testing.expectEqual(Backend.sqlite, Backend.compiled());
    }
}

test "naming the compiled backend opens it" {
    try testing.expectEqual(Backend.compiled(), try resolve(Backend.compiled().text()));
}

test "no request means the compiled backend" {
    try testing.expectEqual(Backend.compiled(), try resolve(null));
    try testing.expectEqual(Backend.compiled(), try resolve(""));
    try testing.expectEqual(Backend.compiled(), try resolve("   "));
}

test "the backend the build did not compile is refused" {
    const other: Backend = if (Backend.compiled() == .sqlite) .postgres else .sqlite;
    try testing.expectError(error.BackendNotCompiled, resolve(other.text()));
}

test "a name that is not a backend is refused" {
    try testing.expectError(error.UnknownBackend, resolve("postgresql"));
    try testing.expectError(error.UnknownBackend, resolve("Postgres"));
    try testing.expectError(error.UnknownBackend, resolve(":memory:"));
}
