const std = @import("std");
const builtin = @import("builtin");
const prompts = @import("prompts/prompts.zig");
const memory_prompts = @import("prompts/memory.zig");
const tool_search_skills_mod = @import("tools/skill_tools.zig");
const tool_models = @import("Agent.zig");
const tool_memories_mod = @import("tools/memories.zig");

// =============================================================================
// Re-exports only.

// Re-export all prompts for easy access
pub const UniversalRules = prompts.UniversalRules;
pub const PromptAutoFix = prompts.PromptAutoFix;
pub const Agent = prompts.Agent;
pub const ParallelWork = prompts.ParallelWork;
pub const Classification = prompts.Classification;
pub const Execution = prompts.Execution;
pub const Escalation = prompts.Escalation;
pub const MemoryPrompt = prompts.MemoryPrompt;
pub const PabrikMdAutoUpdate = prompts.PabrikMdAutoUpdate;
pub const GitPrompt = prompts.GitPrompt;
pub const GlobalMemorySystem = prompts.GlobalMemorySystem;
pub const LocalMemorySystem = prompts.LocalMemorySystem;
pub const CompactionAgent = prompts.CompactionAgent;
pub const GenerateSessionNameAgent = prompts.GenerateSessionNameAgent;
pub const ResponseFormatting = prompts.ResponseFormatting;
pub const SearchToolRule = prompts.SearchToolRule;
pub const ReadWorkspaceSessionToolRule = prompts.ReadWorkspaceSessionToolRule;
pub const MemoryToolRule = prompts.MemoryToolRule;
// The agent's special tool (search the catalog for the tool a task needs) and
// its special skills (load the skill a task needs).
pub const ProgressiveToolRule = prompts.ProgressiveToolRule;
pub const SkillsToolRule = prompts.SkillsToolRule;
// Skill Evals — evaluate the skills this session actually used.
pub const SkillEvalToolRule = prompts.SkillEvalToolRule;
// The write half of the skills loop — `add_skill` when a task taught
// something a future session would otherwise rediscover, `edit_skill` when an
// eval flags a skill as stale.
pub const SkillWriteToolRule = prompts.SkillWriteToolRule;
// Session VCS binding — see the comment above the constants in
// `prompts/core.zig`. Appended unconditionally by `buildMessages`, immediately
// after `SkillWriteToolRule` and before the gated Secrets rule.
pub const GitWorktreeToolRule = prompts.GitWorktreeToolRule;
pub const PullRequestToolRule = prompts.PullRequestToolRule;

// ---------------------------------------------------------------------------
// Thin delegating re-exports for the two pure helpers that `prompts_test.zig`
// exercises directly.
pub const loadGlobalKnowledge = @import("../../agentic_loop/prompts_build_messages_for_agent_prompt.zig").loadGlobalKnowledge;
pub const loadLocalKnowledge = @import("../../agentic_loop/prompts_build_messages_for_agent_prompt.zig").loadLocalKnowledge;
pub const SubAgentListingRow = @import("../../agentic_loop/prompts_build_messages_for_agent_prompt.zig").SubAgentListingRow;
pub const appendSubAgentsListing = @import("../../agentic_loop/prompts_build_messages_for_agent_prompt.zig").appendSubAgentsListing;

// ===== Tests merged from prompts_test.zig (2026-09-29 flatten) =====
const prompts_mod = @import("../../agentic_loop/prompts_build_messages_for_agent_prompt.zig");
const AgentTool = tool_models.AgentTool;
const AgentToolFunction = tool_models.AgentToolFunction;
const ToolParameters = tool_models.ToolParameters;
// `tool_models` here is Agent.zig, whose `ToolProperty` alias is private.
// The test builds schemas.AgentTool literals, so reach the real type
// through the schemas module directly.
const ToolProperty = @import("tools/schemas.zig").ToolProperty;

// Helper: substring check
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// Build a minimal AgentTool for use in tests.
fn makeTool(name: []const u8, desc: []const u8) AgentTool {
    return AgentTool{
        .type = "function",
        .function = .{
            .name = name,
            .description = desc,
            .parameters = .{
                .type = "object",
                .properties = &[_]ToolProperty{},
                .required = &[_][]const u8{},
            },
        },
    };
}

// -------------------------------------------------------------------------
// build_agent_prompt — empty / no-memory cases
test "build_agent_prompt loads memory files into Global Knowledge section" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/pabrik-main-prompt-test";
    const memories_dir = "/tmp/pabrik-main-prompt-test/.config/pabrik/memories";
    const file_path = "/tmp/pabrik-main-prompt-test/.config/pabrik/memories/regression-test-rule.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Write a Regression Test First
            \\
            \\After fixing a tricky bug, write a regression test before
            \\touching anything else. Fixes without tests regress.
            \\
        );
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
        makeTool("list_memory", "List memory files"),
    };
    const prompt = try prompts_mod.build_agent_prompt(alloc, io, "/tmp", "", "", "", "", &tools, "", &env, "", "", "", "");
    defer alloc.free(prompt);

    // The Global Knowledge section is present
    try std.testing.expect(contains(prompt, "## Global Knowledge"));
    // The memory file is loaded with its content
    try std.testing.expect(contains(prompt, "regression-test-rule.md"));
    try std.testing.expect(contains(prompt, "Write a Regression Test First"));
    try std.testing.expect(contains(prompt, "Fixes without tests regress"));
}

// build_agent_prompt — Available Skills listing
// -------------------------------------------------------------------------

test "build_agent_prompt omits Available Skills section when search_skills tool is absent" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Set up a HOME with a real skill, so the test confirms the GATING,
    // not just the "no skill found" path.
    const tmp_home = "/tmp/pabrik-prompt-test-skills-gated";
    const global_skill_dir = "/tmp/pabrik-prompt-test-skills-gated/.config/pabrik/skills/test-gated-skill";
    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, global_skill_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(
            io,
            "/tmp/pabrik-prompt-test-skills-gated/.config/pabrik/skills/test-gated-skill/SKILL.MD",
            .{},
        );
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\---
            \\name: test-gated-skill
            \\description: "Should be hidden when search_skills is absent"
            \\---
            \\
        );
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    // Tools list intentionally does NOT include search_skills
    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
    };
    const prompt = try prompts_mod.build_agent_prompt(alloc, io, "/tmp", "", "", "", "", &tools, "", &env, "", "", "", "");
    defer alloc.free(prompt);

    try std.testing.expect(!contains(prompt, "## Available Skills"));
    try std.testing.expect(!contains(prompt, "test-gated-skill"));
}

test "build_agent_prompt silently skips Available Skills when env is null" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // search_skills IS in the tools list, but env is null → graceful skip
    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
        makeTool("search_skills", "Search available skills"),
    };
    const prompt = try prompts_mod.build_agent_prompt(alloc, io, "/tmp", "", "", "", "", &tools, "", null, // ← env is null
        "", "", "", "");
    defer alloc.free(prompt);

    // No section emitted; no error thrown
    try std.testing.expect(!contains(prompt, "## Available Skills"));
}

// build_agent_prompt — Local Knowledge section (<cwd>/.pabrik/memories/*.md)
// -------------------------------------------------------------------------

