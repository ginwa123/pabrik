// Regression tests for the MULTI-`ask_user` stall. Zig port of
// `tests/functional/ask_user_multi_question_test.py` (same test names, same
// order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const ask = @import("ask_user_test.zig");

const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

/// What `_seed_two_questions_in_one_assistant_turn` hands back:
/// `((q1_id, q1_row_id), (q2_id, q2_row_id))`. All four are OWNED.
const Pair = struct {
    question_id: []u8,
    tool_row_id: []u8,

    fn deinit(self: *Pair) void {
        gpa.free(self.question_id);
        gpa.free(self.tool_row_id);
        self.* = undefined;
    }
};

const TwoSeeded = struct {
    q1: Pair,
    q2: Pair,

    fn deinit(self: *TwoSeeded) void {
        self.q1.deinit();
        self.q2.deinit();
        self.* = undefined;
    }
};

/// What `handle_tool` writes when ONE assistant message carries TWO
/// `ask_user` tool calls.
fn seedTwoQuestions(h: *Harness, session_id: []const u8) !TwoSeeded {
    const now_ns = ask.nowNs();

    // ONE assistant row, TWO tool_call ids — the real shape.
    {
        const calls_json = try std.json.Stringify.valueAlloc(gpa, &.{
            ask.ToolCall{ .id = "call_1" },
            ask.ToolCall{ .id = "call_2" },
        }, .{});
        defer gpa.free(calls_json);
        const calls_lit = try ask.sqlLit(calls_json);
        defer gpa.free(calls_lit);
        const sid_lit = try ask.sqlLit(session_id);
        defer gpa.free(sid_lit);
        const sql = try std.fmt.allocPrint(gpa,
            \\INSERT INTO llm_history (id, session_id, model, response_content, role,
            \\    finish_reason, tool_calls_json, tool_call_id, created_at_nano,
            \\    is_feed_to_llm, agent, loop_index, temperature, is_thinking,
            \\    is_input, is_output)
            \\VALUES ('asst_multi', {s}, 'test-model', '', 'assistant', 'tool_calls', {s},
            \\    NULL, {d}, 1, 'Agent', 0, 0.2, 0, 0, 1)
        , .{ sid_lit, calls_lit, now_ns });
        defer gpa.free(sql);
        try ask.execSql(h.temp_dir, sql);
    }

    const specs = [_]struct { call_id: []const u8, qid: []const u8, question: []const u8 }{
        .{ .call_id = "call_1", .qid = "q_1", .question = "Which environment should I deploy to?" },
        .{ .call_id = "call_2", .qid = "q_2", .question = "Which region should I deploy to?" },
    };

    var out: TwoSeeded = undefined;
    var made: usize = 0;
    // `errdefer` so a mid-loop failure still frees the pairs already built.
    errdefer {
        if (made >= 1) out.q1.deinit();
        if (made >= 2) out.q2.deinit();
    }

    for (specs, 0..) |spec, idx| {
        const row_id = try std.fmt.allocPrint(gpa, "row_{s}", .{spec.qid});
        defer gpa.free(row_id);

        {
            const env_json = try ask.toolEnvelopeJson(spec.qid, spec.question);
            defer gpa.free(env_json);
            const env_lit = try ask.sqlLit(env_json);
            defer gpa.free(env_lit);
            const row_lit = try ask.sqlLit(row_id);
            defer gpa.free(row_lit);
            const sid_lit = try ask.sqlLit(session_id);
            defer gpa.free(sid_lit);
            const call_lit = try ask.sqlLit(spec.call_id);
            defer gpa.free(call_lit);
            const sql = try std.fmt.allocPrint(gpa,
                \\INSERT INTO llm_history (id, session_id, model, response_content,
                \\    role, finish_reason, tool_calls_json, tool_call_id, tool_name,
                \\    created_at_nano, is_feed_to_llm, agent, loop_index, temperature,
                \\    is_thinking, is_input, is_output)
                \\VALUES ({s}, {s}, 'test-model', {s}, 'tool', 'tool', '', {s}, 'ask_user', {d},
                \\    1, 'Agent', 0, 0.2, 0, 0, 1)
            , .{ row_lit, sid_lit, env_lit, call_lit, now_ns + @as(i64, @intCast(idx)) + 1 });
            defer gpa.free(sql);
            try ask.execSql(h.temp_dir, sql);
        }

        {
            const qid_lit = try ask.sqlLit(spec.qid);
            defer gpa.free(qid_lit);
            const sid_lit = try ask.sqlLit(session_id);
            defer gpa.free(sid_lit);
            const call_lit = try ask.sqlLit(spec.call_id);
            defer gpa.free(call_lit);
            const row_lit = try ask.sqlLit(row_id);
            defer gpa.free(row_lit);
            const q_lit = try ask.sqlLit(spec.question);
            defer gpa.free(q_lit);
            const sql = try std.fmt.allocPrint(gpa,
                \\INSERT INTO session_pending_question
                \\    (id, session_id, tool_call_id, llm_history_id, question,
                \\     multi_select, status, answer, created_at, resolved_at)
                \\VALUES ({s}, {s}, {s}, {s}, {s}, 0, 'pending', NULL, {d}, NULL)
            , .{ qid_lit, sid_lit, call_lit, row_lit, q_lit, now_ns });
            defer gpa.free(sql);
            try ask.execSql(h.temp_dir, sql);
        }

        const pair: Pair = .{
            .question_id = try gpa.dupe(u8, spec.qid),
            .tool_row_id = try gpa.dupe(u8, row_id),
        };
        if (idx == 0) out.q1 = pair else out.q2 = pair;
        made += 1;
    }
    return out;
}

