//! The compaction envelope: the single JSON message that replaces a session's
//! dropped history. Every field except `summary` is read straight from the DB,
//! so a handoff needs no model call and cannot fail on one.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const llm_history = @import("llm_history.zig");
const session_plan_mod = pabrikcore.session_plan;
const git_state_mod = @import("git_state.zig");
const AgentMessage = pabrikcore.agent.AgentMessage;

const timestampIso = pabrikcore.loggermod.timestampIso;

pub const FORMAT_VERSION: u32 = 2;
pub const MAX_USER_TURNS: usize = 100;
pub const MAX_USER_CONTENT_CHARS: usize = 2000;
pub const MAX_SKILLS: usize = 50;
pub const MAX_SKILL_CONTENT_CHARS: usize = 10_000;
pub const MAX_INDEX_ENTRIES: usize = 50;
pub const PREVIEW_CHARS: usize = 100;
pub const TAIL_ENTRIES: usize = 6;
pub const TAIL_PREVIEW_CHARS: usize = 4000;

/// Every envelope begins with this, which is how a reader recognises one.
pub const ENVELOPE_PREFIX = "{\"compact_messages\"";

pub const UserTurn = struct {
    content: []const u8,
    created_at: []const u8,

    pub fn deinit(self: UserTurn, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        allocator.free(self.created_at);
    }
};

pub const RecentActivity = struct {
    description: []const u8,
    created_at: []const u8,

    pub fn deinit(self: RecentActivity, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
        allocator.free(self.created_at);
    }
};

/// One read_file tool-result row. `path` is the value of the `<path>` tag in
/// that row's own output envelope.
pub const ReadFileTurn = struct {
    path: []const u8,
    raw_content: []const u8,
    created_at: []const u8,

    pub fn deinit(self: ReadFileTurn, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.raw_content);
        allocator.free(self.created_at);
    }
};

pub const Plan = struct {
    updated_at: ?[]const u8,
    markdown: []const u8,
};

pub const DirtyFile = struct {
    status: []const u8,
    path: []const u8,
};

pub const WorkingDirectory = struct {
    active_dir: []const u8,
    session_cwd: []const u8,
    git_worktree_cwd: []const u8,
    is_git_repo: bool,
    worktree_root: ?[]const u8,
    repo_root: ?[]const u8,
    is_linked_worktree: bool,
    branch: ?[]const u8,
    head: ?[]const u8,
    dirty_total: usize,
    dirty_files: []const DirtyFile,
};

pub const Metadata = struct {
    session_id: []const u8,
    model: []const u8,
    compacted_at: []const u8,
    original_count: usize,
};

pub const Turn = struct {
    created_at: []const u8,
    content: []const u8,
};

pub const ReadFile = struct {
    path: []const u8,
    abs: []const u8,
};

pub const Activity = struct {
    created_at: []const u8,
    description: []const u8,
};

pub const Skill = struct {
    name: []const u8,
    loaded_at: ?i64,
    content: []const u8,
};

pub const IndexEntry = struct {
    id: []const u8,
    role: []const u8,
    tool_call_id: ?[]const u8,
    preview: []const u8,
};

pub const TruncatedEntries = struct {
    count: usize,
    note: []const u8,
};

/// Field order is the order the next agent reads them in, so `plan` sits
/// immediately after the metadata: its own task state comes before any
/// background material.
pub const Payload = struct {
    format_version: u32,
    metadata: Metadata,
    plan: ?Plan,
    working_directory: WorkingDirectory,
    user_history: []const Turn,
    read_files: []const ReadFile,
    recent_activities: []const Activity,
    session_skills: []const Skill,
    summary: ?[]const u8,
    message_index: []const IndexEntry,
    truncated_entries: ?TruncatedEntries,
};

pub const Envelope = struct {
    compact_messages: Payload,
};

pub const Input = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session_id: []const u8,
    model: []const u8,
    /// Messages the envelope replaces, excluding the system prompt.
    dropped_messages: []const AgentMessage,
    /// Size of the message list before compaction, system prompt included.
    original_count: usize,
    plan: ?session_plan_mod.PlanRow = null,
    session_cwd: []const u8 = "",
    git_worktree_cwd: []const u8 = "",
    git_state: ?git_state_mod.GitState = null,
    user_turns: []const UserTurn = &.{},
    read_files: []const ReadFileTurn = &.{},
    recent_activities: []const RecentActivity = &.{},
    session_skills: []const llm_history.SkillInfo = &.{},
    /// Compactor output. `null` — the default — means no summarization ran.
    summary: ?[]const u8 = null,
};

