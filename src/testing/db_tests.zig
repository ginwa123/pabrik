const std = @import("std");
const pabrikcore = @import("pabrikcore");

const db_target = pabrikcore.boot_db_target;
const test_db = pabrikcore.test_db;
const database = pabrikcore.database;
const Backend = db_target.Backend;
const Origin = db_target.Origin;
const Request = db_target.Request;
const Setting = db_target.Setting;
const Source = db_target.Source;

const testing = std.testing;

fn testDefaults() db_target.Defaults {
    return .{ .sqlite_path = "/home/tester/.config/pabrik/agent.db" };
}

fn flagBackend(backend: Backend) Setting {
    return .{ .value = backend.text(), .source = .flag };
}

test "the compiled backend is the one the build selected" {
    if (database.backend_is_postgres) {
        try testing.expectEqual(Backend.postgres, Backend.compiled());
    } else {
        try testing.expectEqual(Backend.sqlite, Backend.compiled());
    }
}

test "a boot with no database flag opens the backend the build compiled in" {
    var target = try db_target.resolve(testing.allocator, .{}, testDefaults());
    defer target.deinit();

    try testing.expectEqual(Backend.compiled(), target.backend);
    try testing.expectEqual(Origin.compile_default, target.origin);
    if (Backend.compiled() == .sqlite) {
        try testing.expectEqualStrings(testDefaults().sqlite_path, target.sqlite_path);
    } else {
        try testing.expectEqualStrings("", target.conninfo);
    }
}

test "the backend flag naming the compiled backend is accepted" {
    const request: Request = .{ .backend = flagBackend(Backend.compiled()) };
    var target = try db_target.resolve(testing.allocator, request, testDefaults());
    defer target.deinit();

    try testing.expectEqual(Backend.compiled(), target.backend);
    try testing.expectEqual(Origin.flag, target.origin);
}

test "the backend the build did not compile is refused" {
    const other: Backend = if (Backend.compiled() == .sqlite) .postgres else .sqlite;
    const request: Request = .{ .backend = flagBackend(other) };

    try testing.expectError(error.BackendNotCompiled, db_target.resolve(testing.allocator, request, testDefaults()));
}

test "a backend name that is not a backend is refused" {
    for ([_][]const u8{ "mysql", "SQLite", "", "postgresql" }) |name| {
        const request: Request = .{ .backend = .{ .value = name, .source = .flag } };
        try testing.expectError(error.UnknownBackend, db_target.resolve(testing.allocator, request, testDefaults()));
    }
}

test "the option belonging to the backend that was not selected is refused" {
    const request: Request = if (Backend.compiled() == .sqlite)
        .{ .backend = flagBackend(.sqlite), .conninfo = .{ .value = "host=127.0.0.1", .source = .flag } }
    else
        .{ .backend = flagBackend(.postgres), .sqlite_path = .{ .value = "/tmp/agent.db", .source = .flag } };

    try testing.expectError(error.ForeignOption, db_target.resolve(testing.allocator, request, testDefaults()));
}

test "the same option from the environment is ignored instead of refused" {
    const compiled = Backend.compiled();
    const request: Request = if (compiled == .sqlite)
        .{ .conninfo = .{ .value = "host=127.0.0.1", .source = .environment } }
    else
        .{ .sqlite_path = .{ .value = "/tmp/agent.db", .source = .environment } };
    var target = try db_target.resolve(testing.allocator, request, testDefaults());
    defer target.deinit();

    try testing.expectEqual(compiled, target.backend);
    if (compiled == .sqlite) {
        try testing.expectEqualStrings(testDefaults().sqlite_path, target.sqlite_path);
        try testing.expectEqualStrings("", target.conninfo);
    } else {
        try testing.expectEqualStrings("", target.sqlite_path);
    }
}

