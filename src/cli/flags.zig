//! Every command-line flag `pabrik` understands, in one table.
//! `parse.zig` reads flags from it, and `--help` is rendered from it, so a
//! flag cannot exist in one and be missing from the other.

const std = @import("std");

/// Which command owns a flag. `db` is the `--db-*=` family `boot/db_config.zig`
/// applies to the SQLite policy; `db_target` is the `--database*=` family
/// `boot/db_target.zig` pulls out of argv before a scope parser sees it.
pub const Scope = enum { global, db, db_target, service, create_admin, headless };

/// The value type a `.store` flag parses its text into. `mode` is a named
/// on/off pair (`--http2 h2c|off`), so its target field is a bool.
pub const Kind = enum { boolean, u16_num, u32_num, u64_num, text, mode };

/// What seeing the flag does.
pub const Action = enum { set_true, set_false, store, help };

/// How a `.store` flag takes its value: the next word, the next word when
/// there is one, or `=value` in the same word.
pub const Syntax = enum { separate, optional_value, equals };

pub const Mode = struct { text: []const u8, on: bool };

pub const Flag = struct {
    /// Without the leading dashes: `port`, not `--port`.
    long: []const u8,
    help: []const u8,
    /// Single-dash spellings, without the dash: `h` for `-h`.
    aliases: []const []const u8 = &.{},
    scopes: []const Scope = &.{.global},
    /// Which subcommand verbs accept it. Empty = every verb of its scope;
    /// a scope parsed without a verb (`global`) ignores this field.
    verbs: []const []const u8 = &.{},
    action: Action = .set_true,
    kind: Kind = .boolean,
    syntax: Syntax = .separate,
    /// The target struct field(s), in value order. Two fields = two values.
    fields: []const []const u8 = &.{},
    modes: []const Mode = &.{},
    /// The value when an `optional_value` flag is the last word.
    missing_mode: bool = false,
    value_name: []const u8 = "",
    default_text: []const u8 = "",
};

