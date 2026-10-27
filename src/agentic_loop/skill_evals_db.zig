//! Persistence for Skill Evals — Migration 095's usage ledger (and the home
//! for the eval-table repository that follows).

const std = @import("std");
const testing = std.testing;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const logger_mod = pabrikcore.loggermod;
const migration = @import("../migrations/migration.zig");

/// The kinds of ledger row. Stored as text so a `SELECT` is readable without a
/// decoder, and so adding a kind later cannot invalidate existing rows.
pub const SkillEventKind = enum {
    /// The skill appeared in a `search_skills` result. Recorded once per
    /// `(session, skill)` — see `insertEvent`'s `dedupe` flag.
    listed,
    /// `use_skill` read the body. Carries `content_hash` of what was read.
    loaded,
    created,
    edited,
    removed,

    pub fn asString(self: SkillEventKind) []const u8 {
        return switch (self) {
            .listed => "listed",
            .loaded => "loaded",
            .created => "created",
            .edited => "edited",
            .removed => "removed",
        };
    }
};

/// Hex-encode SHA-256(input) into a 64-char lowercase string.
pub fn sha256Hex(input: []const u8, out: *[64]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
}

/// Monotonic counter for ledger row ids. Atomic because the ledger is written
/// from tool dispatch, which can run on more than one thread in one process.
var event_seq = std.atomic.Value(u64).init(0);

fn nextEventSeq() u64 {
    return event_seq.fetchAdd(1, .monotonic);
}

pub const SkillToolEventArgs = struct {
    io: std.Io,
    /// The session that ran the tool — the ledger's primary read key.
    session_id: []const u8,
    /// `tool_call.function.name`.
    tool_name: []const u8,
    /// The wrapped tool result JSON (`{"tool":…,"success":…,"data":…}`).
    tool_result_json: []const u8,
    /// `handle_tool`'s `loop_counter` — the turn this happened on.
    loop_index: u32,
    /// The `llm_history` row id of this tool result, so the ledger can point
    /// back at its own evidence.
    llm_history_id: []const u8,
};

/// The `data` keys an "offered skills" result may carry the matches under.
/// `search_skills` (current) returns ONE `skills` array with `scope` on each
/// row.
const offered_buckets = [_][]const u8{ "skills", "global_skills", "local_skills" };

/// Append one ledger row.
pub fn insertEvent(
    allocator: std.mem.Allocator,
    db: *database.Db,
    args: SkillToolEventArgs,
    skill_name: []const u8,
    kind: SkillEventKind,
    content_hash: []const u8,
    ordinal: u32,
) !void {
    if (args.session_id.len == 0 or skill_name.len == 0) return;

    const source = args.tool_name;
    const loop_index_str = try std.fmt.allocPrint(allocator, "{d}", .{args.loop_index});
    defer allocator.free(loop_index_str);

    if (kind == .listed) {
        // Deterministic id ⇒ the PK does the dedupe and no read is needed.
        const id = try std.fmt.allocPrint(allocator, "sse:listed:{s}:{s}", .{ args.session_id, skill_name });
        defer allocator.free(id);
        try db.exec(allocator,
            \\INSERT OR IGNORE INTO session_skill_events
            \\    (id, session_id, skill_name, event, source, content_hash, loop_index, llm_history_id)
            \\VALUES
            \\    (?, ?, ?, 'listed', COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), ?, COALESCE(NULLIF(?, ''), ''))
        , &.{ id, args.session_id, skill_name, source, content_hash, loop_index_str, args.llm_history_id });
        return;
    }

    // A per-call monotonic counter, not the caller's `ordinal` (which every
    // non-`listed` call site passes as 0).
    const seq = nextEventSeq();
    const id = try std.fmt.allocPrint(allocator, "sse:{d}_{d}_{d}", .{
        std.Io.Timestamp.now(args.io, .real).nanoseconds,
        seq,
        ordinal,
    });
    defer allocator.free(id);

    try db.exec(allocator,
        \\INSERT INTO session_skill_events
        \\    (id, session_id, skill_name, event, source, content_hash, loop_index, llm_history_id)
        \\VALUES
        \\    (?, ?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), ?, COALESCE(NULLIF(?, ''), ''))
    , &.{
        id,
        args.session_id,
        skill_name,
        kind.asString(),
        source,
        content_hash,
        loop_index_str,
        args.llm_history_id,
    });
}

/// Read one string field out of the envelope's `data` object, or null.
fn dataString(data: std.json.Value, key: []const u8) ?[]const u8 {
    if (data != .object) return null;
    const v = data.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        .number_string => |s| s,
        else => null,
    };
}

fn dataArray(data: std.json.Value, key: []const u8) ?std.json.Array {
    if (data != .object) return null;
    const v = data.object.get(key) orelse return null;
    return switch (v) {
        .array => |a| a,
        else => null,
    };
}

const Envelope = struct {
    success: bool = false,
    data: ?std.json.Value = null,
};

/// Entry point for the save site in `handle_tool.zig`: one call per completed
/// skill-tool call, and it decides what (if anything) belongs in the ledger.
fn logWarn(logger: ?*logger_mod.Logger, comptime fmt: []const u8, args: anytype) void {
    if (logger) |l| l.warnFmt(fmt, args);
}

fn logDebug(logger: ?*logger_mod.Logger, comptime fmt: []const u8, args: anytype) void {
    if (logger) |l| l.debugFmt(fmt, args);
}

pub fn recordSkillToolEvents(
    allocator: std.mem.Allocator,
    db: *database.Db,
    logger: ?*logger_mod.Logger,
    args: SkillToolEventArgs,
) void {
    if (args.session_id.len == 0) return;

    const is_skill_tool =
        std.mem.eql(u8, args.tool_name, "use_skill") or
        std.mem.eql(u8, args.tool_name, "search_skills") or
        std.mem.eql(u8, args.tool_name, "add_skill") or
        std.mem.eql(u8, args.tool_name, "edit_skill") or
        std.mem.eql(u8, args.tool_name, "set_skill_metadata") or
        std.mem.eql(u8, args.tool_name, "remove_skill");
    if (!is_skill_tool) return;

    const parsed = std.json.parseFromSlice(Envelope, allocator, args.tool_result_json, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        logDebug(logger, "skill ledger: could not parse {s} result: {s}", .{ args.tool_name, @errorName(err) });
        return;
    };
    defer parsed.deinit();

    // A failed tool call changed nothing, so it records nothing. The ledger is
    // evidence about what the agent was offered and what it read — not a tool
    // call log (that is `llm_history`'s job).
    if (!parsed.value.success) return;
    const data = parsed.value.data orelse return;

    if (std.mem.eql(u8, args.tool_name, "search_skills")) {
        // One row per matched skill, deduped by the PK, so a session that
        // searches skills ten times still records each skill once — at the
        // moment it was FIRST offered.
        var ordinal: u32 = 0;
        for (offered_buckets) |bucket| {
            const arr = dataArray(data, bucket) orelse continue;
            for (arr.items) |entry| {
                const name = dataString(entry, "name") orelse continue;
                insertEvent(allocator, db, args, name, .listed, "", ordinal) catch |err| {
                    logWarn(logger, "skill ledger: failed to record 'listed' for '{s}': {s}", .{ name, @errorName(err) });
                };
                ordinal += 1;
            }
        }
        return;
    }

    const name = dataString(data, "skill_name") orelse dataString(data, "name") orelse return;

    if (std.mem.eql(u8, args.tool_name, "use_skill")) {
        // Only a real read carries a body; a `loaded: false` result (oversized,
        // unreadable) must not look like a successful load.
        const loaded = if (data == .object) blk: {
            const v = data.object.get("loaded") orelse break :blk false;
            break :blk switch (v) {
                .bool => |b| b,
                else => false,
            };
        } else false;
        if (!loaded) return;

        const content = dataString(data, "content") orelse "";
        var hash_buf: [64]u8 = undefined;
        sha256Hex(content, &hash_buf);
        insertEvent(allocator, db, args, name, .loaded, hash_buf[0..], 0) catch |err| {
            logWarn(logger, "skill ledger: failed to record 'loaded' for '{s}': {s}", .{ name, @errorName(err) });
        };
        return;
    }

    const kind: SkillEventKind = if (std.mem.eql(u8, args.tool_name, "add_skill"))
        .created
    else if (std.mem.eql(u8, args.tool_name, "edit_skill") or std.mem.eql(u8, args.tool_name, "set_skill_metadata"))
        .edited
    else
        .removed;

    insertEvent(allocator, db, args, name, kind, "", 0) catch |err| {
        logWarn(logger, "skill ledger: failed to record '{s}' for '{s}': {s}", .{ kind.asString(), name, @errorName(err) });
    };
}

// ─── tests ───────────────────────────────────────────────────────────────

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn countEvents(db: *database.Db, alloc: std.mem.Allocator, session_id: []const u8) !i64 {
    var q = try db.query(alloc,
        "SELECT COUNT(*) FROM session_skill_events WHERE session_id = ?",
        &.{session_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}

fn eventCount(
    db: *database.Db,
    alloc: std.mem.Allocator,
    session_id: []const u8,
    event: []const u8,
) !i64 {
    var q = try db.query(alloc,
        "SELECT COUNT(*) FROM session_skill_events WHERE session_id = ? AND event = ?",
        &.{ session_id, event });
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}

fn testArgs(io: std.Io, session_id: []const u8, tool_name: []const u8, result: []const u8) SkillToolEventArgs {
    return .{
        .io = io,
        .session_id = session_id,
        .tool_name = tool_name,
        .tool_result_json = result,
        .loop_index = 7,
        .llm_history_id = "hist_1",
    };
}

test "sha256Hex matches a known vector and is stable" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    sha256Hex("hello", &a);
    sha256Hex("hello", &b);
    try testing.expectEqualStrings(a[0..], b[0..]);
    // Standard SHA-256("hello").
    try testing.expectEqualStrings(
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        a[0..],
    );
    // A one-byte difference must change the hash.
    var c: [64]u8 = undefined;
    sha256Hex("hellp", &c);
    try testing.expect(!std.mem.eql(u8, a[0..], c[0..]));
}

test "recordSkillToolEvents records a successful use_skill as 'loaded' with a content hash" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const body = "---\nname: my-skill\n---\n## Procedure\nstep\n";
    const result = try std.fmt.allocPrint(alloc,
        "{{\"tool\":\"use_skill\",\"success\":true,\"data\":{{\"skill_name\":\"my-skill\",\"content\":{f},\"loaded\":true}},\"error\":null,\"v\":1}}",
        .{std.json.fmt(body, .{})});
    defer alloc.free(result);

    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "use_skill", result));

    try testing.expectEqual(@as(i64, 1), try countEvents(&ctx.db, alloc, "sess_1"));
    try testing.expectEqual(@as(i64, 1), try eventCount(&ctx.db, alloc, "sess_1", "loaded"));

    var q = try ctx.db.query(alloc,
        "SELECT content_hash, loop_index, llm_history_id, source FROM session_skill_events WHERE session_id = ?",
        &.{"sess_1"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);

    // The hash must match the body that was read — that is the whole point of
    // storing it (drift becomes a hash compare later).
    var expected: [64]u8 = undefined;
    sha256Hex(body, &expected);
    try testing.expectEqualStrings(expected[0..], row.values[0]);
    try testing.expectEqualStrings("7", row.values[1]);
    try testing.expectEqualStrings("hist_1", row.values[2]);
    try testing.expectEqualStrings("use_skill", row.values[3]);
}