test "the connection the operator asked for is the connection OpenConfig returns" {
    const compiled = Backend.compiled();
    const request: Request = if (compiled == .sqlite)
        .{ .backend = flagBackend(.sqlite), .sqlite_path = .{ .value = "/tmp/asked.db", .source = .flag } }
    else
        .{ .backend = flagBackend(.postgres), .conninfo = .{ .value = "host=/tmp dbname=pabrik", .source = .flag } };
    var target = try db_target.resolve(testing.allocator, request, testDefaults());
    defer target.deinit();

    switch (target.openConfig()) {
        .sqlite_path => |path| {
            try testing.expectEqual(Backend.sqlite, compiled);
            try testing.expectEqualStrings("/tmp/asked.db", path);
        },
        .postgres_conninfo => |conninfo| {
            try testing.expectEqual(Backend.postgres, compiled);
            try testing.expectEqualStrings("host=/tmp dbname=pabrik", conninfo);
        },
    }
}

test "a target carries only the connection its backend uses" {
    var target = try db_target.resolve(testing.allocator, .{}, testDefaults());
    defer target.deinit();

    if (Backend.compiled() == .postgres) {
        try testing.expectEqualStrings("", target.sqlite_path);
    } else {
        try testing.expectEqualStrings("", target.conninfo);
    }
}

test "an environment choice is named as the source of the target" {
    const request: Request = .{ .backend = .{ .value = Backend.compiled().text(), .source = .environment } };
    var target = try db_target.resolve(testing.allocator, request, testDefaults());
    defer target.deinit();

    try testing.expectEqual(Origin.environment, target.origin);
}

test "a flag wins over the environment for the same field" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put(db_target.env_backend, if (Backend.compiled() == .sqlite) "postgres" else "sqlite");

    var request: Request = .{ .backend = flagBackend(Backend.compiled()) };
    db_target.applyEnv(&request, &env);
    var target = try db_target.resolve(testing.allocator, request, testDefaults());
    defer target.deinit();

    try testing.expectEqual(Origin.flag, target.origin);
    try testing.expectEqual(Backend.compiled(), target.backend);
}

test "the environment fills the fields no flag named" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put(db_target.env_backend, Backend.compiled().text());
    try env.put(db_target.env_sqlite_path, "/tmp/from-env.db");
    try env.put(db_target.env_conninfo, "host=127.0.0.1 dbname=from_env");

    var request: Request = .{};
    db_target.applyEnv(&request, &env);
    var target = try db_target.resolve(testing.allocator, request, testDefaults());
    defer target.deinit();

    try testing.expectEqual(Origin.environment, target.origin);
    if (Backend.compiled() == .sqlite) {
        try testing.expectEqualStrings("/tmp/from-env.db", target.sqlite_path);
    } else {
        try testing.expectEqualStrings("host=127.0.0.1 dbname=from_env", target.conninfo);
    }
}

test "parseArgs takes the database words out of argv and leaves the rest in order" {
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(testing.allocator);
    var request: Request = .{};
    const argv = [_][]const u8{
        "--port",
        "8080",
        "--database=postgres",
        "--auth",
        "--database-conninfo=host=127.0.0.1 dbname=pabrik",
        "stray",
        "--database_path=/tmp/x.db",
    };

    try db_target.parseArgs(testing.allocator, &argv, &request, &rest);

    try testing.expectEqualStrings("postgres", request.backend.?.value);
    try testing.expectEqualStrings("host=127.0.0.1 dbname=pabrik", request.conninfo.?.value);
    try testing.expectEqualStrings("/tmp/x.db", request.sqlite_path.?.value);
    try testing.expectEqual(@as(usize, 4), rest.items.len);
    try testing.expectEqualStrings("--port", rest.items[0]);
    try testing.expectEqualStrings("8080", rest.items[1]);
    try testing.expectEqualStrings("--auth", rest.items[2]);
    try testing.expectEqualStrings("stray", rest.items[3]);
}