/// Serialize the handoff envelope. Returns a heap-allocated JSON document the
/// caller owns.
pub fn build(input: Input) ![]u8 {
    const allocator = input.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const now_iso = try timestampIso(allocator, input.io);
    defer allocator.free(now_iso);

    const active_dir = if (input.git_worktree_cwd.len > 0) input.git_worktree_cwd else input.session_cwd;

    const payload = Payload{
        .format_version = FORMAT_VERSION,
        .metadata = .{
            .session_id = try safe(arena, input.session_id),
            .model = try safe(arena, input.model),
            .compacted_at = try safe(arena, now_iso),
            .original_count = input.original_count,
        },
        .plan = if (input.plan) |plan| .{
            .updated_at = if (plan.updated_at.len > 0) try safe(arena, plan.updated_at) else null,
            .markdown = try safe(arena, plan.plan_md),
        } else null,
        .working_directory = try buildWorkingDirectory(arena, input, active_dir),
        .user_history = try buildUserHistory(arena, input.user_turns),
        .read_files = try buildReadFiles(arena, input.read_files, active_dir),
        .recent_activities = try buildActivities(arena, input.recent_activities),
        .session_skills = try buildSkills(arena, input.session_skills),
        .summary = if (input.summary) |text| try safe(arena, text) else null,
        .message_index = try buildMessageIndex(arena, input.dropped_messages),
        .truncated_entries = try buildTruncatedEntries(arena, input.dropped_messages.len),
    };

    return std.json.Stringify.valueAlloc(allocator, Envelope{ .compact_messages = payload }, .{});
}

fn buildWorkingDirectory(
    arena: std.mem.Allocator,
    input: Input,
    active_dir: []const u8,
) !WorkingDirectory {
    const state = input.git_state;
    var dirty_files: []const DirtyFile = &.{};
    if (state) |s| {
        const files = try arena.alloc(DirtyFile, s.dirty_files.len);
        for (s.dirty_files, 0..) |file, index| {
            files[index] = .{
                .status = try safe(arena, file.status),
                .path = try safe(arena, file.path),
            };
        }
        dirty_files = files;
    }
    return .{
        .active_dir = try safe(arena, active_dir),
        .session_cwd = try safe(arena, input.session_cwd),
        .git_worktree_cwd = try safe(arena, input.git_worktree_cwd),
        .is_git_repo = state != null,
        .worktree_root = if (state) |s| try safe(arena, s.worktree_root) else null,
        .repo_root = if (state) |s| try safe(arena, s.repo_root) else null,
        .is_linked_worktree = if (state) |s| s.is_linked_worktree else false,
        .branch = if (state) |s| try safe(arena, s.branch) else null,
        .head = if (state) |s| try safe(arena, s.head) else null,
        .dirty_total = if (state) |s| s.dirty_total else 0,
        .dirty_files = dirty_files,
    };
}

fn buildUserHistory(arena: std.mem.Allocator, turns: []const UserTurn) ![]const Turn {
    const shown = @min(turns.len, MAX_USER_TURNS);
    const out = try arena.alloc(Turn, shown);
    for (turns[0..shown], 0..) |turn, index| {
        out[index] = .{
            .created_at = try safe(arena, turn.created_at),
            .content = try safe(arena, truncate(turn.content, MAX_USER_CONTENT_CHARS)),
        };
    }
    return out;
}

fn buildReadFiles(arena: std.mem.Allocator, files: []const ReadFileTurn, active_dir: []const u8) ![]const ReadFile {
    var out: std.ArrayList(ReadFile) = .empty;
    var seen = std.StringHashMapUnmanaged(void){};
    for (files) |file| {
        if (seen.contains(file.path)) continue;
        try seen.put(arena, file.path, {});
        const abs = if (std.fs.path.isAbsolute(file.path))
            try arena.dupe(u8, file.path)
        else
            try std.fs.path.join(arena, &.{ active_dir, file.path });
        try out.append(arena, .{
            .path = try safe(arena, file.path),
            .abs = try safe(arena, abs),
        });
    }
    return out.items;
}