test "recordSkillToolEvents ignores a use_skill that did not load" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // `loaded: false` (oversized / unreadable) must not look like a successful
    // load, or the eval would judge a body the agent never saw.
    const result =
        \\{"tool":"use_skill","success":true,"data":{"skill_name":"big","content":"","loaded":false},"error":null,"v":1}
    ;
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "use_skill", result));
    try testing.expectEqual(@as(i64, 0), try countEvents(&ctx.db, alloc, "sess_1"));
}

test "recordSkillToolEvents ignores a failed tool call" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result =
        \\{"tool":"use_skill","success":false,"data":null,"error":"use_skill failed: InvalidInput","v":1}
    ;
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "use_skill", result));
    try testing.expectEqual(@as(i64, 0), try countEvents(&ctx.db, alloc, "sess_1"));
}

test "recordSkillToolEvents records one 'listed' row per offered skill, across scopes" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result =
        \\{"tool":"search_skills","success":true,"data":{"query":"","skills":[{"name":"g-one","description":"d","scope":"global","path":"/p"},{"name":"g-two","description":"d","scope":"global","path":"/p"},{"name":"l-one","description":"d","scope":"local","path":"/p"}],"count":3,"total":3},"error":null,"v":1}
    ;
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "search_skills", result));

    try testing.expectEqual(@as(i64, 3), try countEvents(&ctx.db, alloc, "sess_1"));
    try testing.expectEqual(@as(i64, 3), try eventCount(&ctx.db, alloc, "sess_1", "listed"));

    // A `listed` row must NOT claim a body hash — nothing was read.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM session_skill_events WHERE session_id = ? AND content_hash = ''",
        &.{"sess_1"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("3", row.values[0]);
}

test "a second search_skills does not duplicate 'listed' rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result =
        \\{"tool":"search_skills","success":true,"data":{"query":"g","skills":[{"name":"g-one","description":"d","scope":"global","path":"/p"}],"count":1,"total":1},"error":null,"v":1}
    ;
    const args = testArgs(ctx.threaded.io(), "sess_1", "search_skills", result);
    recordSkillToolEvents(alloc, &ctx.db, null, args);
    recordSkillToolEvents(alloc, &ctx.db, null, args);
    recordSkillToolEvents(alloc, &ctx.db, null, args);

    // The deterministic composite id means the PRIMARY KEY does the dedupe, so
    // this holds without any read-then-write (which would be a TOCTOU bug).
    try testing.expectEqual(@as(i64, 1), try countEvents(&ctx.db, alloc, "sess_1"));
}

test "a listed skill and a loaded skill coexist for the same name" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const listed =
        \\{"tool":"search_skills","success":true,"data":{"query":"my","skills":[{"name":"my-skill","description":"d","scope":"global","path":"/p"}],"count":1,"total":1},"error":null,"v":1}
    ;
    const loaded =
        \\{"tool":"use_skill","success":true,"data":{"skill_name":"my-skill","content":"body","loaded":true},"error":null,"v":1}
    ;
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "search_skills", listed));
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "use_skill", loaded));

    // Two rows, two kinds — this pair is exactly what distinguishes "offered
    // and then used" from "offered and ignored".
    try testing.expectEqual(@as(i64, 2), try countEvents(&ctx.db, alloc, "sess_1"));
    try testing.expectEqual(@as(i64, 1), try eventCount(&ctx.db, alloc, "sess_1", "listed"));
    try testing.expectEqual(@as(i64, 1), try eventCount(&ctx.db, alloc, "sess_1", "loaded"));
}

test "recordSkillToolEvents handles add/edit/metadata/remove" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const cases = [_]struct { tool: []const u8, result: []const u8 }{
        .{ .tool = "add_skill", .result =
        \\{"tool":"add_skill","success":true,"data":{"skill_name":"new-skill","name":"new-skill","created":true,"path":"/p"},"error":null,"v":1}
        },
        .{ .tool = "edit_skill", .result =
        \\{"tool":"edit_skill","success":true,"data":{"skill_name":"new-skill","name":"new-skill","updated":true,"path":"/p"},"error":null,"v":1}
        },
        .{ .tool = "set_skill_metadata", .result =
        \\{"tool":"set_skill_metadata","success":true,"data":{"skill_name":"new-skill","updated":true,"metadata":[{"key":"license","value":"MIT"}]},"error":null,"v":1}
        },
        .{ .tool = "remove_skill", .result =
        \\{"tool":"remove_skill","success":true,"data":{"skill_name":"new-skill","removed":true,"path":"/p"},"error":null,"v":1}
        },
    };

    for (cases) |c| {
        recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", c.tool, c.result));
    }

    try testing.expectEqual(@as(i64, 4), try countEvents(&ctx.db, alloc, "sess_1"));
    try testing.expectEqual(@as(i64, 1), try eventCount(&ctx.db, alloc, "sess_1", "created"));
    try testing.expectEqual(@as(i64, 1), try eventCount(&ctx.db, alloc, "sess_1", "removed"));
    // A metadata write is a write to the row, so it lands as `edited` beside
    // `edit_skill` — the ledger would otherwise show a skill changing with no
    // event explaining it.
    try testing.expectEqual(@as(i64, 2), try eventCount(&ctx.db, alloc, "sess_1", "edited"));
}

test "recordSkillToolEvents tolerates a payload it cannot parse" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // A tool result that is not JSON at all, and one whose `data` was wrapped as
    // `{"_raw":…}` by `normalizeDataFragment`. Neither may throw or write.
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "use_skill", "not json"));
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "search_skills",
        \\{"tool":"search_skills","success":true,"data":{"_raw":"oops"},"error":null,"v":1}
    ));
    try testing.expectEqual(@as(i64, 0), try countEvents(&ctx.db, alloc, "sess_1"));
}

test "recordSkillToolEvents ignores tools that are not skill tools" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result =
        \\{"tool":"read_file","success":true,"data":{"skill_name":"sneaky"},"error":null,"v":1}
    ;
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "read_file", result));
    try testing.expectEqual(@as(i64, 0), try countEvents(&ctx.db, alloc, "sess_1"));
}

test "recordSkillToolEvents is a no-op without a session id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result =
        \\{"tool":"use_skill","success":true,"data":{"skill_name":"my-skill","content":"b","loaded":true},"error":null,"v":1}
    ;
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "", "use_skill", result));
    try testing.expectEqual(@as(i64, 0), try countEvents(&ctx.db, alloc, "sess_1"));
}

// ─────────────────────────────────────────────────────────────────────────────
// The report contract
// ─────────────────────────────────────────────────────────────────────────────

