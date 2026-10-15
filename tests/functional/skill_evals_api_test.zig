// Wire test: the Skill Evals HTTP surface. Zig port of
// `tests/functional/skill_evals_api_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// SQLite CLI helpers
// ============================================================================

/// Exit code for a finished child, or null if a signal stopped it.
fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// Skip unless a `sqlite3` CLI is present and speaks `-json`.
fn requireSqlite3Cli() !void {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-json", ":memory:", "SELECT 1 AS probe;" },
    }) catch |err| {
        std.debug.print("sqlite3 CLI unavailable ({s}); skipping the skill_eval seed\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code = exitCode(res.term);
    if (code == null or code.? != 0 or std.mem.indexOf(u8, res.stdout, "\"probe\"") == null) {
        std.debug.print(
            "sqlite3 CLI lacks -json support (rc={?}, out={s}); skipping the skill_eval seed\n",
            .{ code, res.stdout },
        );
        return error.SkipZigTest;
    }
}

/// Single-quote `s` as an SQL literal, doubling embedded quotes. Owned.
fn sqlLit(s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    out.writer.writeByte('\'') catch return error.OutOfMemory;
    for (s) |c| {
        if (c == '\'') out.writer.writeByte('\'') catch return error.OutOfMemory;
        out.writer.writeByte(c) catch return error.OutOfMemory;
    }
    out.writer.writeByte('\'') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The sqlite file the running binary opened. Owned. `helpers/db_path.zig`
/// resolves this path on every platform; the harness points HOME at an
/// isolated tmpdir, so it is always under `h.temp_dir`.
fn dbPath(temp_dir: []const u8) ![]u8 {
    return harness.harnessPath(gpa, temp_dir, &.{ ".config", "pabrik", "agent.db" });
}

/// Run the statement(s) in `sql` against the harness DB. Caller frees the
/// returned stdout.
fn sqliteRun(db_path: []const u8, sql: []const u8) ![]u8 {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-cmd", ".timeout 5000", db_path, sql },
    }) catch |err| {
        std.debug.print("sqlite3 did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer gpa.free(res.stderr);

    const code = exitCode(res.term) orelse {
        gpa.free(res.stdout);
        std.debug.print("sqlite3 was killed by a signal: {any}\n", .{res.term});
        return error.TestUnexpectedResult;
    };
    if (code != 0) {
        defer gpa.free(res.stdout);
        std.debug.print("sqlite3 exited {d}: {s}\nsql: {s}\n", .{ code, res.stderr, sql });
        return error.TestUnexpectedResult;
    }
    return res.stdout;
}

/// Python `_seed_result`: one run row plus one result row, the shape
/// `run_skill_eval` writes.
fn seedResult(h: *Harness, result_id: []const u8, verdict: []const u8) !void {
    try requireSqlite3Cli();

    const db = try dbPath(h.temp_dir);
    defer gpa.free(db);
    std.Io.Dir.cwd().access(io, db, .{}) catch {
        std.debug.print("agent.db missing at {s}\n", .{db});
        return error.TestUnexpectedResult;
    };

    const rid = try sqlLit(result_id);
    defer gpa.free(rid);
    const run_id = try std.fmt.allocPrint(gpa, "run_{s}", .{result_id});
    defer gpa.free(run_id);
    const run_lit = try sqlLit(run_id);
    defer gpa.free(run_lit);
    const v = try sqlLit(verdict);
    defer gpa.free(v);

    const sql = try std.fmt.allocPrint(
        gpa,
        "INSERT OR IGNORE INTO skill_eval_runs " ++
            "(id, session_id, scope, trigger, status, total_tokens) " ++
            "VALUES ({s}, 'sess_wire', 'session', 'self_prompt', 'done', 0);" ++
            "INSERT OR IGNORE INTO skill_eval_results " ++
            "(id, run_id, skill_key, skill_name, session_id, status, verdict, " ++
            " base_content_hash, rationale) " ++
            "VALUES ({s}, {s}, 'global:wire-skill', 'wire-skill', 'sess_wire', " ++
            "'done', {s}, 'deadbeef', 'seeded for the wire test');",
        .{ run_lit, rid, run_lit, v },
    );
    defer gpa.free(sql);

    const out = try sqliteRun(db, sql);
    gpa.free(out);
}

/// Python's inline `UPDATE skill_eval_results SET status = 'stale'` in
/// `test_apply_on_a_stale_result_is_409`.
fn markResultStale(h: *Harness, result_id: []const u8) !void {
    const db = try dbPath(h.temp_dir);
    defer gpa.free(db);
    const rid = try sqlLit(result_id);
    defer gpa.free(rid);
    const sql = try std.fmt.allocPrint(
        gpa,
        "UPDATE skill_eval_results SET status = 'stale' WHERE id = {s}",
        .{rid},
    );
    defer gpa.free(sql);
    const out = try sqliteRun(db, sql);
    gpa.free(out);
}

// ============================================================================
// Wire helpers
// ============================================================================

/// `GET /api/skill-evals/runs` with the given filters.
fn getRuns(h: *Harness, params: []const harness.Harness.Param) !harness.Response {
    return h.http(io, .GET, "/api/skill-evals/runs", .{ .params = params, .expect = &.{200} });
}

/// The string at `key` of a JSON OBJECT, or a named failure.
fn strField(o: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (o.get(key) orelse {
        std.debug.print("missing `{s}` in a JSON object\n", .{key});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("`{s}` is not a string\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
}

/// The one-element array at `key`, or a named failure.
fn firstOf(doc: *const harness.Json, key: []const u8) !std.json.ObjectMap {
    const arr = doc.array(key) orelse {
        std.debug.print("`{s}` is missing or not an array\n", .{key});
        return error.TestUnexpectedResult;
    };
    if (arr.items.len == 0) {
        std.debug.print("`{s}` is empty, but the test expects one row\n", .{key});
        return error.TestUnexpectedResult;
    }
    return switch (arr.items[0]) {
        .object => |o| o,
        else => {
            std.debug.print("`{s}[0]` is not an object\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
}

/// The `counts` tally Python built as
/// `{c["verdict"]: c["n"] for c in body["counts"]}` — here just the `n` for
/// one verdict, or null when that verdict is absent.
fn countFor(doc: *const harness.Json, verdict: []const u8) ?i64 {
    const arr = doc.array("counts") orelse return null;
    for (arr.items) |item| {
        const o = switch (item) {
            .object => |m| m,
            else => continue,
        };
        const v = switch (o.get("verdict") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, v, verdict)) continue;
        return switch (o.get("n") orelse continue) {
            .integer => |n| n,
            else => null,
        };
    }
    return null;
}

/// Does the body text (lower-cased by the caller where needed) contain the
/// needle? Python's `json.dumps(body).lower()` idiom, kept as a plain
/// substring search over the raw body — the needle is ASCII.
fn bodyHas(body: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, body, needle) != null;
}

/// Assert a response body is parseable JSON, echoing it on failure.
fn expectJson(r: *harness.Response) !void {
    var doc = r.json() catch |err| {
        std.debug.print(
            "response body is not JSON ({s}): {s}\n",
            .{ @errorName(err), r.body[0..@min(r.body.len, 500)] },
        );
        return error.TestUnexpectedResult;
    };
    doc.deinit();
}

// ============================================================================
// Test 1: an unmatched filter is an empty 200, not a 404
// ============================================================================

// A filter that matches nothing is a 200 with empty arrays. Not a 404 and not
// a 500: `?run_id=` is a filter, and "no rows" is a legitimate answer to a
// filter.
test "runs_returns_valid_json_with_empty_arrays_when_nothing_matches" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try getRuns(&h, &.{.{ .name = "run_id", .value = "nope" }});
    defer r.deinit();
    try expectJson(&r);

    var doc = try r.json();
    defer doc.deinit();

    // `assert body["runs"] == []` — an EMPTY array, not merely absent.
    const runs = doc.array("runs") orelse {
        std.debug.print("`runs` missing or not an array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (runs.items.len != 0) {
        std.debug.print("expected 0 runs for an unmatched filter, got {d}: {s}\n", .{ runs.items.len, r.body });
        return error.TestUnexpectedResult;
    }
    const results = doc.array("results") orelse {
        std.debug.print("`results` missing or not an array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (results.items.len != 0) {
        std.debug.print("expected 0 results for an unmatched filter, got {d}: {s}\n", .{ results.items.len, r.body });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 2: the seeded run and its results come back
// ============================================================================

test "runs_returns_a_seeded_run_and_its_results" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try seedResult(&h, "res_wire_1", "update");

    var r = try getRuns(&h, &.{.{ .name = "run_id", .value = "run_res_wire_1" }});
    defer r.deinit();
    try expectJson(&r);

    var doc = try r.json();
    defer doc.deinit();

    const runs = doc.array("runs") orelse {
        std.debug.print("`runs` missing or not an array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (runs.items.len != 1) {
        std.debug.print("expected exactly 1 run, got {d}: {s}\n", .{ runs.items.len, r.body });
        return error.TestUnexpectedResult;
    }
    const run0 = switch (runs.items[0]) {
        .object => |o| o,
        else => {
            std.debug.print("runs[0] is not an object: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqualStrings("run_res_wire_1", try strField(run0, "id"));

    const results = doc.array("results") orelse {
        std.debug.print("`results` missing or not an array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (results.items.len != 1) {
        std.debug.print("expected exactly 1 result, got {d}: {s}\n", .{ results.items.len, r.body });
        return error.TestUnexpectedResult;
    }
    const res0 = try firstOf(&doc, "results");
    try testing.expectEqualStrings("wire-skill", try strField(res0, "skill_name"));
    try testing.expectEqualStrings("update", try strField(res0, "verdict"));

    // Not applied yet, so the UI offers Apply. `applied` is derived by the
    // server from `applied_at IS NOT NULL`, so this also pins that the seed
    // left `applied_at` NULL.
    const applied = switch (res0.get("applied") orelse {
        std.debug.print("result row has no `applied`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .bool => |b| b,
        else => {
            std.debug.print("`applied` is not a bool: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    if (applied) {
        std.debug.print("a freshly seeded result must not read as applied: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 3: a non-numeric limit is a 400 naming the parameter
// ============================================================================

test "runs_rejects_a_non_numeric_limit_with_400" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/skill-evals/runs", .{
        .params = &.{.{ .name = "limit", .value = "abc" }},
        .expect = &.{400},
    });
    defer r.deinit();

    // Python: `"limit" in json.dumps(body).lower()`.
    if (!bodyHas(r.body, "limit")) {
        std.debug.print("400 should name the offending `limit`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 4: limit=0 is a 400
// ============================================================================

test "runs_rejects_limit_zero_with_400" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/skill-evals/runs", .{
        .params = &.{.{ .name = "limit", .value = "0" }},
        .expect = &.{400},
    });
    defer r.deinit();
}

// ============================================================================
// Test 5: an oversized limit is clamped, not rejected
// ============================================================================

// `limit=99999` is clamped to MAX_LIMIT, not rejected. A caller asking for
// more than we serve gets what we serve; only a malformed value is a 400.
test "runs_clamps_an_oversized_limit_rather_than_erroring" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // The STATUS is the assertion, so the harness must not assert it too.
    var r = try h.http(io, .GET, "/api/skill-evals/runs", .{
        .params = &.{.{ .name = "limit", .value = "99999" }},
        .assert_status = false,
    });
    defer r.deinit();
    if (r.status != 200) {
        std.debug.print(
            "limit=99999 should be clamped, not rejected; got {d}: {s}\n",
            .{ r.status, r.body[0..@min(r.body.len, 500)] },
        );
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 6: the summary tallies the seeded rows
// ============================================================================

test "summary_is_valid_json_and_tallies_the_seeded_rows" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try seedResult(&h, "res_wire_2", "keep");
    try seedResult(&h, "res_wire_3", "keep");

    var r = try h.http(io, .GET, "/api/skill-evals/summary", .{
        .params = &.{.{ .name = "session_id", .value = "sess_wire" }},
        .expect = &.{200},
    });
    defer r.deinit();
    try expectJson(&r);

    var doc = try r.json();
    defer doc.deinit();

    const total = doc.int("total") orelse {
        std.debug.print("summary has no integer `total`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(i64, 2), total);

    // `counts.get("keep") == 2`. A missing `keep` entry reads as null, which
    // is the assertion failing rather than a silent pass.
    const keep = countFor(&doc, "keep") orelse {
        std.debug.print("summary counts carry no `keep` row: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(i64, 2), keep);
}

// ============================================================================
// Test 7: an empty table is a zero, not an error
// ============================================================================

test "summary_on_an_empty_table_is_zero_not_an_error" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/skill-evals/summary", .{
        .params = &.{.{ .name = "session_id", .value = "never_seen" }},
        .expect = &.{200},
    });
    defer r.deinit();
    try expectJson(&r);

    var doc = try r.json();
    defer doc.deinit();

    try testing.expectEqual(@as(i64, 0), doc.int("total") orelse {
        std.debug.print("summary has no integer `total`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    });

    // `body["counts"] == []` — present and EMPTY, not absent.
    const counts = doc.array("counts") orelse {
        std.debug.print("`counts` missing or not an array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (counts.items.len != 0) {
        std.debug.print("expected an empty `counts` array, got {d}: {s}\n", .{ counts.items.len, r.body });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 8: a stored quote survives JSON encoding
// ============================================================================

// The response must parse even when a stored string contains a quote.
// `rationale` is free text written by an LLM, so a raw `"` in it is normal
// input, not an edge case.
test "a_rationale_containing_a_quote_survives_json_encoding" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try requireSqlite3Cli();

    const db = try dbPath(h.temp_dir);
    defer gpa.free(db);
    std.Io.Dir.cwd().access(io, db, .{}) catch {
        std.debug.print("agent.db missing at {s}\n", .{db});
        return error.TestUnexpectedResult;
    };

    // Byte-identical to the Python seed, including the double quotes inside
    // the single-quoted SQL literal.
    const sql =
        \\INSERT OR IGNORE INTO skill_eval_runs
        \\ (id, session_id, scope, trigger, status)
        \\VALUES ('run_quote', 'sess_wire', 'session', 'self_prompt', 'done');
        \\INSERT OR IGNORE INTO skill_eval_results
        \\ (id, run_id, skill_key, skill_name, session_id, status, verdict, rationale)
        \\VALUES ('res_quote', 'run_quote', 'global:q', 'q', 'sess_wire',
        \\ 'done', 'update', 'it said "this path is gone" and left');
    ;
    {
        const out = try sqliteRun(db, sql);
        gpa.free(out);
    }

    var r = try getRuns(&h, &.{.{ .name = "run_id", .value = "run_quote" }});
    defer r.deinit();

    // Python's `json.loads(r.body)  # raises if the escaping is wrong`.
    try expectJson(&r);

    var doc = try r.json();
    defer doc.deinit();
    const res0 = try firstOf(&doc, "results");
    const rationale = try strField(res0, "rationale");
    if (std.mem.indexOf(u8, rationale, "\"this path is gone\"") == null) {
        std.debug.print("rationale lost its embedded quotes: {s}\n", .{rationale});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 9: apply without a result_id is a 400 naming the parameter
// ============================================================================

test "apply_requires_a_result_id" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .POST, "/api/skill-evals/results/apply", .{ .expect = &.{400} });
    defer r.deinit();

    if (!bodyHas(r.body, "result_id")) {
        std.debug.print("400 should name the missing `result_id`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 10: apply on an unknown result is a 404
// ============================================================================

test "apply_on_an_unknown_result_is_404" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .POST, "/api/skill-evals/results/apply", .{
        .params = &.{.{ .name = "result_id", .value = "does_not_exist" }},
        .expect = &.{404},
    });
    defer r.deinit();
}

// ============================================================================
// Test 11: the first apply wins; the second is a 409
// ============================================================================

// The first apply wins; the second is a 409, not a second write.
//
// Two clicks, two clients or two humans must not both write the skill.
test "apply_records_the_action_and_is_idempotent_guarded" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try seedResult(&h, "res_apply_1", "update");

    {
        var first = try h.http(io, .POST, "/api/skill-evals/results/apply", .{
            .params = &.{
                .{ .name = "result_id", .value = "res_apply_1" },
                .{ .name = "action", .value = "edit" },
            },
            .expect = &.{200},
        });
        defer first.deinit();
        try expectJson(&first);

        var doc = try first.json();
        defer doc.deinit();

        try testing.expectEqual(true, doc.boolean("applied") orelse {
            std.debug.print("apply response has no bool `applied`: {s}\n", .{first.body});
            return error.TestUnexpectedResult;
        });
        try testing.expectEqualStrings("edit", doc.str("action") orelse {
            std.debug.print("apply response has no string `action`: {s}\n", .{first.body});
            return error.TestUnexpectedResult;
        });
    }

    // The second attempt is refused, and the refusal is a 409 — the caller
    // can tell "someone already did this" from "that does not exist".
    {
        var second = try h.http(io, .POST, "/api/skill-evals/results/apply", .{
            .params = &.{
                .{ .name = "result_id", .value = "res_apply_1" },
                .{ .name = "action", .value = "delete" },
            },
            .expect = &.{409},
        });
        second.deinit();
    }

    // And the row still records the FIRST action, not the loser's.
    {
        var r = try getRuns(&h, &.{.{ .name = "run_id", .value = "run_res_apply_1" }});
        defer r.deinit();
        try expectJson(&r);

        var doc = try r.json();
        defer doc.deinit();
        const res0 = try firstOf(&doc, "results");
        try testing.expectEqual(true, switch (res0.get("applied") orelse {
            std.debug.print("result row has no `applied`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }) {
            .bool => |b| b,
            else => {
                std.debug.print("`applied` is not a bool: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            },
        });
        try testing.expectEqualStrings("edit", try strField(res0, "apply_action"));
    }
}

// ============================================================================
// Test 12: a stale verdict is a 409
// ============================================================================

// A verdict whose body moved on is not applicable.
test "apply_on_a_stale_result_is_409" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try seedResult(&h, "res_stale_1", "update");
    try markResultStale(&h, "res_stale_1");

    var r = try h.http(io, .POST, "/api/skill-evals/results/apply", .{
        .params = &.{.{ .name = "result_id", .value = "res_stale_1" }},
        .expect = &.{409},
    });
    defer r.deinit();
}

// The helpers exist for their callers, not for the reader: a function body is
// never type-checked until something references it, so an unreferenced helper
// is where a stdlib rename hides until the day a test needs it.
comptime {
    _ = getRuns;
    _ = strField;
    _ = firstOf;
    _ = countFor;
    _ = bodyHas;
    _ = expectJson;
    _ = seedResult;
    _ = markResultStale;
    _ = sqlLit;
    _ = sqliteRun;
    _ = dbPath;
    _ = requireSqlite3Cli;
    _ = exitCode;
}