fn buildActivities(arena: std.mem.Allocator, activities: []const RecentActivity) ![]const Activity {
    const out = try arena.alloc(Activity, activities.len);
    for (activities, 0..) |activity, index| {
        out[index] = .{
            .created_at = try safe(arena, activity.created_at),
            .description = try safe(arena, activity.description),
        };
    }
    return out;
}

fn buildSkills(arena: std.mem.Allocator, skills: []const llm_history.SkillInfo) ![]const Skill {
    const shown = @min(skills.len, MAX_SKILLS);
    const out = try arena.alloc(Skill, shown);
    for (skills[0..shown], 0..) |skill, index| {
        out[index] = .{
            .name = try safe(arena, skill.skill_name),
            .loaded_at = skill.loaded_at,
            .content = try safe(arena, truncate(skill.content, MAX_SKILL_CONTENT_CHARS)),
        };
    }
    return out;
}

fn buildMessageIndex(arena: std.mem.Allocator, dropped: []const AgentMessage) ![]const IndexEntry {
    const shown = @min(dropped.len, MAX_INDEX_ENTRIES);
    const start = dropped.len - shown;
    const tail_start = dropped.len - @min(dropped.len, TAIL_ENTRIES);

    const out = try arena.alloc(IndexEntry, shown);
    for (dropped[start..], start..) |dropped_message, index| {
        const cap = if (index >= tail_start) TAIL_PREVIEW_CHARS else PREVIEW_CHARS;
        const entry_id = try std.fmt.allocPrint(arena, "adhoc_{d}", .{index});
        out[index - start] = .{
            .id = entry_id,
            .role = try safe(arena, dropped_message.role.to_str()),
            .tool_call_id = if (dropped_message.role == .tool) try safe(arena, dropped_message.tool_call_id orelse "") else null,
            .preview = try safe(arena, truncate(dropped_message.content orelse "", cap)),
        };
    }
    return out;
}

fn buildTruncatedEntries(arena: std.mem.Allocator, dropped_count: usize) !?TruncatedEntries {
    if (dropped_count <= MAX_INDEX_ENTRIES) return null;
    return .{
        .count = dropped_count - MAX_INDEX_ENTRIES,
        .note = try safe(arena, "older entries omitted from message_index; use read_workspace_session with this session_id to fetch the full history"),
    };
}

/// Newest `dropped` messages win, so the tail — what the agent was doing when
/// the handoff fired — is always the part that survives.
fn truncate(value: []const u8, max_chars: usize) []const u8 {
    return if (value.len > max_chars) value[0..max_chars] else value;
}

/// A copy that is legal inside a JSON string: invalid UTF-8 and the control
/// characters JSON forbids become U+FFFD. Half a multi-byte character in a
/// preview would otherwise break the whole document for every reader.
fn safe(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < raw.len) {
        const length = std.unicode.utf8ByteSequenceLength(raw[index]) catch {
            try out.appendSlice(arena, "\u{FFFD}");
            index += 1;
            continue;
        };
        if (index + length > raw.len or !std.unicode.utf8ValidateSlice(raw[index .. index + length])) {
            try out.appendSlice(arena, "\u{FFFD}");
            index += 1;
            continue;
        }
        for (raw[index .. index + length]) |byte| {
            if (isForbiddenControl(byte)) {
                try out.appendSlice(arena, "\u{FFFD}");
            } else {
                try out.append(arena, byte);
            }
        }
        index += length;
    }
    return out.items;
}

fn isForbiddenControl(byte: u8) bool {
    return switch (byte) {
        0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => true,
        else => false,
    };
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const Parsed = struct {
    arena_state: std.heap.ArenaAllocator,
    value: std.json.Value,

    fn init(document: []const u8) !Parsed {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena_state.deinit();
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), document, .{});
        return .{ .arena_state = arena_state, .value = parsed };
    }

    fn deinit(self: *Parsed) void {
        self.arena_state.deinit();
    }

    fn payload(self: Parsed) std.json.Value {
        return self.value.object.get("compact_messages").?;
    }
};

fn message(role: pabrikcore.agent.Role, content: []const u8) AgentMessage {
    return .{ .role = role, .content = content };
}

fn buildParsed(input: Input) !Parsed {
    const document = try build(input);
    defer testing.allocator.free(document);
    return Parsed.init(document);
}