pub const Verdict = enum {
    keep,
    update,
    rewrite,
    merge,
    delete,
    needs_human,

    pub fn asString(self: Verdict) []const u8 {
        return switch (self) {
            .keep => "keep",
            .update => "update",
            .rewrite => "rewrite",
            .merge => "merge",
            .delete => "delete",
            .needs_human => "needs_human",
        };
    }

    /// Parse a verdict as an LLM wrote it. Trimmed and case-insensitive,
    /// because the value comes from generated text and "Keep" is as good an
    /// answer as "keep".
    pub fn fromString(raw: []const u8) ?Verdict {
        const s = std.mem.trim(u8, raw, &std.ascii.whitespace);
        inline for (@typeInfo(Verdict).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

/// Severity as reported. Unknown values are not fatal; they simply never count
/// as `high`, so an unrecognised severity can never authorise a `delete`.
pub fn isHigh(raw: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw, &std.ascii.whitespace), "high");
}

pub const ReportFinding = struct {
    /// Which rubric dimension this belongs to (freshness / accuracy /
    /// duplication / relevance / used / helpfulness / stale_path / structural).
    dimension: []const u8 = "",
    /// low | medium | high. Only `high` can authorise a delete.
    severity: []const u8 = "",
    claim: []const u8 = "",
    /// REQUIRED and non-empty. A verdict with no evidence is the single most
    /// damaging failure mode of an LLM judge, so it is rejected structurally
    /// rather than trusted.
    evidence: []const u8 = "",
};

/// What an eval sub-agent submits as its final message.
pub const Report = struct {
    skill_name: []const u8 = "",
    verdict: []const u8 = "",
    confidence: f32 = 0,
    /// Intrinsic half — depends only on the body and the code state.
    freshness: u8 = 0,
    accuracy: u8 = 0,
    duplication: u8 = 0,
    /// Session-relative half — depends on the task that loaded the skill.
    relevance: u8 = 0,
    used: u8 = 0,
    helpfulness: u8 = 0,
    findings: []const ReportFinding = &.{},
    /// Required for `update` / `rewrite`.
    proposed_content: []const u8 = "",
    /// Required for `merge`.
    merge_target: []const u8 = "",
    rationale: []const u8 = "",
};

pub const Validation = struct {
    verdict: Verdict = .needs_human,
    /// True when the submitted verdict was refused and replaced by
    /// `needs_human`. `reason` says why, and is stored on the result so the
    /// refusal is auditable rather than silent.
    downgraded: bool = false,
    reason: []const u8 = "",
};

fn refuse(reason: []const u8) Validation {
    return .{ .verdict = .needs_human, .downgraded = true, .reason = reason };
}

pub fn hasHighFinding(findings: []const ReportFinding) bool {
    for (findings) |f| {
        if (isHigh(f.severity)) return true;
    }
    return false;
}

/// Validate a submitted report and return the verdict that may be stored.
/// This is the trust boundary: nothing an eval sub-agent writes reaches the
/// tables without passing through here.
pub fn validateReport(report: Report) Validation {
    const submitted = Verdict.fromString(report.verdict) orelse
        return refuse("verdict is not one of keep|update|rewrite|merge|delete|needs_human");

    if (submitted == .needs_human) return .{ .verdict = .needs_human };

    if (report.relevance > 3 or report.used > 3 or report.helpfulness > 3 or
        report.freshness > 3 or report.accuracy > 3 or report.duplication > 3)
    {
        return refuse("a score is outside 0..3");
    }
    if (!std.math.isFinite(report.confidence) or report.confidence < 0 or report.confidence > 1) {
        return refuse("confidence is outside 0..1");
    }

    for (report.findings) |f| {
        if (f.evidence.len == 0) return refuse("a finding has no evidence");
    }

    switch (submitted) {
        .update, .rewrite => {
            if (report.proposed_content.len == 0) return refuse("update/rewrite requires proposed_content");
        },
        .merge => {
            if (report.merge_target.len == 0) return refuse("merge requires merge_target");
        },
        .delete => {
            // A delete without a high-severity finding is exactly how a good
            // skill gets destroyed by a confident-sounding report.
            if (!hasHighFinding(report.findings)) return refuse("delete requires a high-severity finding");
        },
        else => {},
    }

    return .{ .verdict = submitted };
}

/// Combine the shared (intrinsic) half with the per-session half into the
/// verdict that is shown to a human. Note what is **not** a parameter:
/// `relevance`, `used`, `helpfulness`.
pub fn decideVerdict(intrinsic: Verdict, intrinsic_has_high: bool) Verdict {
    if (intrinsic == .needs_human) return .needs_human;
    if (intrinsic_has_high) return .delete;
    return switch (intrinsic) {
        .keep => .keep,
        .update => .update,
        .rewrite => .rewrite,
        .merge => .merge,
        // `delete` only ever arrives with a high finding (validateReport), so
        // reaching here without one is a needs_human, never a deletion.
        .delete => .needs_human,
        .needs_human => .needs_human,
    };
}

/// Human-readable reading of the session-relative relevance score. Reported
/// alongside the verdict; deliberately never able to change it.
pub fn relevanceNote(relevance: u8) []const u8 {
    return switch (relevance) {
        0 => "irrelevant to this task - a discovery problem, not a skill problem",
        1 => "partially relevant to this task",
        else => "",
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Concurrent-state primitives
// ─────────────────────────────────────────────────────────────────────────────

pub const FactClaim = enum {
    /// We inserted the lease; we own the computation and must publish it.
    won,
    /// A completed fact already exists for this exact question. Reuse it.
    reusable,
    /// Another session holds a live lease. Do not duplicate the work; the
    /// caller falls back to `stealFact` (which succeeds only once the lease is
    /// stale) or records its result with the intrinsic half pending.
    held,
};

/// Claim the right to compute the intrinsic half for one exact question.
pub fn claimFact(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    skill_key: []const u8,
    content_hash: []const u8,
    context_key: []const u8,
) !FactClaim {
    try db.exec(allocator,
        \\INSERT OR IGNORE INTO skill_eval_facts
        \\    (id, skill_key, content_hash, context_key, verdict_intrinsic, computed_at)
        \\VALUES
        \\    (?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''),
        \\     COALESCE(NULLIF(?, ''), ''), 'computing', datetime('now'))
    , &.{ id, skill_key, content_hash, context_key });
    if (db.changes() > 0) return .won;

    // We lost the insert. Find out whether there is an answer to reuse or a
    // live owner to leave alone. Either way we do NOT compute.
    var q = try db.query(allocator,
        "SELECT verdict_intrinsic FROM skill_eval_facts WHERE skill_key = ? AND content_hash = ? AND context_key = ?",
        &.{ skill_key, content_hash, context_key });
    defer q.deinit();
    const row = (try q.next()) orelse return .held;
    defer row.deinit(allocator);
    if (std.mem.eql(u8, row.values[0], "computing")) return .held;
    return .reusable;
}

pub const FactRow = struct {
    id: []u8,
    verdict: Verdict,
    freshness: u8,
    accuracy: u8,
    duplication: u8,
    findings_json: []u8,
    evidence_json: []u8,
    proposed_content: []u8,
    missing_paths_json: []u8,
    drift_commits_json: []u8,

    /// Guarded like `Analysis.deinit` and `RunOutcome.deinit`: a field left at
    /// its `&.{}` default is not an allocation, and freeing it would be a
    /// double-free the moment a second constructor appears.
    pub fn deinit(self: FactRow, allocator: std.mem.Allocator) void {
        if (self.id.len > 0) allocator.free(self.id);
        if (self.findings_json.len > 0) allocator.free(self.findings_json);
        if (self.evidence_json.len > 0) allocator.free(self.evidence_json);
        if (self.proposed_content.len > 0) allocator.free(self.proposed_content);
        if (self.missing_paths_json.len > 0) allocator.free(self.missing_paths_json);
        if (self.drift_commits_json.len > 0) allocator.free(self.drift_commits_json);
    }
};

/// Parse a stored score.
fn parseScore(raw: []const u8) u8 {
    const n = std.fmt.parseInt(u8, raw, 10) catch return 0;
    return if (n > 3) 3 else n;
}

/// Read a **completed** fact for one exact question, or null. The `!=
/// 'computing'` predicate is load-bearing, not cosmetic: a lease must never
/// be mistaken for a verdict, so every read goes through here.
pub fn readFact(
    allocator: std.mem.Allocator,
    db: *database.Db,
    skill_key: []const u8,
    content_hash: []const u8,
    context_key: []const u8,
) !?FactRow {
    var q = try db.query(allocator,
        \\SELECT id, verdict_intrinsic, freshness, accuracy, duplication,
        \\       findings_json, evidence_json, proposed_content, missing_paths_json, drift_commits_json
        \\  FROM skill_eval_facts
        \\ WHERE skill_key = ? AND content_hash = ? AND context_key = ?
        \\   AND verdict_intrinsic != 'computing'
    , &.{ skill_key, content_hash, context_key });
    defer q.deinit();
    const row = (try q.next()) orelse return null;
    defer row.deinit(allocator);

    return FactRow{
        .id = try allocator.dupe(u8, row.values[0]),
        // An unrecognised stored verdict degrades to needs_human rather than
        // erroring: a corrupt row must not be able to fail a whole eval run.
        .verdict = Verdict.fromString(row.values[1]) orelse .needs_human,
        .freshness = parseScore(row.values[2]),
        .accuracy = parseScore(row.values[3]),
        .duplication = parseScore(row.values[4]),
        .findings_json = try allocator.dupe(u8, row.values[5]),
        .evidence_json = try allocator.dupe(u8, row.values[6]),
        .proposed_content = try allocator.dupe(u8, row.values[7]),
        .missing_paths_json = try allocator.dupe(u8, row.values[8]),
        .drift_commits_json = try allocator.dupe(u8, row.values[9]),
    };
}

/// Take over a lease whose owner has been gone longer than `lease_seconds`.
pub fn stealFact(
    allocator: std.mem.Allocator,
    db: *database.Db,
    skill_key: []const u8,
    content_hash: []const u8,
    context_key: []const u8,
    lease_seconds: u32,
) !bool {
    var buf: [32]u8 = undefined;
    const modifier = std.fmt.bufPrint(&buf, "-{d} seconds", .{lease_seconds}) catch return false;
    try db.exec(allocator,
        \\UPDATE skill_eval_facts
        \\   SET computed_at = datetime('now')
        \\ WHERE skill_key = ? AND content_hash = ? AND context_key = ?
        \\   AND verdict_intrinsic = 'computing'
        \\   AND computed_at < datetime('now', ?)
    , &.{ skill_key, content_hash, context_key, modifier });
    return db.changes() > 0;
}

pub const FactValues = struct {
    verdict: Verdict,
    freshness: u8 = 0,
    accuracy: u8 = 0,
    duplication: u8 = 0,
    findings_json: []const u8 = "",
    evidence_json: []const u8 = "",
    proposed_content: []const u8 = "",
    missing_paths_json: []const u8 = "",
    drift_commits_json: []const u8 = "",
};

/// Publish the intrinsic half. Only the lease holder can, and only once: the
/// `verdict_intrinsic = 'computing'` predicate makes a second publish a no-op,
/// so a stolen lease cannot be overwritten by the original owner waking up.
pub fn publishFact(
    allocator: std.mem.Allocator,
    db: *database.Db,
    fact_id: []const u8,
    values: FactValues,
) !bool {
    const freshness = try std.fmt.allocPrint(allocator, "{d}", .{values.freshness});
    defer allocator.free(freshness);
    const accuracy = try std.fmt.allocPrint(allocator, "{d}", .{values.accuracy});
    defer allocator.free(accuracy);
    const duplication = try std.fmt.allocPrint(allocator, "{d}", .{values.duplication});
    defer allocator.free(duplication);

    try db.exec(allocator,
        \\UPDATE skill_eval_facts
        \\   SET verdict_intrinsic = ?,
        \\       freshness = ?, accuracy = ?, duplication = ?,
        \\       findings_json = COALESCE(NULLIF(?, ''), ''),
        \\       evidence_json = COALESCE(NULLIF(?, ''), ''),
        \\       proposed_content = COALESCE(NULLIF(?, ''), ''),
        \\       missing_paths_json = COALESCE(NULLIF(?, ''), ''),
        \\       drift_commits_json = COALESCE(NULLIF(?, ''), ''),
        \\       computed_at = datetime('now')
        \\ WHERE id = ? AND verdict_intrinsic = 'computing'
    , &.{
        values.verdict.asString(),
        freshness,
        accuracy,
        duplication,
        values.findings_json,
        values.evidence_json,
        values.proposed_content,
        values.missing_paths_json,
        values.drift_commits_json,
        fact_id,
    });
    return db.changes() > 0;
}

// ─── the judge tier's writes ──────────────────────────────────────────────

/// The session-relative half, as the judge submitted it and as
/// `validateReport` allowed it through. Separate from `FactValues` because
/// these are per-SESSION facts.
pub const JudgeValues = struct {
    verdict: Verdict,
    relevance: u8 = 0,
    used: u8 = 0,
    helpfulness: u8 = 0,
    confidence: f32 = 0,
    /// The sub-agent session that produced the report — the transcript anchor
    /// a human reads when they want to know why.
    sub_session_id: []const u8 = "",
    /// `done` when a validated report landed, `needs_human` when it did not.
    status: []const u8 = "done",
    rationale: []const u8 = "",
    /// The text this verdict would write into the skill -- the judge's
    /// `proposed_content`, stored verbatim.
    proposed_diff: []const u8 = "",
};

/// Write the judge tier's half onto one result row.
pub fn updateJudgeResult(
    allocator: std.mem.Allocator,
    db: *database.Db,
    result_id: []const u8,
    values: JudgeValues,
) !bool {
    // `exec` binds an empty slice as SQL NULL, so every number goes over the
    // wire as a non-empty formatted string and every text column is
    // COALESCE-wrapped (Migration 079's class).
    const relevance = try std.fmt.allocPrint(allocator, "{d}", .{values.relevance});
    defer allocator.free(relevance);
    const used = try std.fmt.allocPrint(allocator, "{d}", .{values.used});
    defer allocator.free(used);
    const helpfulness = try std.fmt.allocPrint(allocator, "{d}", .{values.helpfulness});
    defer allocator.free(helpfulness);
    const confidence = try std.fmt.allocPrint(allocator, "{d:.4}", .{values.confidence});
    defer allocator.free(confidence);

    try db.exec(allocator,
        \\UPDATE skill_eval_results
        \\   SET relevance = ?, used = ?, helpfulness = ?, confidence = ?,
        \\       verdict = COALESCE(NULLIF(?, ''), 'needs_human'),
        \\       status = COALESCE(NULLIF(?, ''), 'needs_human'),
        \\       rationale = COALESCE(NULLIF(?, ''), ''),
        \\       sub_session_id = COALESCE(NULLIF(?, ''), ''),
        \\       proposed_diff = COALESCE(NULLIF(?, ''), '')
        \\ WHERE id = ? AND applied_at IS NULL
    , &.{
        relevance,
        used,
        helpfulness,
        confidence,
        values.verdict.asString(),
        values.status,
        values.rationale,
        values.sub_session_id,
        values.proposed_diff,
        result_id,
    });
    return db.changes() > 0;
}

/// Read the session-relative scores off one result row, for the read path and
/// for tests. Null when the row does not exist.
pub const JudgeScores = struct {
    relevance: u8,
    used: u8,
    helpfulness: u8,
    confidence: f32,
    status: []u8,
    verdict: []u8,
    sub_session_id: []u8,

    pub fn deinit(self: JudgeScores, allocator: std.mem.Allocator) void {
        allocator.free(self.status);
        allocator.free(self.verdict);
        allocator.free(self.sub_session_id);
    }
};

pub fn readJudgeScores(
    allocator: std.mem.Allocator,
    db: *database.Db,
    result_id: []const u8,
) !?JudgeScores {
    var q = try db.query(allocator,
        \\SELECT relevance, used, helpfulness, confidence,
        \\       COALESCE(status, ''), COALESCE(verdict, ''), COALESCE(sub_session_id, '')
        \\  FROM skill_eval_results WHERE id = ?
    , &.{result_id});
    defer q.deinit();
    const row = (try q.next()) orelse return null;
    defer row.deinit(allocator);
    return JudgeScores{
        .relevance = parseScore(row.values[0]),
        .used = parseScore(row.values[1]),
        .helpfulness = parseScore(row.values[2]),
        .confidence = std.fmt.parseFloat(f32, row.values[3]) catch 0,
        .status = try allocator.dupe(u8, row.values[4]),
        .verdict = try allocator.dupe(u8, row.values[5]),
        .sub_session_id = try allocator.dupe(u8, row.values[6]),
    };
}

/// The task this session was doing, as the judge needs to see it. "Is this
/// skill relevant?" has no referent without it, so this is not an optional
/// input to the judge — it is what makes the session-relative half computable
pub fn sessionTaskContext(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    max_bytes: usize,
) ![]u8 {
    if (session_id.len == 0) return allocator.dupe(u8, "");
    var q = try db.query(allocator,
        \\SELECT response_content FROM llm_history
        \\ WHERE session_id = ? AND role = 'user'
        \\ ORDER BY created_at_nano ASC
        \\ LIMIT 1
    , &.{session_id});
    defer q.deinit();
    const row = (try q.next()) orelse return allocator.dupe(u8, "");
    defer row.deinit(allocator);
    const raw = row.values[0];
    if (raw.len == 0) return allocator.dupe(u8, "");
    if (raw.len <= max_bytes) return allocator.dupe(u8, raw);
    // Truncated with a visible marker: a judge that reads half a task and
    // reports confidently about all of it is the failure this guards.
    return std.fmt.allocPrint(allocator, "{s}\n… [{d} more characters omitted]", .{
        raw[0..max_bytes],
        raw.len - max_bytes,
    });
}

/// Claim the one self-prompted run a session is allowed.
pub fn claimRun(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    session_id: []const u8,
    trigger: []const u8,
    skill_name: []const u8,
    scope: []const u8,
    cwd: []const u8,
    context_key: []const u8,
    profile: []const u8,
    model: []const u8,
) !bool {
    try db.exec(allocator,
        \\INSERT OR IGNORE INTO skill_eval_runs
        \\    (id, session_id, skill_name, scope, trigger, status, profile, model,
        \\     cwd, context_key, started_at)
        \\VALUES
        \\    (?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''),
        \\     COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), 'running',
        \\     COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''),
        \\     COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), datetime('now'))
    // Bind order MUST match the placeholder order in the VALUES clause above:
    // id, session_id, skill_name, scope, trigger, profile, model, cwd,
    // context_key.
    , &.{ id, session_id, skill_name, scope, trigger, profile, model, cwd, context_key });
    return db.changes() > 0;
}

