const std = @import("std");

pub const Role = enum {
    lead,
    worker,

    pub fn fromText(text: []const u8) Role {
        return if (std.ascii.eqlIgnoreCase(text, "lead")) .lead else .worker;
    }

    pub fn toText(self: Role) []const u8 {
        return switch (self) {
            .lead => "lead",
            .worker => "worker",
        };
    }
};

pub const Member = struct {
    name: []const u8,
    role: Role = .worker,
};

pub const CloseReason = enum {
    no_members,
    hop_budget,
    lead_finished,
};

pub const Decision = union(enum) {
    speak: []const u8,
    close: CloseReason,
};

pub const Turn = struct {
    /// The agent whose row is the newest in the thread. Empty when the newest
    /// row is the human's, because then nobody has spoken yet.
    last_speaker: []const u8,
    last_text: []const u8,
    hops_so_far: u32,
    hop_budget: u32,
};

/// The agent a turn with no mention belongs to. An explicit lead wins; failing
/// that the first member that calls itself the lead; failing that the first
/// member. Null only when the roster is empty.
pub fn leadOf(members: []const Member, explicit_lead: []const u8) ?[]const u8 {
    if (explicit_lead.len > 0) {
        for (members) |m| {
            if (std.mem.eql(u8, m.name, explicit_lead)) return m.name;
        }
    }
    for (members) |m| {
        if (m.role == .lead) return m.name;
    }
    if (members.len == 0) return null;
    return members[0].name;
}

/// The token a mention uses in text: `Security Engineerr` becomes
/// `security-engineerr`, so a member whose name carries a space stays
/// addressable as one word.
pub fn slug(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var pending_dash = false;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_dash and out.items.len > 0) try out.append(allocator, '-');
            pending_dash = false;
            try out.append(allocator, std.ascii.toLower(c));
        } else {
            pending_dash = true;
        }
    }
    return out.toOwnedSlice(allocator);
}

const Match = struct {
    member: []const u8,
    end: usize,
};

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn matchMemberAt(allocator: std.mem.Allocator, text: []const u8, at: usize, m: Member) !?Match {
    const candidates = [_][]const u8{ m.name, try slug(allocator, m.name) };
    defer allocator.free(candidates[1]);

    var best: ?Match = null;
    for (candidates) |candidate| {
        if (candidate.len == 0) continue;
        if (at + candidate.len > text.len) continue;
        const span = text[at .. at + candidate.len];
        if (!std.ascii.eqlIgnoreCase(span, candidate)) continue;
        const end = at + candidate.len;
        if (end < text.len and isWordChar(text[end])) continue;
        if (best == null or end > best.?.end) best = .{ .member = m.name, .end = end };
    }
    return best;
}

/// Every member the text addresses, in the order the mentions appear, each one
/// once. An `@` inside a word (`you@mail.example`) is not a mention. The slice
/// is owned by the caller; its strings point into `members`.
pub fn mentions(allocator: std.mem.Allocator, text: []const u8, members: []const Member) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    errdefer found.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '@' or (i > 0 and isWordChar(text[i - 1]))) {
            i += 1;
            continue;
        }

        var best: ?Match = null;
        for (members) |m| {
            const candidate = try matchMemberAt(allocator, text, i + 1, m);
            if (candidate) |c| {
                if (best == null or c.end > best.?.end) best = c;
            }
        }

        const hit = best orelse {
            i += 1;
            continue;
        };

        var seen = false;
        for (found.items) |already| {
            if (already.ptr == hit.member.ptr and already.len == hit.member.len) seen = true;
        }
        if (!seen) try found.append(allocator, hit.member);
        i = hit.end;
    }

    return found.toOwnedSlice(allocator);
}