test "envelope is one JSON object under compact_messages" {
    const dropped = [_]AgentMessage{message(.user, "fix the bug")};
    var parsed = try buildParsed(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .session_id = "sess_1",
        .model = "gpt-4o",
        .dropped_messages = &dropped,
        .original_count = 2,
    });
    defer parsed.deinit();

    const payload = parsed.payload();
    try testing.expectEqual(@as(i64, FORMAT_VERSION), payload.object.get("format_version").?.integer);
    try testing.expectEqual(@as(usize, 1), parsed.value.object.count());
}

test "metadata carries the session, the model, the pre-compaction size and a timestamp" {
    const dropped = [_]AgentMessage{message(.user, "hello")};
    var parsed = try buildParsed(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .session_id = "sess_meta",
        .model = "MiniMax-M3",
        .dropped_messages = &dropped,
        .original_count = 9,
    });
    defer parsed.deinit();

    const metadata = parsed.payload().object.get("metadata").?.object;
    try testing.expectEqualStrings("sess_meta", metadata.get("session_id").?.string);
    try testing.expectEqualStrings("MiniMax-M3", metadata.get("model").?.string);
    try testing.expectEqual(@as(i64, 9), metadata.get("original_count").?.integer);
    try testing.expect(metadata.get("compacted_at").?.string.len > 0);
}

test "plan leads the content sections and keeps its markdown verbatim" {
    const dropped = [_]AgentMessage{message(.user, "go")};
    const plan = session_plan_mod.PlanRow{
        .session_id = "sess_plan",
        .plan_md = "# Goal\n- [ ] ship it\n",
        .updated_at = "2026-10-16 12:00:00",
    };
    var parsed = try buildParsed(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .session_id = "sess_plan",
        .model = "m",
        .dropped_messages = &dropped,
        .original_count = 2,
        .plan = plan,
    });
    defer parsed.deinit();

    const payload = parsed.payload().object;
    try testing.expectEqualStrings("# Goal\n- [ ] ship it\n", payload.get("plan").?.object.get("markdown").?.string);
    try testing.expectEqualStrings("2026-10-16 12:00:00", payload.get("plan").?.object.get("updated_at").?.string);

    const document = try build(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .session_id = "sess_plan",
        .model = "m",
        .dropped_messages = &dropped,
        .original_count = 2,
        .plan = plan,
    });
    defer testing.allocator.free(document);
    const plan_at = std.mem.indexOf(u8, document, "\"plan\"").?;
    try testing.expect(plan_at < std.mem.indexOf(u8, document, "\"working_directory\"").?);
    try testing.expect(plan_at < std.mem.indexOf(u8, document, "\"user_history\"").?);
}

test "plan is null when the session has never set one" {
    const dropped = [_]AgentMessage{message(.user, "go")};
    var parsed = try buildParsed(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .session_id = "sess_noplan",
        .model = "m",
        .dropped_messages = &dropped,
        .original_count = 2,
    });
    defer parsed.deinit();

    try testing.expect(parsed.payload().object.get("plan").? == .null);
}

test "working_directory names the session cwd and the bound worktree separately" {
    var state = git_state_mod.GitState{
        .worktree_root = "REPO/.worktrees/t1",
        .repo_root = "REPO",
        .branch = "worktree/t1",
        .head = "abc1234",
        .dirty_files = &.{},
        .dirty_total = 0,
        .is_linked_worktree = true,
    };
    var dirty = [_]git_state_mod.DirtyFile{.{ .status = "M", .path = "src/a.zig" }};
    state.dirty_files = &dirty;

    const dropped = [_]AgentMessage{message(.user, "go")};
    var parsed = try buildParsed(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .session_id = "sess_wt",
        .model = "m",
        .dropped_messages = &dropped,
        .original_count = 2,
        .session_cwd = "REPO",
        .git_worktree_cwd = "REPO/.worktrees/t1",
        .git_state = state,
    });
    defer parsed.deinit();

    const wd = parsed.payload().object.get("working_directory").?.object;
    try testing.expectEqualStrings("REPO/.worktrees/t1", wd.get("active_dir").?.string);
    try testing.expectEqualStrings("REPO", wd.get("session_cwd").?.string);
    try testing.expectEqualStrings("REPO/.worktrees/t1", wd.get("git_worktree_cwd").?.string);
    try testing.expectEqualStrings("worktree/t1", wd.get("branch").?.string);
    try testing.expectEqualStrings("src/a.zig", wd.get("dirty_files").?.array.items[0].object.get("path").?.string);
    try testing.expectEqual(true, wd.get("is_git_repo").?.bool);
}

