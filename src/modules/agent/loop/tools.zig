const std = @import("std");
const pabrikcore = @import("pabrikcore");

const logger_mod = pabrikcore.loggermod;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const config_mod = pabrikcore.config;

pub const all_agent_tools = @import("../tools/tools_equipped.zig").equips;
pub const wrapToolOutput = @import("../tools/tools_wrap_output.zig").wrapToolOutput;
pub const withDurationMs = @import("../tools/tools_wrap_output.zig").withDurationMs;
pub const withPending = @import("../tools/tools_wrap_output.zig").withPending;

// Re-export every migrated exec function. Tool_Registry.zig references
// these via `agentic_loop_mod.tools.execXxx` etc.
pub const execReadFile = @import("../tools/read_file.zig").execReadFile;
pub const execTextReplace = @import("../tools/text_replace.zig").execTextReplace;
pub const execWriteFile = @import("../tools/write_file.zig").execWriteFile;
pub const execSearchSkills = @import("../tools/skill_tools.zig").execSearchSkills;
pub const execListMemory = @import("../tools/list_memory.zig").execListMemory;
pub const execSaveMemory = @import("../tools/memory.zig").execSaveMemory;
pub const execLoadMemory = @import("../tools/memory.zig").execLoadMemory;
pub const execReadWorkspaceSession = @import("../tools/read_workspace_session.zig").execReadWorkspaceSession;
// run_session: start/resume a session agent, another workspace included.
pub const execRunSession = @import("../tools/run_session.zig").execRunSession;
// view_session: one session's detail (cwd, worktree, task, running state).
pub const execViewSession = @import("../tools/view_session.zig").execViewSession;
// Workspace credential DISCOVERY. The value never leaves the store — this
// adapter lists names only (see list_secrets.zig).
pub const execListSecrets = @import("../tools/list_secrets.zig").execListSecrets;
pub const execDocumentMarkdown = @import("../tools/document.zig").execDocumentMarkdown;
pub const execDocumentHtml = @import("../tools/document_html.zig").execDocumentHtml;
pub const execUseSkill = @import("../tools/skill_tools.zig").execUseSkill;
pub const execRemoveSkill = @import("../tools/skill_tools.zig").execRemoveSkill;
pub const execAddSkill = @import("../tools/skill_tools.zig").execAddSkill;
pub const execEditSkill = @import("../tools/skill_tools.zig").execEditSkill;
pub const execSetSkillMetadata = @import("../tools/skill_tools.zig").execSetSkillMetadata;
pub const execRemoveFile = @import("../tools/remove_file.zig").execRemoveFile;
pub const execSetGitWorktree = @import("../tools/set_git_worktree.zig").execSetGitWorktree;
pub const execSetPullRequest = @import("../tools/set_pull_request.zig").execSetPullRequest;
pub const execStatusPullRequest = @import("../tools/status_pull_request.zig").execStatusPullRequest;
pub const execKanbanList = @import("../tools/kanban_list.zig").execKanbanList;
pub const execKanbanMoveTask = @import("../tools/kanban_move_task.zig").execKanbanMoveTask;
pub const execCreateKanbanTask = @import("../tools/create_kanban_task.zig").execCreateKanbanTask;
pub const execSetDesignPage = @import("../tools/set_design_page.zig").execSetDesignPage;
pub const execAddElement = @import("../tools/add_design_element.zig").execAddElement;
pub const execUpdateElement = @import("../tools/update_design_element.zig").execUpdateElement;
pub const execGroupElements = @import("../tools/group_design_elements.zig").execGroupElements;
pub const execSetElementParent = @import("../tools/set_element_parent.zig").execSetElementParent;
pub const execMoveDesignElement = @import("../tools/move_design_element.zig").execMoveDesignElement;
pub const execMoveElementToPage = @import("../tools/move_element_to_page.zig").execMoveElementToPage;
pub const execPresentFiles = @import("../tools/present_files.zig").execPresentFiles;
pub const execGenerateImage = @import("../tools/generate_image.zig").execGenerateImage;
pub const execGetDesignContext = @import("../tools/get_design_context.zig").execGetDesignContext;
pub const execPreviewDesignPage = @import("../tools/preview_design_page.zig").execPreviewDesignPage;
pub const execWebSearch = @import("../tools/web_search.zig").execWebSearch;
pub const execListWebSearchProviders = @import("../tools/exec_list_web_search_providers.zig").execListWebSearchProviders;
pub const execGlob = @import("../tools/glob.zig").execGlob;
pub const execSearch = @import("../tools/search.zig").execSearch;
pub const execBash = @import("../tools/command.zig").execBash;
pub const execPwsh = @import("../tools/command.zig").execPwsh;
pub const execCommand = @import("../tools/command.zig").execCommand;
/// `process` — read the delta of a detached process's log, stop it (tree
/// included), or list what this session started.
pub const execProcess = @import("../tools/process.zig").execProcess;
// 2026-08-14 — list_directory agent tool (Task 5 of ban-absolute-paths plan).
pub const execListDirectory = @import("../tools/list_directory.zig").execListDirectory;
pub const execSpawnSubAgent = @import("../tools/spawn_sub_agent.zig").execSpawnSubAgent;
pub const execDelegateAgent = @import("../tools/delegate_agent.zig").execDelegateAgent;

