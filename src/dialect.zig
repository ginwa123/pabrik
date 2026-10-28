//! The SQL that differs between the two backends `-Ddb_used` can compile in.
//! Everything here is comptime: one build is one backend, so a branch costs nothing at runtime.

const std = @import("std");
const databases = @import("databases");

pub const database = databases.database;
pub const DbOrTx = database.DbOrTx;

/// True when this build links postgres (`-Ddb_used=sqlite,postgres`).
pub const is_postgres: bool = database.backend_is_postgres;

/// `EXTRACT` on postgres, `strftime` on sqlite: both yield unix epoch seconds.
pub const now_epoch: []const u8 = if (is_postgres)
    "CAST(EXTRACT(EPOCH FROM now()) AS BIGINT)"
else
    "CAST(strftime('%s','now') AS INTEGER)";

/// A `YYYY-MM-DD HH:MM:SS` string in UTC — the format sqlite's `datetime()`
/// returns, so stored text and `since`/`until` comparisons stay identical.
pub const now_text: []const u8 = if (is_postgres)
    "to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS')"
else
    "datetime('now')";

/// A value for a column of type `TIMESTAMP`. Both engines spell it the same,
/// and postgres compares it against its own `now()` rather than a parsed string.
pub const now_stamp: []const u8 = "CURRENT_TIMESTAMP";

/// "Now" as a UTC `TIMESTAMP`: sqlite's `datetime('now')` is UTC text, and
/// postgres gets its `now()` made timezone-free so the value does not depend on
/// the connection's `TimeZone`. Usable both as a value (`SET ad_at = …`) and on
/// the right of a comparison against a `TIMESTAMP` column (`expires_at > …`),
/// including on a database where migration 121's `datetime()` shim is absent.
pub const now_stamp_utc: []const u8 = if (is_postgres)
    "(now() AT TIME ZONE 'UTC')"
else
    "datetime('now')";

/// Column type for an epoch-seconds column: postgres `INTEGER` is 32-bit and
/// would overflow in 2038, so it gets `BIGINT`.
pub const epoch_type: []const u8 = if (is_postgres) "BIGINT" else "INTEGER";

/// A column definition suffix for an epoch-seconds column that defaults to now:
/// `BIGINT DEFAULT (CAST(EXTRACT(EPOCH FROM now()) AS BIGINT))` and the sqlite
/// spelling of the same thing.
pub const epoch_default: []const u8 = epoch_type ++ " DEFAULT (" ++ now_epoch ++ ")";

/// `created_iso`-style text formatting of `expr`, a SQL expression that holds
/// unix epoch seconds as text. `expr` must be a SQL expression, not a bind.
pub fn epochToText(allocator: std.mem.Allocator, expr: []const u8) ![]u8 {
    if (is_postgres) {
        return std.fmt.allocPrint(
            allocator,
            "to_char(to_timestamp(CAST({s} AS BIGINT)) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS')",
            .{expr},
        );
    }
    return std.fmt.allocPrint(allocator, "datetime(CAST({s} AS INTEGER), 'unixepoch')", .{expr});
}

/// A `TIMESTAMP` column rendered as `YYYY-MM-DD HH24:MI:SS` text, so a read
/// that returns it to Zig gets the same string from either engine.
pub fn timestampText(buf: []u8, column: []const u8) error{NoSpaceLeft}![]const u8 {
    if (is_postgres) return std.fmt.bufPrint(buf, "to_char({s}, 'YYYY-MM-DD HH24:MI:SS')", .{column});
    return std.fmt.bufPrint(buf, "{s}", .{column});
}

/// Columns a table's metadata can be read from: sqlite's `sqlite_master` and
/// postgres' catalogue expose `type`/`name`, so one predicate reads both.
pub const tables_source: []const u8 = if (is_postgres)
    "(SELECT 'table'::text AS type, table_name::text AS name FROM information_schema.tables WHERE table_schema = current_schema())"
else
    "sqlite_master";