test "working_directory falls back to the session cwd and reports no repository when git state is absent" {
    const dropped = [_]AgentMessage{message(.user, "go")};
    var parsed = try buildParsed(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .session_id = "sess_plain",
        .model = "m",
        .dropped_messages = &dropped,
        .original_count = 2,
        .session_cwd = "PLAIN",
    });
    defer parsed.deinit();

    const wd = parsed.payload().object.get("working_directory").?.object;
    try testing.expectEqualStrings("PLAIN", wd.get("active_dir").?.string);
    try testing.expectEqualStrings("", wd.get("git_worktree_cwd").?.string);
    try testing.expectEqual(false, wd.get("is_git_repo").?.bool);
    try testing.expect(wd.get("branch").? == .null);
}

test "user_history keeps the oldest turns first, up to the turn cap" {
    const alloc = testing.allocator;
    const turns = try alloc.alloc(UserTurn, MAX_USER_TURNS + 3);
    defer alloc.free(turns);
    const owned = try alloc.alloc([]u8, turns.len);
    defer {
        for (owned) |slice| alloc.free(slice);
        alloc.free(owned);
    }
    for (turns, owned, 0..) |*turn, *slice, index| {
        slice.* = try std.fmt.allocPrint(alloc, "turn {d}", .{index});
        turn.* = .{ .content = slice.*, .created_at = "2026-01-01 00:00:00" };
    }

    const dropped = [_]AgentMessage{message(.user, "go")};
    var parsed = try buildParsed(.{
        .allocator = alloc,
        .io = testing.io,
        .session_id = "sess_turns",
        .model = "m",
        .dropped_messages = &dropped,
        .original_count = 2,
        .user_turns = turns,
    });
    defer parsed.deinit();

    const history = parsed.payload().object.get("user_history").?.array;
    try testing.expectEqual(MAX_USER_TURNS, history.items.len);
    try testing.expectEqualStrings("turn 0", history.items[0].object.get("content").?.string);
    try testing.expectEqualStrings("turn 99", history.items[MAX_USER_TURNS - 1].object.get("content").?.string);
}

test "user_history truncates an over-long turn to the character cap" {
    const alloc = testing.allocator;
    const long = try alloc.alloc(u8, MAX_USER_CONTENT_CHARS + 50);
    defer alloc.free(long);
    @memset(long, 'x');
    const turns = [_]UserTurn{.{ .content = long, .created_at = "t" }};

    const dropped = [_]AgentMessage{message(.user, "go")};
    var parsed = try buildParsed(.{
        .allocator = alloc,
        .io = testing.io,
        .session_id = "sess_long",
        .model = "m",
        .dropped_messages = &dropped,
        .original_count = 2,
        .user_turns = &turns,
    });
    defer parsed.deinit();

    const content = parsed.payload().object.get("user_history").?.array.items[0].object.get("content").?.string;
    try testing.expectEqual(MAX_USER_CONTENT_CHARS, content.len);
}

test "read_files lists each path once and resolves a relative path against the active directory" {
    const alloc = testing.allocator;
    const files = [_]ReadFileTurn{
        .{ .path = "src/a.zig", .raw_content = "", .created_at = "t1" },
        .{ .path = "src/b.zig", .raw_content = "", .created_at = "t2" },
        .{ .path = "src/a.zig", .raw_content = "", .created_at = "t3" },
    };

    const dropped = [_]AgentMessage{message(.user, "go")};
    var parsed = try buildParsed(.{
        .allocator = alloc,
        .io = testing.io,
        .session_id = "sess_read",
        .model = "m",
        .dropped_messages = &dropped,
        .original_count = 2,
        .read_files = &files,
        .git_worktree_cwd = "WT",
        .session_cwd = "REPO",
    });
    defer parsed.deinit();

    const entries = parsed.payload().object.get("read_files").?.array;
    try testing.expectEqual(@as(usize, 2), entries.items.len);
    try testing.expectEqualStrings("src/a.zig", entries.items[0].object.get("path").?.string);
    // `std.fs.path.join` uses the host separator, so assert the two facts that
    // hold everywhere: it resolved under the worktree, not the session cwd.
    const abs = entries.items[0].object.get("abs").?.string;
    try testing.expect(std.mem.startsWith(u8, abs, "WT"));
    try testing.expect(std.mem.endsWith(u8, abs, "src/a.zig"));
    try testing.expect(std.mem.indexOf(u8, abs, "REPO") == null);
    try testing.expect(std.mem.indexOf(u8, abs, "b.zig") == null);
}