test "a database word with no value is refused instead of ignored" {
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(testing.allocator);
    var request: Request = .{};

    try testing.expectError(error.MissingValue, db_target.parseArgs(testing.allocator, &.{"--database"}, &request, &rest));
    try testing.expectError(error.MissingValue, db_target.parseArgs(testing.allocator, &.{"--database="}, &request, &rest));
    try testing.expectError(error.MissingValue, db_target.parseArgs(testing.allocator, &.{"--database-conninfo="}, &request, &rest));
}

test "the last database word wins" {
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(testing.allocator);
    var request: Request = .{};

    try db_target.parseArgs(testing.allocator, &.{ "--database=sqlite", "--database=postgres" }, &request, &rest);
    try testing.expectEqualStrings("postgres", request.backend.?.value);
}

test "the boot line names the backend, the source and the path it will open" {
    var target = try db_target.resolve(testing.allocator, .{}, testDefaults());
    defer target.deinit();

    var buf: [256]u8 = undefined;
    const line = try target.describe(&buf);
    try testing.expect(std.mem.indexOf(u8, line, "backend=") != null);
    try testing.expect(std.mem.indexOf(u8, line, "source=compile_default") != null);
    if (Backend.compiled() == .sqlite) {
        try testing.expect(std.mem.indexOf(u8, line, testDefaults().sqlite_path) != null);
    }
}

test "a conninfo password never reaches the boot line" {
    const cases = [_]struct { conninfo: []const u8, secret: []const u8 }{
        .{ .conninfo = "host=127.0.0.1 user=pabrik password=hunter2 dbname=pabrik", .secret = "hunter2" },
        .{ .conninfo = "postgresql://pabrik:hunter2@127.0.0.1:5432/pabrik", .secret = "hunter2" },
        .{ .conninfo = "postgres://pabrik:hunter2@127.0.0.1/pabrik?sslmode=disable", .secret = "hunter2" },
        .{ .conninfo = "host=/tmp dbname=pabrik passfile=/home/tester/.pgpass", .secret = "/home/tester/.pgpass" },
    };
    for (cases) |case| {
        var buf: [512]u8 = undefined;
        const line = try db_target.redactConninfo(case.conninfo, &buf);
        if (std.mem.indexOf(u8, line, case.secret) != null) {
            std.debug.print("\n!! {s} leaks {s} !!\n", .{ line, case.secret });
            return error.SecretLeaked;
        }
        try testing.expect(std.mem.indexOf(u8, line, "***") != null);
        try testing.expect(std.mem.indexOf(u8, line, "pabrik") != null);
    }
}

test "a conninfo without a secret is printed unchanged" {
    var buf: [128]u8 = undefined;
    const line = try db_target.redactConninfo("host=127.0.0.1 dbname=pabrik", &buf);
    try testing.expectEqualStrings("host=127.0.0.1 dbname=pabrik", line);
}

test "a temp database is writable and reads back what it stored" {
    var temp = try test_db.create(testing.allocator);
    defer temp.deinit();
    const db = test_db.handle(&temp);

    try db.exec(testing.allocator, "CREATE TABLE probe (id BIGINT PRIMARY KEY, v TEXT NOT NULL)", &.{});
    try db.exec(testing.allocator, "INSERT INTO probe (id, v) VALUES (?, ?)", &.{ "1", "written" });

    var row = try db.queryRow(testing.allocator, "SELECT v FROM probe WHERE id = ?", &.{"1"});
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("written", row.values[0]);
}