/// One question, one assistant row — the N == 1 regression guard.
fn seedOneQuestion(h: *Harness, session_id: []const u8) !ask.Seeded {
    const now_ns = ask.nowNs();

    {
        const calls_json = try std.json.Stringify.valueAlloc(
            gpa,
            &.{ask.ToolCall{ .id = "call_solo" }},
            .{},
        );
        defer gpa.free(calls_json);
        const calls_lit = try ask.sqlLit(calls_json);
        defer gpa.free(calls_lit);
        const sid_lit = try ask.sqlLit(session_id);
        defer gpa.free(sid_lit);
        const sql = try std.fmt.allocPrint(gpa,
            \\INSERT INTO llm_history (id, session_id, model, response_content, role,
            \\    finish_reason, tool_calls_json, tool_call_id, created_at_nano,
            \\    is_feed_to_llm, agent, loop_index, temperature, is_thinking,
            \\    is_input, is_output)
            \\VALUES ('asst_solo', {s}, 'test-model', '', 'assistant', 'tool_calls', {s},
            \\    NULL, {d}, 1, 'Agent', 0, 0.2, 0, 0, 1)
        , .{ sid_lit, calls_lit, now_ns });
        defer gpa.free(sql);
        try ask.execSql(h.temp_dir, sql);
    }

    return ask.seedQuestion(h, session_id, "q_solo", "call_solo", "Which environment?");
}

/// An owned list of the session's still-pending question ids, in
/// `created_at ASC` order.
const PendingIds = struct {
    items: [][]u8,

    fn deinit(self: *PendingIds) void {
        for (self.items) |id| gpa.free(id);
        gpa.free(self.items);
        self.* = undefined;
    }
};

