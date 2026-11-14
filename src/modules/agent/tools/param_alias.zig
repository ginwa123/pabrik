const std = @import("std");
const schemas = @import("schemas.zig");

/// Canonical (long) parameter name → short name used on the provider wire.
pub const Alias = struct {
    canonical: []const u8,
    short: []const u8,
};

pub const TABLE = [_]Alias{
    .{ .canonical = "action", .short = "ac" },
    .{ .canonical = "after_context", .short = "af" },
    .{ .canonical = "agent", .short = "ag" },
    .{ .canonical = "agent_name", .short = "an" },
    .{ .canonical = "apply_to_children", .short = "atc" },
    .{ .canonical = "args", .short = "ar" },
    .{ .canonical = "background", .short = "bg" },
    .{ .canonical = "base", .short = "bs" },
    .{ .canonical = "before_context", .short = "bc" },
    .{ .canonical = "branch", .short = "br" },
    .{ .canonical = "child_ids", .short = "chd" },
    .{ .canonical = "clear", .short = "cl" },
    .{ .canonical = "column_id", .short = "cid" },
    .{ .canonical = "command", .short = "cmd" },
    .{ .canonical = "compacted_only", .short = "cpo" },
    .{ .canonical = "content", .short = "ct" },
    .{ .canonical = "context", .short = "cx" },
    .{ .canonical = "corner_radius", .short = "cr" },
    .{ .canonical = "count_only", .short = "co" },
    .{ .canonical = "create_with_dir", .short = "cd" },
    .{ .canonical = "curl", .short = "cu" },
    .{ .canonical = "cwd", .short = "c" },
    .{ .canonical = "depends_on", .short = "dep" },
    .{ .canonical = "description", .short = "ds" },
    .{ .canonical = "do_encoding", .short = "de" },
    .{ .canonical = "document_id", .short = "did" },
    .{ .canonical = "element_id", .short = "eid" },
    .{ .canonical = "enabled", .short = "en" },
    .{ .canonical = "file_type", .short = "ft" },
    .{ .canonical = "files", .short = "fs" },
    .{ .canonical = "fill", .short = "fi" },
    .{ .canonical = "follow", .short = "fo" },
    .{ .canonical = "force", .short = "fr" },
    .{ .canonical = "format", .short = "fm" },
    .{ .canonical = "glob", .short = "gl" },
    .{ .canonical = "group_by_file", .short = "gbf" },
    .{ .canonical = "head", .short = "hd" },
    .{ .canonical = "headers", .short = "hdr" },
    .{ .canonical = "height", .short = "ht" },
    .{ .canonical = "hidden", .short = "hn" },
    .{ .canonical = "html", .short = "hm" },
    .{ .canonical = "ignore_case", .short = "ic" },
    .{ .canonical = "image_url", .short = "iu" },
    .{ .canonical = "image_urls", .short = "ius" },
    .{ .canonical = "include_content", .short = "incl" },
    .{ .canonical = "invert", .short = "iv" },
    .{ .canonical = "is_auto_retry_until_stop", .short = "ars" },
    .{ .canonical = "is_current_session", .short = "ics" },
    .{ .canonical = "is_stop", .short = "st" },
    .{ .canonical = "item_id", .short = "iid" },
    .{ .canonical = "json_input", .short = "ji" },
    .{ .canonical = "limit", .short = "l" },
    .{ .canonical = "literal", .short = "lit" },
    .{ .canonical = "live_only", .short = "lo" },
    .{ .canonical = "max_bytes", .short = "mb" },
    .{ .canonical = "max_lines", .short = "ml" },
    .{ .canonical = "max_output", .short = "mo" },
    .{ .canonical = "max_results", .short = "mr" },
    .{ .canonical = "message", .short = "msg" },
    .{ .canonical = "message_ids", .short = "mids" },
    .{ .canonical = "metadata", .short = "md" },
    .{ .canonical = "mode", .short = "m" },
    .{ .canonical = "model", .short = "mdl" },
    .{ .canonical = "name", .short = "nm" },
    .{ .canonical = "new_page_id", .short = "npg" },
    .{ .canonical = "new_parent_id", .short = "npd" },
    .{ .canonical = "new_str", .short = "ns" },
    .{ .canonical = "new_text", .short = "nt" },
    .{ .canonical = "offset", .short = "o" },
    .{ .canonical = "old_str", .short = "os" },
    .{ .canonical = "old_text", .short = "ot" },
    .{ .canonical = "only_matching", .short = "om" },
    .{ .canonical = "opacity", .short = "op" },
    .{ .canonical = "order", .short = "od" },
    .{ .canonical = "output_format", .short = "of" },
    .{ .canonical = "page_id", .short = "pg" },
    .{ .canonical = "page_name", .short = "pgn" },
    .{ .canonical = "parent_id", .short = "prt" },
    .{ .canonical = "parent_session_id", .short = "pss" },
    .{ .canonical = "path", .short = "p" },
    .{ .canonical = "pattern", .short = "pat" },
    .{ .canonical = "pid", .short = "pd" },
    .{ .canonical = "position", .short = "pos" },
    .{ .canonical = "pr_url", .short = "pr" },
    .{ .canonical = "prompt", .short = "prm" },
    .{ .canonical = "provider", .short = "pv" },
    .{ .canonical = "quality", .short = "ql" },
    .{ .canonical = "query", .short = "q" },
    .{ .canonical = "recursive", .short = "rc" },
    .{ .canonical = "remove", .short = "rm" },
    .{ .canonical = "replace_all", .short = "ra" },
    .{ .canonical = "respect_ignore_files", .short = "ri" },
    .{ .canonical = "response_format", .short = "rf" },
    .{ .canonical = "role", .short = "rl" },
    .{ .canonical = "rotation", .short = "rt" },
    .{ .canonical = "scale", .short = "sc" },
    .{ .canonical = "selected_profile_model", .short = "spm" },
    .{ .canonical = "server", .short = "sv" },
    .{ .canonical = "session_id", .short = "sid" },
    .{ .canonical = "since", .short = "sn" },
    .{ .canonical = "size", .short = "sz" },
    .{ .canonical = "skill_name", .short = "skn" },
    .{ .canonical = "snippet_max_chars", .short = "smc" },
    .{ .canonical = "stdin_data", .short = "sd" },
    .{ .canonical = "stroke", .short = "sk" },
    .{ .canonical = "stroke_width", .short = "sw" },
    .{ .canonical = "style", .short = "sy" },
    .{ .canonical = "tags", .short = "tg" },
    .{ .canonical = "tail", .short = "tl" },
    .{ .canonical = "target_column_id", .short = "tcid" },
    .{ .canonical = "target_column_name", .short = "tcn" },
    .{ .canonical = "task_id", .short = "tid" },
    .{ .canonical = "text_content", .short = "tc" },
    .{ .canonical = "text_style", .short = "ts" },
    .{ .canonical = "timeout", .short = "t" },
    .{ .canonical = "timeout_ms", .short = "tm" },
    .{ .canonical = "title", .short = "ti" },
    .{ .canonical = "tool_name", .short = "tn" },
    .{ .canonical = "transport", .short = "tr" },
    .{ .canonical = "type", .short = "ty" },
    .{ .canonical = "until", .short = "un" },
    .{ .canonical = "url", .short = "u" },
    .{ .canonical = "user", .short = "us" },
    .{ .canonical = "verify", .short = "vf" },
    .{ .canonical = "width", .short = "w" },
    .{ .canonical = "with_content", .short = "wc" },
    .{ .canonical = "word_boundary", .short = "wb" },
    .{ .canonical = "workspace_id", .short = "wid" },
    .{ .canonical = "workspace_item_id", .short = "wii" },
};

