const std = @import("std");
const testing = std.testing;

pub const MAX_HEADER_CHARS = 40;
pub const MIN_OPTIONS = 2;
pub const MAX_OPTIONS = 6;

pub const NAME = "ask_user";

pub const MARKER_OPEN = "<ask_user>";
pub const MARKER_CLOSE = "</ask_user>";

pub const AskUserInput = struct {
    question: []const u8 = "",
    header: []const u8 = "",
    options: []const []const u8 = &.{},
    allow_free_text: ?bool = null,
    multi_select: ?bool = null,
    recommended: []const u8 = "",
};

pub const ValidationError = error{
    MissingQuestion,
    HeaderTooLong,
    EmptyOption,
    TooFewOptions,
    TooManyOptions,
    RecommendedNotAnOption,
    MultiSelectWithoutOptions,
};

pub fn validateAskUserInput(input: AskUserInput) ValidationError!void {
    if (std.mem.trim(u8, input.question, " \t\r\n").len == 0) return error.MissingQuestion;
    if (input.header.len > MAX_HEADER_CHARS) return error.HeaderTooLong;

    const multi = input.multi_select orelse false;

    if (input.options.len == 0) {
        if (multi) return error.MultiSelectWithoutOptions;
    } else if (input.options.len < MIN_OPTIONS) {
        return error.TooFewOptions;
    } else if (input.options.len > MAX_OPTIONS) {
        return error.TooManyOptions;
    }

    for (input.options) |opt| {
        if (std.mem.trim(u8, opt, " \t\r\n").len == 0) return error.EmptyOption;
    }

    if (input.recommended.len > 0) {
        var found = false;
        for (input.options) |opt| {
            if (std.mem.eql(u8, opt, input.recommended)) {
                found = true;
                break;
            }
        }
        if (!found) return error.RecommendedNotAnOption;
    }
}

pub const Status = enum {
    pending,
    answered,
    skipped,
    abandoned,
    unavailable,

    pub fn to_str(self: Status) []const u8 {
        return switch (self) {
            .pending => "pending",
            .answered => "answered",
            .skipped => "skipped",
            .abandoned => "abandoned",
            .unavailable => "unavailable",
        };
    }

    pub fn from_str(s: []const u8) ?Status {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "answered")) return .answered;
        if (std.mem.eql(u8, s, "skipped")) return .skipped;
        if (std.mem.eql(u8, s, "abandoned")) return .abandoned;
        if (std.mem.eql(u8, s, "unavailable")) return .unavailable;
        return null;
    }
};

pub fn instructionFor(status: Status) []const u8 {
    return switch (status) {
        .pending => "The human has been asked and this turn is ending. Do not continue and do not guess — you will be resumed with their answer.",
        .answered => "",
        .skipped => "The human declined to answer. Do not guess. State what you are blocked on and stop this line of work.",
        .abandoned => "The human moved on without answering. Do not guess. If the answer is still needed, ask again once.",
        .unavailable => "No human is available. Choose the most reasonable option yourself, state the assumption explicitly, and continue.",
    };
}

pub const AskUserJson = struct {
    status: Status,
    question_id: []const u8 = "",
    question: []const u8 = "",
    answer: []const u8 = "",
    answers_count: usize = 0,
    header: []const u8 = "",
    options: []const []const u8 = &.{},
    allow_free_text: ?bool = null,
    multi_select: ?bool = null,
    recommended: []const u8 = "",
};

pub fn buildAskUserJson(allocator: std.mem.Allocator, json: AskUserJson) ![]u8 {
    const instruction = instructionFor(json.status);
    return std.json.Stringify.valueAlloc(allocator, .{
        .status = json.status.to_str(),
        .question_id = if (json.question_id.len > 0) @as(?[]const u8, json.question_id) else null,
        .question = if (json.question.len > 0) @as(?[]const u8, json.question) else null,
        .answer = if (json.status == .answered and json.answer.len > 0) @as(?[]const u8, json.answer) else null,
        .answers_count = if (json.status == .answered) @as(?usize, json.answers_count) else null,
        .header = if (json.header.len > 0) @as(?[]const u8, json.header) else null,
        .allow_free_text = json.allow_free_text,
        .multi_select = json.multi_select,
        .recommended = if (json.recommended.len > 0) @as(?[]const u8, json.recommended) else null,
        .options = json.options,
        .instruction = if (instruction.len > 0) @as(?[]const u8, instruction) else null,
    }, .{});
}

pub fn validationErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingQuestion => "question is required and must not be blank",
        error.HeaderTooLong => "header must be 40 characters or fewer",
        error.EmptyOption => "every option must be a non-blank string",
        error.TooFewOptions => "options must contain at least 2 entries (or be omitted for a free-text-only question)",
        error.TooManyOptions => "options must contain at most 6 entries",
        error.RecommendedNotAnOption => "recommended must exactly match one of the strings in options",
        error.MultiSelectWithoutOptions => "multi_select requires at least 2 options",
        else => "invalid ask_user input",
    };
}