test "build_agent_prompt injects Local Knowledge section from <cwd>/.pabrik/memories" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/pabrik-prompt-test-local-knowledge";
    const local_dir = "/tmp/pabrik-prompt-test-local-knowledge/.pabrik/memories";
    const file_path = "/tmp/pabrik-prompt-test-local-knowledge/.pabrik/memories/project-rule.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};

    try std.Io.Dir.cwd().createDirPath(io, local_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Project Build Rule
            \\
            \\Always run `zig build test:ai_workflow:tui` before declaring a
            \\task done in this repo. Fixes without tests regress.
            \\
        );
    }

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
    };
    const prompt = try prompts_mod.build_agent_prompt(alloc, io, tmp_cwd, "", "", "", "", &tools, "", null, // env is null — only local knowledge should be present
        "", "", "", "");
    defer alloc.free(prompt);

    // The section header is present
    try std.testing.expect(contains(prompt, "## Local Knowledge"));
    // Filename appears (in the ### <title> (`<filename>`) heading)
    try std.testing.expect(contains(prompt, "project-rule.md"));
    // H1-derived title appears
    try std.testing.expect(contains(prompt, "Project Build Rule"));
    // Full content appears (not truncated)
    try std.testing.expect(contains(prompt, "Always run `zig build test:ai_workflow:tui`"));
    try std.testing.expect(contains(prompt, "Fixes without tests regress"));
    // Preamble tells the model where the files came from
    try std.testing.expect(contains(prompt, "auto-loaded from `<cwd>/.pabrik/memories/`"));
}

// build_agent_prompt — Memory paths are rendered alongside filenames
// -------------------------------------------------------------------------
// Every memory entry rendered in the `## Local Knowledge` / `## Global

test "build_agent_prompt Global Knowledge section emits each memory's absolute path" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/pabrik-prompt-test-global-knowledge-path";
    const memories_dir = "/tmp/pabrik-prompt-test-global-knowledge-path/.config/pabrik/memories";
    const file_path = "/tmp/pabrik-prompt-test-global-knowledge-path/.config/pabrik/memories/path-test-rule.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Path Emission Test
            \\
            \\Body content for the path-emission regression test.
            \\
        );
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const tools = [_]AgentTool{
        makeTool("list_memory", "List memory files"),
    };
    const prompt = try prompts_mod.build_agent_prompt(alloc, io, "/tmp", "", "", "", "", &tools, "", &env, "", "", "", "");
    defer alloc.free(prompt);

    // The full absolute path appears in the prompt — copy-pasteable
    // straight into read_file / write_file / text_replace / remove_file.
    try std.testing.expect(contains(prompt, file_path));
    // The path appears inside backticks (Markdown code span), not as a
    // bare string — that's the convention for paths in this prompt.
    try std.testing.expect(contains(prompt, "`" ++ file_path ++ "`"));
    // The heading format is unchanged — the path is a separate line below
    // the `### <title> (`<filename>`)` heading, not part of it.
    try std.testing.expect(contains(prompt, "### Path Emission Test (`path-test-rule.md`)"));
}

test "build_agent_prompt Local Knowledge section emits each memory's absolute path" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/pabrik-prompt-test-local-knowledge-path";
    const local_dir = "/tmp/pabrik-prompt-test-local-knowledge-path/.pabrik/memories";
    const file_path = "/tmp/pabrik-prompt-test-local-knowledge-path/.pabrik/memories/local-path-rule.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};

    try std.Io.Dir.cwd().createDirPath(io, local_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Local Path Emission Test
            \\
            \\Body content for the local-memory path-emission regression test.
            \\
        );
    }

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
    };
    const prompt = try prompts_mod.build_agent_prompt(alloc, io, tmp_cwd, "", "", "", "", &tools, "", null, "", "", "", "");
    defer alloc.free(prompt);

    // Full absolute path of the local memory, copy-pasteable.
    try std.testing.expect(contains(prompt, file_path));
    // Wrapped in a Markdown code span.
    try std.testing.expect(contains(prompt, "`" ++ file_path ++ "`"));
    // Heading format is unchanged.
    try std.testing.expect(contains(prompt, "### Local Path Emission Test (`local-path-rule.md`)"));
}

test "build_agent_prompt renders Local and Global Knowledge together when both exist" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Set up a HOME with a global memory
    const tmp_home = "/tmp/pabrik-prompt-test-local-and-global-home";
    const global_dir = "/tmp/pabrik-prompt-test-local-and-global-home/.config/pabrik/memories";
    const global_file = "/tmp/pabrik-prompt-test-local-and-global-home/.config/pabrik/memories/global-rule.md";

    // And a cwd with a local memory
    const tmp_cwd = "/tmp/pabrik-prompt-test-local-and-global-cwd";
    const local_dir = "/tmp/pabrik-prompt-test-local-and-global-cwd/.pabrik/memories";
    const local_file = "/tmp/pabrik-prompt-test-local-and-global-cwd/.pabrik/memories/local-rule.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer {
        std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
        std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    }

    try std.Io.Dir.cwd().createDirPath(io, global_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, global_file, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Global Cross-Project Rule
            \\
            \\This rule applies to every pabrik project.
            \\
        );
    }

    try std.Io.Dir.cwd().createDirPath(io, local_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, local_file, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Local Project Rule
            \\
            \\This rule is specific to this project only.
            \\
        );
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
        makeTool("list_memory", "List memory files"),
    };
    const prompt = try prompts_mod.build_agent_prompt(alloc, io, tmp_cwd, "", "", "", "", &tools, "", &env, "", "", "", "");
    defer alloc.free(prompt);

    // Both sections are present
    try std.testing.expect(contains(prompt, "## Local Knowledge"));
    try std.testing.expect(contains(prompt, "## Global Knowledge"));
    // Both files appear
    try std.testing.expect(contains(prompt, "local-rule.md"));
    try std.testing.expect(contains(prompt, "Local Project Rule"));
    try std.testing.expect(contains(prompt, "global-rule.md"));
    try std.testing.expect(contains(prompt, "Global Cross-Project Rule"));

    // Local Knowledge appears BEFORE Global Knowledge in the rendered prompt
    // (most-specific-first ordering).
    const local_pos = std.mem.indexOf(u8, prompt, "## Local Knowledge").?;
    const global_pos = std.mem.indexOf(u8, prompt, "## Global Knowledge").?;
    try std.testing.expect(local_pos < global_pos);
}

test "build_agent_prompt omits Local Knowledge when <cwd>/.pabrik/memories does not exist" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Use a cwd that has no .pabrik/ subdir at all
    const tmp_cwd = "/tmp/pabrik-prompt-test-no-local-dir";

    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    std.Io.Dir.cwd().createDirPath(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
    };
    const prompt = try prompts_mod.build_agent_prompt(alloc, io, tmp_cwd, "", "", "", "", &tools, "", null, "", "", "", "");
    defer alloc.free(prompt);

    // No .pabrik/memories → no Local Knowledge section
    try std.testing.expect(!contains(prompt, "## Local Knowledge"));
}

test "build_agent_prompt omits Local Knowledge when cwd is empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
    };
    const prompt = try prompts_mod.build_agent_prompt(alloc, io, "", // ← cwd is empty
        "", "", "", "", &tools, "", null, "", "", "", "");
    defer alloc.free(prompt);

    // No cwd → no Local Knowledge section
    try std.testing.expect(!contains(prompt, "## Local Knowledge"));
}

// build_agent_prompt — LocalMemorySystem static section (no gating)
// -------------------------------------------------------------------------
// The LocalMemorySystem section is static — it appears in every prompt