// 2026-08-19 — session_plan agent tools (Task 4 of 2026-08-19-session-plan-agent-tool.md).
// update_plan (UPSERT) + get_plan (fetch) — the markdown task plan that
// persists across iterations and gets re-injected into the system prompt.
pub const execUpdatePlan = @import("../tools/update_plan.zig").execUpdatePlan;
pub const execGetPlan = @import("../tools/get_plan.zig").execGetPlan;
pub const execListAgents = @import("../tools/list_agents.zig").execListAgents;
pub const execUsedTools = @import("../tools/used_tools.zig").execUsedTools;
// 2026-08-28 — add_mcp_server agent tool (Step 3 of
// 2026-08-28-add-mcp-server-agent-tool.md).
pub const execAddMcpServer = @import("../tools/add_mcp_server.zig").execAddMcpServer;
// The edit + delete halves of the MCP-server trio. All three share the
// persist/reload/tools-listing helpers inside add_mcp_server.zig.
pub const execEditMcpServer = @import("../tools/add_mcp_server.zig").execEditMcpServer;
pub const execDeleteMcpServer = @import("../tools/add_mcp_server.zig").execDeleteMcpServer;

// Progressive tool search (plan 2026-09-12-progressive-tool-search): the three
// meta-tools that browse and enable the catalog of tools this session does not
// already have (MCP tools + not-enabled built-ins).
pub const execSearchTool = @import("../tools/progressive_tools.zig").execSearchTool;
pub const execViewTool = @import("../tools/progressive_tools.zig").execViewTool;
pub const execUseTool = @import("../tools/progressive_tools.zig").execUseTool;

pub const SkillSaveInfo = struct {
    name: []const u8,
    content: []const u8,
};

pub const AgentSaveInfo = struct {
    name: []const u8,
};

pub const ToolExecContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    config: *const config_mod.LlmConfig,
    agent_temperature: *f32,
    is_thinking: *bool,
    environment: ?*const std.process.Environ.Map,
    /// The object store document bodies live in, when one is configured.
    storage: ?@import("../../storage/mod.zig").storage.Storage = null,
    selected_profile_model: []const u8 = "",
    cwd_override: ?[]const u8 = null,
    /// The active design page id (when the LLM is in a design-item session).
    /// Empty string means "no active design page" — the design tools
    /// (move_design_element, set_design_page, etc.) require this.
    active_page_id: []const u8 = "",
    /// The parent's tool_call id for THIS dispatch. 2026-08-23 spawn-
    /// subagent-live-progress: `execSpawnSubAgent` needs this to key its
    /// per-tool progress events (ChatView.vue's frontend reducer routes by
    tool_call_id: []const u8 = "",
    /// This session's resolved `allowed_tools` CSV (the agent/kanban
    /// allowlist, or "" / "all" for no filtering).
    allowed_tools: []const u8 = "",
    /// Whether this is a sub-agent session. Mirrors the flag the workflow
    /// uses for the anti-recursion strip; the catalog honours it too so a
    /// sub-agent cannot discover its way back to `spawn_sub_agent`.
    is_sub_agent: bool = false,
    /// The `llm_history` tool-result row this dispatch belongs to (set by
    /// `handle_tool` Phase 3 from its placeholder list).
    llm_history_id: []const u8 = "",
    /// The SSE bus a tool broadcasts a mutation on (today only the document
    /// tools — see `document_events.zig`). Null in tests and in any host that
    /// has no bus, which makes the emit a no-op.
    event_bus: ?*pabrikcore.event_bus.EventBus = null,
    /// The Stop button, for a tool that blocks its thread (`command`): null in
    /// tests, so nothing polls a context that was built directly.
    cancel_hook: ?pabrikcore.shell_tool.CancelHook = null,
};

/// Set by `use_tool` when it actually INSERTed a `session_progressive_tool`
/// row. `handle_tool` persists it; the flag exists so the tool result's
/// `inserted` value can never disagree with the database.
pub const ProgressiveToolSaveInfo = struct {
    name: []const u8,
    server_name: []const u8,
};

pub const ToolExecResult = struct {
    output: []const u8,
    output_allocated: bool = false,
    /// A `data:image/<mime>;base64,...` URL the result carries to the model as
    /// an `image_url` part. Owned by the result when non-null.
    image_url: ?[]const u8 = null,
    temperature: ?f32 = null,
    is_thinking: ?bool = null,
    skill_save: ?SkillSaveInfo = null,
    agent_save: ?AgentSaveInfo = null,
    progressive_tool_save: ?ProgressiveToolSaveInfo = null,
    /// The tool asked the agentic loop to END THIS TURN once the whole tool
    /// batch has been dispatched and persisted (`command`'s `is_stop`).
    stop_loop: bool = false,

    pub fn deinit(self: *const ToolExecResult, allocator: std.mem.Allocator) void {
        if (self.output_allocated) {
            allocator.free(self.output);
        }
        if (self.image_url) |url| allocator.free(url);
    }
};