/// A single-row upsert's verb: sqlite replaces the conflicting row, postgres
/// needs `ON CONFLICT (…) DO UPDATE SET …` appended instead.
pub const upsert_verb: []const u8 = if (is_postgres) "INSERT" else "INSERT OR REPLACE";

/// An `INSERT` that must land once and silently skip a duplicate: sqlite
/// spells it `INSERT OR IGNORE`, postgres puts `conflict_ignore` at the end.
/// Both halves are needed — sqlite cannot parse `ON CONFLICT` after a SELECT.
pub const insert_ignore_prefix: []const u8 = if (is_postgres) "INSERT" else "INSERT OR IGNORE";
pub const conflict_ignore: []const u8 = if (is_postgres) " ON CONFLICT DO NOTHING" else "";

/// The `BEGIN` a two-statement write opens with: sqlite's `IMMEDIATE` takes
/// the write lock up front, postgres has no equivalent and rejects the word.
pub const begin_write: []const u8 = if (is_postgres) "BEGIN" else "BEGIN IMMEDIATE";

/// Postgres enforces the foreign keys the schema declares and sqlite (with
/// its pragma off) does not, so a drop that leaves dependants behind needs
/// `CASCADE` there and would be a syntax error on sqlite.
pub const drop_cascade: []const u8 = if (is_postgres) " CASCADE" else "";

/// Postgres has real foreign keys and ignores the sqlite pragma; a sqlite
/// build has to switch them on per connection.
pub const enable_foreign_keys: []const u8 = if (is_postgres) "" else "PRAGMA foreign_keys = ON";

/// Whether this backend can spell `MATCH`/`snippet()`/`rank` — the FTS5
/// surface. Postgres reaches full text search through `tsvector` instead.
pub const has_fts5: bool = !is_postgres;

/// The `to_tsvector` postgres matches and ranks `expr` with, rewritten to the
/// token boundaries FTS5 uses — FTS5 splits `SPEC.md`, postgres' `simple` does not.
pub fn tsVectorText(comptime expr: []const u8) []const u8 {
    return "to_tsvector('simple'::regconfig, regexp_replace(" ++ expr ++ ", '[^[:alnum:]_]+', ' ', 'g'))";
}

/// Index rows: `name`, plus the `tbl_name`/`type` a `sqlite_master` predicate
/// filters on. Postgres keeps the same three facts in `pg_indexes`, so a test
/// that asks "does index X exist on table Y" reads the same either way.
pub const indexes_source: []const u8 = if (is_postgres)
    "(SELECT 'index'::text AS type, indexname::text AS name, tablename::text AS tbl_name, " ++
        "indexdef::text AS sql FROM pg_indexes WHERE schemaname = current_schema())"
else
    "sqlite_master";

/// sqlite's `pragma_table_info` question — `name`, `cid`, `type`, `notnull`,
/// `dflt_value`, `pk`, `hidden` — answered from `information_schema`, whose
/// spellings differ on every one.
pub fn tableColumns(comptime table: []const u8) []const u8 {
    if (is_postgres) return
    "(SELECT c.column_name::text AS name, c.ordinal_position AS cid, " ++
        "upper(CASE WHEN c.data_type IN ('character varying', 'character', 'text') THEN 'text' " ++
        "WHEN c.data_type LIKE 'timestamp%' THEN 'timestamp' ELSE c.data_type END) AS type, " ++
        "CASE WHEN c.is_nullable = 'NO' THEN 1 ELSE 0 END AS \"notnull\", " ++
        "CASE WHEN COALESCE(c.column_default, '') IN ('now()', 'CURRENT_TIMESTAMP') THEN 'CURRENT_TIMESTAMP' " ++
        "ELSE regexp_replace(COALESCE(c.column_default, ''), '::[a-zA-Z_ ]+$', '') END AS dflt_value, " ++
        "COALESCE((SELECT kcu.ordinal_position FROM information_schema.table_constraints tc " ++
        "JOIN information_schema.key_column_usage kcu ON kcu.constraint_name = tc.constraint_name " ++
        "AND kcu.table_schema = tc.table_schema " ++
        "WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = current_schema() " ++
        "AND tc.table_name = '" ++ table ++ "' AND kcu.column_name = c.column_name), 0) AS pk, " ++
        "0 AS hidden " ++
        "FROM information_schema.columns c " ++
        "WHERE c.table_schema = current_schema() AND c.table_name = '" ++ table ++ "')";
    return "pragma_table_info('" ++ table ++ "')";
}