/// The one place. Adding a flag here is the whole change; the help text, the
/// parser and the `--db-*` names all come from this array.
pub const flags = [_]Flag{
    .{
        .long = "help",
        .aliases = &.{"h"},
        .scopes = &.{ .global, .create_admin, .headless },
        .action = .help,
        .fields = &.{"help_requested"},
        .help = "Show this help and exit",
    },
    .{
        .long = "port",
        .scopes = &.{ .global, .service },
        .verbs = &.{ "start", "restart" },
        .action = .store,
        .kind = .u16_num,
        .fields = &.{"port"},
        .value_name = "PORT",
        .help = "Port to run the HTTP server on (0 = pick a random free port)",
        .default_text = "8081",
    },
    .{
        .long = "static-dir",
        .scopes = &.{ .global, .service },
        .verbs = &.{ "start", "restart" },
        .action = .store,
        .kind = .text,
        .fields = &.{"static_dir"},
        .value_name = "DIR",
        .help = "Serve files from DIR at HTTP /",
    },
    .{
        .long = "no-static-dir",
        .scopes = &.{ .global, .service },
        .verbs = &.{"start"},
        .fields = &.{"no_static_dir"},
        .help = "API only: serve no static files at /",
    },
    .{
        .long = "http2",
        .action = .store,
        .kind = .mode,
        .syntax = .optional_value,
        .fields = &.{"enable_h2c"},
        .modes = &.{ .{ .text = "h2c", .on = true }, .{ .text = "off", .on = false } },
        .missing_mode = true,
        .value_name = "h2c|off",
        .help = "Also accept HTTP/2 cleartext (h2c) clients on the same port",
        .default_text = "off",
    },
    .{
        .long = "tls",
        .action = .store,
        .kind = .text,
        .fields = &.{ "tls_cert_path", "tls_key_path" },
        .value_name = "CERT KEY",
        .help = "Serve TLS with <cert.pem> <key.pem>",
    },
    .{
        .long = "tls-selfsigned",
        .fields = &.{"tls_selfsigned"},
        .help = "Generate/reuse a self-signed pair in the app data dir",
    },
    .{
        .long = "auth",
        .scopes = &.{ .global, .service },
        .verbs = &.{ "start", "restart" },
        .fields = &.{"auth_enabled"},
        .help = "Require login (session cookie + middleware)",
    },
    .{
        .long = "saas",
        .fields = &.{"saas"},
        .help = "Run each workspace in its own microVM (Linux + KVM only; implies --auth)",
    },
    .{
        .long = "db-read-conns",
        .scopes = &.{.db},
        .action = .store,
        .kind = .u64_num,
        .syntax = .equals,
        .fields = &.{"read_conns"},
        .value_name = "N",
        .help = "Readers opened at boot (warm floor)",
        .default_text = "1",
    },
    .{
        .long = "db-max-read-conns",
        .scopes = &.{.db},
        .action = .store,
        .kind = .u64_num,
        .syntax = .equals,
        .fields = &.{"max_read_conns"},
        .value_name = "N",
        .help = "Ceiling on pooled readers (0 = uncapped)",
        .default_text = "0",
    },
    .{
        .long = "db-cache-size-kb",
        .scopes = &.{.db},
        .action = .store,
        .kind = .u64_num,
        .syntax = .equals,
        .fields = &.{"cache_size_kb"},
        .value_name = "N",
        .help = "Page cache PER connection, in KiB",
        .default_text = "512",
    },
    .{
        .long = "db-mmap-size-bytes",
        .scopes = &.{.db},
        .action = .store,
        .kind = .u64_num,
        .syntax = .equals,
        .fields = &.{"mmap_size_bytes"},
        .value_name = "N",
        .help = "mmap window per connection (0 = off)",
        .default_text = "268435456",
    },
    .{
        .long = "db-journal-size-limit-bytes",
        .scopes = &.{.db},
        .action = .store,
        .kind = .u64_num,
        .syntax = .equals,
        .fields = &.{"journal_size_limit_bytes"},
        .value_name = "N",
        .help = "WAL/journal size cap",
        .default_text = "67108864",
    },
    .{
        .long = "db-wal-autocheckpoint-pages",
        .scopes = &.{.db},
        .action = .store,
        .kind = .u64_num,
        .syntax = .equals,
        .fields = &.{"wal_autocheckpoint_pages"},
        .value_name = "N",
        .help = "Pages between WAL checkpoints",
        .default_text = "1000",
    },
    .{
        .long = "db-busy-timeout-ms",
        .scopes = &.{.db},
        .action = .store,
        .kind = .u64_num,
        .syntax = .equals,
        .fields = &.{"busy_timeout_ms"},
        .value_name = "N",
        .help = "How long SQLite waits for a lock",
        .default_text = "15000",
    },
    .{
        .long = "db-max-idle-time-ms",
        .scopes = &.{.db},
        .action = .store,
        .kind = .u64_num,
        .syntax = .equals,
        .fields = &.{"max_idle_time_ms"},
        .value_name = "N",
        .help = "How long an idle reader is kept before it is closed",
        .default_text = "30000",
    },
    .{
        .long = "database",
        .scopes = &.{.db_target},
        .action = .store,
        .kind = .text,
        .syntax = .equals,
        .fields = &.{"database"},
        .value_name = "sqlite|postgres",
        .help = "Database backend to open",
        .default_text = "sqlite",
    },
    .{
        .long = "database-path",
        .scopes = &.{.db_target},
        .action = .store,
        .kind = .text,
        .syntax = .equals,
        .fields = &.{"database_path"},
        .value_name = "PATH",
        .help = "SQLite file to open (default: the app data dir)",
    },
    .{
        .long = "database-conninfo",
        .scopes = &.{.db_target},
        .action = .store,
        .kind = .text,
        .syntax = .equals,
        .fields = &.{"database_conninfo"},
        .value_name = "CONNINFO",
        .help = "libpq conninfo or postgres:// URL (postgres backend only)",
        .default_text = "$PABRIK_DATABASE_CONNINFO",
    },
    .{
        .long = "graceful-timeout-ms",
        .scopes = &.{.service},
        .verbs = &.{ "stop", "restart" },
        .action = .store,
        .kind = .u32_num,
        .fields = &.{"graceful_timeout_ms"},
        .value_name = "MS",
        .help = "How long stop waits for in-flight requests",
        .default_text = "5000",
    },
    .{
        .long = "email",
        .scopes = &.{.create_admin},
        .action = .store,
        .kind = .text,
        .fields = &.{"email"},
        .value_name = "EMAIL",
        .help = "Admin email (required)",
    },
    .{
        .long = "password",
        .scopes = &.{.create_admin},
        .action = .store,
        .kind = .text,
        .fields = &.{"password"},
        .value_name = "PASSWORD",
        .help = "Admin password (required, min 8 chars)",
    },
    .{
        .long = "name",
        .scopes = &.{.create_admin},
        .action = .store,
        .kind = .text,
        .fields = &.{"name"},
        .value_name = "NAME",
        .help = "Display name",
    },
    .{
        .long = "force",
        .scopes = &.{.create_admin},
        .fields = &.{"force"},
        .help = "Create another admin even if one is active",
    },
    .{
        .long = "session",
        .scopes = &.{.headless},
        .verbs = &.{"run"},
        .action = .store,
        .kind = .text,
        .fields = &.{"session_id"},
        .value_name = "ID",
        .help = "Resume an existing session (default: mint a new one)",
    },
    .{
        .long = "cwd",
        .scopes = &.{.headless},
        .verbs = &.{"run"},
        .action = .store,
        .kind = .text,
        .fields = &.{"cwd"},
        .value_name = "DIR",
        .help = "Working directory for the turn (default: process cwd)",
    },
    .{
        .long = "profile",
        .scopes = &.{.headless},
        .verbs = &.{"run"},
        .action = .store,
        .kind = .text,
        .fields = &.{"profile"},
        .value_name = "NAME",
        .help = "LLM agent from config.json's profiles_models",
    },
    .{
        .long = "tools",
        .scopes = &.{.headless},
        .verbs = &.{"run"},
        .action = .store,
        .kind = .text,
        .fields = &.{"allowed_tools"},
        .value_name = "A,B,C",
        .help = "Comma-separated tool allowlist (default: config default)",
    },
    .{
        .long = "timeout-ms",
        .scopes = &.{.headless},
        .verbs = &.{"run"},
        .action = .store,
        .kind = .u64_num,
        .fields = &.{"timeout_ms"},
        .value_name = "N",
        .help = "Wall-clock budget for the turn (default: no budget)",
    },
    .{
        .long = "quiet",
        .scopes = &.{.headless},
        .verbs = &.{"run"},
        .fields = &.{"quiet"},
        .help = "Print the assistant text only, not the JSON envelope",
    },
    .{
        .long = "json",
        .scopes = &.{.headless},
        .verbs = &.{"run"},
        .action = .set_false,
        .fields = &.{"quiet"},
        .help = "Force the JSON envelope even with --quiet",
    },
    .{
        .long = "limit",
        .scopes = &.{.headless},
        .verbs = &.{ "sessions", "messages" },
        .action = .store,
        .kind = .u32_num,
        .fields = &.{"limit"},
        .value_name = "N",
        .help = "Max rows to list",
    },
    .{
        .long = "log-file",
        .scopes = &.{.headless},
        .action = .store,
        .kind = .text,
        .fields = &.{"log_file"},
        .value_name = "PATH",
        .help = "Where diagnostics go (default: $TMPDIR/agentic_coding.log)",
    },
};