/// Finalize a run. Last write wins, which is correct here: the claim above
/// guarantees a single owner per `(session, trigger)`.
pub fn finishRun(
    allocator: std.mem.Allocator,
    db: *database.Db,
    run_id: []const u8,
    status: []const u8,
    total_tokens: u32,
    err_msg: []const u8,
) !void {
    const tokens = try std.fmt.allocPrint(allocator, "{d}", .{total_tokens});
    defer allocator.free(tokens);
    try db.exec(allocator,
        \\UPDATE skill_eval_runs
        \\   SET status = COALESCE(NULLIF(?, ''), 'done'),
        \\       total_tokens = ?,
        \\       error = COALESCE(NULLIF(?, ''), ''),
        \\       finished_at = datetime('now')
        \\ WHERE id = ?
    , &.{ status, tokens, err_msg, run_id });
}

pub const ApplyClaim = enum {
    /// We hold the exclusive right to apply this verdict.
    won,
    /// Someone else already applied it.
    already_applied,
    /// No such result row.
    missing,
};

/// Take the exclusive right to apply one verdict. `applied_at IS NULL` in the
/// WHERE clause is the lock, so two clicks, two clients or two humans cannot
/// both write the skill.
pub fn claimApply(
    allocator: std.mem.Allocator,
    db: *database.Db,
    result_id: []const u8,
    action: []const u8,
) !ApplyClaim {
    try db.exec(allocator,
        \\UPDATE skill_eval_results
        \\   SET applied_at = datetime('now'),
        \\       apply_action = COALESCE(NULLIF(?, ''), '')
        \\ WHERE id = ? AND applied_at IS NULL
    , &.{ action, result_id });
    if (db.changes() > 0) return .won;
    return if (try resultExists(allocator, db, result_id)) .already_applied else .missing;
}

/// Give an apply claim back.
pub fn releaseApply(
    allocator: std.mem.Allocator,
    db: *database.Db,
    result_id: []const u8,
) !void {
    try db.exec(allocator,
        "UPDATE skill_eval_results SET applied_at = NULL, apply_action = '' WHERE id = ?",
        &.{result_id});
}

/// Mark a verdict as unapplicable because the body moved on. Recorded rather
/// than deleted so the UI can offer a re-evaluate.
pub fn markResultStale(
    allocator: std.mem.Allocator,
    db: *database.Db,
    result_id: []const u8,
) !void {
    try db.exec(allocator,
        \\UPDATE skill_eval_results
        \\   SET status = 'stale'
        \\ WHERE id = ?
    , &.{result_id});
}