/// `tableColumns` plus `hidden` — `pragma_table_xinfo`'s extra column, which
/// postgres does not distinguish (a column is either stored or it is not).
pub fn tableColumnsWithHidden(comptime table: []const u8) []const u8 {
    if (is_postgres) return tableColumns(table);
    return "pragma_table_xinfo('" ++ table ++ "')";
}

/// Columns of the table NAMED BY A BIND, for the callers that only learn the
/// table at run time: same `name`/`cid`/`type` shape as `tableColumns`, keyed
/// by one `?`.
pub const table_columns_of_bound_table: []const u8 = if (is_postgres)
    "(SELECT column_name::text AS name, ordinal_position AS cid, " ++
        "upper(CASE WHEN data_type IN ('character varying', 'character', 'text') THEN 'text' " ++
        "WHEN data_type LIKE 'timestamp%' THEN 'timestamp' ELSE data_type END) AS type " ++
        "FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = ?)"
else
    "pragma_table_info(?)";

/// sqlite runs with `PRAGMA foreign_keys` off, so an FK clause in its DDL is
/// inert documentation. Postgres enforces it — which changes which inserts and
/// deletes are legal — so it declares a no-op check in the same slot.
pub fn foreignKey(comptime clause: []const u8) []const u8 {
    return if (is_postgres) "CHECK (1 = 1)" else clause;
}

