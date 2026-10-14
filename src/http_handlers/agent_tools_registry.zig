//! `GET /api/agent-tools/registry`.
//!
//! Returns the canonical tool registry as
//! `{tools: [{name, description, parameters}]}`. Each entry carries its full
//! parameter list — name, JSON type and whether the schema REQUIRES it — so a
//! consumer can answer "which tools take a file/folder path, and in which
//! parameter?" without a second source of truth. That question is why the
//! list exists: the path-taking tools now require an absolute `cwd`, and the
//! only honest place to check that is the schema the model is actually
//! handed.
//! Sourced from `tools_equipped.UNIFIED_TOOL_REGISTRY()` — the same
//! source of truth the runtime tool filter reads. When a tool is added
//! or removed in that function, the registry endpoint automatically
//! reflects it (no drift, no second list to maintain).
//!
//! Layered as:
//!   - `useCase` — transforms the runtime registry into a
//!     [{name, description}] list.
//!   - `agentToolsRegistryHandler` — thin orchestrator over
//!     `useCase`: delegates to `useCase`, marshals the result to
//!     JSON.
//!
//! Memory: the per-request arena reaps all allocations at request
//! end, so neither layer needs explicit `free`s.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const tools_equipped = @import("../agentic_loop/tools_equipped.zig");

/// One parameter of a registry entry's schema.
pub const RegistryParameter = struct {
    /// Borrowed from the tool definition (static, lives forever).
    name: []const u8,
    type: []const u8,
    /// True when the JSON schema lists it in `required`. A REQUIRED `cwd` is
    /// what stops a path-taking call from silently inheriting the server's
    /// working directory instead of the one the model is editing.
    required: bool,
};

/// One entry in the registry response.
pub const RegistryEntry = struct {
    name: []const u8,
    /// Owned by the use-case (lifetime = request arena).
    description: []const u8,
    /// One row per schema property, in declaration order. Owned by the
    /// use-case (lifetime = request arena).
    parameters: []const RegistryParameter,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches (intentional — adding a new variant fails to compile in
/// the handler until both switches are updated, keeping status
/// codes in lockstep with the error set).
pub const RegistryError = error{
    /// `allocator.dupe` failed while copying descriptions. In
    /// production this is effectively unreachable (the per-request
    /// arena reaps everything at request end) but the type system
    /// requires the variant so the `try` propagates a typed error.
    OutOfMemory,
};

/// Output of the registry use-case.
pub const RegistryOutput = struct {
    entries: []const RegistryEntry,
};

// =====================================================================
// Use case
// =====================================================================

/// Transform the runtime registry into a slice of `{name,description}`
/// entries. The use-case is transport-agnostic: it works for both
/// the per-request arena (production HTTP handler) and
/// `testing.allocator` (unit tests below) — all allocations go
/// through the passed-in allocator.
fn useCase(allocator: std.mem.Allocator) RegistryError!RegistryOutput {
    const registry = tools_equipped.UNIFIED_TOOL_REGISTRY();

    var list: std.ArrayList(RegistryEntry) = .empty;
    for (registry) |entry| {
        const props = entry.tool_def.function.parameters.properties;
        const required_names = entry.tool_def.function.parameters.required;
        const params = try allocator.alloc(RegistryParameter, props.len);
        for (props, 0..) |prop, i| {
            var is_required = false;
            for (required_names) |name| {
                if (std.mem.eql(u8, name, prop.name)) is_required = true;
            }
            params[i] = .{
                .name = prop.name,
                .type = prop.type,
                .required = is_required,
            };
        }
        try list.append(allocator, .{
            .name = entry.name,
            .description = try allocator.dupe(u8, entry.tool_def.function.description),
            .parameters = params,
        });
    }
    return .{ .entries = try list.toOwnedSlice(allocator) };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn agentToolsRegistryHandler(
    ctx: gserverz.HttpContext,
    _: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const output = useCase(allocator) catch |err| {
        const status: u16 = switch (err) {
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Pass the entries directly — std.json.Stringify flattens the
    // struct fields into a `{name, description}` JSON object.
    const data = try std.json.Stringify.valueAlloc(allocator, .{ .tools = output.entries }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
//
// impl + tests in one file (project convention for Agent Mode).
// 2 behavioural tests cover the use-case:
//
//   1. Registry is non-empty (sanity — if UNIFIED_TOOL_REGISTRY is
//      accidentally emptied, the frontend's Tools panel dies)
//   2. Every entry has a non-empty `name` and `description`

const testing = std.testing;

/// Free everything `useCase` allocated.
fn freeOutput(alloc: std.mem.Allocator, output: RegistryOutput) void {
    for (output.entries) |e| {
        alloc.free(e.description);
        alloc.free(e.parameters);
    }
    alloc.free(output.entries);
}

fn findEntry(output: RegistryOutput, name: []const u8) ?RegistryEntry {
    for (output.entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

fn findParam(entry: RegistryEntry, name: []const u8) ?RegistryParameter {
    for (entry.parameters) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

test "useCase: every path-taking tool REQUIRES an absolute cwd" {
    // This is the contract the 2026-10-14 change introduced: a call that
    // touches the filesystem must say which tree it works in, or it silently
    // acts on the SERVER's directory instead of the one the model is
    // editing. The registry is where the model's schema is published, so the
    // requirement is asserted against the real output — a tool that quietly
    // lost its `cwd` (or its `required` entry) fails here.
    const alloc = testing.allocator;
    const output = try useCase(alloc);
    defer freeOutput(alloc, output);

    const path_tools = [_][]const u8{
        "read_file",
        "write_file",
        "text_replace",
        "remove_file",
        "glob",
        "list_directory",
        "present_files",
        "search",
        "set_git_worktree",
    };
    for (path_tools) |tool_name| {
        const entry = findEntry(output, tool_name) orelse {
            std.debug.print("registry is missing path-taking tool '{s}'\n", .{tool_name});
            return error.TestUnexpectedResult;
        };
        const cwd = findParam(entry, "cwd") orelse {
            std.debug.print("'{s}' has no `cwd` parameter\n", .{tool_name});
            return error.TestUnexpectedResult;
        };
        if (!cwd.required) {
            std.debug.print("'{s}' does not REQUIRE `cwd`\n", .{tool_name});
            return error.TestUnexpectedResult;
        }
    }

    // Controls, so the loop above cannot pass vacuously: a tool with no
    // filesystem parameter must not carry a `cwd`, and the two tools whose
    // `cwd` was dropped the same day must not have kept one.
    const cwd_free = [_][]const u8{ "ask_user", "create_kanban_task", "add_mcp_server" };
    for (cwd_free) |tool_name| {
        const entry = findEntry(output, tool_name) orelse {
            std.debug.print("registry is missing '{s}'\n", .{tool_name});
            return error.TestUnexpectedResult;
        };
        try testing.expect(findParam(entry, "cwd") == null);
    }

    // The swept tools are gone from the published schema too — being absent
    // from the registry is what makes a name uncallable.
    for ([_][]const u8{ "change_agent", "list_agents", "remove_agent" }) |tool_name| {
        try testing.expect(findEntry(output, tool_name) == null);
    }
}

test "useCase: returns a non-empty registry" {
    const alloc = testing.allocator;
    const output = try useCase(alloc);
    defer freeOutput(alloc, output);
    try testing.expect(output.entries.len > 0);
}

test "useCase: every entry has non-empty name and description" {
    const alloc = testing.allocator;
    const output = try useCase(alloc);
    defer freeOutput(alloc, output);
    for (output.entries) |e| {
        try testing.expect(e.name.len > 0);
        try testing.expect(e.description.len > 0);
    }
}