comptime {
    @setEvalBranchQuota(20_000);
    for (flags, 0..) |f, i| {
        if (f.long.len == 0) @compileError("a flag row has an empty name");
        if (f.help.len == 0) @compileError("--" ++ f.long ++ " has no help text");
        if (f.scopes.len == 0) @compileError("--" ++ f.long ++ " belongs to no scope");
        if (f.action == .store and f.fields.len == 0) @compileError("--" ++ f.long ++ " stores nothing");
        if (f.action != .store and f.fields.len != 1) @compileError("--" ++ f.long ++ " needs exactly one target");
        if (f.kind == .mode and f.modes.len == 0) @compileError("--" ++ f.long ++ " has no modes");
        for (flags[i + 1 ..]) |g| {
            if (std.mem.eql(u8, f.long, g.long)) @compileError("duplicate flag --" ++ f.long);
            for (g.aliases) |alias| {
                if (std.mem.eql(u8, f.long, alias)) @compileError("--" ++ f.long ++ " collides with alias -" ++ alias);
            }
            for (f.aliases) |alias| {
                if (std.mem.eql(u8, g.long, alias)) @compileError("alias -" ++ alias ++ " collides with --" ++ g.long);
                for (g.aliases) |other| {
                    if (std.mem.eql(u8, alias, other)) @compileError("alias -" ++ alias ++ " is declared twice");
                }
            }
        }
    }
}

