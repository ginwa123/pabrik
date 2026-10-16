//! The skill list a task asks its agent to use (Migration 112). One task may
//! name several skills. They are validated, deduplicated, stored
//! `||`-joined, and the create_and_run note gets one `#Skill` line each.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const skills_store = pabrikcore.skills_store;

/// Hard cap on the skills one task may ask for: bounds both the row and the
/// agent's first message without a silent truncation.
pub const MAX_SKILLS_PER_TASK: usize = 20;

/// Separator between names inside the stored column. A legal skill name is
/// `[A-Za-z0-9._-]`, so `|` can never occur inside one.
pub const SEPARATOR = "||";

pub const NormalizeError = error{
    SkillNameTooLong,
    SkillNameContainsControlChar,
    TooManySkills,
    OutOfMemory,
};

/// Validate every name, drop blanks and duplicates and return the `||`-joined
/// form the column holds. `legacy` is the pre-112 single-name field, read only
/// when no array was sent. The caller owns the returned slice.
pub fn normalize(
    allocator: std.mem.Allocator,
    names: ?[]const []const u8,
    legacy: ?[]const u8,
) NormalizeError![]const u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(allocator);

    if (names) |list| {
        for (list) |raw| {
            const name = std.mem.trim(u8, raw, " \t\n\r");
            if (name.len == 0) continue;
            try validateName(name);
            if (containsName(kept.items, name)) continue;
            if (kept.items.len >= MAX_SKILLS_PER_TASK) return error.TooManySkills;
            try kept.append(allocator, name);
        }
    } else if (legacy) |raw| {
        const name = std.mem.trim(u8, raw, " \t\n\r");
        if (name.len > 0) {
            try validateName(name);
            try kept.append(allocator, name);
        }
    }

    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(allocator);
    for (kept.items, 0..) |name, i| {
        if (i > 0) try joined.appendSlice(allocator, SEPARATOR);
        try joined.appendSlice(allocator, name);
    }
    return joined.toOwnedSlice(allocator);
}

/// The note block for the create_and_run message: one `#Skill <name>` line per
/// skill, the whole block introduced by a blank line. Empty input yields "",
/// so a task without skills leaves the message exactly as the caller wrote it.
pub fn directives(allocator: std.mem.Allocator, joined: []const u8) ![]const u8 {
    if (joined.len == 0) return allocator.dupe(u8, "");

    var block: std.ArrayList(u8) = .empty;
    errdefer block.deinit(allocator);
    try block.appendSlice(allocator, "\n\n#Skill ");

    var it = std.mem.splitSequence(u8, joined, SEPARATOR);
    var first = true;
    while (it.next()) |name| {
        if (name.len == 0) continue;
        if (!first) try block.appendSlice(allocator, "\n#Skill ");
        try block.appendSlice(allocator, name);
        first = false;
    }
    return block.toOwnedSlice(allocator);
}

/// True when `name` is already in `kept`. Linear on purpose: the list is
/// capped at MAX_SKILLS_PER_TASK.
fn containsName(kept: []const []const u8, name: []const u8) bool {
    for (kept) |existing| {
        if (std.mem.eql(u8, existing, name)) return true;
    }
    return false;
}

/// The single-name rules Migration 110 introduced, unchanged: a length bound,
/// no control characters, and the directory-safe token shape.
fn validateName(name: []const u8) NormalizeError!void {
    if (name.len > skills_store.MAX_NAME_BYTES) return error.SkillNameTooLong;
    for (name) |c| {
        if (c < 0x20 or c == 0x7f) return error.SkillNameContainsControlChar;
    }
    if (!skills_store.isValidSkillName(name)) return error.SkillNameContainsControlChar;
}

const testing = std.testing;

test "normalize: no names at all yields the empty sentinel" {
    const alloc = testing.allocator;
    const joined = try normalize(alloc, null, null);
    defer alloc.free(joined);
    try testing.expectEqualStrings("", joined);
}

test "normalize: one name round-trips unchanged" {
    const alloc = testing.allocator;
    const joined = try normalize(alloc, &[_][]const u8{"pdf"}, null);
    defer alloc.free(joined);
    try testing.expectEqualStrings("pdf", joined);
}