/// Parameter names that are already as short as a wire name can be.
pub const ALREADY_SHORT: []const []const u8 = &.{ "dx", "dy", "id", "n", "x", "y" };

pub fn isAlreadyShort(name: []const u8) bool {
    for (ALREADY_SHORT) |short| {
        if (std.mem.eql(u8, short, name)) return true;
    }
    return false;
}

/// The direction a key rewrite runs in.
pub const Direction = enum { to_short, to_canonical };

fn mapped(name: []const u8, direction: Direction) ?[]const u8 {
    for (TABLE) |entry| {
        switch (direction) {
            .to_short => if (std.mem.eql(u8, entry.canonical, name)) return entry.short,
            .to_canonical => if (std.mem.eql(u8, entry.short, name)) return entry.canonical,
        }
    }
    return null;
}

/// Wire name for a canonical parameter, or null when the parameter has none.
pub fn shortName(canonical: []const u8) ?[]const u8 {
    return mapped(canonical, .to_short);
}

/// Canonical parameter for a wire name, or null when the wire name is not ours.
pub fn canonicalName(short: []const u8) ?[]const u8 {
    return mapped(short, .to_canonical);
}

/// Tools whose parameters travel short. Anything not listed here (every MCP
/// server tool, for one) keeps the names its own schema declares.
pub const BUILTIN_TOOLS: []const []const u8 = &.{
    "add_element",
    "add_mcp_server",
    "add_skill",
    "command",
    "create_kanban_task",
    "delegate_agent",
    "delete_mcp_server",
    "document_html",
    "document_markdown",
    "edit_mcp_server",
    "edit_skill",
    "generate_image",
    "get_design_context",
    "get_plan",
    "glob",
    "group_elements",
    "kanban_list",
    "kanban_move_task",
    "list_agents",
    "list_directory",
    "list_secrets",
    "list_web_search_providers",
    "load_memory",
    "move_design_element",
    "move_element_to_page",
    "present_files",
    "preview_design_page",
    "process",
    "read_file",
    "read_workspace_session",
    "remove_file",
    "remove_skill",
    "run_command",
    "run_session",
    "run_skill_eval",
    "save_memory",
    "search",
    "search_skills",
    "search_tool",
    "set_design_page",
    "set_element_parent",
    "set_git_worktree",
    "set_pull_request",
    "set_skill_metadata",
    "spawn_sub_agent",
    "status_pull_request",
    "text_replace",
    "update_element",
    "update_plan",
    "use_skill",
    "use_tool",
    "used_tools",
    "view_session",
    "view_tool",
    "web_search",
    "write_file",
};