test "build_agent_prompt omits Local Knowledge when <cwd>/.pabrik/memories has no .md files" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/pabrik-prompt-test-local-dir-empty";
    const local_dir = "/tmp/pabrik-prompt-test-local-dir-empty/.pabrik/memories";
    const txt_path = "/tmp/pabrik-prompt-test-local-dir-empty/.pabrik/memories/notes.txt";

    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};

    try std.Io.Dir.cwd().createDirPath(io, local_dir);
    // Drop a non-md file
    {
        const f = try std.Io.Dir.createFileAbsolute(io, txt_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "not a memory");
    }

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
    };
    const prompt = try prompts_mod.build_agent_prompt(alloc, io, tmp_cwd, "", "", "", "", &tools, "", null, "", "", "", "");
    defer alloc.free(prompt);

    // Dir exists but has no .md files → no section
    try std.testing.expect(!contains(prompt, "## Local Knowledge"));
}

// ---------------------------------------------------------------------------
// appendSubAgentsListing — "Available Sub-Agents" section
// ---------------------------------------------------------------------------

test "appendSubAgentsListing: empty rows slice is a no-op" {
    const alloc = std.testing.allocator;

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try appendSubAgentsListing(alloc, &result, &.{});
    try std.testing.expectEqual(@as(usize, 0), result.items.len);
}

test "appendSubAgentsListing: renders a single row with name + model + description" {
    const alloc = std.testing.allocator;

    const rows = [_]SubAgentListingRow{
        .{
            .name = "code-reviewer",
            .model = "gpt-4o",
            .description = "You are a strict code reviewer.",
            .source = "",
        },
    };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try appendSubAgentsListing(alloc, &result, &rows);

    const out = result.items;
    // Header is present.
    try std.testing.expect(contains(out, "## Available Sub-Agents"));
    // Row is rendered with name, model, description.
    try std.testing.expect(contains(out, "**code-reviewer**"));
    try std.testing.expect(contains(out, "model: `gpt-4o`"));
    try std.testing.expect(contains(out, "You are a strict code reviewer."));
    // No source suffix when source is empty.
    try std.testing.expect(!contains(out, "from profile"));
    // Footer explains where the list came from.
    try std.testing.expect(contains(out, "sub_agents"));
    try std.testing.expect(contains(out, "profile"));
}

test "appendSubAgentsListing: per-profile source suffix is shown" {
    const alloc = std.testing.allocator;

    const rows = [_]SubAgentListingRow{
        .{
            .name = "reviewer",
            .model = "gpt-4o",
            .description = "Profile-specific reviewer.",
            .source = "profile1",
        },
    };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try appendSubAgentsListing(alloc, &result, &rows);

    try std.testing.expect(contains(result.items, "from profile `profile1`"));
}

test "appendSubAgentsListing: rows with empty name are skipped (defensive)" {
    const alloc = std.testing.allocator;

    const rows = [_]SubAgentListingRow{
        .{ .name = "", .model = "m", .description = "should be skipped", .source = "" },
        .{ .name = "valid", .model = "m", .description = "should be rendered", .source = "" },
    };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try appendSubAgentsListing(alloc, &result, &rows);

    try std.testing.expect(!contains(result.items, "should be skipped"));
    try std.testing.expect(contains(result.items, "should be rendered"));
    try std.testing.expect(contains(result.items, "**valid**"));
}

test "appendSubAgentsListing: empty model/description still renders the row" {
    const alloc = std.testing.allocator;

    const rows = [_]SubAgentListingRow{
        .{ .name = "minimal", .model = "", .description = "", .source = "" },
    };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try appendSubAgentsListing(alloc, &result, &rows);

    // The name is present but neither the model nor the
    // description is rendered (no "model: \`\`", no em-dash).
    try std.testing.expect(contains(result.items, "**minimal**"));
    try std.testing.expect(!contains(result.items, "model: `"));
    try std.testing.expect(!contains(result.items, " — \""));
}

test "build_agent_prompt with sub_agents_listing: section is omitted when empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{};
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "", // empty sub_agents_listing
        "", // empty workspaceContext
        "", // empty kanbanStatusContent
        "", // empty designStatusContent
    );
    defer alloc.free(prompt);

    try std.testing.expect(!contains(prompt, "## Available Sub-Agents"));
}

// ---------------------------------------------------------------------------
// build_agent_prompt with kanbanStatusContent — tests for the `## Kanban
// Status Tracking` section (added by the 2026-06-27 kanban-status-prompt

test "build_agent_prompt renders Kanban Status Tracking when section is non-empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{};
    const kanban_block =
        \\## Kanban Status Tracking
        \\
        \\This task is on a kanban board (parent item_type: `kanban`).
        \\**You MUST call the `kanban_move_task` tool at every meaningful
        \\workflow checkpoint** below.
        \\
        \\**Current column:** `todo` (`col_a`)
        \\
        \\**Columns on this board** (in flow order):
        \\- `todo` (`col_a`, position 0)
        \\- `in progress` (`col_b`, position 1)
        \\- `done` (`col_c`, position 2)
        \\
        \\**Status transitions** (call `kanban_move_task`):
        \\- **start** — move from `todo` → `in progress`
        \\- **complete** — move to `done` before your final reply
        \\- **blocked** — do NOT move
    ;
    const prompt = try prompts_mod.build_agent_prompt(alloc, io, "/tmp", "", "", "", "", &tools, "", null, "", "", kanban_block, "");
    defer alloc.free(prompt);

    try std.testing.expect(contains(prompt, "## Kanban Status Tracking"));
    try std.testing.expect(contains(prompt, "MUST call the `kanban_move_task` tool"));
    try std.testing.expect(contains(prompt, "Current column:** `todo` (`col_a`)"));
    try std.testing.expect(contains(prompt, "- `todo` (`col_a`, position 0)"));
    try std.testing.expect(contains(prompt, "**start**"));
    try std.testing.expect(contains(prompt, "**complete**"));
    try std.testing.expect(contains(prompt, "**blocked**"));
}

test "build_agent_prompt omits Kanban Status Tracking when section is empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{};
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        "", // empty workspaceContext
        "", // empty kanbanStatusContent
        "", // empty designStatusContent
    );
    defer alloc.free(prompt);

    try std.testing.expect(!contains(prompt, "## Kanban Status Tracking"));
    try std.testing.expect(!contains(prompt, "MUST call the `kanban_move_task`"));
}

// ---------------------------------------------------------------------------
// loadGlobalKnowledge — direct unit tests for the memory-file loader.

test "loadGlobalKnowledge returns empty string when env is null" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const result = try loadGlobalKnowledge(alloc, io, null);
    defer alloc.free(result);

    // Graceful degradation: no error, no content.
    try std.testing.expectEqualStrings("", result);
}