test "normalize: several names keep the order they were picked in" {
    const alloc = testing.allocator;
    const joined = try normalize(alloc, &[_][]const u8{ "pdf", "zig-trap", "code-review" }, null);
    defer alloc.free(joined);
    try testing.expectEqualStrings("pdf||zig-trap||code-review", joined);
}

test "normalize: a repeated name is kept once, in first-appearance order" {
    const alloc = testing.allocator;
    const joined = try normalize(alloc, &[_][]const u8{ "pdf", "zig-trap", "pdf" }, null);
    defer alloc.free(joined);
    try testing.expectEqualStrings("pdf||zig-trap", joined);
}

test "normalize: surrounding whitespace is trimmed and blank entries are skipped" {
    const alloc = testing.allocator;
    const joined = try normalize(alloc, &[_][]const u8{ "  pdf  ", "", "   ", "zig-trap" }, null);
    defer alloc.free(joined);
    try testing.expectEqualStrings("pdf||zig-trap", joined);
}

test "normalize: exactly the cap is accepted" {
    const alloc = testing.allocator;
    var names: [MAX_SKILLS_PER_TASK][]const u8 = undefined;
    var bufs: [MAX_SKILLS_PER_TASK][16]u8 = undefined;
    for (&names, 0..) |*slot, i| {
        slot.* = try std.fmt.bufPrint(&bufs[i], "skill-{d}", .{i});
    }
    const joined = try normalize(alloc, &names, null);
    defer alloc.free(joined);
    try testing.expect(joined.len > 0);
}

test "normalize: one name past the cap is rejected" {
    const alloc = testing.allocator;
    var names: [MAX_SKILLS_PER_TASK + 1][]const u8 = undefined;
    var bufs: [MAX_SKILLS_PER_TASK + 1][16]u8 = undefined;
    for (&names, 0..) |*slot, i| {
        slot.* = try std.fmt.bufPrint(&bufs[i], "skill-{d}", .{i});
    }
    try testing.expectError(error.TooManySkills, normalize(alloc, &names, null));
}

test "normalize: a name with a slash is rejected" {
    const alloc = testing.allocator;
    try testing.expectError(
        error.SkillNameContainsControlChar,
        normalize(alloc, &[_][]const u8{"../../etc/passwd"}, null),
    );
}

test "normalize: a name holding a control character is rejected" {
    const alloc = testing.allocator;
    try testing.expectError(
        error.SkillNameContainsControlChar,
        normalize(alloc, &[_][]const u8{"pdf\u{7}evil"}, null),
    );
}

test "normalize: a name past the byte bound is rejected" {
    const alloc = testing.allocator;
    const long = "a" ** (skills_store.MAX_NAME_BYTES + 1);
    try testing.expectError(error.SkillNameTooLong, normalize(alloc, &[_][]const u8{long}, null));
}

test "normalize: the legacy single name is used only when no array was sent" {
    const alloc = testing.allocator;
    const from_legacy = try normalize(alloc, null, " pdf ");
    defer alloc.free(from_legacy);
    try testing.expectEqualStrings("pdf", from_legacy);

    const explicit_empty = try normalize(alloc, &[_][]const u8{}, "pdf");
    defer alloc.free(explicit_empty);
    try testing.expectEqualStrings("", explicit_empty);
}

test "directives: a task with no skill adds nothing to the message" {
    const alloc = testing.allocator;
    const block = try directives(alloc, "");
    defer alloc.free(block);
    try testing.expectEqualStrings("", block);
}

test "directives: one skill gets one line after a blank line" {
    const alloc = testing.allocator;
    const block = try directives(alloc, "pdf");
    defer alloc.free(block);
    try testing.expectEqualStrings("\n\n#Skill pdf", block);
}

test "directives: two skills get two lines, and the blank line appears once" {
    const alloc = testing.allocator;
    const block = try directives(alloc, "pdf||zig-trap");
    defer alloc.free(block);
    try testing.expectEqualStrings("\n\n#Skill pdf\n#Skill zig-trap", block);
}