fn pendingIds(temp_dir: []const u8, session_id: []const u8) !PendingIds {
    const lit = try ask.sqlLit(session_id);
    defer gpa.free(lit);
    const sql = try std.fmt.allocPrint(
        gpa,
        "SELECT id FROM session_pending_question WHERE session_id = {s} AND status = 'pending' ORDER BY created_at ASC",
        .{lit},
    );
    defer gpa.free(sql);

    const out = try ask.sqliteRun(temp_dir, sql);
    defer gpa.free(out);
    var parsed = try ask.parseSqliteJson(out);
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    var items: [][]u8 = &.{};
    errdefer {
        for (items) |id| gpa.free(id);
        gpa.free(items);
    }
    for (arr.items) |item| {
        const o = switch (item) {
            .object => |m| m,
            else => continue,
        };
        const id = switch (o.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        items = try gpa.realloc(items, items.len + 1);
        items[items.len - 1] = try gpa.dupe(u8, id);
    }
    return .{ .items = items };
}

/// Assert the session's pending set is EXACTLY `want`, in order. Python's `==
/// [q1, q2]` is a list equality; there is no `std.json.Value` analogue for
/// that, so the length plus the order are compared directly.
fn expectPendingIds(temp_dir: []const u8, session_id: []const u8, want: []const []const u8) !void {
    var got = try pendingIds(temp_dir, session_id);
    defer got.deinit();

    if (got.items.len != want.len) {
        std.debug.print("expected {d} pending question(s), got {d}\n", .{ want.len, got.items.len });
        return error.TestUnexpectedResult;
    }
    for (got.items, want) |actual, expected| {
        if (!std.mem.eql(u8, actual, expected)) {
            std.debug.print("pending question mismatch: got {s}, want {s}\n", .{ actual, expected });
            return error.TestUnexpectedResult;
        }
    }
}

/// `_llm_row_count` — how many transcript rows exist. An LLM call ADDS at
/// least one row (the assistant row it streams back), so a flat count across
/// a resume window proves the run never reached the provider.
fn llmRowCount(temp_dir: []const u8, session_id: []const u8) !i64 {
    const lit = try ask.sqlLit(session_id);
    defer gpa.free(lit);
    const sql = try std.fmt.allocPrint(
        gpa,
        "SELECT COUNT(*) AS n FROM llm_history WHERE session_id = {s}",
        .{lit},
    );
    defer gpa.free(sql);
    return ask.scalarCount(temp_dir, sql);
}

/// `_queued_message_count`.
fn queuedMessageCount(temp_dir: []const u8, session_id: []const u8) !i64 {
    const lit = try ask.sqlLit(session_id);
    defer gpa.free(lit);
    const sql = try std.fmt.allocPrint(
        gpa,
        "SELECT COUNT(*) AS n FROM session_queue_messages WHERE session_id = {s}",
        .{lit},
    );
    defer gpa.free(sql);
    return ask.scalarCount(temp_dir, sql);
}

/// `_answer(...)` — POST one answer and return the parsed response body. The
/// `Response` is consumed and freed here, so nothing borrows across the
/// return: the caller gets an OWNING `harness.Json`.
fn answerJson(h: *Harness, session_id: []const u8, question_id: []const u8, answer: []const u8) !harness.Json {
    var r = try ask.postAnswer(h, session_id, .{
        .question_id = question_id,
        .answer = answer,
    }, &.{200});
    defer r.deinit();
    return r.json();
}

fn expectCount(got: i64, want: i64, what: []const u8) !void {
    if (got != want) {
        std.debug.print("{s}: expected {d}, got {d}\n", .{ what, want, got });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Tests
// ============================================================================

// Control: the two-question shape is seedable and both rows are live. Without
// this the other tests could pass for the wrong reason (e.g. the second
// question silently deduplicated onto the first).
test "two_pending_questions_are_seeded_and_independent" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try ask.requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try ask.createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);
    var seeded = try seedTwoQuestions(&h, session_id);
    defer seeded.deinit();

    if (std.mem.eql(u8, seeded.q1.tool_row_id, seeded.q2.tool_row_id)) {
        std.debug.print("the two questions share a tool row: {s}\n", .{seeded.q1.tool_row_id});
        return error.TestUnexpectedResult;
    }
    try expectPendingIds(h.temp_dir, session_id, &.{ seeded.q1.question_id, seeded.q2.question_id });

    {
        const c1 = try ask.toolRowContent(h.temp_dir, seeded.q1.tool_row_id);
        defer gpa.free(c1);
        try ask.wantContains(c1, "\"status\":\"pending\"");
        const needle = try std.fmt.allocPrint(gpa, "\"question_id\":\"{s}\"", .{seeded.q1.question_id});
        defer gpa.free(needle);
        try ask.wantContains(c1, needle);
    }
    {
        const c2 = try ask.toolRowContent(h.temp_dir, seeded.q2.tool_row_id);
        defer gpa.free(c2);
        try ask.wantContains(c2, "\"status\":\"pending\"");
        const needle = try std.fmt.allocPrint(gpa, "\"question_id\":\"{s}\"", .{seeded.q2.question_id});
        defer gpa.free(needle);
        try ask.wantContains(c2, needle);
    }
}

// The regression. Answering Q1 must NOT start a run.
test "answering_the_first_of_two_defers_the_resume" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try ask.requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try ask.createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);
    var seeded = try seedTwoQuestions(&h, session_id);
    defer seeded.deinit();

    const before = try llmRowCount(h.temp_dir, session_id);

    var body = try answerJson(&h, session_id, seeded.q1.question_id, "staging");
    defer body.deinit();

    if (!std.mem.eql(u8, try ask.wantStr(&body, "status"), "answered")) {
        std.debug.print("expected status=answered\n", .{});
        return error.TestUnexpectedResult;
    }
    // The answer is still committed — deferring the resume must not lose it.
    {
        const c1 = try ask.toolRowContent(h.temp_dir, seeded.q1.tool_row_id);
        defer gpa.free(c1);
        try ask.wantContains(c1, "\"status\":\"answered\"");
    }
    try ask.expectQuestionStatus(h.temp_dir, seeded.q1.question_id, "answered");

    // …but NO run was started, and the card is told how many are left so the
    // UI can say "1 of 2 answered" instead of showing a dead turn.
    if (try ask.wantBool(&body, "resumed")) {
        std.debug.print("answering Q1 must NOT resume the run\n", .{});
        return error.TestUnexpectedResult;
    }
    try expectCount(try ask.wantInt(&body, "questions_remaining"), 1, "questions_remaining");

    ask.sleepMs(2_000);
    if (try ask.workerExists(h.temp_dir, session_id)) {
        std.debug.print("a doomed run was started\n", .{});
        return error.TestUnexpectedResult;
    }
    try expectCount(try llmRowCount(h.temp_dir, session_id), before, "llm_history row count");

    // Q2 is untouched and still owed.
    try ask.expectQuestionStatus(h.temp_dir, seeded.q2.question_id, "pending");
    try expectPendingIds(h.temp_dir, session_id, &.{seeded.q2.question_id});
}