fn resultExists(allocator: std.mem.Allocator, db: *database.Db, result_id: []const u8) !bool {
    var q = try db.query(allocator, "SELECT 1 FROM skill_eval_results WHERE id = ?", &.{result_id});
    defer q.deinit();
    const row = (try q.next()) orelse return false;
    row.deinit(allocator);
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests — report validation and the verdict function
// ─────────────────────────────────────────────────────────────────────────────

test "Verdict.fromString trims, ignores case, and rejects anything unknown" {
    try testing.expectEqual(Verdict.keep, Verdict.fromString("keep").?);
    try testing.expectEqual(Verdict.keep, Verdict.fromString("  KEEP ").?);
    try testing.expectEqual(Verdict.needs_human, Verdict.fromString("Needs_Human").?);
    try testing.expectEqual(Verdict.delete, Verdict.fromString("DELETE").?);
    try testing.expectEqual(@as(?Verdict, null), Verdict.fromString("remove"));
    try testing.expectEqual(@as(?Verdict, null), Verdict.fromString(""));
}

const good_finding = ReportFinding{
    .dimension = "freshness",
    .severity = "high",
    .claim = "the path it names no longer exists",
    .evidence = "ls src/ai_workflow/tui/agentic_loop/workflow.zig -> no such file",
};

test "validateReport accepts a well-formed keep" {
    const v = validateReport(.{ .skill_name = "s", .verdict = "keep", .confidence = 0.8, .freshness = 3 });
    try testing.expectEqual(Verdict.keep, v.verdict);
    try testing.expect(!v.downgraded);
    try testing.expectEqualStrings("", v.reason);
}

test "validateReport refuses a verdict string it does not recognise" {
    const v = validateReport(.{ .skill_name = "s", .verdict = "remove", .confidence = 0.9 });
    try testing.expectEqual(Verdict.needs_human, v.verdict);
    try testing.expect(v.downgraded);
}

test "validateReport passes needs_human through WITHOUT calling it a downgrade" {
    // needs_human is an honest answer, not a refusal — the UI must not label it
    // as one.
    const v = validateReport(.{ .skill_name = "s", .verdict = "needs_human" });
    try testing.expectEqual(Verdict.needs_human, v.verdict);
    try testing.expect(!v.downgraded);
}

test "validateReport refuses an out-of-range score rather than clamping it" {
    // A score outside 0..3 means the report cannot be relied on in the parts
    // that DO look well-formed, so the whole report is refused.
    const v = validateReport(.{ .skill_name = "s", .verdict = "keep", .confidence = 0.9, .freshness = 9 });
    try testing.expectEqual(Verdict.needs_human, v.verdict);
    try testing.expect(v.downgraded);
    try testing.expectEqualStrings("a score is outside 0..3", v.reason);
}

test "validateReport refuses a confidence outside 0..1" {
    try testing.expect(validateReport(.{ .verdict = "keep", .confidence = 1.5 }).downgraded);
    try testing.expect(validateReport(.{ .verdict = "keep", .confidence = -0.1 }).downgraded);
}

test "validateReport refuses any finding with no evidence" {
    const no_evidence = ReportFinding{ .dimension = "freshness", .severity = "high", .claim = "it is stale", .evidence = "" };
    const v = validateReport(.{
        .verdict = "delete",
        .confidence = 0.99,
        .findings = &.{ good_finding, no_evidence },
    });
    try testing.expectEqual(Verdict.needs_human, v.verdict);
    try testing.expectEqualStrings("a finding has no evidence", v.reason);
}

test "validateReport refuses update/rewrite without proposed_content" {
    const upd = validateReport(.{ .verdict = "update", .confidence = 0.7, .findings = &.{good_finding} });
    try testing.expectEqual(Verdict.needs_human, upd.verdict);
    try testing.expectEqualStrings("update/rewrite requires proposed_content", upd.reason);

    const ok = validateReport(.{
        .verdict = "update",
        .confidence = 0.7,
        .findings = &.{good_finding},
        .proposed_content = "---\nname: s\n---\nnew body\n",
    });
    try testing.expectEqual(Verdict.update, ok.verdict);
    try testing.expect(!ok.downgraded);
}

test "validateReport refuses merge without merge_target" {
    try testing.expect(validateReport(.{ .verdict = "merge", .confidence = 0.7 }).downgraded);
    const ok = validateReport(.{ .verdict = "merge", .confidence = 0.7, .merge_target = "other-skill" });
    try testing.expectEqual(Verdict.merge, ok.verdict);
}

test "validateReport refuses a delete with no high-severity finding" {
    // This is the rule that stops a confident-sounding report from destroying a
    // perfectly good skill.
    const soft = ReportFinding{ .dimension = "freshness", .severity = "medium", .claim = "slightly stale", .evidence = "git log" };
    const refused = validateReport(.{ .verdict = "delete", .confidence = 0.95, .findings = &.{soft} });
    try testing.expectEqual(Verdict.needs_human, refused.verdict);
    try testing.expectEqualStrings("delete requires a high-severity finding", refused.reason);

    // No findings at all is the same refusal.
    try testing.expect(validateReport(.{ .verdict = "delete", .confidence = 0.95 }).downgraded);

    // With a high finding (case-insensitively) it passes.
    const ok = validateReport(.{ .verdict = "delete", .confidence = 0.95, .findings = &.{good_finding} });
    try testing.expectEqual(Verdict.delete, ok.verdict);
    try testing.expect(!ok.downgraded);

    const upper = ReportFinding{ .dimension = "accuracy", .severity = "HIGH", .claim = "wrong", .evidence = "file:1" };
    try testing.expectEqual(Verdict.delete, validateReport(.{ .verdict = "delete", .confidence = 0.5, .findings = &.{upper} }).verdict);
}

test "an unrecognised severity never counts as high, so it can never authorise a delete" {
    try testing.expect(!isHigh("critical"));
    try testing.expect(!isHigh(""));
    try testing.expect(isHigh("high"));
    try testing.expect(isHigh(" high "));
}

test "decideVerdict maps the intrinsic half, and a bare delete is never a deletion" {
    try testing.expectEqual(Verdict.keep, decideVerdict(.keep, false));
    try testing.expectEqual(Verdict.update, decideVerdict(.update, false));
    try testing.expectEqual(Verdict.rewrite, decideVerdict(.rewrite, false));
    try testing.expectEqual(Verdict.merge, decideVerdict(.merge, false));
    try testing.expectEqual(Verdict.needs_human, decideVerdict(.needs_human, false));
    // A high finding promotes to delete...
    try testing.expectEqual(Verdict.delete, decideVerdict(.keep, true));
    // ...and a needs_human is never promoted, even with a high finding, because
    // the intrinsic verdict itself was refused as untrustworthy.
    try testing.expectEqual(Verdict.needs_human, decideVerdict(.needs_human, true));
    // `delete` only reaches here WITH a high finding (validateReport); without
    // one it must not delete.
    try testing.expectEqual(Verdict.needs_human, decideVerdict(.delete, false));
}

test "relevance can never change the verdict - the whole 0..3 range" {
    // The structural guarantee that a good skill loaded for the wrong task
    // cannot be deleted or rewritten.
    for ([_]Verdict{ .keep, .update, .rewrite, .merge, .needs_human }) |intrinsic| {
        const base = decideVerdict(intrinsic, false);
        var r: u8 = 0;
        while (r <= 3) : (r += 1) {
            // Nothing in the call can vary with `r`, so the assertion is about
            // the signature itself — which is exactly the guarantee wanted.
            try testing.expectEqual(base, decideVerdict(intrinsic, false));
            _ = relevanceNote(r);
        }
    }
    try testing.expectEqualStrings("", relevanceNote(2));
    try testing.expectEqualStrings("", relevanceNote(3));
    try testing.expect(std.mem.indexOf(u8, relevanceNote(0), "discovery problem") != null);
    try testing.expectEqualStrings("partially relevant to this task", relevanceNote(1));
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests — the concurrent-state primitives
// ─────────────────────────────────────────────────────────────────────────────

test "claimFact: first writer wins, a live lease is not reusable, a published fact is" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const sk = "global:foo";
    const ch = "hashA";
    const ck = "/repo@abc";

    try testing.expectEqual(FactClaim.won, try claimFact(alloc, &ctx.db, "f1", sk, ch, ck));
    // Second caller for the SAME question: the lease is live, so neither claims
    // nor reuses. It must not compute — that is the duplicate-work guard.
    try testing.expectEqual(FactClaim.held, try claimFact(alloc, &ctx.db, "f2", sk, ch, ck));

    // A different body is a different question, so it gets its own lease.
    try testing.expectEqual(FactClaim.won, try claimFact(alloc, &ctx.db, "f3", sk, "hashB", ck));
    // As is the same body in a different repo/commit (freshness is repo-relative).
    try testing.expectEqual(FactClaim.won, try claimFact(alloc, &ctx.db, "f4", sk, ch, "/other@abc"));

    // Publish, and now the second caller reuses instead of recomputing.
    try testing.expect(try publishFact(alloc, &ctx.db, "f1", .{
        .verdict = .keep,
        .freshness = 3,
        .accuracy = 2,
        .duplication = 1,
        .findings_json = "[]",
    }));
    try testing.expectEqual(FactClaim.reusable, try claimFact(alloc, &ctx.db, "f5", sk, ch, ck));
}

test "readFact returns a published fact and refuses a bare lease" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    _ = try claimFact(alloc, &ctx.db, "f1", "global:foo", "hashA", "/repo@abc");

    // A lease is NOT an answer. If this returned a row, every reader would have
    // to remember to check for 'computing' — so the check lives in the query.
    try testing.expectEqual(@as(?FactRow, null), try readFact(alloc, &ctx.db, "global:foo", "hashA", "/repo@abc"));

    // Empty free-text columns must round-trip as "" rather than blowing up on
    // the NOT NULL constraints (the empty-slice-binds-as-NULL trap).
    try testing.expect(try publishFact(alloc, &ctx.db, "f1", .{
        .verdict = .update,
        .freshness = 1,
        .accuracy = 3,
        .duplication = 0,
    }));

    const fact = (try readFact(alloc, &ctx.db, "global:foo", "hashA", "/repo@abc")).?;
    defer fact.deinit(alloc);
    try testing.expectEqualStrings("f1", fact.id);
    try testing.expectEqual(Verdict.update, fact.verdict);
    try testing.expectEqual(@as(u8, 1), fact.freshness);
    try testing.expectEqual(@as(u8, 3), fact.accuracy);
    try testing.expectEqualStrings("", fact.findings_json);
    try testing.expectEqualStrings("", fact.proposed_content);
    try testing.expectEqualStrings("", fact.drift_commits_json);
}

test "publishFact is once-only: a stolen lease cannot be overwritten later" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    _ = try claimFact(alloc, &ctx.db, "f1", "global:foo", "hashA", "/repo@abc");
    try testing.expect(try publishFact(alloc, &ctx.db, "f1", .{ .verdict = .keep, .freshness = 3 }));
    // The original owner waking up after a steal must not clobber the winner.
    try testing.expect(!try publishFact(alloc, &ctx.db, "f1", .{ .verdict = .delete, .freshness = 0 }));

    const fact = (try readFact(alloc, &ctx.db, "global:foo", "hashA", "/repo@abc")).?;
    defer fact.deinit(alloc);
    try testing.expectEqual(Verdict.keep, fact.verdict);
}

test "stealFact only takes a lease that has actually expired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    _ = try claimFact(alloc, &ctx.db, "f1", "global:foo", "hashA", "/repo@abc");

    // Fresh lease: not stealable, so a second session does not duplicate work.
    try testing.expect(!try stealFact(alloc, &ctx.db, "global:foo", "hashA", "/repo@abc", 300));

    // Age it past the lease (simulating a crashed owner) and it becomes
    // reclaimable — otherwise the fact could never be computed at all.
    try ctx.db.exec(alloc, "UPDATE skill_eval_facts SET computed_at = datetime('now', '-3600 seconds') WHERE id = 'f1'", &.{});
    try testing.expect(try stealFact(alloc, &ctx.db, "global:foo", "hashA", "/repo@abc", 300));
    try testing.expect(!try stealFact(alloc, &ctx.db, "global:foo", "hashA", "/repo@abc", 300));

    // After a steal the row is still a lease, so it is still not an answer.
    try testing.expectEqual(@as(?FactRow, null), try readFact(alloc, &ctx.db, "global:foo", "hashA", "/repo@abc"));
}

test "claimRun: one self-prompted run per session, other triggers unaffected" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expect(try claimRun(alloc, &ctx.db, "r1", "sess_a", "self_prompt", "", "session", "/cwd", "/cwd@abc", "p", "m"));
    // The agent can emit two run_skill_eval calls in one turn. The partial
    // unique index is the arbiter — not a pre-check, which would race.
    try testing.expect(!try claimRun(alloc, &ctx.db, "r2", "sess_a", "self_prompt", "", "session", "/cwd", "/cwd@abc", "p", "m"));
    // A different session gets its own.
    try testing.expect(try claimRun(alloc, &ctx.db, "r3", "sess_b", "self_prompt", "", "session", "/cwd", "/cwd@abc", "p", "m"));
    // `on_demand` is outside the partial index, so both can coexist.
    try testing.expect(try claimRun(alloc, &ctx.db, "r4", "sess_a", "on_demand", "foo", "skill", "/cwd", "/cwd@abc", "p", "m"));

    try finishRun(alloc, &ctx.db, "r1", "done", 1234, "");

    var q = try ctx.db.query(alloc, "SELECT COUNT(*), MAX(CASE WHEN id='r1' THEN status END) FROM skill_eval_runs", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("3", row.values[0]);
    try testing.expectEqualStrings("done", row.values[1]);
}

test "claimApply: exactly one winner, releasable, and honest about a missing row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\INSERT INTO skill_eval_results (id, run_id, skill_key, skill_name, session_id, status, verdict)
        \\VALUES ('res_1', 'run_1', 'global:foo', 'foo', 'sess_a', 'done', 'update')
    , &.{});

    try testing.expectEqual(ApplyClaim.won, try claimApply(alloc, &ctx.db, "res_1", "edit"));
    // Two clients, two clicks: the second is told the truth, not given a second write.
    try testing.expectEqual(ApplyClaim.already_applied, try claimApply(alloc, &ctx.db, "res_1", "edit"));
    try testing.expectEqual(ApplyClaim.missing, try claimApply(alloc, &ctx.db, "nope", "edit"));

    // The staleness path: we won, discovered the body had moved underneath us,
    // and must give the claim back or the verdict is unapplicable forever.
    try releaseApply(alloc, &ctx.db, "res_1");
    try testing.expectEqual(ApplyClaim.won, try claimApply(alloc, &ctx.db, "res_1", "delete"));

    var q = try ctx.db.query(alloc, "SELECT apply_action FROM skill_eval_results WHERE id = 'res_1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("delete", row.values[0]);
}