pub const Span = struct { start: usize, end: usize };

pub fn findSpan(content: []const u8) ?Span {
    const close = std.mem.lastIndexOf(u8, content, MARKER_CLOSE) orelse return null;
    const open = std.mem.lastIndexOf(u8, content[0..close], MARKER_OPEN) orelse return null;
    return .{ .start = open, .end = close + MARKER_CLOSE.len };
}

pub const Detection = struct {
    parsed: std.json.Parsed(AskUserInput),
    span: Span,

    pub fn deinit(self: Detection) void {
        self.parsed.deinit();
    }

    pub fn question(self: Detection) AskUserInput {
        return self.parsed.value;
    }
};

pub fn detect(allocator: std.mem.Allocator, content: []const u8) ?Detection {
    const span = findSpan(content) orelse return null;
    const body = content[span.start + MARKER_OPEN.len .. span.end - MARKER_CLOSE.len];
    const parsed = std.json.parseFromSlice(AskUserInput, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    validateAskUserInput(parsed.value) catch {
        parsed.deinit();
        return null;
    };
    return .{ .parsed = parsed, .span = span };
}

const ResolvedBlock = struct {
    status: []const u8 = "",
    question: []const u8 = "",
    answer: []const u8 = "",
};

/// The resolved shape of the same `<ask_user>` marker: `detect` parses the
/// question the model writes, this parses the block the answer endpoint
/// rewrites in place.
pub const Resolution = struct {
    parsed: std.json.Parsed(ResolvedBlock),

    pub fn deinit(self: Resolution) void {
        self.parsed.deinit();
    }

    pub fn status(self: Resolution) Status {
        return Status.from_str(self.parsed.value.status) orelse .pending;
    }

    pub fn question(self: Resolution) []const u8 {
        return self.parsed.value.question;
    }

    pub fn answer(self: Resolution) []const u8 {
        return self.parsed.value.answer;
    }
};

pub fn resolution(allocator: std.mem.Allocator, content: []const u8) ?Resolution {
    const span = findSpan(content) orelse return null;
    const body = content[span.start + MARKER_OPEN.len .. span.end - MARKER_CLOSE.len];
    const parsed = std.json.parseFromSlice(ResolvedBlock, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    const status = Status.from_str(parsed.value.status) orelse {
        parsed.deinit();
        return null;
    };
    if (status == .pending) {
        parsed.deinit();
        return null;
    }
    return .{ .parsed = parsed };
}

/// Without this turn the transcript ends on the model's own assistant message,
/// and the provider continues that message instead of starting a new one.
pub fn resolvedTurn(allocator: std.mem.Allocator, res: Resolution) ![]u8 {
    return switch (res.status()) {
        .answered => if (res.question().len > 0)
            std.fmt.allocPrint(allocator, "The human answered your question.\nQuestion: {s}\nAnswer: {s}", .{ res.question(), res.answer() })
        else
            std.fmt.allocPrint(allocator, "The human answered your question: {s}", .{res.answer()}),
        .skipped => allocator.dupe(u8, instructionFor(.skipped)),
        .abandoned => allocator.dupe(u8, instructionFor(.abandoned)),
        .unavailable => allocator.dupe(u8, instructionFor(.unavailable)),
        .pending => allocator.dupe(u8, ""),
    };
}

fn trimEndCopy(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    return allocator.dupe(u8, std.mem.trimEnd(u8, s, " \t\r\n"));
}

pub fn strip(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const span = findSpan(content) orelse return trimEndCopy(allocator, content);
    const head = content[0..span.start];
    const tail = content[span.end..];
    const combined = try allocator.alloc(u8, head.len + tail.len);
    defer allocator.free(combined);
    @memcpy(combined[0..head.len], head);
    @memcpy(combined[head.len..], tail);
    return trimEndCopy(allocator, combined);
}

const a = testing.allocator;

test "a message with no block yields no question" {
    try testing.expect(detect(a, "Which environment? Just tell me.") == null);
    try testing.expect(detect(a, "") == null);
}

test "a trailing block yields the question it describes" {
    const content =
        \\I need one thing before I deploy.
        \\<ask_user>{"header":"Deploy target","question":"Which environment?","options":["staging","production"],"recommended":"staging"}</ask_user>
    ;
    const found = detect(a, content).?;
    defer found.deinit();
    const q = found.question();
    try testing.expectEqualStrings("Which environment?", q.question);
    try testing.expectEqualStrings("Deploy target", q.header);
    try testing.expectEqualStrings("staging", q.recommended);
    try testing.expectEqual(@as(usize, 2), q.options.len);
}

test "a block that fails validation is ignored" {
    const seven_options =
        \\<ask_user>{"question":"Pick","options":["a","b","c","d","e","f","g"]}</ask_user>
    ;
    try testing.expect(detect(a, seven_options) == null);

    const bad_recommended =
        \\<ask_user>{"question":"Pick","options":["a","b"],"recommended":"c"}</ask_user>
    ;
    try testing.expect(detect(a, bad_recommended) == null);

    const blank_question =
        \\<ask_user>{"question":"   "}</ask_user>
    ;
    try testing.expect(detect(a, blank_question) == null);
}

test "a block that is not JSON is ignored" {
    try testing.expect(detect(a, "<ask_user>not json at all</ask_user>") == null);
    try testing.expect(detect(a, "<ask_user>{</ask_user>") == null);
}

test "only the last block of a message is honoured" {
    const content =
        \\<ask_user>{"question":"first"}</ask_user>
        \\<ask_user>{"question":"second"}</ask_user>
    ;
    const found = detect(a, content).?;
    defer found.deinit();
    try testing.expectEqualStrings("second", found.question().question);
}

test "the block is stripped from the text it was embedded in" {
    const content =
        \\Before.
        \\<ask_user>{"question":"Which environment?"}</ask_user>
        \\After.
    ;
    const out = try strip(a, content);
    defer a.free(out);
    try testing.expectEqualStrings("Before.\n\nAfter.", out);
}

test "stripping a message with no block leaves it untouched" {
    const out = try strip(a, "Just an answer.\n");
    defer a.free(out);
    try testing.expectEqualStrings("Just an answer.", out);
}

test "a question containing the closing marker still parses" {
    const content =
        \\<ask_user>{"question":"Is </ask_user> fine?"}</ask_user>
    ;
    const found = detect(a, content).?;
    defer found.deinit();
    try testing.expectEqualStrings("Is </ask_user> fine?", found.question().question);
}

test "the example in the prompt parses as a valid question" {
    const prompts = @import("../prompts/prompts.zig");
    const found = detect(a, prompts.AskUserRule).?;
    defer found.deinit();
    const q = found.question();
    try testing.expect(q.question.len > 0);
    try testing.expect(q.options.len >= MIN_OPTIONS);
    try testing.expect(q.recommended.len > 0);
}

test "a block the human answered reports its status and answer" {
    const content =
        \\<markdown>
        \\Which mark?
        \\<ask_user>{"status":"answered","question_id":"q_1","question":"Which mark?","answer":"No mark","answers_count":1}</ask_user>
        \\</markdown>
    ;
    const res = resolution(a, content).?;
    defer res.deinit();
    try testing.expectEqual(Status.answered, res.status());
    try testing.expectEqualStrings("Which mark?", res.question());
    try testing.expectEqualStrings("No mark", res.answer());
}

test "a still-pending block is not a resolution" {
    const content =
        \\<ask_user>{"status":"pending","question":"Which mark?","options":["a","b"]}</ask_user>
    ;
    try testing.expect(resolution(a, content) == null);
}

test "a question block with no status is not a resolution" {
    const content =
        \\<ask_user>{"question":"Which mark?","options":["a","b"]}</ask_user>
    ;
    try testing.expect(resolution(a, content) == null);
}

test "a message with no block is not a resolution" {
    try testing.expect(resolution(a, "Just prose.") == null);
    try testing.expect(resolution(a, "") == null);
}

test "an answered question becomes a user turn carrying the answer" {
    const content =
        \\<ask_user>{"status":"answered","question":"Which mark?","answer":"No mark"}</ask_user>
    ;
    const res = resolution(a, content).?;
    defer res.deinit();
    const turn = try resolvedTurn(a, res);
    defer a.free(turn);
    try testing.expect(std.mem.indexOf(u8, turn, "Which mark?") != null);
    try testing.expect(std.mem.indexOf(u8, turn, "No mark") != null);
}

test "a skipped question becomes a user turn that forbids guessing" {
    const content =
        \\<ask_user>{"status":"skipped","question":"Which mark?"}</ask_user>
    ;
    const res = resolution(a, content).?;
    defer res.deinit();
    const turn = try resolvedTurn(a, res);
    defer a.free(turn);
    try testing.expectEqualStrings(instructionFor(.skipped), turn);
}

test "an abandoned question becomes a user turn that forbids guessing" {
    const content =
        \\<ask_user>{"status":"abandoned","question":"Which mark?"}</ask_user>
    ;
    const res = resolution(a, content).?;
    defer res.deinit();
    const turn = try resolvedTurn(a, res);
    defer a.free(turn);
    try testing.expectEqualStrings(instructionFor(.abandoned), turn);
}