pub fn isBuiltinTool(name: []const u8) bool {
    for (BUILTIN_TOOLS) |builtin| {
        if (std.mem.eql(u8, builtin, name)) return true;
    }
    return false;
}

/// Byte offset of the quote that closes the string opened at `start`.
fn stringEnd(text: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '\\' => i += 1,
            '"' => return i,
            else => {},
        }
    }
    return text.len;
}

/// Rewrites the keys of the ROOT object only, so every value stays
/// byte-for-byte (a `write_file` payload is never re-encoded) and a
/// key-shaped fragment inside a string value is never mistaken for a key.
pub fn rewriteKeys(allocator: std.mem.Allocator, text: []const u8, direction: Direction) ![]const u8 {
    if (text.len == 0) return text;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var depth: usize = 0;
    var expect_key = false;
    var changed = false;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '"' => {
                const end = stringEnd(text, i);
                const stop = @min(end + 1, text.len);
                if (depth == 1 and expect_key and end < text.len) {
                    const key = text[i + 1 .. end];
                    if (mapped(key, direction)) |replacement| {
                        try out.append(allocator, '"');
                        try out.appendSlice(allocator, replacement);
                        try out.append(allocator, '"');
                        changed = true;
                        expect_key = false;
                        i = stop;
                        continue;
                    }
                }
                try out.appendSlice(allocator, text[i..stop]);
                i = stop;
                continue;
            },
            '{', '[' => {
                depth += 1;
                if (depth == 1) expect_key = true;
            },
            '}', ']' => {
                if (depth > 0) depth -= 1;
            },
            ',' => {
                if (depth == 1) expect_key = true;
            },
            else => {},
        }
        try out.append(allocator, c);
        i += 1;
    }

    if (!changed) {
        out.deinit(allocator);
        return text;
    }
    return out.toOwnedSlice(allocator);
}