/// Postgres spellings of sqlite's two time functions: ~260 statements say
/// `datetime('now')` or `strftime('%s', x)` and mean "now"/"epoch", not a
/// dialect choice. Empty on sqlite, which has them already.
pub const sqlite_time_functions = if (is_postgres) [_][]const u8{
    \\CREATE OR REPLACE FUNCTION datetime(ts text) RETURNS timestamp
    \\LANGUAGE sql STABLE AS $fn$
    \\  SELECT CASE
    \\    WHEN lower(btrim(ts)) IN ('now', 'current_timestamp')
    \\      THEN (now() AT TIME ZONE 'UTC')
    \\    ELSE ts::timestamp
    \\  END
    \\$fn$
    ,
    \\CREATE OR REPLACE FUNCTION datetime(ts text, modifier text) RETURNS timestamp
    \\LANGUAGE sql STABLE AS $fn$
    \\  SELECT CASE
    \\    WHEN lower(btrim(modifier)) = 'unixepoch'
    \\      THEN (to_timestamp(ts::double precision) AT TIME ZONE 'UTC')
    \\    WHEN lower(btrim(ts)) IN ('now', 'current_timestamp')
    \\      THEN ((now() + modifier::interval) AT TIME ZONE 'UTC')
    \\    ELSE ts::timestamp
    \\  END
    \\$fn$
    ,
    \\CREATE OR REPLACE FUNCTION datetime(ts numeric, modifier text) RETURNS timestamp
    \\LANGUAGE sql STABLE AS $fn$
    \\  SELECT CASE
    \\    WHEN lower(btrim(modifier)) = 'unixepoch'
    \\      THEN (to_timestamp(ts::double precision) AT TIME ZONE 'UTC')
    \\    ELSE (to_timestamp(ts::double precision) AT TIME ZONE 'UTC')
    \\  END
    \\$fn$
    ,
    \\CREATE OR REPLACE FUNCTION strftime(fmt text, ts text, modifier text) RETURNS text
    \\LANGUAGE sql STABLE AS $fn$
    \\  SELECT CASE
    \\    WHEN lower(btrim(modifier)) = 'unixepoch'
    \\      THEN to_char(to_timestamp(ts::double precision) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS')
    \\    ELSE ts
    \\  END
    \\$fn$
    ,
    \\CREATE OR REPLACE FUNCTION strftime(fmt text, ts numeric, modifier text) RETURNS text
    \\LANGUAGE sql STABLE AS $fn$
    \\  SELECT to_char(to_timestamp(ts::double precision) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS')
    \\$fn$
    ,
    \\CREATE OR REPLACE FUNCTION strftime(fmt text, ts text) RETURNS bigint
    \\LANGUAGE sql STABLE AS $fn$
    \\  SELECT CASE
    \\    WHEN lower(btrim(ts)) IN ('now', 'current_timestamp')
    \\      THEN (extract(epoch FROM now()))::bigint
    \\    ELSE (extract(epoch FROM ts::timestamp))::bigint
    \\  END
    \\$fn$
    ,
    \\CREATE OR REPLACE FUNCTION strftime(fmt text, ts timestamp) RETURNS bigint
    \\LANGUAGE sql STABLE AS $fn$
    \\  SELECT (extract(epoch FROM ts))::bigint
    \\$fn$
    ,
    \\CREATE OR REPLACE FUNCTION strftime(fmt text) RETURNS bigint
    \\LANGUAGE sql STABLE AS $fn$
    \\  SELECT (extract(epoch FROM now()))::bigint
    \\$fn$
    ,
} else [_][]const u8{};

fn count(db: DbOrTx, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) !i64 {
    var row = try db.queryRow(allocator, sql, argv);
    defer row.deinit(allocator);
    if (row.values.len == 0) return 0;
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}

/// True when `table` exists in the current schema.
pub fn tableExists(db: DbOrTx, allocator: std.mem.Allocator, table: []const u8) !bool {
    const sql = "SELECT COUNT(*) FROM " ++ tables_source ++ " WHERE type = 'table' AND name = ?";
    return (try count(db, allocator, sql, &.{table})) > 0;
}

/// How many tables the current schema holds — the "is this a fresh database"
/// probe several migrations open with.
pub fn tableCount(db: DbOrTx, allocator: std.mem.Allocator) !i64 {
    return count(db, allocator, "SELECT COUNT(*) FROM " ++ tables_source ++ " WHERE type = 'table'", &.{});
}

/// How many tables whose name matches a `LIKE` pattern (same syntax on both).
pub fn tableCountLike(db: DbOrTx, allocator: std.mem.Allocator, pattern: []const u8) !i64 {
    return count(db, allocator, "SELECT COUNT(*) FROM " ++ tables_source ++ " WHERE type = 'table' AND name LIKE ?", &.{pattern});
}

/// True when `column` exists on `table`.
pub fn columnExists(db: DbOrTx, allocator: std.mem.Allocator, table: []const u8, column: []const u8) !bool {
    if (is_postgres) {
        const sql = "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = ? AND column_name = ?";
        return (try count(db, allocator, sql, &.{ table, column })) > 0;
    }
    return (try count(db, allocator, "SELECT COUNT(*) FROM pragma_table_info(?) WHERE name = ?", &.{ table, column })) > 0;
}

test "the epoch and timestamp fragments are the ones the compiled backend understands" {
    const testing = std.testing;
    if (is_postgres) {
        try testing.expect(std.mem.indexOf(u8, now_epoch, "EXTRACT") != null);
        try testing.expect(std.mem.indexOf(u8, now_text, "to_char") != null);
        try testing.expectEqualStrings("BIGINT", epoch_type);
        try testing.expect(!has_fts5);
        try testing.expectEqualStrings("", enable_foreign_keys);
        try testing.expectEqualStrings("(now() AT TIME ZONE 'UTC')", now_stamp_utc);
    } else {
        try testing.expect(std.mem.indexOf(u8, now_epoch, "strftime") != null);
        try testing.expectEqualStrings("datetime('now')", now_text);
        try testing.expectEqualStrings("INTEGER", epoch_type);
        try testing.expect(has_fts5);
        try testing.expectEqualStrings("PRAGMA foreign_keys = ON", enable_foreign_keys);
        try testing.expectEqualStrings("datetime('now')", now_stamp_utc);
    }
}