// The positive half: the LAST answer resumes, and the model reads both. This
// is what the old code failed to do for the first answer — it now happens
// once, at the end, instead of never.
test "answering_the_last_question_resumes_once_with_both_answers" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try ask.requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try ask.createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);
    var seeded = try seedTwoQuestions(&h, session_id);
    defer seeded.deinit();

    {
        var first = try answerJson(&h, session_id, seeded.q1.question_id, "staging");
        defer first.deinit();
        if (try ask.wantBool(&first, "resumed")) {
            std.debug.print("the FIRST answer must not resume\n", .{});
            return error.TestUnexpectedResult;
        }
        try expectCount(try ask.wantInt(&first, "questions_remaining"), 1, "questions_remaining");
    }

    {
        var second = try answerJson(&h, session_id, seeded.q2.question_id, "eu-west-1");
        defer second.deinit();
        if (!std.mem.eql(u8, try ask.wantStr(&second, "status"), "answered")) {
            std.debug.print("expected status=answered\n", .{});
            return error.TestUnexpectedResult;
        }
        try expectCount(try ask.wantInt(&second, "questions_remaining"), 0, "questions_remaining");
        if (!try ask.wantBool(&second, "resumed")) {
            std.debug.print("the LAST answer must resume exactly once\n", .{});
            return error.TestUnexpectedResult;
        }
    }

    // Both answers are in the transcript the model is about to be given.
    {
        const c1 = try ask.toolRowContent(h.temp_dir, seeded.q1.tool_row_id);
        defer gpa.free(c1);
        try ask.wantContains(c1, "\"answer\":\"staging\"");
    }
    {
        const c2 = try ask.toolRowContent(h.temp_dir, seeded.q2.tool_row_id);
        defer gpa.free(c2);
        try ask.wantContains(c2, "\"answer\":\"eu-west-1\"");
    }
    try expectPendingIds(h.temp_dir, session_id, &.{});

    if (!try ask.waitForWorker(h.temp_dir, session_id, 8_000)) {
        std.debug.print("the last answer did not start a run\n", .{});
        return error.TestUnexpectedResult;
    }
}