test "session_skills keeps the first skills up to the cap and truncates each body" {
    const alloc = testing.allocator;
    const skills = try alloc.alloc(llm_history.SkillInfo, MAX_SKILLS + 2);
    defer alloc.free(skills);
    const names = try alloc.alloc([]u8, skills.len);
    defer {
        for (names) |name| alloc.free(name);
        alloc.free(names);
    }
    const body = try alloc.alloc(u8, MAX_SKILL_CONTENT_CHARS + 10);
    defer alloc.free(body);
    @memset(body, 'y');
    for (skills, names, 0..) |*skill, *name, index| {
        name.* = try std.fmt.allocPrint(alloc, "skill-{d}", .{index});
        skill.* = .{ .skill_name = name.*, .content = body, .loaded_at = null };
    }

    const dropped = [_]AgentMessage{message(.user, "go")};
    var parsed = try buildParsed(.{
        .allocator = alloc,
        .io = testing.io,
        .session_id = "sess_skills",
        .model = "m",
        .dropped_messages = &dropped,
        .original_count = 2,
        .session_skills = skills,
    });
    defer parsed.deinit();

    const entries = parsed.payload().object.get("session_skills").?.array;
    try testing.expectEqual(MAX_SKILLS, entries.items.len);
    try testing.expectEqualStrings("skill-0", entries.items[0].object.get("name").?.string);
    try testing.expectEqual(MAX_SKILL_CONTENT_CHARS, entries.items[0].object.get("content").?.string.len);
}

test "message_index gives the newest entries a longer preview than the older ones" {
    const alloc = testing.allocator;
    const long = try alloc.alloc(u8, TAIL_PREVIEW_CHARS + 500);
    defer alloc.free(long);
    @memset(long, 'z');

    const dropped = try alloc.alloc(AgentMessage, TAIL_ENTRIES + 4);
    defer alloc.free(dropped);
    for (dropped) |*m| m.* = message(.user, long);

    var parsed = try buildParsed(.{
        .allocator = alloc,
        .io = testing.io,
        .session_id = "sess_index",
        .model = "m",
        .dropped_messages = dropped,
        .original_count = dropped.len + 1,
    });
    defer parsed.deinit();

    const entries = parsed.payload().object.get("message_index").?.array;
    try testing.expectEqual(dropped.len, entries.items.len);
    try testing.expectEqual(PREVIEW_CHARS, entries.items[0].object.get("preview").?.string.len);
    try testing.expectEqual(TAIL_PREVIEW_CHARS, entries.items[entries.items.len - 1].object.get("preview").?.string.len);
}

test "message_index keeps only the newest entries and reports how many it dropped" {
    var dropped: [MAX_INDEX_ENTRIES + 4]AgentMessage = undefined;
    for (&dropped, 0..) |*m, index| {
        m.* = message(.user, if (index == 0) "oldest" else "middle");
    }
    dropped[dropped.len - 1] = message(.assistant, "newest");

    var parsed = try buildParsed(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .session_id = "sess_trim",
        .model = "m",
        .dropped_messages = &dropped,
        .original_count = dropped.len + 1,
    });
    defer parsed.deinit();

    const payload = parsed.payload().object;
    const entries = payload.get("message_index").?.array;
    try testing.expectEqual(MAX_INDEX_ENTRIES, entries.items.len);
    try testing.expectEqualStrings("newest", entries.items[entries.items.len - 1].object.get("preview").?.string);
    try testing.expectEqual(@as(i64, 4), payload.get("truncated_entries").?.object.get("count").?.integer);
}

test "message_index carries the tool_call_id only for tool results" {
    var dropped = [_]AgentMessage{
        message(.user, "run it"),
        .{ .role = .tool, .content = "exit 0", .tool_call_id = "tc_7" },
    };

    var parsed = try buildParsed(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .session_id = "sess_tool",
        .model = "m",
        .dropped_messages = &dropped,
        .original_count = 3,
    });
    defer parsed.deinit();

    const entries = parsed.payload().object.get("message_index").?.array;
    try testing.expect(entries.items[0].object.get("tool_call_id").? == .null);
    try testing.expectEqualStrings("tc_7", entries.items[1].object.get("tool_call_id").?.string);
    try testing.expectEqualStrings("tool", entries.items[1].object.get("role").?.string);
}

