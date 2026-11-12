//! The one rule for a row's glyph name, shared by every handler that accepts
//! one: 1-64 lowercase letters, digits or hyphens — the shape of an `ICON_PATHS`
//! key. The registry is not duplicated here; the UI degrades unknown names.

const std = @import("std");

pub fn isValidIconName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

const testing = std.testing;

test "isValidIconName accepts every shape the registry uses" {
    for ([_][]const u8{ "folder", "folder-open", "chevron-down", "box", "pr", "a", "x1" }) |name| {
        try testing.expect(isValidIconName(name));
    }
}

test "isValidIconName rejects what could never be a registry key" {
    for ([_][]const u8{ "", "Folder", "folder_open", "folder open", "folder!", "a" ** 65 }) |name| {
        try testing.expect(!isValidIconName(name));
    }
}
