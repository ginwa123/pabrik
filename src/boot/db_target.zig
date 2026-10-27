const std = @import("std");
const databases = @import("databases");
const helpers = @import("helpers");
const cli_flags = @import("../cli/flags.zig");

pub const database = databases.database;

pub const env_backend = "PABRIK_DATABASE";
pub const env_sqlite_path = "PABRIK_DATABASE_PATH";
pub const env_conninfo = "PABRIK_DATABASE_CONNINFO";

pub const flag_backend = "database";
pub const flag_sqlite_path = "database-path";
pub const flag_conninfo = "database-conninfo";

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

    pub fn compiled() Backend {
        return if (database.backend_is_postgres) .postgres else .sqlite;
    }

    pub fn neededBuildList(backend: Backend) []const u8 {
        return if (backend == .postgres) "sqlite,postgres" else "sqlite";
    }
};

pub const Source = enum {
    flag,
    environment,

    pub fn text(self: Source) []const u8 {
        return @tagName(self);
    }
};

pub const Setting = struct {
    value: []const u8,
    source: Source,
};

pub const Request = struct {
    backend: ?Setting = null,
    sqlite_path: ?Setting = null,
    conninfo: ?Setting = null,

    pub fn isEmpty(self: Request) bool {
        return self.backend == null and self.sqlite_path == null and self.conninfo == null;
    }
};

pub const Origin = enum {
    flag,
    environment,
    compile_default,

    pub fn text(self: Origin) []const u8 {
        return @tagName(self);
    }
};

pub const Defaults = struct {
    sqlite_path: [:0]const u8,
};

pub const ArgError = error{
    MissingValue,
    OutOfMemory,
};

pub const ResolveError = error{
    UnknownBackend,
    BackendNotCompiled,
    ForeignOption,
    OutOfMemory,
};

pub const Target = struct {
    backend: Backend,
    origin: Origin,
    sqlite_path: [:0]const u8 = "",
    conninfo: [:0]const u8 = "",
    allocator: std.mem.Allocator,
    live: bool = true,

    pub fn deinit(self: *Target) void {
        if (!self.live) return;
        self.live = false;
        switch (self.backend) {
            .sqlite => self.allocator.free(self.sqlite_path),
            .postgres => self.allocator.free(self.conninfo),
        }
        self.sqlite_path = "";
        self.conninfo = "";
    }

    pub fn openConfig(self: *const Target) database.OpenConfig {
        return if (database.backend_is_postgres)
            .{ .postgres_conninfo = self.conninfo }
        else
            .{ .sqlite_path = self.sqlite_path };
    }

    pub fn describe(self: *const Target, buf: []u8) error{NoSpaceLeft}![]const u8 {
        if (self.backend == .sqlite) {
            return std.fmt.bufPrint(
                buf,
                "database: backend=sqlite source={s} path={s}",
                .{ self.origin.text(), self.sqlite_path },
            );
        }
        if (self.conninfo.len == 0) {
            return std.fmt.bufPrint(
                buf,
                "database: backend=postgres source={s} conninfo=(libpq defaults)",
                .{self.origin.text()},
            );
        }
        var safe_buf: [512]u8 = undefined;
        const safe = redactConninfo(self.conninfo, &safe_buf) catch return error.NoSpaceLeft;
        return std.fmt.bufPrint(
            buf,
            "database: backend=postgres source={s} conninfo={s}",
            .{ self.origin.text(), safe },
        );
    }
};

fn canonicalFlagName(typed: []const u8) ?[]const u8 {
    if (cli_flags.underscoredEql(typed, flag_backend)) return flag_backend;
    if (cli_flags.underscoredEql(typed, flag_sqlite_path)) return flag_sqlite_path;
    if (cli_flags.underscoredEql(typed, flag_conninfo)) return flag_conninfo;
    return null;
}

pub fn parseArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Request,
    rest: *std.ArrayList([]const u8),
) ArgError!void {
    out.* = .{};
    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) {
            try rest.append(allocator, arg);
            continue;
        }
        const bare = cli_flags.stripDashes(arg);
        const eq = std.mem.indexOfScalar(u8, bare, '=');
        const name = if (eq) |at| bare[0..at] else bare;
        const canonical = canonicalFlagName(name) orelse {
            try rest.append(allocator, arg);
            continue;
        };
        const at = eq orelse return error.MissingValue;
        const value = bare[at + 1 ..];
        if (value.len == 0) return error.MissingValue;
        const setting: Setting = .{ .value = value, .source = .flag };
        if (std.mem.eql(u8, canonical, flag_backend)) {
            out.backend = setting;
        } else if (std.mem.eql(u8, canonical, flag_sqlite_path)) {
            out.sqlite_path = setting;
        } else {
            out.conninfo = setting;
        }
    }
}

pub fn applyEnv(request: *Request, env: *const std.process.Environ.Map) void {
    if (request.backend == null) {
        if (env.get(env_backend)) |value| request.backend = .{ .value = value, .source = .environment };
    }
    if (request.sqlite_path == null) {
        if (env.get(env_sqlite_path)) |value| request.sqlite_path = .{ .value = value, .source = .environment };
    }
    if (request.conninfo == null) {
        if (env.get(env_conninfo)) |value| request.conninfo = .{ .value = value, .source = .environment };
    }
}