// Answering Q2 first must defer exactly like answering Q1 first. The old
// stall was reachable from the second POST whichever question it was, because
// the guard is session-scoped, not question-scoped.
test "the_answer_order_does_not_matter" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try ask.requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try ask.createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);
    var seeded = try seedTwoQuestions(&h, session_id);
    defer seeded.deinit();

    {
        var second_first = try answerJson(&h, session_id, seeded.q2.question_id, "eu-west-1");
        defer second_first.deinit();
        if (try ask.wantBool(&second_first, "resumed")) {
            std.debug.print("answering Q2 first must NOT resume\n", .{});
            return error.TestUnexpectedResult;
        }
        try expectCount(try ask.wantInt(&second_first, "questions_remaining"), 1, "questions_remaining");
    }
    ask.sleepMs(1_500);
    if (try ask.workerExists(h.temp_dir, session_id)) {
        std.debug.print("a doomed run was started\n", .{});
        return error.TestUnexpectedResult;
    }

    {
        var last = try answerJson(&h, session_id, seeded.q1.question_id, "staging");
        defer last.deinit();
        if (!try ask.wantBool(&last, "resumed")) {
            std.debug.print("the LAST answer must resume\n", .{});
            return error.TestUnexpectedResult;
        }
        try expectCount(try ask.wantInt(&last, "questions_remaining"), 0, "questions_remaining");
    }
    {
        const c1 = try ask.toolRowContent(h.temp_dir, seeded.q1.tool_row_id);
        defer gpa.free(c1);
        try ask.wantContains(c1, "\"answer\":\"staging\"");
    }
    try expectPendingIds(h.temp_dir, session_id, &.{});
}

// N == 1 must be untouched — the common path cannot afford a regression.
// `questions_remaining` is the new signal the fix branches on, so an
// off-by-one there would silently stop every ordinary question from resuming.
test "a_single_question_still_resumes_immediately" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try ask.requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try ask.createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);
    var seeded = try seedOneQuestion(&h, session_id);
    defer seeded.deinit();

    var body = try answerJson(&h, session_id, seeded.question_id, "staging");
    defer body.deinit();

    if (!std.mem.eql(u8, try ask.wantStr(&body, "status"), "answered")) {
        std.debug.print("expected status=answered\n", .{});
        return error.TestUnexpectedResult;
    }
    try expectCount(try ask.wantInt(&body, "questions_remaining"), 0, "questions_remaining");
    if (!try ask.wantBool(&body, "resumed")) {
        std.debug.print("a lone question must resume immediately\n", .{});
        return error.TestUnexpectedResult;
    }
    {
        const c1 = try ask.toolRowContent(h.temp_dir, seeded.tool_row_id);
        defer gpa.free(c1);
        try ask.wantContains(c1, "\"status\":\"answered\"");
    }
    if (!try ask.waitForWorker(h.temp_dir, session_id, 8_000)) {
        std.debug.print("a single question did not start a run\n", .{});
        return error.TestUnexpectedResult;
    }
}