test "loadGlobalKnowledge returns empty string when HOME has no memories subdir" {
    // First-run case: HOME exists but the user has not created
    // ~/.config/pabrik/memories/ yet. Must not error, must return "".
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/pabrik-load-global-knowledge-missing-dir";
    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_home);

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const result = try loadGlobalKnowledge(alloc, io, &env);
    defer alloc.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "loadGlobalKnowledge returns empty string when memories dir exists but is empty" {
    // The dir exists but contains no .md files. Mirrors the first-run
    // contract: no memories → no Global Knowledge content.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/pabrik-load-global-knowledge-empty-dir";
    const memories_dir = "/tmp/pabrik-load-global-knowledge-empty-dir/.config/pabrik/memories";
    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, memories_dir);

    // Drop a non-md file to confirm it's ignored, not picked up as a memory.
    const txt_path = "/tmp/pabrik-load-global-knowledge-empty-dir/.config/pabrik/memories/notes.txt";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, txt_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "should be ignored");
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const result = try loadGlobalKnowledge(alloc, io, &env);
    defer alloc.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "loadGlobalKnowledge loads a single memory file with H1 title" {
    // The happy path: one .md file with an H1 heading. The function must emit
    // `### <title> (`<filename>`)` followed by the full file content.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/pabrik-load-global-knowledge-single-h1";
    const memories_dir = "/tmp/pabrik-load-global-knowledge-single-h1/.config/pabrik/memories";
    const file_path = "/tmp/pabrik-load-global-knowledge-single-h1/.config/pabrik/memories/regression-test-rule.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Write a Regression Test First
            \\
            \\After fixing a tricky bug, write a regression test before
            \\touching anything else. Fixes without tests regress.
            \\
        );
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const result = try loadGlobalKnowledge(alloc, io, &env);
    defer alloc.free(result);

    // Heading uses the H1 title in backticks, paired with the filename.
    try std.testing.expect(contains(result, "### Write a Regression Test First (`regression-test-rule.md`)"));
    // Full file content is included (not truncated).
    try std.testing.expect(contains(result, "After fixing a tricky bug, write a regression test before"));
    try std.testing.expect(contains(result, "touching anything else. Fixes without tests regress"));
    // Trailing blank line separator between entries.
    try std.testing.expect(contains(result, "regress.\n\n"));
}

test "loadGlobalKnowledge uses filename stem as title when no H1 is present" {
    // No H1 → `extractTitle` falls back to the filename stem (e.g.
    // "random-name.md" → "random-name"). The rendered heading must use
    // the stem in place of an H1 title.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/pabrik-load-global-knowledge-no-h1";
    const memories_dir = "/tmp/pabrik-load-global-knowledge-no-h1/.config/pabrik/memories";
    const file_path = "/tmp/pabrik-load-global-knowledge-no-h1/.config/pabrik/memories/random-name.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "Just some prose, no header at all.\n");
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const result = try loadGlobalKnowledge(alloc, io, &env);
    defer alloc.free(result);

    // Title is the stem (without .md), not the full filename.
    try std.testing.expect(contains(result, "### random-name (`random-name.md`)"));
    // File body is present.
    try std.testing.expect(contains(result, "Just some prose, no header at all."));
}

test "loadGlobalKnowledge concatenates multiple memory files" {
    // Two .md files in the same dir → both rendered, separated by a blank
    // line.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/pabrik-load-global-knowledge-multi";
    const memories_dir = "/tmp/pabrik-load-global-knowledge-multi/.config/pabrik/memories";
    const file1 = "/tmp/pabrik-load-global-knowledge-multi/.config/pabrik/memories/after-fix-test.md";
    const file2 = "/tmp/pabrik-load-global-knowledge-multi/.config/pabrik/memories/stderr-debug.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file1, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Write Regression Test First
            \\
            \\Always add a regression test after fixing a tricky bug.
            \\
        );
    }
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file2, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Use stderr for Debug Output
            \\
            \\Stderr can be redirected without affecting stdout.
            \\
        );
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const result = try loadGlobalKnowledge(alloc, io, &env);
    defer alloc.free(result);

    // Both headings appear.
    try std.testing.expect(contains(result, "### Write Regression Test First (`after-fix-test.md`)"));
    try std.testing.expect(contains(result, "### Use stderr for Debug Output (`stderr-debug.md`)"));
    // Both bodies appear.
    try std.testing.expect(contains(result, "Always add a regression test after fixing a tricky bug."));
    try std.testing.expect(contains(result, "Stderr can be redirected without affecting stdout."));
}

test "loadGlobalKnowledge skips a corrupt file and loads the rest" {
    // Mirrors the "openFile/readFile errors skip-and-continue" contract from
    // `loadGlobalKnowledge`.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/pabrik-load-global-knowledge-corrupt-skip";
    const memories_dir = "/tmp/pabrik-load-global-knowledge-corrupt-skip/.config/pabrik/memories";
    const bad_path = "/tmp/pabrik-load-global-knowledge-corrupt-skip/.config/pabrik/memories/broken.md";
    const good_path = "/tmp/pabrik-load-global-knowledge-corrupt-skip/.config/pabrik/memories/working.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);

    // Create `broken.md` AS A DIRECTORY (so openFile fails — it's not
    // a regular file). This simulates a corrupt / permission-denied
    // file. The loader must skip it, not abort.
    try std.Io.Dir.cwd().createDirPath(io, bad_path);

    {
        const f = try std.Io.Dir.createFileAbsolute(io, good_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Good Memory
            \\
            \\This file loads fine.
            \\
        );
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const result = try loadGlobalKnowledge(alloc, io, &env);
    defer alloc.free(result);

    // The good file is rendered; the bad one is silently absent.
    try std.testing.expect(contains(result, "### Good Memory (`working.md`)"));
    try std.testing.expect(contains(result, "This file loads fine."));
    try std.testing.expect(!contains(result, "broken.md"));
}

// ---------------------------------------------------------------------------
// loadLocalKnowledge — direct unit tests for the per-project memory loader.

test "loadLocalKnowledge returns empty string when cwd is empty" {
    // No project context → no local knowledge. Mirrors the first-run
    // contract: an empty cwd must NOT error, must return "".
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const result = try loadLocalKnowledge(alloc, io, "");
    defer alloc.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "loadLocalKnowledge returns empty string when cwd has no .pabrik/memories subdir" {
    // First-run case: cwd is a real path but the user has not created
    // `<cwd>/.pabrik/memories/` yet. Must not error, must return "".
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/pabrik-load-local-knowledge-missing-dir";
    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_cwd);

    const result = try loadLocalKnowledge(alloc, io, tmp_cwd);
    defer alloc.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "loadLocalKnowledge returns empty string when memories dir exists but is empty" {
    // The dir exists but contains no .md files. Mirrors the first-run
    // contract: no memories → no Local Knowledge content.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/pabrik-load-local-knowledge-empty-dir";
    const memories_dir = "/tmp/pabrik-load-local-knowledge-empty-dir/.pabrik/memories";
    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    try std.Io.Dir.cwd().createDirPath(io, memories_dir);

    // Drop a non-md file to confirm it's ignored, not picked up as a memory.
    const txt_path = "/tmp/pabrik-load-local-knowledge-empty-dir/.pabrik/memories/notes.txt";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, txt_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "should be ignored");
    }

    const result = try loadLocalKnowledge(alloc, io, tmp_cwd);
    defer alloc.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "loadLocalKnowledge loads a single memory file with H1 title" {
    // Happy path: one .md file with an H1 heading. The function must emit
    // `### <title> (<filename>)` followed by the full file content.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/pabrik-load-local-knowledge-single-h1";
    const memories_dir = "/tmp/pabrik-load-local-knowledge-single-h1/.pabrik/memories";
    const file_path = "/tmp/pabrik-load-local-knowledge-single-h1/.pabrik/memories/project-build-rule.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Project Build Rule
            \\
            \\Always run `zig build test:ai_workflow:tui` before declaring
            \\a task done in this repo. Fixes without tests regress.
            \\
        );
    }

    const result = try loadLocalKnowledge(alloc, io, tmp_cwd);
    defer alloc.free(result);

    // Heading uses the H1 title in backticks, paired with the filename.
    try std.testing.expect(contains(result, "### Project Build Rule (`project-build-rule.md`)"));
    // Full file content is included (not truncated).
    try std.testing.expect(contains(result, "Always run `zig build test:ai_workflow:tui` before declaring"));
    try std.testing.expect(contains(result, "a task done in this repo. Fixes without tests regress"));
    // Trailing blank line separator between entries.
    try std.testing.expect(contains(result, "regress.\n\n"));
}