test "truncated_entries is null while every dropped message fits the index" {
    var dropped = [_]AgentMessage{ message(.user, "a"), message(.user, "b") };
    var parsed = try buildParsed(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .session_id = "sess_fits",
        .model = "m",
        .dropped_messages = &dropped,
        .original_count = 3,
    });
    defer parsed.deinit();

    try testing.expect(parsed.payload().object.get("truncated_entries").? == .null);
}

test "summary is null without a summarization pass and holds the text when one ran" {
    const dropped = [_]AgentMessage{message(.user, "go")};
    const base = Input{
        .allocator = testing.allocator,
        .io = testing.io,
        .session_id = "sess_sum",
        .model = "m",
        .dropped_messages = &dropped,
        .original_count = 2,
    };

    var without = try buildParsed(base);
    defer without.deinit();
    try testing.expect(without.payload().object.get("summary").? == .null);

    var with = try buildParsed(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .session_id = "sess_sum",
        .model = "m",
        .dropped_messages = &dropped,
        .original_count = 2,
        .summary = "NEXT ACTION: merge",
    });
    defer with.deinit();
    try testing.expectEqualStrings("NEXT ACTION: merge", with.payload().object.get("summary").?.string);
}

test "recent_activities are carried through with their descriptions" {
    const activities = [_]RecentActivity{
        .{ .description = "ran the tests", .created_at = "2026-01-01 00:00:01" },
    };
    const dropped = [_]AgentMessage{message(.user, "go")};

    var parsed = try buildParsed(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .session_id = "sess_act",
        .model = "m",
        .dropped_messages = &dropped,
        .original_count = 2,
        .recent_activities = &activities,
    });
    defer parsed.deinit();

    const entries = parsed.payload().object.get("recent_activities").?.array;
    try testing.expectEqual(@as(usize, 1), entries.items.len);
    try testing.expectEqualStrings("ran the tests", entries.items[0].object.get("description").?.string);
}

test "content that would break a naive envelope still yields parseable JSON" {
    const hostile = "quote \" backslash \\ newline \n tab \t cdata ]]> tag <x> amp & \x01 control";
    const turns = [_]UserTurn{.{ .content = hostile, .created_at = hostile }};
    var dropped = [_]AgentMessage{
        message(.user, hostile),
        .{ .role = .tool, .content = hostile, .tool_call_id = hostile },
    };

    var parsed = try buildParsed(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .session_id = hostile,
        .model = hostile,
        .dropped_messages = &dropped,
        .original_count = 3,
        .user_turns = &turns,
        .summary = hostile,
    });
    defer parsed.deinit();

    const payload = parsed.payload().object;
    const summary_text = payload.get("summary").?.string;
    // The printable part survives byte-for-byte; the control character does not.
    try testing.expect(std.mem.indexOf(u8, summary_text, "quote \" backslash \\ newline \n tab \t") != null);
    try testing.expect(std.mem.indexOf(u8, summary_text, "cdata ]]> tag <x> amp &") != null);
    try testing.expect(std.mem.indexOfScalar(u8, summary_text, 0x01) == null);
    try testing.expect(std.mem.indexOf(u8, payload.get("user_history").?.array.items[0].object.get("content").?.string, "]]>") != null);
}

test "invalid utf-8 and forbidden control characters in a preview become the replacement character" {
    const hostile = [_]u8{ 'o', 'k', 0xff, 0xfe, 0x01, 'e', 'n', 'd' };
    var dropped = [_]AgentMessage{message(.user, &hostile)};

    var parsed = try buildParsed(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .session_id = "sess_utf8",
        .model = "m",
        .dropped_messages = &dropped,
        .original_count = 2,
    });
    defer parsed.deinit();

    const preview = parsed.payload().object.get("message_index").?.array.items[0].object.get("preview").?.string;
    try testing.expect(std.mem.indexOf(u8, preview, "\u{FFFD}") != null);
    try testing.expect(std.mem.indexOfScalar(u8, preview, 0x01) == null);
    try testing.expect(std.mem.indexOf(u8, preview, "end") != null);
}