/// Provider-facing form of a tool call's arguments.
pub fn shortenArgs(allocator: std.mem.Allocator, args: []const u8) ![]const u8 {
    return rewriteKeys(allocator, args, .to_short);
}

/// Canonical form of a tool call's arguments, as every consumer downstream of
/// the provider expects them.
pub fn expandArgs(allocator: std.mem.Allocator, args: []const u8) ![]const u8 {
    return rewriteKeys(allocator, args, .to_canonical);
}

/// Schema properties as the provider sees them. `short` is false for a tool
/// whose parameter names belong to someone else (an MCP server).
pub fn wireProperties(
    allocator: std.mem.Allocator,
    properties: []const schemas.ToolProperty,
    short: bool,
) ![]const schemas.ToolProperty {
    if (!short) return properties;
    const out = try allocator.alloc(schemas.ToolProperty, properties.len);
    for (properties, 0..) |prop, i| {
        out[i] = .{
            .name = shortName(prop.name) orelse prop.name,
            .type = prop.type,
            .description = prop.description,
        };
    }
    return out;
}

/// The schema's `required` list, translated to the same names `wireProperties`
/// emitted. A name with no alias stays as it is.
pub fn wireRequired(
    allocator: std.mem.Allocator,
    required: []const []const u8,
    short: bool,
) ![]const []const u8 {
    if (!short) return required;
    const out = try allocator.alloc([]const u8, required.len);
    for (required, 0..) |name, i| {
        out[i] = shortName(name) orelse name;
    }
    return out;
}

const testing = std.testing;

test "shortenArgs translates a command call to one-letter keys and keeps values intact" {
    const long = "{\"command\":\"ls -la\",\"cwd\":\"/tmp/x\",\"timeout\":30,\"mode\":\"foreground\",\"is_stop\":true}";
    const short = try shortenArgs(testing.allocator, long);
    defer testing.allocator.free(short);
    try testing.expectEqualStrings(
        "{\"cmd\":\"ls -la\",\"c\":\"/tmp/x\",\"t\":30,\"m\":\"foreground\",\"st\":true}",
        short,
    );
}

test "expandArgs restores the canonical names the tool handlers read" {
    const short = "{\"cmd\":\"ls -la\",\"c\":\"/tmp/x\",\"t\":30}";
    const long = try expandArgs(testing.allocator, short);
    defer testing.allocator.free(long);
    try testing.expectEqualStrings("{\"command\":\"ls -la\",\"cwd\":\"/tmp/x\",\"timeout\":30}", long);
}

test "every table entry survives a shorten then expand round trip" {
    for (TABLE) |entry| {
        const json = try std.fmt.allocPrint(testing.allocator, "{{\"{s}\":\"v\"}}", .{entry.canonical});
        defer testing.allocator.free(json);

        const short = try shortenArgs(testing.allocator, json);
        defer testing.allocator.free(short);
        try testing.expectEqualStrings(entry.short, short[2 .. short.len - 6]);

        const round = try expandArgs(testing.allocator, short);
        defer testing.allocator.free(round);
        try testing.expectEqualStrings(json, round);
    }
}

test "a key-shaped string inside a value is left alone" {
    const long = "{\"content\":\"{\\\"cwd\\\":\\\"/tmp\\\"}\",\"path\":\"a.txt\"}";
    const short = try shortenArgs(testing.allocator, long);
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("{\"ct\":\"{\\\"cwd\\\":\\\"/tmp\\\"}\",\"p\":\"a.txt\"}", short);
}

test "keys of a nested object stay canonical" {
    const long = "{\"cwd\":\"/tmp\",\"metadata\":{\"cwd\":\"/nested\",\"timeout\":5}}";
    const short = try shortenArgs(testing.allocator, long);
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("{\"c\":\"/tmp\",\"md\":{\"cwd\":\"/nested\",\"timeout\":5}}", short);
}