test "loadLocalKnowledge uses filename stem as title when no H1 is present" {
    // No H1 → `extractTitle` falls back to the filename stem (e.g.
    // "random-name.md" → "random-name"). The rendered heading must use
    // the stem in place of an H1 title.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/pabrik-load-local-knowledge-no-h1";
    const memories_dir = "/tmp/pabrik-load-local-knowledge-no-h1/.pabrik/memories";
    const file_path = "/tmp/pabrik-load-local-knowledge-no-h1/.pabrik/memories/random-name.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "Just some prose, no header at all.\n");
    }

    const result = try loadLocalKnowledge(alloc, io, tmp_cwd);
    defer alloc.free(result);

    // Title is the stem (without .md), not the full filename.
    try std.testing.expect(contains(result, "### random-name (`random-name.md`)"));
    // File body is present.
    try std.testing.expect(contains(result, "Just some prose, no header at all."));
}

test "loadLocalKnowledge concatenates multiple memory files" {
    // Two .md files in the same dir → both rendered, separated by a blank
    // line.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/pabrik-load-local-knowledge-multi";
    const memories_dir = "/tmp/pabrik-load-local-knowledge-multi/.pabrik/memories";
    const file1 = "/tmp/pabrik-load-local-knowledge-multi/.pabrik/memories/run-tests-first.md";
    const file2 = "/tmp/pabrik-load-local-knowledge-multi/.pabrik/memories/commit-style.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file1, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Run Tests First
            \\
            \\Always run the test suite before committing.
            \\
        );
    }
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file2, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Commit Style
            \\
            \\Use conventional commits for this project.
            \\
        );
    }

    const result = try loadLocalKnowledge(alloc, io, tmp_cwd);
    defer alloc.free(result);

    // Both headings appear.
    try std.testing.expect(contains(result, "### Run Tests First (`run-tests-first.md`)"));
    try std.testing.expect(contains(result, "### Commit Style (`commit-style.md`)"));
    // Both bodies appear.
    try std.testing.expect(contains(result, "Always run the test suite before committing."));
    try std.testing.expect(contains(result, "Use conventional commits for this project."));
}

test "loadLocalKnowledge skips a corrupt file and loads the rest" {
    // Mirrors the "openFile/readFile errors skip-and-continue" contract from
    // `loadLocalKnowledge`.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/pabrik-load-local-knowledge-corrupt-skip";
    const memories_dir = "/tmp/pabrik-load-local-knowledge-corrupt-skip/.pabrik/memories";
    const bad_path = "/tmp/pabrik-load-local-knowledge-corrupt-skip/.pabrik/memories/broken.md";
    const good_path = "/tmp/pabrik-load-local-knowledge-corrupt-skip/.pabrik/memories/working.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);

    // Create `broken.md` AS A DIRECTORY (so openFile fails — it's not
    // a regular file). This simulates a corrupt / permission-denied
    // file. The loader must skip it, not abort.
    try std.Io.Dir.cwd().createDirPath(io, bad_path);

    {
        const f = try std.Io.Dir.createFileAbsolute(io, good_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Good Memory
            \\
            \\This file loads fine.
            \\
        );
    }

    const result = try loadLocalKnowledge(alloc, io, tmp_cwd);
    defer alloc.free(result);

    // The good file is rendered; the bad one is silently absent.
    try std.testing.expect(contains(result, "### Good Memory (`working.md`)"));
    try std.testing.expect(contains(result, "This file loads fine."));
    try std.testing.expect(!contains(result, "broken.md"));
}

// ---------------------------------------------------------------------------
// build_agent_prompt — Workspace Context section
// ---------------------------------------------------------------------------

test "build_agent_prompt renders Workspace Context when section is non-empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{};
    // Realistic Workspace Context block (the same shape produced by
    // `BuildWorkspaceContext` in
    // `prompts_build_messages_for_agent_prompt.zig`).
    const workspaceContext =
        \\## Workspace Context
        \\
        \\This task is part of workspace `ws_smoke`. The other items in this
        \\workspace are listed below for discovery.
        \\
        \\- **Frontend** (item_type: `chat`, path: `/tmp/frontend`) *(this task)*
        \\  - task: `Setup` (type: standard, session: `sess_self`)
        \\  - task: `Build` (type: standard)
        \\- **Backend** (item_type: `chat`, path: `/tmp/backend`)
        \\  - task: `API` (type: standard, session: `sess_backend`)
        \\
    ;
    const prompt = try prompts_mod.build_agent_prompt(alloc, io, "/tmp", "", "", "", "", &tools, "", null, "", workspaceContext, "", "");
    defer alloc.free(prompt);

    // Section header is present.
    try std.testing.expect(contains(prompt, "## Workspace Context"));
    // Self marker is present.
    try std.testing.expect(contains(prompt, "*(this task)*"));
    // Item names are present.
    try std.testing.expect(contains(prompt, "**Frontend**"));
    try std.testing.expect(contains(prompt, "**Backend**"));
    // Item paths are present.
    try std.testing.expect(contains(prompt, "`/tmp/frontend`"));
    try std.testing.expect(contains(prompt, "`/tmp/backend`"));
    // Task names are present.
    try std.testing.expect(contains(prompt, "`Setup`"));
    try std.testing.expect(contains(prompt, "`Build`"));
    try std.testing.expect(contains(prompt, "`API`"));
    // Session IDs are present.
    try std.testing.expect(contains(prompt, "session: `sess_self`"));
    try std.testing.expect(contains(prompt, "session: `sess_backend`"));

    // Workspace Context is rendered between cwd and OS info.
    const cwd_pos = std.mem.indexOf(u8, prompt, "**Current working directory:**") orelse
        return error.CwdLineMissing;
    const ws_pos = std.mem.indexOf(u8, prompt, "## Workspace Context") orelse
        return error.WorkspaceContextMissing;
    const os_pos = std.mem.indexOf(u8, prompt, "**Operating System:**") orelse
        return error.OsLineMissing;
    try std.testing.expect(cwd_pos < ws_pos);
    try std.testing.expect(ws_pos < os_pos);
}

test "build_agent_prompt omits Workspace Context when section is empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{};
    // workspaceContext is "" — mirrors the production behavior when
    // the session is not bound to any workspace_item_task.
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        "", // empty workspaceContext
        "", // empty kanbanStatusContent
        "", // empty designStatusContent
    );
    defer alloc.free(prompt);

    // No Workspace Context section is rendered.
    try std.testing.expect(!contains(prompt, "## Workspace Context"));
    // No self-marker text either.
    try std.testing.expect(!contains(prompt, "*(this task)*"));
}

// ---------------------------------------------------------------------------
// build_agent_prompt — Search Tool Preference (MANDATORY) section.

