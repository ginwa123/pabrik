const std = @import("std");

// =============================================================================
// Shell Tool Types — canonical home, re-exported as BashInput/BashOutput
// and PwshInput/PwshOutput so the wire schema cannot drift between shells.
// =============================================================================

// Canonical types live in shell.zig (Task 1+ of 2026-08-14-pwsh-tool.md).
// Keep the schema ergonomic by aliasing here.
pub const BashInput = @import("shell.zig").ShellInput;
pub const BashOutput = @import("shell.zig").ShellOutput;
pub const CommandInput = @import("command.zig").CommandInput;
pub const CommandOutput = @import("command.zig").CommandOutput;

// Deprecated alias kept for any caller still using the long name. The
// BashResult is a subset of BashOutput (3 fields), so this aliasing is
// intentionally NOT a struct alias — it's a forwarder to a different
// type. New code should use BashOutput.
pub const BashResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u32,
};

// =============================================================================
// Read File Tool Types
// =============================================================================

pub const ReadFileInput = struct {
    path: []const u8,
    offset: ?usize = null,
    limit: ?usize = null,
    /// REQUIRED on the wire. Absolute directory this call works in; a
    /// relative `path` resolves against it. Empty by default so the struct
    /// stays constructible in tests that do not exercise the `cwd` rule —
    /// `path_validate.validateCwd` rejects the empty value at exec time.
    cwd: []const u8 = "",
};

// =============================================================================
// Agent Tool Schema Types
// =============================================================================

pub const ToolProperty = struct {
    name: []const u8,
    type: []const u8,
    description: []const u8,
};

pub const ToolParameters = struct {
    type: []const u8,
    properties: []const ToolProperty,
    required: []const []const u8,
};

pub const AgentToolFunction = struct {
    name: []const u8,
    description: []const u8,
    parameters: ToolParameters,
    /// Behavioral system prompt for this tool — co-located with the tool
    /// definition so the prompt stays in sync with the tool's schema.
    /// Empty when the tool has no dedicated behavior prompt (e.g. dynamic
    /// MCP tools). The aggregator in `prompts_build_messages_for_agent_prompt.zig`
    /// reads this field directly from `filtered_tools` without hardcoding names.
    system_prompt: []const u8 = "",
};

pub const AgentTool = struct {
    type: []const u8,
    function: AgentToolFunction,
};

// =============================================================================
// List struct for batch building tool properties
// =============================================================================

pub const List = struct {
    items: std.ArrayList(ToolProperty),

    pub fn init() List {
        return .{ .items = std.ArrayList(ToolProperty).empty };
    }

    pub fn deinit(self: *List) void {
        self.items.deinit();
    }

    pub fn append(self: *List, allocator: std.mem.Allocator, name: []const u8, type_: []const u8, description: []const u8) !void {
        try self.items.append(allocator, .{
            .name = name,
            .type = type_,
            .description = description,
        });
    }

    pub fn to_owned_slice(self: *List, allocator: std.mem.Allocator) ![]ToolProperty {
        return try self.items.toOwnedSlice(allocator);
    }
};

// =============================================================================
// Web Search Tool Types
//
// REMOVED 2026-10-02 (plan 2026-10-02-web-search-tool.md, D1). The old
// `web_search` here was a URL BROWSER — it shelled out to `agent-browser
// snapshot {url}` and returned raw stdout, with `cwd` existing only to give
// that shell-out somewhere to run. Its registry entry was commented out and
// it was absent from `equips()`, so no session could ever call it.
//
// The real search tool keeps its own types next to the code that produces
// them, the way `generate_image.zig` does:
//   `WebSearchInput` -> src/modules/agent/tools/web_search.zig
// =============================================================================