/// Who speaks next, given the roster and the last row of the thread.
pub fn decide(allocator: std.mem.Allocator, members: []const Member, explicit_lead: []const u8, turn: Turn) !Decision {
    const lead = leadOf(members, explicit_lead) orelse return .{ .close = .no_members };

    if (turn.hops_so_far >= turn.hop_budget) return .{ .close = .hop_budget };

    const addressed = try mentions(allocator, turn.last_text, members);
    defer allocator.free(addressed);

    if (addressed.len > 0) {
        for (addressed) |name| {
            if (!std.mem.eql(u8, name, turn.last_speaker)) return .{ .speak = name };
        }
        if (turn.last_speaker.len > 0 and !std.mem.eql(u8, turn.last_speaker, lead)) {
            return .{ .speak = lead };
        }
        return .{ .close = .lead_finished };
    }

    if (turn.last_speaker.len == 0) return .{ .speak = lead };
    if (!std.mem.eql(u8, turn.last_speaker, lead)) return .{ .speak = lead };
    return .{ .close = .lead_finished };
}

const testing = std.testing;

const roster = [_]Member{
    .{ .name = "Engineer", .role = .lead },
    .{ .name = "Security Engineerr", .role = .worker },
    .{ .name = "Android Engineer", .role = .worker },
    .{ .name = "deepseek auto", .role = .worker },
};

fn turnOf(last_speaker: []const u8, last_text: []const u8) Turn {
    return .{
        .last_speaker = last_speaker,
        .last_text = last_text,
        .hops_so_far = 0,
        .hop_budget = 8,
    };
}

fn expectSpeaks(expected: []const u8, decision: Decision) !void {
    switch (decision) {
        .speak => |name| try testing.expectEqualStrings(expected, name),
        .close => |reason| {
            std.debug.print("expected {s} to speak, the turn closed with {s}\n", .{ expected, @tagName(reason) });
            return error.TurnClosed;
        },
    }
}

fn expectCloses(expected: CloseReason, decision: Decision) !void {
    switch (decision) {
        .speak => |name| {
            std.debug.print("expected the turn to close with {s}, {s} spoke\n", .{ @tagName(expected), name });
            return error.TurnStayedOpen;
        },
        .close => |reason| try testing.expectEqual(expected, reason),
    }
}

test "a human message that mentions nobody opens the turn for the lead" {
    const decision = try decide(testing.allocator, &roster, "Engineer", turnOf("", "Add rate limiting and open a PR."));
    try expectSpeaks("Engineer", decision);
}

test "a mention of a worker hands the turn to that worker" {
    const decision = try decide(testing.allocator, &roster, "Engineer", turnOf("Engineer", "Audit it first, @Android Engineer."));
    try expectSpeaks("Android Engineer", decision);
}

test "a mention written with the reference slug finds the member whose name has a space" {
    const decision = try decide(testing.allocator, &roster, "Engineer", turnOf("Engineer", "Audit it, @security-engineerr."));
    try expectSpeaks("Security Engineerr", decision);
}

test "a mention written with the display name and its space finds the member" {
    const decision = try decide(testing.allocator, &roster, "Engineer", turnOf("Engineer", "@deepseek auto take the retry path"));
    try expectSpeaks("deepseek auto", decision);
}

test "a mention is matched whatever its case" {
    const decision = try decide(testing.allocator, &roster, "Engineer", turnOf("Engineer", "@DEEPSEEK-AUTO handle this"));
    try expectSpeaks("deepseek auto", decision);
}

test "the longest member name wins when one name is a prefix of another" {
    const overlapping = [_]Member{
        .{ .name = "Engineer", .role = .lead },
        .{ .name = "Engineer Two", .role = .worker },
    };
    const decision = try decide(testing.allocator, &overlapping, "Engineer", turnOf("", "@Engineer Two runs the migration"));
    try expectSpeaks("Engineer Two", decision);
}

test "a name that is only a prefix of the mention does not match" {
    const decision = try decide(testing.allocator, &roster, "Engineer", turnOf("", "@Engineers are talking"));
    try expectSpeaks("Engineer", decision);
}

test "an at sign inside a word is not a mention" {
    const decision = try decide(testing.allocator, &roster, "Engineer", turnOf("", "mail me at you@deepseek-auto.example"));
    try expectSpeaks("Engineer", decision);
}