test "build_agent_prompt always renders Search Tool Preference (unconditional)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Empty tool list — proves the section has no `requires_tool` gate.
    const tools = [_]AgentTool{};
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        "",
        "",
        "",
    );
    defer alloc.free(prompt);

    // Header is rendered.
    try std.testing.expect(contains(prompt, "## Search Tool Preference (MANDATORY)"));
    // Hard-rule language is preserved.
    try std.testing.expect(contains(prompt, "always use the `search` tool"));
    // The rule names the live tool, not the retired one — teaching `bash` is
    // what kept the model emitting it.
    try std.testing.expect(contains(prompt, "Do NOT run `rg`, `grep`, or `find` through the `command` tool"));
    // Mapping examples survived into the rendered prompt.
    try std.testing.expect(contains(prompt, "search(pattern=\"pattern\""));
    try std.testing.expect(contains(prompt, "group_by_file: false"));
    try std.testing.expect(contains(prompt, "word_boundary: true"));
    try std.testing.expect(contains(prompt, "literal: true"));
    // The opt-in rg fallback list is also present so agents know when a shell
    // `rg` (via `command`) is OK.
    try std.testing.expect(contains(prompt, "When a shell `rg` IS allowed"));
    try std.testing.expect(contains(prompt, "rg -C N"));
    try std.testing.expect(contains(prompt, "rg --json"));
    // Self-check is the closing reinforcement.
    try std.testing.expect(contains(prompt, "code/text search"));
}

test "build_agent_prompt Search Tool Preference appears even with non-empty tool list" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Realistic tool list — the search rule must still appear.
    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
        makeTool("bash", "Run a bash command"),
        makeTool("search", "Search tool"),
    };
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        "",
        "",
        "",
    );
    defer alloc.free(prompt);

    try std.testing.expect(contains(prompt, "## Search Tool Preference (MANDATORY)"));
    try std.testing.expect(contains(prompt, "always use the `search` tool"));
}

// -------------------------------------------------------------------------
// Memory Tools Rule (save_memory + load_memory) — gated on `load_memory`
// -------------------------------------------------------------------------

test "build_agent_prompt renders Memory Tools section when load_memory is in tool list" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // load_memory IS in tools → section rendered.
    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
        makeTool("load_memory", "Search saved notes (FTS5)"),
    };
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        "",
        "",
        "",
    );
    defer alloc.free(prompt);

    // Section header is rendered.
    try std.testing.expect(contains(prompt, "## Memory Tools"));
    // Both tool names are mentioned (the rule covers both tools).
    try std.testing.expect(contains(prompt, "save_memory"));
    try std.testing.expect(contains(prompt, "load_memory"));
    // FTS5 sanitization note is preserved (mirrors ReadWorkspaceSessionToolRule pattern).
    try std.testing.expect(contains(prompt, "FTS5") or contains(prompt, "FTS query syntax is auto-sanitized"));
    // When-to-call example survives.
    try std.testing.expect(contains(prompt, "do you remember"));
}

test "build_agent_prompt omits Memory Tools section when load_memory is absent" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // load_memory NOT in tools → section omitted entirely.
    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
        makeTool("bash", "Run shell"),
    };
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        "",
        "",
        "",
    );
    defer alloc.free(prompt);

    try std.testing.expect(!contains(prompt, "## Memory Tools"));
}

test "CompactionAgent constant teaches save_memory + load_memory (cross-session memory block)" {
    // CompactionAgent is a comptime string literal (`pub const X = \\…`), so
    // we read it directly without an allocator.
    const prompt: []const u8 = CompactionAgent;

    // The new block is present.
    try std.testing.expect(contains(prompt, "CROSS-SESSION MEMORY"));
    // Both tools are referenced.
    try std.testing.expect(contains(prompt, "save_memory"));
    try std.testing.expect(contains(prompt, "load_memory"));
    // The block teaches the compaction step to forward save/load cues to
    // the next agent rather than pasting the value verbatim.
    try std.testing.expect(contains(prompt, "save_memory id=") or
        contains(prompt, "load_memory query=") or
        contains(prompt, "next agent"));
}

// -------------------------------------------------------------------------
// ResponseFormatting — <html> wrapper tag (2026-08-23 html-tag-support)
// -------------------------------------------------------------------------

test "ResponseFormatting teaches the <html> wrapper tag" {
    // The model must know it CAN wrap raw HTML in <html>...</html> so the
    // chat UI renders it as a live sandboxed-iframe block. Capability
    // phrasing ("you can use"), not mandate.
    const prompt: []const u8 = ResponseFormatting;

    // The tag pair is present.
    try std.testing.expect(contains(prompt, "<html>"));
    try std.testing.expect(contains(prompt, "</html>"));
    // The capability phrasing the user asked for.
    try std.testing.expect(contains(prompt, "HTML Responses"));
    try std.testing.expect(contains(prompt, "you can use"));
    // Verbatim-emission note (wire-format requirement).
    try std.testing.expect(contains(prompt, "verbatim"));
    // Theme note (2026-09-13, task_1789312493325_7).
    try std.testing.expect(contains(prompt, "DARK"));
    try std.testing.expect(contains(prompt, "#1D1C19"));
}

// -------------------------------------------------------------------------
// Regression: build_agent_prompt was moved from src/modules/agent/prompts.zig
// into src/agentic_loop/prompts_build_messages_for_agent_prompt.zig on

// -------------------------------------------------------------------------
// ProgressiveToolRule + SkillsToolRule + MemoryToolRule +
// ReadWorkspaceSessionToolRule + GitWorktreeToolRule + PullRequestToolRule —

test "ProgressiveToolRule names the special tool and the three-call loop" {
    const prompt: []const u8 = ProgressiveToolRule;

    // It is framed as the agent's special tool with a mandate to use it.
    try std.testing.expect(contains(prompt, "your special tool"));
    try std.testing.expect(contains(prompt, "search_tool"));
    // The loop: search -> view -> use, in that order.
    const i_search = std.mem.indexOf(u8, prompt, "- `search_tool`").?;
    const i_view = std.mem.indexOf(u8, prompt, "- `view_tool`").?;
    const i_use = std.mem.indexOf(u8, prompt, "- `use_tool`").?;
    try std.testing.expect(i_search < i_view);
    try std.testing.expect(i_view < i_use);
    // The "always search to finish the task" mandate, not just "when stuck".
    try std.testing.expect(contains(prompt, "every task"));
    try std.testing.expect(contains(prompt, "Before hand-rolling"));
}

test "SkillsToolRule names the special skills and the search->use loop" {
    const prompt: []const u8 = SkillsToolRule;

    try std.testing.expect(contains(prompt, "your special skills"));
    const i_list = std.mem.indexOf(u8, prompt, "- `search_skills`").?;
    const i_use = std.mem.indexOf(u8, prompt, "- `use_skill`").?;
    try std.testing.expect(i_list < i_use);
    // Mandate: load the skill the task needs, before improvising.
    try std.testing.expect(contains(prompt, "When to load"));
    try std.testing.expect(contains(prompt, "blocking, not advisory"));
    // `use_skill` takes ONE argument — the name `search_skills` returned,
    // verbatim.
    try std.testing.expect(contains(prompt, "verbatim"));
    try std.testing.expect(!contains(prompt, "SKILL.MD"));
    try std.testing.expect(!contains(prompt, ".nalar/skills/"));
    try std.testing.expect(!contains(prompt, "is_global"));
    // Workspace scoping, and a miss is a real miss — no second tier to fall
    // back to.
    try std.testing.expect(contains(prompt, "workspace"));
    try std.testing.expect(contains(prompt, "genuinely not found"));
}

test "SkillsToolRule does not pre-list skills (no Available Skills listing)" {
    // A per-user listing in the system prompt would grow with the skill
    // library and bust the cacheable prefix. Discovery must stay a tool call.
    const prompt: []const u8 = SkillsToolRule;
    try std.testing.expect(!contains(prompt, "## Available Skills"));
    try std.testing.expect(!contains(prompt, "## Loaded Skills"));
    // It must instead say so explicitly, so the model knows to call the tool.
    try std.testing.expect(contains(prompt, "Nothing is pre-injected"));
}