/// True when `f` is one of `scope`'s flags. A row may serve several scopes.
pub fn hasScope(comptime f: Flag, comptime scope: Scope) bool {
    for (f.scopes) |s| {
        if (s == scope) return true;
    }
    return false;
}

/// True when `f` is accepted by `verb`. An empty verb means "any subcommand",
/// and a row without verbs is accepted everywhere in its scope.
pub fn hasVerb(comptime f: Flag, comptime verb: []const u8) bool {
    if (verb.len == 0 or f.verbs.len == 0) return true;
    for (f.verbs) |v| {
        if (std.mem.eql(u8, v, verb)) return true;
    }
    return false;
}

/// One `--help` line for a row: name, aliases, value, then the help text and
/// the default. Columns are padded so the descriptions line up.
pub fn usageLine(comptime f: Flag) []const u8 {
    comptime var left: []const u8 = "  ";
    inline for (f.aliases, 0..) |alias, i| {
        left = left ++ (if (i > 0) ", " else "") ++ "-" ++ alias;
    }
    if (f.aliases.len > 0) left = left ++ ", ";
    left = left ++ "--" ++ f.long;
    if (f.syntax == .equals) {
        left = left ++ "=" ++ (if (f.value_name.len > 0) f.value_name else "N");
    } else if (f.value_name.len > 0) {
        left = left ++ " " ++ f.value_name;
    }
    comptime var pad: []const u8 = "";
    if (left.len < 34) pad = " " ** (34 - left.len);
    comptime var right: []const u8 = f.help;
    if (f.default_text.len > 0) right = right ++ " (default: " ++ f.default_text ++ ")";
    return left ++ pad ++ right ++ "\n";
}

/// Whether a row belongs in the `--help` block of `verb`. An empty verb means
/// "the whole scope" (the master list); a verb-less row is a global flag and
/// is printed by `globalUsageBlock` instead of once per verb.
fn usageApplies(comptime f: Flag, comptime verb: []const u8) bool {
    if (verb.len == 0) return true;
    if (f.verbs.len == 0) return false;
    return hasVerb(f, verb);
}

/// The `--help` lines for every flag of `scope` that `verb` accepts, as one
/// string. Callers print it; nothing here formats at runtime.
pub fn usageBlock(comptime scope: Scope, comptime verb: []const u8) []const u8 {
    return comptime blk: {
        var out: []const u8 = "";
        for (flags) |f| {
            if (!hasScope(f, scope)) continue;
            if (!usageApplies(f, verb)) continue;
            out = out ++ usageLine(f);
        }
        break :blk out;
    };
}

/// The flags of `scope` that apply to every verb of that scope.
pub fn globalUsageBlock(comptime scope: Scope) []const u8 {
    return comptime blk: {
        var out: []const u8 = "";
        for (flags) |f| {
            if (!hasScope(f, scope) or f.verbs.len != 0) continue;
            out = out ++ usageLine(f);
        }
        break :blk out;
    };
}