pub fn resolve(
    allocator: std.mem.Allocator,
    request: Request,
    defaults: Defaults,
) ResolveError!Target {
    const compiled = Backend.compiled();
    const asked = request.backend;
    const backend = if (asked) |setting| Backend.fromText(setting.value) orelse
        return error.UnknownBackend else compiled;
    if (backend != compiled) return error.BackendNotCompiled;

    const origin: Origin = if (asked) |setting| switch (setting.source) {
        .flag => .flag,
        .environment => .environment,
    } else .compile_default;

    switch (backend) {
        .sqlite => {
            if (request.conninfo) |setting| {
                if (setting.source == .flag) return error.ForeignOption;
            }
            const path = request.sqlite_path orelse Setting{
                .value = defaults.sqlite_path,
                .source = .environment,
            };
            return .{
                .backend = .sqlite,
                .origin = origin,
                .allocator = allocator,
                .sqlite_path = try allocator.dupeZ(u8, path.value),
            };
        },
        .postgres => {
            if (request.sqlite_path) |setting| {
                if (setting.source == .flag) return error.ForeignOption;
            }
            const value = if (request.conninfo) |setting| setting.value else "";
            return .{
                .backend = .postgres,
                .origin = origin,
                .allocator = allocator,
                .conninfo = try allocator.dupeZ(u8, value),
            };
        },
    }
}

pub fn openTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    request: Request,
) !Target {
    var with_env = request;
    applyEnv(&with_env, env);
    const default_path = try helpers.db_path.getDbPath(allocator, io, env);
    defer allocator.free(default_path);
    return resolve(allocator, with_env, .{ .sqlite_path = default_path });
}

fn redactable(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "password") or
        std.ascii.eqlIgnoreCase(key, "passfile") or
        std.ascii.eqlIgnoreCase(key, "sslkey");
}

const PasswordSpan = struct { colon: usize, at: usize };

fn uriPasswordSpan(conninfo: []const u8) ?PasswordSpan {
    const scheme_len: usize = if (std.mem.startsWith(u8, conninfo, "postgres://"))
        "postgres://".len
    else if (std.mem.startsWith(u8, conninfo, "postgresql://"))
        "postgresql://".len
    else
        return null;
    const authority_end = std.mem.indexOfScalarPos(u8, conninfo, scheme_len, '/') orelse conninfo.len;
    const authority = conninfo[scheme_len..authority_end];
    const at = std.mem.lastIndexOfScalar(u8, authority, '@') orelse return null;
    const colon = std.mem.lastIndexOfScalar(u8, authority[0..at], ':') orelse return null;
    return .{ .colon = scheme_len + colon + 1, .at = scheme_len + at };
}

pub fn redactConninfo(conninfo: []const u8, buf: []u8) error{WriteFailed}![]const u8 {
    if (uriPasswordSpan(conninfo)) |span| {
        var uri_writer: std.Io.Writer = .fixed(buf);
        try uri_writer.writeAll(conninfo[0..span.colon]);
        try uri_writer.writeAll("***");
        try uri_writer.writeAll(conninfo[span.at..]);
        return uri_writer.buffered();
    }

    var writer: std.Io.Writer = .fixed(buf);
    var i: usize = 0;
    while (i < conninfo.len) {
        const token_start = i;
        while (i < conninfo.len and !std.ascii.isWhitespace(conninfo[i])) i += 1;
        const token = conninfo[token_start..i];
        if (std.mem.indexOfScalar(u8, token, '=')) |eq| {
            const key = token[0..eq];
            try writer.writeAll(key);
            try writer.writeAll("=");
            try writer.writeAll(if (redactable(key)) "***" else token[eq + 1 ..]);
        } else {
            try writer.writeAll(token);
        }
        while (i < conninfo.len and std.ascii.isWhitespace(conninfo[i])) : (i += 1) {
            try writer.writeAll(conninfo[i .. i + 1]);
        }
    }
    return writer.buffered();
}

pub fn isResolveError(err: anyerror) bool {
    return err == error.UnknownBackend or
        err == error.BackendNotCompiled or
        err == error.ForeignOption;
}

fn offendingWord(args: []const []const u8) []const u8 {
    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) continue;
        const bare = cli_flags.stripDashes(arg);
        const eq = std.mem.indexOfScalar(u8, bare, '=');
        const name = if (eq) |at| bare[0..at] else bare;
        if (canonicalFlagName(name) == null) continue;
        if (eq) |at| {
            if (at + 1 < bare.len) continue;
        }
        return arg;
    }
    return "--database";
}

pub fn reportArgError(args: []const []const u8, err: ArgError) void {
    switch (err) {
        error.MissingValue => std.log.err(
            "Error: {s} requires a value (e.g. --{s}=sqlite, --{s}=/tmp/agent.db, --{s}='host=... dbname=...')",
            .{ offendingWord(args), flag_backend, flag_sqlite_path, flag_conninfo },
        ),
        error.OutOfMemory => std.log.err("Error: out of memory parsing the database flags", .{}),
    }
}

pub fn reportResolveError(request: Request, err: ResolveError) void {
    const compiled = Backend.compiled();
    switch (err) {
        error.UnknownBackend => std.log.err(
            "Error: --{s}={s}: expected sqlite or postgres",
            .{ flag_backend, if (request.backend) |setting| setting.value else "" },
        ),
        error.BackendNotCompiled => {
            const asked = if (request.backend) |setting| setting.value else compiled.text();
            std.log.err(
                "Error: this pabrik was compiled with the {s} backend only, so it cannot open {s}; rebuild it with `-Ddb_used={s}`",
                .{ compiled.text(), asked, Backend.neededBuildList(if (std.mem.eql(u8, asked, "postgres")) .postgres else .sqlite) },
            );
        },
        error.ForeignOption => std.log.err(
            "Error: --{s} and --{s} contradict each other; pass the one that belongs to the selected backend",
            .{ flag_sqlite_path, flag_conninfo },
        ),
        error.OutOfMemory => std.log.err("Error: out of memory resolving the database target", .{}),
    }
}