test "markResultStale records the refusal instead of deleting the verdict" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\INSERT INTO skill_eval_results (id, run_id, skill_key, skill_name, status, verdict)
        \\VALUES ('res_1', 'run_1', 'global:foo', 'foo', 'done', 'update')
    , &.{});
    try markResultStale(alloc, &ctx.db, "res_1");

    var q = try ctx.db.query(alloc, "SELECT status, COALESCE(proposed_diff, '') FROM skill_eval_results WHERE id = 'res_1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("stale", row.values[0]);
    // The missing paths are intrinsic and live on the fact; `proposed_diff`
    // means "the text this verdict would write into the skill", so it must NOT
    // be used as a scratch column for a JSON array of paths.
    try testing.expectEqualStrings("", row.values[1]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Reading the ledger
// ─────────────────────────────────────────────────────────────────────────────

/// One skill as the ledger remembers it for a session.
pub const SessionSkillUse = struct {
    skill_name: []u8,
    /// The skill was offered by `search_skills` at some point.
    listed: bool,
    /// The skill was actually read by `use_skill`.
    loaded: bool,
    /// `content_hash` of the last successful read, or "" when never loaded.
    content_hash: []u8,
    /// The turn of the FIRST read, or null when never loaded.
    first_loop_index: ?u32,

    pub fn deinit(self: SessionSkillUse, allocator: std.mem.Allocator) void {
        allocator.free(self.skill_name);
        allocator.free(self.content_hash);
    }
};

/// The skills one session was OFFERED and the ones it actually READ.
pub fn sessionSkillSet(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) ![]SessionSkillUse {
    var out: std.ArrayList(SessionSkillUse) = .empty;
    errdefer {
        for (out.items) |it| it.deinit(allocator);
        out.deinit(allocator);
    }
    if (session_id.len == 0) return try out.toOwnedSlice(allocator);

    var q = try db.query(allocator,
        "SELECT skill_name, event, content_hash, loop_index FROM session_skill_events WHERE session_id = ? ORDER BY created_at ASC",
        &.{session_id});
    defer q.deinit();

    while (try q.next()) |row| {
        defer row.deinit(allocator);
        const name = row.values[0];
        if (name.len == 0) continue;
        const event = row.values[1];
        const hash = row.values[2];
        const loop_raw = row.values[3];

        // An INDEX, not a pointer: `out` is an ArrayList and the `append`
        // below can reallocate its backing array, which would invalidate any
        // pointer taken from an earlier iteration.
        var idx: ?usize = null;
        for (out.items, 0..) |it, i| {
            if (std.mem.eql(u8, it.skill_name, name)) {
                idx = i;
                break;
            }
        }
        if (idx == null) {
            try out.append(allocator, .{
                .skill_name = try allocator.dupe(u8, name),
                .content_hash = try allocator.dupe(u8, ""),
                .listed = false,
                .loaded = false,
                .first_loop_index = null,
            });
            idx = out.items.len - 1;
        }
        const it = &out.items[idx.?];

        if (std.mem.eql(u8, event, "listed")) {
            it.listed = true;
        } else if (std.mem.eql(u8, event, "loaded")) {
            it.loaded = true;
            // The LAST read wins for the hash — a reload after an edit is the
            // body the agent ended up using. The FIRST read wins for the turn,
            // because that is when the skill entered the session.
            if (hash.len > 0) {
                allocator.free(it.content_hash);
                it.content_hash = try allocator.dupe(u8, hash);
            }
            if (it.first_loop_index == null) {
                it.first_loop_index = std.fmt.parseInt(u32, loop_raw, 10) catch null;
            }
        }
    }

    return try out.toOwnedSlice(allocator);
}

pub fn freeSessionSkillSet(allocator: std.mem.Allocator, set: []SessionSkillUse) void {
    for (set) |it| it.deinit(allocator);
    allocator.free(set);
}

test "sessionSkillSet separates OFFERED skills from READ skills" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const listed =
        \\{"tool":"search_skills","success":true,"data":{"query":"","skills":[{"name":"used-one","description":"d","scope":"global","path":"/p"},{"name":"ignored-one","description":"d","scope":"global","path":"/p"}],"count":2,"total":2},"error":null,"v":1}
    ;
    const loaded =
        \\{"tool":"use_skill","success":true,"data":{"skill_name":"used-one","content":"body","loaded":true},"error":null,"v":1}
    ;
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "search_skills", listed));
    recordSkillToolEvents(alloc, &ctx.db, null, testArgs(ctx.threaded.io(), "sess_1", "use_skill", loaded));

    const set = try sessionSkillSet(alloc, &ctx.db, "sess_1");
    defer freeSessionSkillSet(alloc, set);

    try testing.expectEqual(@as(usize, 2), set.len);
    // `used-one` is both offered and read...
    try testing.expect(std.mem.eql(u8, set[0].skill_name, "used-one") or std.mem.eql(u8, set[1].skill_name, "used-one"));
    for (set) |it| {
        if (std.mem.eql(u8, it.skill_name, "used-one")) {
            try testing.expect(it.listed);
            try testing.expect(it.loaded);
            try testing.expect(it.content_hash.len > 0);
            try testing.expect(it.first_loop_index != null);
        } else {
            // ...and `ignored-one` was offered and never read. That pair is the
            // finding `session_skills` could never produce.
            try testing.expect(it.listed);
            try testing.expect(!it.loaded);
            try testing.expectEqualStrings("", it.content_hash);
            try testing.expect(it.first_loop_index == null);
        }
    }
}

test "sessionSkillSet is empty for a session with no ledger rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const set = try sessionSkillSet(alloc, &ctx.db, "never_seen");
    defer freeSessionSkillSet(alloc, set);
    try testing.expectEqual(@as(usize, 0), set.len);

    const empty = try sessionSkillSet(alloc, &ctx.db, "");
    defer freeSessionSkillSet(alloc, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

// ─────────────────────────────────────────────────────────────────────────────
// Reading the eval tables (the HTTP layer's data source)
// ─────────────────────────────────────────────────────────────────────────────

pub const RunRow = struct {
    id: []u8,
    session_id: []u8,
    status: []u8,
    trigger: []u8,
    scope: []u8,
    skill_name: []u8,
    err: []u8,
    total_tokens: i64,
    created_at: []u8,

    pub fn deinit(self: RunRow, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.status);
        allocator.free(self.trigger);
        allocator.free(self.scope);
        allocator.free(self.skill_name);
        allocator.free(self.err);
        allocator.free(self.created_at);
    }
};

pub const RunFilter = struct {
    run_id: []const u8 = "",
    session_id: []const u8 = "",
    limit: u32 = 25,
};

/// Optional filters are expressed as `(? = '' OR col = ?)` rather than by
/// building SQL text.
pub fn listRuns(
    allocator: std.mem.Allocator,
    db: *database.Db,
    filter: RunFilter,
) ![]RunRow {
    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{filter.limit});
    defer allocator.free(limit_str);

    var q = try db.query(allocator,
        \\SELECT id, session_id, status, trigger, scope, skill_name,
        \\       COALESCE(error, ''), COALESCE(total_tokens, 0), COALESCE(created_at, '')
        \\  FROM skill_eval_runs
        \\ WHERE (? = '' OR id = ?)
        \\   AND (? = '' OR session_id = ?)
        \\ ORDER BY created_at DESC, id DESC
        \\ LIMIT ?
    , &.{ filter.run_id, filter.run_id, filter.session_id, filter.session_id, limit_str });
    defer q.deinit();

    var out: std.ArrayList(RunRow) = .empty;
    errdefer {
        for (out.items) |r| r.deinit(allocator);
        out.deinit(allocator);
    }
    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try out.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .status = try allocator.dupe(u8, row.values[2]),
            .trigger = try allocator.dupe(u8, row.values[3]),
            .scope = try allocator.dupe(u8, row.values[4]),
            .skill_name = try allocator.dupe(u8, row.values[5]),
            .err = try allocator.dupe(u8, row.values[6]),
            .total_tokens = std.fmt.parseInt(i64, row.values[7], 10) catch 0,
            .created_at = try allocator.dupe(u8, row.values[8]),
        });
    }
    return try out.toOwnedSlice(allocator);
}

pub fn freeRunRows(allocator: std.mem.Allocator, rows: []RunRow) void {
    for (rows) |r| r.deinit(allocator);
    allocator.free(rows);
}

/// A result row plus the intrinsic half resolved from its fact.
pub const ResultRow = struct {
    id: []u8,
    run_id: []u8,
    /// The session the eval ran in.
    session_id: []u8,
    skill_key: []u8,
    skill_name: []u8,
    status: []u8,
    verdict: []u8,
    freshness: u8,
    accuracy: u8,
    duplication: u8,
    rationale: []u8,
    missing_paths_json: []u8,
    intrinsic_fact_id: []u8,
    /// The hash of the body this verdict was computed against. The apply path
    /// re-checks it: if the file changed since the eval, the proposal describes
    /// a body that is gone.
    base_content_hash: []u8,
    /// That same body, verbatim. A hash can only ANSWER "is this still the
    /// body I judged?" -- it cannot show a human what the body was.
    content_at_use: []u8,
    /// The text this verdict would write, empty when there is none. Pairs with
    /// `content_at_use` to form a before/after.
    proposed_diff: []u8,
    applied: bool,
    apply_action: []u8,

    pub fn deinit(self: ResultRow, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.run_id);
        allocator.free(self.session_id);
        allocator.free(self.skill_key);
        allocator.free(self.skill_name);
        allocator.free(self.status);
        allocator.free(self.verdict);
        allocator.free(self.rationale);
        allocator.free(self.missing_paths_json);
        allocator.free(self.intrinsic_fact_id);
        allocator.free(self.base_content_hash);
        allocator.free(self.content_at_use);
        allocator.free(self.proposed_diff);
        allocator.free(self.apply_action);
    }
};

/// The projection both result reads share, concatenated (never retyped) into
/// the two queries below so the column list and `mapResultRow`'s indices
/// cannot drift apart.
const result_projection =
    \\SELECT r.id, r.run_id, COALESCE(r.session_id, ''),
    \\       r.skill_key, r.skill_name, r.status, r.verdict,
    \\       COALESCE(f.freshness, 0), COALESCE(f.accuracy, 0), COALESCE(f.duplication, 0),
    \\       COALESCE(r.rationale, ''),
    \\       COALESCE(f.missing_paths_json, ''), COALESCE(r.intrinsic_fact_id, ''),
    \\       COALESCE(r.base_content_hash, ''),
    \\       COALESCE(r.content_at_use, ''), COALESCE(r.proposed_diff, ''),
    \\       r.applied_at IS NOT NULL, COALESCE(r.apply_action, '')
    \\  FROM skill_eval_results r
    \\  LEFT JOIN skill_eval_facts f ON f.id = r.intrinsic_fact_id
    \\                              AND f.verdict_intrinsic != 'computing'
;