// Skip is a resolution like any other, so it must defer identically.
// Otherwise "skip question 1" would start the doomed run that "answer
// question 1" no longer does.
test "skipping_one_of_two_also_defers_the_resume" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try ask.requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try ask.createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);
    var seeded = try seedTwoQuestions(&h, session_id);
    defer seeded.deinit();

    {
        var skipped = try ask.postAnswer(&h, session_id, .{
            .question_id = seeded.q1.question_id,
            .skip = true,
        }, &.{200});
        defer skipped.deinit();
        var doc = try skipped.json();
        defer doc.deinit();
        if (!std.mem.eql(u8, try ask.wantStr(&doc, "status"), "skipped")) {
            std.debug.print("expected status=skipped\n", .{});
            return error.TestUnexpectedResult;
        }
        if (try ask.wantBool(&doc, "resumed")) {
            std.debug.print("skipping Q1 must NOT resume\n", .{});
            return error.TestUnexpectedResult;
        }
        try expectCount(try ask.wantInt(&doc, "questions_remaining"), 1, "questions_remaining");
    }
    ask.sleepMs(1_500);
    if (try ask.workerExists(h.temp_dir, session_id)) {
        std.debug.print("a doomed run was started\n", .{});
        return error.TestUnexpectedResult;
    }

    {
        var last = try answerJson(&h, session_id, seeded.q2.question_id, "eu-west-1");
        defer last.deinit();
        if (!try ask.wantBool(&last, "resumed")) {
            std.debug.print("the LAST answer must resume\n", .{});
            return error.TestUnexpectedResult;
        }
    }
    try expectCount(try queuedMessageCount(h.temp_dir, session_id), 0, "session_queue_messages count");
}

// The stall itself: nothing may be left holding an undelivered answer. The
// old failure mode was an answer committed with `resumed:false` and no run,
// queue, or retry left to deliver it.
test "a_deferred_answer_is_never_stranded" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try ask.requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try ask.createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);
    var seeded = try seedTwoQuestions(&h, session_id);
    defer seeded.deinit();

    {
        var a = try answerJson(&h, session_id, seeded.q1.question_id, "staging");
        defer a.deinit();
    }
    {
        var b = try answerJson(&h, session_id, seeded.q2.question_id, "eu-west-1");
        defer b.deinit();
    }

    try expectPendingIds(h.temp_dir, session_id, &.{});
    try expectCount(try queuedMessageCount(h.temp_dir, session_id), 0, "session_queue_messages count");
    {
        const c1 = try ask.toolRowContent(h.temp_dir, seeded.q1.tool_row_id);
        defer gpa.free(c1);
        try ask.wantContains(c1, "\"answer\":\"staging\"");
        try ask.wantAbsent(c1, "\"status\":\"pending\"");
    }
    {
        const c2 = try ask.toolRowContent(h.temp_dir, seeded.q2.tool_row_id);
        defer gpa.free(c2);
        try ask.wantContains(c2, "\"answer\":\"eu-west-1\"");
        try ask.wantAbsent(c2, "\"status\":\"pending\"");
    }
    // The model must never be handed a `pending` envelope it could guess at.
    if (!try ask.waitForWorker(h.temp_dir, session_id, 8_000)) {
        std.debug.print("neither answer delivered the turn\n", .{});
        return error.TestUnexpectedResult;
    }
}

// The frontend has to learn the count from the response, not a list route.
test "no_endpoint_lists_the_remaining_questions" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try ask.requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try ask.createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);
    var seeded = try seedTwoQuestions(&h, session_id);
    defer seeded.deinit();

    for ([_][]const u8{ "question", "questions", "pending_question" }) |suffix| {
        const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/{s}", .{ session_id, suffix });
        defer gpa.free(path);
        var r = try h.http(io, .GET, path, .{ .expect = &.{ 200, 404, 405 } });
        defer r.deinit();
        if (r.status != 404 and r.status != 405) {
            std.debug.print("{s} unexpectedly answered {d}: {s}\n", .{ path, r.status, r.body });
            return error.TestUnexpectedResult;
        }
    }
}

// Body-analysis barrier: an unreferenced helper is never type-checked, so a
// stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = seedTwoQuestions;
    _ = seedOneQuestion;
    _ = pendingIds;
    _ = expectPendingIds;
    _ = llmRowCount;
    _ = queuedMessageCount;
    _ = answerJson;
    _ = expectCount;
    _ = Pair.deinit;
    _ = TwoSeeded.deinit;
    _ = PendingIds.deinit;
    _ = ask.seedQuestion;
    _ = ask.toolRowContent;
    _ = Harness.boot;
}