// -------------------------------------------------------------------------
// Live-path coverage for the six tool mandates.

const prompt_migration = @import("../../migrations/migration.zig");
const prompt_sqlite = @import("pabrikcore").sqlite;

const PromptDbCtx = struct {
    db: prompt_sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupPromptDb() !PromptDbCtx {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: prompt_sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");
    var manager = prompt_migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try prompt_migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

/// The mandates, in the order buildMessages must append them.
const mandate_order = [_][]const u8{
    ProgressiveToolRule,
    SkillsToolRule,
    MemoryToolRule,
    ReadWorkspaceSessionToolRule,
    SkillEvalToolRule,
    SkillWriteToolRule,
    GitWorktreeToolRule,
    PullRequestToolRule,
};

/// Assemble one session's system prompt through the live path and hand
/// back an owned copy of the returned bytes.
fn buildSystemPrompt(ctx: *PromptDbCtx, cwd: []const u8, session_id: []const u8, tools: []AgentTool) ![]u8 {
    const alloc = std.testing.allocator;
    const messages = try prompts_mod.buildMessages(
        alloc,
        ctx.threaded.io(),
        &ctx.db,
        cwd,
        session_id,
        "",
        &.{},
        tools,
        "",
        "",
    );
    const prompt = try alloc.dupe(u8, messages[0].content orelse "");
    for (messages) |*msg| msg.deinit(alloc);
    alloc.free(messages);
    return prompt;
}

test "buildMessages: the eight mandates reach the live prompt, ungated by the tool list" {
    var ctx = try setupPromptDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const cwd = try std.testing.allocator.dupe(u8, path_buf[0..n]);
    defer std.testing.allocator.free(cwd);

    // A tool list carrying every tool the mandates talk about ...
    var with_everything = [_]AgentTool{
        makeTool("command", "Run a shell command"),
        makeTool("update_plan", "Track a plan"),
        makeTool("search_tool", "Search the tool catalog"),
        makeTool("view_tool", "Read a tool"),
        makeTool("use_tool", "Call a tool"),
        makeTool("search_skills", "Search installed skills"),
        makeTool("use_skill", "Load a skill"),
        makeTool("load_memory", "Search saved notes"),
        makeTool("save_memory", "Save a note"),
        makeTool("read_workspace_session", "Search past sessions"),
        makeTool("run_skill_eval", "Evaluate the skills this task used"),
        makeTool("add_skill", "Write a skill"),
        makeTool("edit_skill", "Update a skill"),
        makeTool("set_git_worktree", "Bind a worktree to this session"),
        makeTool("set_pull_request", "Bind a PR to this session"),
        makeTool("status_pull_request", "Read the bound PR's live status"),
    };
    // ... and one with none of them. The mandates are deliberately NOT
    // gated: a per-agent bit inside the cacheable prefix would fragment
    // the prompt cache once per distinct tool set.
    var with_none = [_]AgentTool{
        makeTool("read_file", "Read a file"),
        makeTool("text_replace", "Edit a file"),
    };

    const full = try buildSystemPrompt(&ctx, cwd, "sess_mandates_full", &with_everything);
    defer std.testing.allocator.free(full);
    const bare = try buildSystemPrompt(&ctx, cwd, "sess_mandates_bare", &with_none);
    defer std.testing.allocator.free(bare);

    for ([_][]const u8{ full, bare }) |prompt| {
        // Every mandate is present, in append order, and non-overlapping —
        // a dropped or reordered append fails here.
        var consumed: usize = 0;
        for (mandate_order) |rule| {
            const at = std.mem.indexOf(u8, prompt[consumed..], rule) orelse
                return error.MandateMissingFromLivePrompt;
            consumed += at + rule.len;
        }
        // No skill bodies / no skills listing injected: discovery stays a
        // `search_skills` call so the prefix does not grow with the user's
        // skill library.
        try std.testing.expect(!contains(prompt, "## Loaded Skills"));
        try std.testing.expect(!contains(prompt, "## Available Skills"));
    }

    // Non-vacuity: the tool list really did change the prompt (Task
    // Planning is gated on `update_plan`), yet every mandate survived it.
    try std.testing.expect(contains(full, "## Task Planning"));
    try std.testing.expect(!contains(bare, "## Task Planning"));
}

test "buildMessages: the mandates hold a byte-identical prefix across sessions" {
    var ctx = try setupPromptDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = try std.testing.allocator.dupe(u8, path_buf[0..n]);
    defer std.testing.allocator.free(root);

    // Two sessions that differ only in their working directory — the simplest
    // per-session payload.
    const cwd_a = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ root, "session-a" });
    defer std.testing.allocator.free(cwd_a);
    const cwd_b = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ root, "session-b" });
    defer std.testing.allocator.free(cwd_b);

    var tools = [_]AgentTool{makeTool("command", "Run a shell command")};

    const a = try buildSystemPrompt(&ctx, cwd_a, "sess_prefix_a", &tools);
    defer std.testing.allocator.free(a);
    const b = try buildSystemPrompt(&ctx, cwd_b, "sess_prefix_b", &tools);
    defer std.testing.allocator.free(b);

    // The tail is the LAST unconditional mandate.
    const tail = std.mem.indexOf(u8, a, PullRequestToolRule) orelse
        return error.MandateMissingFromLivePrompt;
    const prefix_len = tail + PullRequestToolRule.len;
    try std.testing.expect(prefix_len <= a.len);
    try std.testing.expect(prefix_len <= b.len);
    // Every byte up to the end of the last mandate is shared, so the block
    // the provider caches is one hit rather than one per session.
    try std.testing.expectEqualStrings(a[0..prefix_len], b[0..prefix_len]);

    // The prompts really do differ, and the difference starts strictly
    // AFTER that prefix: a per-session mutation cannot invalidate it.
    try std.testing.expect(!std.mem.eql(u8, a, b));
    const cwd_a_at = std.mem.indexOf(u8, a, cwd_a) orelse return error.CwdMissing;
    const cwd_b_at = std.mem.indexOf(u8, b, cwd_b) orelse return error.CwdMissing;
    try std.testing.expect(cwd_a_at > prefix_len);
    try std.testing.expect(cwd_b_at > prefix_len);
    try std.testing.expect(std.mem.indexOf(u8, a, cwd_b) == null);
    try std.testing.expect(std.mem.indexOf(u8, b, cwd_a) == null);
}