pub fn listResults(
    allocator: std.mem.Allocator,
    db: *database.Db,
    run_id: []const u8,
) ![]ResultRow {
    var q = try db.query(allocator, result_projection ++
        \\ WHERE r.run_id = ?
        \\ ORDER BY r.skill_name ASC, r.id ASC
    , &.{run_id});
    defer q.deinit();

    var out: std.ArrayList(ResultRow) = .empty;
    errdefer {
        for (out.items) |r| r.deinit(allocator);
        out.deinit(allocator);
    }
    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try out.append(allocator, try mapResultRow(allocator, row));
    }
    return try out.toOwnedSlice(allocator);
}

/// One result by id, or null when there is no such id. The apply path needs
/// it, and needs the row's own `session_id`: the body it re-hashes lives in the
/// session's repo, not wherever the server process was started.
pub fn readResultById(
    allocator: std.mem.Allocator,
    db: *database.Db,
    result_id: []const u8,
) !?ResultRow {
    var q = try db.query(allocator, result_projection ++
        \\ WHERE r.id = ?
    , &.{result_id});
    defer q.deinit();
    const row = (try q.next()) orelse return null;
    defer row.deinit(allocator);
    return try mapResultRow(allocator, row);
}

/// `values[N]` onto the field `result_projection` puts in column N. Read the
/// two together: a column added to one and not the other mis-maps silently --
/// every value is a string, so nothing about the call site would complain.
fn mapResultRow(allocator: std.mem.Allocator, row: database.Db.Row) !ResultRow {
    return .{
        .id = try allocator.dupe(u8, row.values[0]),
        .run_id = try allocator.dupe(u8, row.values[1]),
        .session_id = try allocator.dupe(u8, row.values[2]),
        .skill_key = try allocator.dupe(u8, row.values[3]),
        .skill_name = try allocator.dupe(u8, row.values[4]),
        .status = try allocator.dupe(u8, row.values[5]),
        .verdict = try allocator.dupe(u8, row.values[6]),
        .freshness = parseScore(row.values[7]),
        .accuracy = parseScore(row.values[8]),
        .duplication = parseScore(row.values[9]),
        .rationale = try allocator.dupe(u8, row.values[10]),
        .missing_paths_json = try allocator.dupe(u8, row.values[11]),
        .intrinsic_fact_id = try allocator.dupe(u8, row.values[12]),
        .base_content_hash = try allocator.dupe(u8, row.values[13]),
        .content_at_use = try allocator.dupe(u8, row.values[14]),
        .proposed_diff = try allocator.dupe(u8, row.values[15]),
        .applied = std.mem.eql(u8, row.values[16], "1"),
        .apply_action = try allocator.dupe(u8, row.values[17]),
    };
}

pub fn freeResultRows(allocator: std.mem.Allocator, rows: []ResultRow) void {
    for (rows) |r| r.deinit(allocator);
    allocator.free(rows);
}

pub const VerdictCount = struct {
    verdict: []u8,
    n: i64,

    pub fn deinit(self: VerdictCount, allocator: std.mem.Allocator) void {
        allocator.free(self.verdict);
    }
};

/// Verdict tally, for the UI's "needs attention" badge.
pub fn verdictCounts(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) ![]VerdictCount {
    var q = try db.query(allocator,
        \\SELECT verdict, COUNT(*) FROM skill_eval_results
        \\ WHERE (? = '' OR session_id = ?)
        \\ GROUP BY verdict
        \\ ORDER BY verdict ASC
    , &.{ session_id, session_id });
    defer q.deinit();

    var out: std.ArrayList(VerdictCount) = .empty;
    errdefer {
        for (out.items) |c| c.deinit(allocator);
        out.deinit(allocator);
    }
    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try out.append(allocator, .{
            .verdict = try allocator.dupe(u8, row.values[0]),
            .n = std.fmt.parseInt(i64, row.values[1], 10) catch 0,
        });
    }
    return try out.toOwnedSlice(allocator);
}

pub fn freeVerdictCounts(allocator: std.mem.Allocator, counts: []VerdictCount) void {
    for (counts) |c| c.deinit(allocator);
    allocator.free(counts);
}

test "listRuns and listResults read back what a run wrote" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Columns are OMITTED rather than bound to '' — `exec` binds an empty
    // slice as SQL NULL, and these columns are NOT NULL, so writing '' here
    // would fail the constraint. (Caught by this very test the first time.)
    try ctx.db.exec(alloc,
        \\INSERT INTO skill_eval_runs (id, session_id, scope, trigger, status, total_tokens)
        \\VALUES ('run_1', 'sess_1', 'session', 'self_prompt', 'done', 0)
    , &.{});
    // The intrinsic paths live on the FACT, not on the result — the result
    // references it. So seed a fact and link it; the assertion below proves the
    // join resolves it.
    try ctx.db.exec(alloc,
        \\INSERT INTO skill_eval_facts (id, skill_key, content_hash, context_key, verdict_intrinsic, freshness, missing_paths_json)
        \\VALUES ('f1', 'global:foo', 'hashA', '/cwd@abc', 'update', 1, '["src/gone.zig"]')
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO skill_eval_results (id, run_id, skill_key, skill_name, session_id, status, verdict, rationale, intrinsic_fact_id)
        \\VALUES ('res_1', 'run_1', 'global:foo', 'foo', 'sess_1', 'done', 'update', '2 referenced path(s) no longer exist', 'f1')
    , &.{});

    const runs = try listRuns(alloc, &ctx.db, .{ .session_id = "sess_1" });
    defer freeRunRows(alloc, runs);
    try testing.expectEqual(@as(usize, 1), runs.len);
    try testing.expectEqualStrings("run_1", runs[0].id);
    try testing.expectEqualStrings("done", runs[0].status);
    try testing.expectEqualStrings("self_prompt", runs[0].trigger);

    const results = try listResults(alloc, &ctx.db, "run_1");
    defer freeResultRows(alloc, results);
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("foo", results[0].skill_name);
    try testing.expectEqualStrings("update", results[0].verdict);
    try testing.expectEqual(@as(u8, 1), results[0].freshness);
    // Resolved through the LEFT JOIN on intrinsic_fact_id, not stored twice.
    try testing.expectEqualStrings("[\"src/gone.zig\"]", results[0].missing_paths_json);
    try testing.expectEqualStrings("f1", results[0].intrinsic_fact_id);
    // Not applied yet — the UI shows Apply, not "applied".
    try testing.expect(!results[0].applied);
}

test "listRuns' filters are optional and independent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\INSERT INTO skill_eval_runs (id, session_id, trigger, status) VALUES ('run_a', 'sess_1', 'self_prompt', 'done')
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO skill_eval_runs (id, session_id, trigger, status) VALUES ('run_b', 'sess_2', 'self_prompt', 'done')
    , &.{});

    // No filter: both.
    const all = try listRuns(alloc, &ctx.db, .{});
    defer freeRunRows(alloc, all);
    try testing.expectEqual(@as(usize, 2), all.len);

    // By session: one.
    const one = try listRuns(alloc, &ctx.db, .{ .session_id = "sess_2" });
    defer freeRunRows(alloc, one);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings("run_b", one[0].id);

    // By id, with the session filter left empty.
    const by_id = try listRuns(alloc, &ctx.db, .{ .run_id = "run_a" });
    defer freeRunRows(alloc, by_id);
    try testing.expectEqual(@as(usize, 1), by_id.len);
    try testing.expectEqualStrings("sess_1", by_id[0].session_id);

    // limit is honoured.
    const capped = try listRuns(alloc, &ctx.db, .{ .limit = 1 });
    defer freeRunRows(alloc, capped);
    try testing.expectEqual(@as(usize, 1), capped.len);
}

test "verdictCounts tallies per verdict and totals the whole table when unfiltered" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const insert =
        \\INSERT INTO skill_eval_results (id, run_id, skill_key, skill_name, session_id, status, verdict)
        \\VALUES (?, 'run_1', 'global:foo', 'foo', ?, 'done', ?)
    ;
    try ctx.db.exec(alloc, insert, &.{ "r1", "sess_1", "keep" });
    try ctx.db.exec(alloc, insert, &.{ "r2", "sess_1", "update" });
    try ctx.db.exec(alloc, insert, &.{ "r3", "sess_1", "update" });
    try ctx.db.exec(alloc, insert, &.{ "r4", "sess_2", "keep" });

    const scoped = try verdictCounts(alloc, &ctx.db, "sess_1");
    defer freeVerdictCounts(alloc, scoped);
    try testing.expectEqual(@as(usize, 2), scoped.len);
    // Ordered by verdict, so `keep` precedes `update`.
    try testing.expectEqualStrings("keep", scoped[0].verdict);
    try testing.expectEqual(@as(i64, 1), scoped[0].n);
    try testing.expectEqualStrings("update", scoped[1].verdict);
    try testing.expectEqual(@as(i64, 2), scoped[1].n);

    const all = try verdictCounts(alloc, &ctx.db, "");
    defer freeVerdictCounts(alloc, all);
    var total: i64 = 0;
    for (all) |c| total += c.n;
    try testing.expectEqual(@as(i64, 4), total);
}

// ─── the judge tier's storage ─────────────────────────────────────────────

fn seedResultRow(alloc: std.mem.Allocator, db: *database.Db, id: []const u8, verdict: []const u8) !void {
    try db.exec(alloc,
        \\INSERT INTO skill_eval_results (id, run_id, skill_key, skill_name, session_id, status, verdict, rationale)
        \\VALUES (?, 'run_j', 'global:foo', 'foo', 'sess_j', 'done', ?, 'Tier 0 found no problem')
    , &.{ id, verdict });
}

test "updateJudgeResult stores the session-relative half and round-trips" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seedResultRow(alloc, &ctx.db, "rj1", "keep");

    try testing.expect(try updateJudgeResult(alloc, &ctx.db, "rj1", .{
        .verdict = .keep,
        .relevance = 3,
        .used = 2,
        .helpfulness = 3,
        .confidence = 0.8,
        .sub_session_id = "subagent_123_judge",
        .status = "done",
        .rationale = "Tier 0 found no problem; judge: it was exactly the right skill",
    }));

    const scores = (try readJudgeScores(alloc, &ctx.db, "rj1")).?;
    defer scores.deinit(alloc);
    try testing.expectEqual(@as(u8, 3), scores.relevance);
    try testing.expectEqual(@as(u8, 2), scores.used);
    try testing.expectEqual(@as(u8, 3), scores.helpfulness);
    try testing.expectEqualStrings("keep", scores.verdict);
    try testing.expectEqualStrings("done", scores.status);
    try testing.expectEqualStrings("subagent_123_judge", scores.sub_session_id);
    try testing.expect(std.math.isFinite(scores.confidence));
    try testing.expect(@abs(scores.confidence - 0.8) < 0.01);
}

