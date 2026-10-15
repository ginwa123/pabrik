//! Agent-callable tool: `list_secrets` — the NAMES of the secrets stored in
//! the calling session's workspace, and nothing else.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;

/// Input for `list_secrets`. An empty struct — there is nothing to pass,
/// and every field here would be a chance to pass the wrong thing.
pub const ListSecretsInput = struct {};

pub const list_secrets_tool_system_prompt =
    \\## List Secrets — discover the credential names in this workspace
    \\
    \\Call `list_secrets` with no arguments to learn which secret names this workspace stores.
    \\It returns NAMES and rotation timestamps only, never the credential itself.
    \\
    \\Use a discovered name inside `{{SECRETS:NAME}}` in ANY tool parameter. The placeholder is
    \\replaced with the real credential immediately before the tool runs, and the value is
    \\redacted from whatever the tool reports back.
    \\
    \\**Never** put a secret's value into a file, a commit message, a command that captures
    \\output, or your own reply to the user — not even to show it worked. Reference it by name.
;

pub const list_secrets_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "list_secrets",
        .description =
        \\List this workspace's secrets — Names only, never returned — with the timestamp each was last rotated. No parameters: the workspace is the calling session's. Call this before writing a {{SECRETS:NAME}} placeholder so you use a name that exists. Read-only, no side effects.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
        .system_prompt = list_secrets_tool_system_prompt,
    },
};

const testing = std.testing;

test "list_secrets_tool JSON schema: no properties, no required, and no workspace_id key" {
    const tool = list_secrets_tool;
    try testing.expectEqualStrings("function", tool.type);
    try testing.expectEqualStrings("list_secrets", tool.function.name);
    try testing.expectEqual(@as(usize, 0), tool.function.parameters.required.len);
    try testing.expectEqual(@as(usize, 0), tool.function.parameters.properties.len);

    // Asserted on the SERIALIZED schema, not on the struct: a future edit
    // that adds a property is exactly the regression this has to catch, and
    // counting fields cannot see it.
    const json = try std.json.Stringify.valueAlloc(testing.allocator, tool, .{});
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"workspace_id\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"value\"") == null);
    // No declared property of any kind — the strongest statement available
    // is the empty one, and it is what a future `workspace_id` addition
    // would break.
    try testing.expect(std.mem.indexOf(u8, json, "\"properties\":[]") != null);
}

test "list_secrets_tool: the description teaches the placeholder and promises names only" {
    const description = list_secrets_tool.function.description;
    try testing.expect(std.mem.indexOf(u8, description, "{{SECRETS:NAME}}") != null);
    try testing.expect(std.mem.indexOf(u8, description, "Names only") != null);
    // A model that thinks this tool hands back credentials will use it as a
    // way to read one out loud.
    try testing.expect(std.mem.indexOf(u8, description, "never returned") != null);

    const system_prompt = list_secrets_tool.function.system_prompt;
    try testing.expect(std.mem.indexOf(u8, system_prompt, "{{SECRETS:NAME}}") != null);
    try testing.expect(std.mem.indexOf(u8, system_prompt, "Never") != null);
}