test "an unknown mention is ignored and the lead speaks" {
    const decision = try decide(testing.allocator, &roster, "Engineer", turnOf("", "@nobody do this"));
    try expectSpeaks("Engineer", decision);
}

test "the first of two mentions speaks, so a mention list is a queue" {
    const decision = try decide(testing.allocator, &roster, "Engineer", turnOf("", "@security-engineerr and later @android-engineer"));
    try expectSpeaks("Security Engineerr", decision);
}

test "a worker that mentions nobody hands the turn back to the lead" {
    const decision = try decide(testing.allocator, &roster, "Engineer", turnOf("Security Engineerr", "Three unauthenticated paths, no per-key counter."));
    try expectSpeaks("Engineer", decision);
}

test "a worker that mentions only itself hands the turn back to the lead" {
    const decision = try decide(testing.allocator, &roster, "Engineer", turnOf("Security Engineerr", "@security-engineerr noting for later"));
    try expectSpeaks("Engineer", decision);
}

test "the lead continues when the worker it mentioned answers with a mention of the lead" {
    const decision = try decide(testing.allocator, &roster, "Engineer", turnOf("Security Engineerr", "Done, handing back to @engineer."));
    try expectSpeaks("Engineer", decision);
}

test "a lead that mentions nobody closes the turn" {
    const decision = try decide(testing.allocator, &roster, "Engineer", turnOf("Engineer", "Shipped in PR 412, nothing left open."));
    try expectCloses(.lead_finished, decision);
}

test "the lead mentioning itself closes the turn instead of looping" {
    const decision = try decide(testing.allocator, &roster, "Engineer", turnOf("Engineer", "@engineer will follow up"));
    try expectCloses(.lead_finished, decision);
}

test "the hop budget closes the turn even when a mention asks for more work" {
    var t = turnOf("Security Engineerr", "Over to you @android-engineer");
    t.hops_so_far = 8;
    const decision = try decide(testing.allocator, &roster, "Engineer", t);
    try expectCloses(.hop_budget, decision);
}

test "the hop budget leaves the turn open one hop before it" {
    var t = turnOf("Security Engineerr", "Over to you @android-engineer");
    t.hops_so_far = 7;
    const decision = try decide(testing.allocator, &roster, "Engineer", t);
    try expectSpeaks("Android Engineer", decision);
}

test "an empty roster closes the turn instead of inventing a speaker" {
    const decision = try decide(testing.allocator, &.{}, "", turnOf("", "anybody there"));
    try expectCloses(.no_members, decision);
}

test "a roster with no explicit lead speaks through the member marked lead" {
    try testing.expectEqualStrings("Engineer", leadOf(&roster, "").?);
}

test "a roster whose lead names nobody speaks through the first member" {
    const no_lead = [_]Member{
        .{ .name = "Penelope", .role = .worker },
        .{ .name = "Quill", .role = .worker },
    };
    try testing.expectEqualStrings("Penelope", leadOf(&no_lead, "Nobody").?);
}

test "slug folds a display name into one addressable token" {
    const cases = [_][2][]const u8{
        .{ "Security Engineerr", "security-engineerr" },
        .{ "deepseek auto", "deepseek-auto" },
        .{ "Android  Engineer", "android-engineer" },
        .{ "  spaced  ", "spaced" },
        .{ "Engineer", "engineer" },
    };
    for (cases) |case| {
        const got = try slug(testing.allocator, case[0]);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case[1], got);
    }
}

test "mentions reports each addressed member once, in the order they appear" {
    const names = try mentions(testing.allocator, "@deepseek-auto then @security-engineerr then @deepseek-auto", &roster);
    defer testing.allocator.free(names);

    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("deepseek auto", names[0]);
    try testing.expectEqualStrings("Security Engineerr", names[1]);
}

test "mentions allocates nothing it does not return" {
    const allocator = testing.allocator;
    const names = try mentions(allocator, "@engineer and @android-engineer", &roster);
    allocator.free(names);
}