test "an unknown parameter name passes through untouched" {
    const mcp = "{\"page\":2,\"page_size\":50,\"query\":\"x\"}";
    const short = try shortenArgs(testing.allocator, mcp);
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("{\"page\":2,\"page_size\":50,\"q\":\"x\"}", short);
}

test "text that is not a root object is returned unchanged" {
    const cases = [_][]const u8{ "", "[]", "[{\"cwd\":\"/tmp\"}]", "\"cwd\"", "42", "not json at all" };
    for (cases) |text| {
        const out = try shortenArgs(testing.allocator, text);
        defer if (out.ptr != text.ptr) testing.allocator.free(out);
        try testing.expectEqualStrings(text, out);
    }
}

test "a streamed fragment with a complete key is already shortened" {
    const fragment = "{\"cwd\":\"/tmp\",\"command\":\"ls";
    const short = try shortenArgs(testing.allocator, fragment);
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("{\"c\":\"/tmp\",\"cmd\":\"ls", short);
}

test "a canonical name that is also a wire name is not double translated" {
    const already = "{\"c\":\"/tmp\",\"cmd\":\"ls\",\"t\":5}";
    const short = try shortenArgs(testing.allocator, already);
    defer if (short.ptr != already.ptr) testing.allocator.free(short);
    try testing.expectEqualStrings(already, short);

    const long = try expandArgs(testing.allocator, already);
    defer testing.allocator.free(long);
    try testing.expectEqualStrings("{\"cwd\":\"/tmp\",\"command\":\"ls\",\"timeout\":5}", long);
}

test "a tool the agent does not own is not a builtin tool" {
    try testing.expect(isBuiltinTool("command"));
    try testing.expect(isBuiltinTool("text_replace"));
    try testing.expect(!isBuiltinTool("mcp_graphify_query_graph"));
    try testing.expect(!isBuiltinTool(""));
}

test "wireProperties shortens names for a builtin tool and leaves the rest alone" {
    const props = [_]schemas.ToolProperty{
        .{ .name = "cwd", .type = "string", .description = "dir" },
        .{ .name = "timeout", .type = "number", .description = "seconds" },
    };

    const short = try wireProperties(testing.allocator, &props, true);
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("c", short[0].name);
    try testing.expectEqualStrings("t", short[1].name);
    try testing.expectEqualStrings("dir", short[0].description);

    const untouched = try wireProperties(testing.allocator, &props, false);
    try testing.expectEqualStrings("cwd", untouched[0].name);
}

test "wireRequired translates the same names wireProperties emitted" {
    const required = [_][]const u8{ "command", "cwd", "timeout" };

    const short = try wireRequired(testing.allocator, &required, true);
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("cmd", short[0]);
    try testing.expectEqualStrings("c", short[1]);
    try testing.expectEqualStrings("t", short[2]);

    const untouched = try wireRequired(testing.allocator, &required, false);
    try testing.expectEqualStrings("command", untouched[0]);
}

test "table: wire names are unique, shorter than their canonical name, and never shadow one" {
    for (TABLE, 0..) |entry, i| {
        try testing.expect(entry.short.len < entry.canonical.len);
        try testing.expect(!std.mem.eql(u8, entry.short, entry.canonical));
        for (TABLE[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, entry.short, other.short));
            try testing.expect(!std.mem.eql(u8, entry.canonical, other.canonical));
        }
        if (shortName(entry.canonical)) |s| {
            try testing.expectEqualStrings(entry.short, s);
        } else {
            return error.MissingAlias;
        }
    }
}

test "a name that is already short is never translated" {
    for (ALREADY_SHORT) |name| {
        try testing.expect(isAlreadyShort(name));
        try testing.expect(shortName(name) == null);
    }
    try testing.expect(!isAlreadyShort("cwd"));
    try testing.expect(!isAlreadyShort(""));
}