test "a judge may escalate a deterministic keep to delete" {
    // The one escalation that exists, and the reason Tier 1 is worth its
    // tokens: Tier 0 structurally cannot reach `delete`.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seedResultRow(alloc, &ctx.db, "rj2", "keep");

    try testing.expect(try updateJudgeResult(alloc, &ctx.db, "rj2", .{
        .verdict = .delete,
        .relevance = 0,
        .used = 0,
        .helpfulness = 0,
        .status = "done",
        .rationale = "judge: the documented build step does not exist",
    }));
    const scores = (try readJudgeScores(alloc, &ctx.db, "rj2")).?;
    defer scores.deinit(alloc);
    try testing.expectEqualStrings("delete", scores.verdict);
}

test "a judge never rewrites a result a human already applied" {
    // The apply endpoint is the human's decision. A judge that lands late —
    // a slow sub-agent, a retried run — must not be able to overwrite it, and
    // the guard is a predicate on the one statement, not a read-then-write.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seedResultRow(alloc, &ctx.db, "rj3", "update");
    try ctx.db.exec(alloc,
        "UPDATE skill_eval_results SET applied_at = datetime('now'), apply_action = 'update' WHERE id = ?",
        &.{"rj3"},
    );

    const wrote = try updateJudgeResult(alloc, &ctx.db, "rj3", .{
        .verdict = .delete,
        .status = "done",
        .rationale = "a late judge",
    });
    try testing.expectEqual(false, wrote);

    const scores = (try readJudgeScores(alloc, &ctx.db, "rj3")).?;
    defer scores.deinit(alloc);
    try testing.expectEqualStrings("update", scores.verdict);
}

test "updateJudgeResult on a missing row writes nothing and says so" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const wrote = try updateJudgeResult(alloc, &ctx.db, "does_not_exist", .{
        .verdict = .delete,
        .status = "done",
    });
    try testing.expectEqual(false, wrote);
    try testing.expect((try readJudgeScores(alloc, &ctx.db, "does_not_exist")) == null);
}

test "sessionTaskContext returns the FIRST user message, marked when clipped" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Two user turns; the judge must see the one that says what the session
    // set out to do, not the one it drifted to.
    try ctx.db.exec(alloc,
        \\INSERT INTO llm_history (id, session_id, role, response_content, created_at_nano, model)
        \\VALUES ('h2', 'sess_t', 'user', 'actually now do the other thing', 200, 'm')
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO llm_history (id, session_id, role, response_content, created_at_nano, model)
        \\VALUES ('h1', 'sess_t', 'user', 'fix the empty state in ChatView', 100, 'm')
    , &.{});
    // An assistant row that sorts first must not win.
    try ctx.db.exec(alloc,
        \\INSERT INTO llm_history (id, session_id, role, response_content, created_at_nano, model)
        \\VALUES ('h0', 'sess_t', 'assistant', 'I will look at ChatView', 50, 'm')
    , &.{});

    const task = try sessionTaskContext(alloc, &ctx.db, "sess_t", 4000);
    defer alloc.free(task);
    try testing.expectEqualStrings("fix the empty state in ChatView", task);

    // Clipped rather than silently cut: a judge reading half a task and
    // reporting confidently about all of it is the failure this prevents.
    // 31 bytes in, 10 kept, so 21 are named as omitted.
    const clipped = try sessionTaskContext(alloc, &ctx.db, "sess_t", 10);
    defer alloc.free(clipped);
    try testing.expectEqualStrings("fix the em\n… [21 more characters omitted]", clipped);
}

test "sessionTaskContext is empty, not an error, for a session with no user turn" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // A thin context is a legitimate reason for a judge to answer
    // needs_human, so it is a value the caller can pass on — not a failure
    // that would take the whole eval down.
    const none = try sessionTaskContext(alloc, &ctx.db, "sess_never_existed", 4000);
    defer alloc.free(none);
    try testing.expectEqualStrings("", none);

    const no_id = try sessionTaskContext(alloc, &ctx.db, "", 4000);
    defer alloc.free(no_id);
    try testing.expectEqualStrings("", no_id);
}

test "updateJudgeResult persists the proposal the judge was made to produce" {
    // The judge prompt REQUIRES proposed_content for update/rewrite and
    // validateReport refuses a report without it.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seedResultRow(alloc, &ctx.db, "rj_p1", "update");

    const proposal =
        \\---
        \\name: real-skill
        \\description: corrected
        \\---
        \\Read src/agentic_loop/skill_evals_drift.zig instead.
    ;
    try testing.expect(try updateJudgeResult(alloc, &ctx.db, "rj_p1", .{
        .verdict = .update,
        .relevance = 2,
        .used = 1,
        .helpfulness = 3,
        .confidence = 0.7,
        .sub_session_id = "subagent_9_judge",
        .status = "done",
        .rationale = "judge: one referenced path moved",
        .proposed_diff = proposal,
    }));

    var q = try ctx.db.query(alloc, "SELECT COALESCE(proposed_diff, '') FROM skill_eval_results WHERE id = 'rj_p1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings(proposal, row.values[0]);
}

test "a judge verdict that changes nothing stores no proposal" {
    // `keep` / `merge` / `delete` have no after, so the column must stay empty
    // rather than being filled with the body again.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try seedResultRow(alloc, &ctx.db, "rj_p2", "keep");

    try testing.expect(try updateJudgeResult(alloc, &ctx.db, "rj_p2", .{
        .verdict = .keep,
        .sub_session_id = "subagent_10_judge",
        .status = "done",
        .rationale = "judge: exactly right",
    }));

    var q = try ctx.db.query(alloc, "SELECT COALESCE(proposed_diff, '') FROM skill_eval_results WHERE id = 'rj_p2'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "listResults carries the before body and the proposal" {
    // Without these two in ResultRow the read path cannot surface them, so the
    // write would be invisible everywhere except a raw SQL query.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try ctx.db.exec(alloc,
        \\INSERT INTO skill_eval_runs (id, session_id, trigger, status)
        \\VALUES ('run_ba', 'sess_ba', 'manual', 'done')
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO skill_eval_results
        \\    (id, run_id, skill_key, skill_name, status, verdict,
        \\     base_content_hash, content_at_use, proposed_diff)
        \\VALUES
        \\    ('res_ba', 'run_ba', 'global:foo', 'foo', 'done', 'update',
        \\     'abc123', 'THE-BEFORE-BODY', 'THE-AFTER-BODY')
    , &.{});

    const rows = try listResults(alloc, &ctx.db, "run_ba");
    defer freeResultRows(alloc, rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("THE-BEFORE-BODY", rows[0].content_at_use);
    try testing.expectEqualStrings("THE-AFTER-BODY", rows[0].proposed_diff);
    // The shift of the two pre-existing trailing columns must not have broken
    // the mapping -- `applied` and `apply_action` sit AFTER the new pair.
    try testing.expectEqual(false, rows[0].applied);
    try testing.expectEqualStrings("", rows[0].apply_action);
}

test "readResultById carries the session_id the apply guard resolves the repo from" {
    // Apply re-hashes the body against the SESSION's repo
    // (`readCurrentSkillHash` -> `workspace_scope.sessionCwd`), so a read
    // that dropped the id re-hashed the server's own cwd and refused a live
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try ctx.db.exec(alloc,
        \\INSERT INTO skill_eval_runs (id, session_id, trigger, status)
        \\VALUES ('run_sid', 'sess_sid', 'manual', 'done')
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO skill_eval_results
        \\    (id, run_id, skill_key, skill_name, session_id, status, verdict, base_content_hash)
        \\VALUES
        \\    ('res_sid', 'run_sid', 'local:bar', 'bar', 'sess_sid', 'done', 'update', 'HASH-1')
    , &.{});

    const row = (try readResultById(alloc, &ctx.db, "res_sid")).?;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("sess_sid", row.session_id);
    try testing.expectEqualStrings("HASH-1", row.base_content_hash);

    // The same row through the list read, so the shared projection is proven on
    // both of its callers.
    const rows = try listResults(alloc, &ctx.db, "run_sid");
    defer freeResultRows(alloc, rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("sess_sid", rows[0].session_id);

    // An id nobody stored is null, not an empty row the apply path would go on
    // to hash against.
    try testing.expect((try readResultById(alloc, &ctx.db, "no_such_result")) == null);
}

test "every projected column lands on its own ResultRow field" {
    // `result_projection` is mapped by index. One assertion per column, each
    // carrying a value no other column holds, so an off-by-one fails here
    // instead of quietly filing a verdict's body hash under the wrong field.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try ctx.db.exec(alloc,
        \\INSERT INTO skill_eval_runs (id, session_id, trigger, status)
        \\VALUES ('run_idx', 'RUN-SESS', 'manual', 'done')
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO skill_eval_facts
        \\    (id, skill_key, content_hash, context_key, verdict_intrinsic, freshness, accuracy, duplication, missing_paths_json)
        \\VALUES ('f_idx', 'local:bar', 'HASH-FACT', '/cwd@abc', 'update', 1, 2, 3, '["src/gone.zig"]')
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO skill_eval_results
        \\    (id, run_id, skill_key, skill_name, session_id, status, verdict, rationale,
        \\     intrinsic_fact_id, base_content_hash, content_at_use, proposed_diff,
        \\     applied_at, apply_action)
        \\VALUES
        \\    ('res_idx', 'RUN-ID', 'KEY-2', 'NAME-3', 'SESS-4', 'STATUS-5', 'VERDICT-6',
        \\     'RATIONALE-9', 'f_idx', 'HASH-13', 'BEFORE-14', 'AFTER-15',
        \\     CURRENT_TIMESTAMP, 'ACTION-17')
    , &.{});

    const rows = try listResults(alloc, &ctx.db, "RUN-ID");
    defer freeResultRows(alloc, rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    const r = rows[0];
    try testing.expectEqualStrings("res_idx", r.id); // 0
    try testing.expectEqualStrings("RUN-ID", r.run_id); // 1
    try testing.expectEqualStrings("SESS-4", r.session_id); // 2
    try testing.expectEqualStrings("KEY-2", r.skill_key); // 3
    try testing.expectEqualStrings("NAME-3", r.skill_name); // 4
    try testing.expectEqualStrings("STATUS-5", r.status); // 5
    try testing.expectEqualStrings("VERDICT-6", r.verdict); // 6
    try testing.expectEqual(@as(u8, 1), r.freshness); // 7, through the LEFT JOIN
    try testing.expectEqual(@as(u8, 2), r.accuracy); // 8
    try testing.expectEqual(@as(u8, 3), r.duplication); // 9
    try testing.expectEqualStrings("RATIONALE-9", r.rationale); // 10
    try testing.expectEqualStrings("[\"src/gone.zig\"]", r.missing_paths_json); // 11
    try testing.expectEqualStrings("f_idx", r.intrinsic_fact_id); // 12
    try testing.expectEqualStrings("HASH-13", r.base_content_hash); // 13
    try testing.expectEqualStrings("BEFORE-14", r.content_at_use); // 14
    try testing.expectEqualStrings("AFTER-15", r.proposed_diff); // 15
    try testing.expectEqual(true, r.applied); // 16
    try testing.expectEqualStrings("ACTION-17", r.apply_action); // 17
}