test "a rolled back write leaves no row behind" {
    var temp = try test_db.create(testing.allocator);
    defer temp.deinit();
    const db = test_db.handle(&temp);

    try db.exec(testing.allocator, "CREATE TABLE probe (id BIGINT PRIMARY KEY, v TEXT NOT NULL)", &.{});
    {
        var tx = try db.begin();
        errdefer tx.rollback() catch {};
        try tx.exec(testing.allocator, "INSERT INTO probe (id, v) VALUES (?, ?)", &.{ "1", "rolled back" });
        try tx.rollback();
    }

    var row = try db.queryRow(testing.allocator, "SELECT COUNT(*) FROM probe", &.{});
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "a committed write survives the transaction that made it" {
    var temp = try test_db.create(testing.allocator);
    defer temp.deinit();
    const db = test_db.handle(&temp);

    try db.exec(testing.allocator, "CREATE TABLE probe (id BIGINT PRIMARY KEY, v TEXT NOT NULL)", &.{});
    {
        var tx = try db.begin();
        errdefer tx.rollback() catch {};
        try tx.exec(testing.allocator, "INSERT INTO probe (id, v) VALUES (?, ?)", &.{ "1", "committed" });
        try tx.commit();
    }

    var row = try db.queryRow(testing.allocator, "SELECT v FROM probe WHERE id = ?", &.{"1"});
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("committed", row.values[0]);
}

test "two temp databases do not see each other's rows" {
    var first = try test_db.create(testing.allocator);
    defer first.deinit();
    var second = try test_db.create(testing.allocator);
    defer second.deinit();

    try test_db.handle(&first).exec(testing.allocator, "CREATE TABLE probe (v TEXT NOT NULL)", &.{});
    try test_db.handle(&first).exec(testing.allocator, "INSERT INTO probe (v) VALUES (?)", &.{"only here"});
    try test_db.handle(&second).exec(testing.allocator, "CREATE TABLE probe (v TEXT NOT NULL)", &.{});

    var row = try test_db.handle(&second).queryRow(testing.allocator, "SELECT COUNT(*) FROM probe", &.{});
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "closing a temp database twice is safe" {
    var temp = try test_db.create(testing.allocator);
    temp.deinit();
    temp.deinit();

    try testing.expect(!temp.live);
}

fn migrate(db: *database.Db) !void {
    var manager = pabrikcore.migrations_mod.migration.MigrationManager.init(testing.allocator, db);
    defer manager.deinit();
    try pabrikcore.migrations_mod.migration.registerAllMigrations(&manager);
    try manager.runMigrations();
}

fn lastMigrationVersion() u32 {
    var last: u32 = 0;
    for (pabrikcore.migrations_mod.migration.allMigrations) |m| {
        if (m.version > last) last = m.version;
    }
    return last;
}

test "every migration applies to the database the build compiled in" {
    var temp = try test_db.create(testing.allocator);
    defer temp.deinit();
    const db = test_db.handle(&temp);

    try migrate(db);

    var row = try db.queryRow(testing.allocator, "SELECT MAX(version) FROM schema_migrations", &.{});
    defer row.deinit(testing.allocator);
    const reached = try std.fmt.parseInt(u32, row.values[0], 10);
    try testing.expectEqual(lastMigrationVersion(), reached);
}

test "a table the schema declares is a table the migration created" {
    var temp = try test_db.create(testing.allocator);
    defer temp.deinit();
    const db = test_db.handle(&temp);

    try migrate(db);

    try testing.expect(try pabrikcore.dialect.tableExists(.{ .db = db }, testing.allocator, "llm_history"));
    try testing.expect(try pabrikcore.dialect.tableExists(.{ .db = db }, testing.allocator, "agent_memories"));
    try testing.expect(try pabrikcore.dialect.columnExists(.{ .db = db }, testing.allocator, "llm_history", "response_content"));
    try testing.expect(!try pabrikcore.dialect.columnExists(.{ .db = db }, testing.allocator, "llm_history", "no_such_column"));
}

test "a saved memory comes back from full text search with the term bracketed" {
    const alloc = testing.allocator;
    var temp = try test_db.create(alloc);
    defer temp.deinit();
    const db = test_db.handle(&temp);
    try migrate(db);

    const saved = try pabrikcore.agent_memories.saveMemory(alloc, db, .{
        .content = "the zephyrword turbine spins at dusk",
        .tags = &.{"hardware"},
        .workspace_id = "ws_search",
    });
    defer pabrikcore.agent_memories.freeMemoryRow(alloc, saved);

    const hits = try pabrikcore.agent_memories.loadMemoriesByFts(alloc, db, .{
        .query = "zephyrword",
        .tags = &.{},
        .limit = 10,
        .offset = 0,
        .workspace_id = "ws_search",
    });
    defer pabrikcore.agent_memories.freeMemoryHits(alloc, hits);

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings(saved.id, hits[0].id);
    try testing.expect(std.mem.indexOf(u8, hits[0].snippet, "[zephyrword]") != null);
    try testing.expectEqual(@as(u32, 1), hits[0].total_count);
}

test "full text search does not reach another workspace's memories" {
    const alloc = testing.allocator;
    var temp = try test_db.create(alloc);
    defer temp.deinit();
    const db = test_db.handle(&temp);
    try migrate(db);

    const mine = try pabrikcore.agent_memories.saveMemory(alloc, db, .{
        .content = "quasarterm lives in one workspace",
        .tags = &.{},
        .workspace_id = "ws_a",
    });
    defer pabrikcore.agent_memories.freeMemoryRow(alloc, mine);
    const other = try pabrikcore.agent_memories.saveMemory(alloc, db, .{
        .content = "quasarterm lives in another workspace",
        .tags = &.{},
        .workspace_id = "ws_b",
    });
    defer pabrikcore.agent_memories.freeMemoryRow(alloc, other);

    const hits = try pabrikcore.agent_memories.loadMemoriesByFts(alloc, db, .{
        .query = "quasarterm",
        .tags = &.{},
        .limit = 10,
        .offset = 0,
        .workspace_id = "ws_a",
    });
    defer pabrikcore.agent_memories.freeMemoryHits(alloc, hits);

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings(mine.id, hits[0].id);
}

test "a stored message is found by full text search and the snippet names the term" {
    const alloc = testing.allocator;
    var temp = try test_db.create(alloc);
    defer temp.deinit();
    const db = test_db.handle(&temp);
    try migrate(db);

    try db.exec(alloc,
        \\INSERT INTO llm_history (id, session_id, model, response_content, role, created_iso)
        \\VALUES ('msg_search_1', 'sess_search', 'm', 'a deltaword appears here', 'assistant', '2026-01-02 03:04:05')
    , &.{});

    const hits = try pabrikcore.llm_history.searchMessagesFts(alloc, db, "deltaword", .{});
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("msg_search_1", hits[0].id);
    try testing.expectEqualStrings("sess_search", hits[0].session_id);
    try testing.expect(std.mem.indexOf(u8, hits[0].snippet, "[deltaword]") != null);
    try testing.expectEqual(@as(u32, 1), hits[0].total_count);
}

test "a message the search term is not in is not a hit" {
    const alloc = testing.allocator;
    var temp = try test_db.create(alloc);
    defer temp.deinit();
    const db = test_db.handle(&temp);
    try migrate(db);

    try db.exec(alloc,
        \\INSERT INTO llm_history (id, session_id, model, response_content, role, created_iso)
        \\VALUES ('msg_search_2', 'sess_search', 'm', 'nothing in common here', 'assistant', '2026-01-02 03:04:05')
    , &.{});

    const hits = try pabrikcore.llm_history.searchMessagesFts(alloc, db, "deltaword", .{});
    defer alloc.free(hits);

    try testing.expectEqual(@as(usize, 0), hits.len);
}

test "a failed statement leaves its reason readable through the reporter" {
    if (!database.backend_is_postgres) return error.SkipZigTest;

    const alloc = testing.allocator;
    var temp = try test_db.create(alloc);
    defer temp.deinit();
    const db = test_db.handle(&temp);

    try testing.expectError(error.ExecuteFailed, db.exec(alloc, "INSERT INTO pabrik_no_such_table (x) VALUES (?)", &.{"1"}));

    // The pabrik-side seam the boot path prints: the backend keeps the text, and
    // `lastErrorMessage` reads it without the caller knowing which backend is compiled in.
    const detail = db_target.lastErrorMessage(db) orelse return error.ExpectedLastErrorMessage;
    try testing.expect(std.mem.indexOf(u8, detail, "pabrik_no_such_table") != null);
}