test "the tools the mandates name are really in the equipped set" {
    // A mandate that names a tool the agent does not carry is a lie the model
    // can do nothing about.
    const tools_equipped = @import("../../agentic_loop/tools_equipped.zig");
    const equipped = tools_equipped.equips(std.testing.allocator);
    defer std.testing.allocator.free(equipped);
    const named = [_][]const u8{
        "search_skills",
        "use_skill",
        "load_memory",
        "save_memory",
        "read_workspace_session",
        "run_skill_eval",
        "add_skill",
        "edit_skill",
        "set_git_worktree",
        "set_pull_request",
        "status_pull_request",
    };
    for (named) |name| {
        var found = false;
        for (equipped) |t| {
            if (std.mem.eql(u8, t.function.name, name)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "MemoryToolRule names both memory tools and the blocking gate" {
    const prompt: []const u8 = MemoryToolRule;

    try std.testing.expect(contains(prompt, "save_memory"));
    try std.testing.expect(contains(prompt, "load_memory"));
    // The mandate framing the user asked for — not optional, blocking.
    try std.testing.expect(contains(prompt, "NOT optional"));
    try std.testing.expect(contains(prompt, "blocking, not advisory"));
    // The two load triggers that make it actionable without re-reading the rule.
    try std.testing.expect(contains(prompt, "first user message of any session"));
    // Cross-reference stays accurate: buildMessages does inject this block.
    try std.testing.expect(contains(prompt, "## Global Knowledge"));
}

test "ReadWorkspaceSessionToolRule names the tool and the four behaviors" {
    const prompt: []const u8 = ReadWorkspaceSessionToolRule;

    try std.testing.expect(contains(prompt, "read_workspace_session"));
    // The anti-pattern it exists to stop.
    try std.testing.expect(contains(prompt, "ask the user to repeat themselves"));
    // FOUR BEHAVIORS, in the documented order: list / search / read / search-within.
    const i_behaviors = std.mem.indexOf(u8, prompt, "FOUR BEHAVIORS").?;
    const i_search = std.mem.indexOf(u8, prompt, "`query`").?;
    const i_read = std.mem.indexOf(u8, prompt, "`session_id`").?;
    const i_within = std.mem.indexOf(u8, prompt, "SEARCH-WITHIN").?;
    try std.testing.expect(i_behaviors < i_search);
    try std.testing.expect(i_search < i_read);
    try std.testing.expect(i_read < i_within);
    // The live filters must be named — the old "compacted_messages
    // envelopes" phrasing was stale jargon for a concept the tool now
    // exposes as live_only / compacted_only.
    try std.testing.expect(contains(prompt, "live_only"));
    try std.testing.expect(contains(prompt, "compacted_only"));
    try std.testing.expect(!contains(prompt, "compacted_messages"));
}

test "SkillEvalToolRule names the tool and its non-negotiable behaviors" {
    const prompt: []const u8 = SkillEvalToolRule;

    try std.testing.expect(contains(prompt, "run_skill_eval"));
    // The common case: nothing was loaded, so a skip is correct.
    try std.testing.expect(contains(prompt, "Skip it"));
    // A second call must read as a cheap no-op, not a second eval.
    try std.testing.expect(contains(prompt, "Once per task"));
    // The agent chooses WHEN, not the verdict — that is the whole design.
    try std.testing.expect(contains(prompt, "You are not the judge"));
    // It must NOT be told to pass the skill list: the tool reads the ledger,
    // which is what stops an agent omitting the skill it worked around.
    try std.testing.expect(contains(prompt, "you cannot"));
    try std.testing.expect(contains(prompt, "Self-check"));
    // It must be honest about the needs_human outcome rather than hiding it.
    try std.testing.expect(contains(prompt, "needs_human"));
}

// -------------------------------------------------------------------------
// SkillWriteToolRule — the WRITE half of the skills loop.

test "SkillWriteToolRule drives the create -> eval -> edit loop" {
    const prompt: []const u8 = SkillWriteToolRule;

    try std.testing.expect(contains(prompt, "add_skill"));
    try std.testing.expect(contains(prompt, "edit_skill"));
    // The loop closes on the eval tool: an outdated skill is fixed, not
    // re-litigated.
    try std.testing.expect(contains(prompt, "run_skill_eval"));
    const i_write_action = std.mem.indexOf(u8, prompt, "**When to write").?;
    const i_dup_check = std.mem.indexOf(u8, prompt, "check for a near-duplicate").?;
    const i_format = std.mem.indexOf(u8, prompt, "**Format").?;
    const i_loop = std.mem.indexOf(u8, prompt, "Close the loop").?;
    try std.testing.expect(i_write_action < i_dup_check);
    try std.testing.expect(i_dup_check < i_format);
    try std.testing.expect(i_format < i_loop);
}

test "SkillWriteToolRule states when NOT to write and what a skill body needs" {
    const prompt: []const u8 = SkillWriteToolRule;

    // The anti-bloat half. A write mandate without a stop condition trains
    // the agent to save every routine task, and every saved skill is a future
    // `search_skills` row that dilutes the ones that matter.
    try std.testing.expect(contains(prompt, "Do NOT write"));
    try std.testing.expect(contains(prompt, "fact"));
    // Facts go to save_memory; procedures go to skills.
    try std.testing.expect(contains(prompt, "save_memory"));
    // Format: frontmatter `description` is what search_skills results are read
    // from, so the rule has to name it.
    try std.testing.expect(contains(prompt, "description"));
    try std.testing.expect(contains(prompt, "name:"));
    try std.testing.expect(contains(prompt, "## Procedure"));
    try std.testing.expect(contains(prompt, "## Pitfalls"));
    // Self-check, like every other mandate in this block.
    try std.testing.expect(contains(prompt, "Self-check"));
    // add_skill / edit_skill / remove_skill all land one row in THIS
    // workspace.
    try std.testing.expect(!contains(prompt, "SKILL.MD"));
    try std.testing.expect(!contains(prompt, ".nalar/skills/"));
    try std.testing.expect(!contains(prompt, "is_global"));
}


// -------------------------------------------------------------------------
// GitWorktreeToolRule + PullRequestToolRule — the session VCS-binding
// mandates.

test "GitWorktreeToolRule mandates the tool, forbids the hand-rolled command, names the hatch" {
    const prompt: []const u8 = GitWorktreeToolRule;

    try std.testing.expect(contains(prompt, "set_git_worktree"));
    // The mandate, blunt: the tool, not the shell command.
    try std.testing.expect(contains(prompt, "MUST use"));
    try std.testing.expect(contains(prompt, "NOT a substitute"));
    try std.testing.expect(contains(prompt, "git worktree"));
    // The reason, so a paraphrased rule still carries it: it is the session
    // BINDING the tool writes — what the UI and the other tools read — not
    // merely the directory.
    try std.testing.expect(contains(prompt, "sessions.git_worktree_cwd"));
    // The task-note contract the kanban dialog bakes in.
    try std.testing.expect(contains(prompt, "#Notes UseGitWorktree"));
    try std.testing.expect(contains(prompt, "Base:"));
    try std.testing.expect(contains(prompt, "clear=true"));
    // The escape hatch: this tool is NOT in DEFAULT_AGENT_TOOLS, so an
    // unconditional rule naming it is only honest if it also says how to
    // equip it.
    try std.testing.expect(contains(prompt, "search_tool"));
    try std.testing.expect(contains(prompt, "use_tool"));
    try std.testing.expect(contains(prompt, "Self-check"));
}

test "PullRequestToolRule mandates the binding, keeps creation with the forge CLI, names status_pull_request" {
    const prompt: []const u8 = PullRequestToolRule;

    try std.testing.expect(contains(prompt, "set_pull_request"));
    try std.testing.expect(contains(prompt, "MUST call"));
    // Creation is NOT this tool's job — the rule must not send the model to
    // `set_pull_request` to open a PR that does not exist yet.
    try std.testing.expect(contains(prompt, "gh pr create"));
    try std.testing.expect(contains(prompt, "glab mr create"));
    try std.testing.expect(contains(prompt, "only attaches"));
    // Live status is the second half of the same surface.
    try std.testing.expect(contains(prompt, "status_pull_request"));
    // The escape hatch, same reasoning as the worktree rule above.
    try std.testing.expect(contains(prompt, "search_tool"));
    try std.testing.expect(contains(prompt, "use_tool"));
    try std.testing.expect(contains(prompt, "Self-check"));
}