/// The word a user types for `long`, dashes included. Compile error when no
/// row declares it, so no caller can depend on a flag that does not exist.
pub fn word(comptime long: []const u8) []const u8 {
    return comptime blk: {
        for (flags) |f| {
            if (std.mem.eql(u8, f.long, long)) break :blk "--" ++ f.long;
        }
        @compileError("no flag named " ++ long);
    };
}

/// The canonical name (dashes, no `--`) of the `db` knob whose target field
/// is `knob_name`. Compile error when no row claims it, so a new knob cannot
/// be added to the SQLite policy without its flag.
pub fn dbFlagName(comptime knob_name: []const u8) []const u8 {
    return comptime blk: {
        for (flags) |f| {
            if (!hasScope(f, .db)) continue;
            if (std.mem.eql(u8, f.fields[0], knob_name)) break :blk f.long;
        }
        @compileError("no --db-* flag targets the knob " ++ knob_name);
    };
}

/// The `db` knob a user-typed name selects, as its target field name. Accepts
/// the dashed and underscored spellings of the same knob.
pub fn dbKnobTag(typed: []const u8) ?[]const u8 {
    const bare = stripDashes(typed);
    if (!std.mem.startsWith(u8, bare, "db-") and !std.mem.startsWith(u8, bare, "db_")) return null;
    inline for (flags) |f| {
        if (hasScope(f, .db) and underscoredEql(bare, f.long)) return f.fields[0];
    }
    return null;
}

/// `--db-cache-size-kb` and `--db_cache_size_kb` name the same knob.
pub fn underscoredEql(bare: []const u8, comptime long: []const u8) bool {
    if (std.mem.eql(u8, bare, long)) return true;
    if (bare.len != long.len) return false;
    for (bare, long) |b, l| {
        if (b != (if (l == '-') '_' else l)) return false;
    }
    return true;
}

pub fn stripDashes(typed: []const u8) []const u8 {
    if (std.mem.startsWith(u8, typed, "--")) return typed[2..];
    if (typed.len > 1 and typed[0] == '-') return typed[1..];
    return typed;
}

const testing = std.testing;

test "a scope's help block names every flag that scope parses" {
    @setEvalBranchQuota(100_000);
    inline for ([_]Scope{ .global, .db, .db_target, .service, .create_admin, .headless }) |scope| {
        const block = comptime usageBlock(scope, "");
        inline for (flags) |f| {
            if (comptime hasScope(f, scope)) {
                var dashed_buf: [64]u8 = undefined;
                const dashed = try std.fmt.bufPrint(&dashed_buf, "--{s}", .{f.long});
                if (std.mem.indexOf(u8, block, dashed) == null) {
                    std.debug.print("\n!! {s} is parsed by {s} but missing from its help !!\n", .{ dashed, @tagName(scope) });
                    return error.MissingFromHelp;
                }
            }
        }
    }
}

test "usageBlock filters by verb, so stop does not advertise start's flags" {
    const stop = comptime usageBlock(.service, "stop");
    try testing.expect(std.mem.indexOf(u8, stop, "--graceful-timeout-ms") != null);
    try testing.expect(std.mem.indexOf(u8, stop, "--static-dir") == null);

    const start = comptime usageBlock(.service, "start");
    try testing.expect(std.mem.indexOf(u8, start, "--static-dir") != null);
    try testing.expect(std.mem.indexOf(u8, start, "--graceful-timeout-ms") == null);
}

test "an underscored db spelling names the same knob as the dashed one" {
    try testing.expectEqualStrings(dbFlagName("cache_size_kb"), "db-cache-size-kb");
    try testing.expectEqualStrings(dbKnobTag("--db-cache-size-kb").?, "cache_size_kb");
    try testing.expectEqualStrings(dbKnobTag("--db_cache_size_kb").?, "cache_size_kb");
    try testing.expect(dbKnobTag("--db-nope") == null);
    try testing.expect(dbKnobTag("--port") == null);
}
