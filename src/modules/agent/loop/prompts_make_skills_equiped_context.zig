const std = @import("std");
const pabrikcore = @import("pabrikcore");

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;

/// Build skills content string from database for persistence
pub fn makeSkillsEquippedContext(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) {
        return allocator.dupe(u8, "");
    }

    var skillsBuilder: std.ArrayList(u8) = .empty;
    errdefer skillsBuilder.deinit(allocator);

    const sql = "SELECT skill_name, content FROM session_skills WHERE session_id = ?";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    var hasSkills = false;
    while (try rows.next()) |row| {
        hasSkills = true;
        const skill_name = row.values[0];
        const content = row.values[1];
        try skillsBuilder.appendSlice(allocator, "### ");
        try skillsBuilder.appendSlice(allocator, skill_name);
        try skillsBuilder.appendSlice(allocator, "\n\n");
        try skillsBuilder.appendSlice(allocator, content);
        try skillsBuilder.appendSlice(allocator, "\n\n");
        row.deinit(allocator);
    }

    if (!hasSkills) {
        return allocator.dupe(u8, "");
    }

    // Prepend the header to the existing content
    const header = "\n\n## Loaded Skills\n\n";
    const result = try allocator.alloc(u8, header.len + skillsBuilder.items.len);
    @memcpy(result[0..header.len], header);
    @memcpy(result[header.len..], skillsBuilder.items);
    return result;
}
