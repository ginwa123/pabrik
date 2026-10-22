const std = @import("std");
const pabrikcore = @import("pabrikcore");

const logger_mod = pabrikcore.loggermod;
const sqlite = pabrikcore.sqlite;
const config_mod = pabrikcore.config;

pub const all_agent_tools = @import("tools_equipped.zig").equips;
pub const wrapToolOutput = @import("tools_wrap_output.zig").wrapToolOutput;
pub const withDurationMs = @import("tools_wrap_output.zig").withDurationMs;

// Re-export every migrated exec function. Tool_Registry.zig references
// these via `agentic_loop_mod.tools.execXxx` etc.
pub const execReadFile = @import("../modules/agent/tools/read_file.zig").execReadFile;
pub const execTextReplace = @import("../modules/agent/tools/text_replace.zig").execTextReplace;
pub const execWriteFile = @import("../modules/agent/tools/write_file.zig").execWriteFile;
pub const execSearchSkills = @import("../modules/agent/tools/skill_tools.zig").execSearchSkills;
pub const execListMemory = @import("../modules/agent/tools/list_memory.zig").execListMemory;
pub const execSaveMemory = @import("../modules/agent/tools/memory.zig").execSaveMemory;
pub const execLoadMemory = @import("../modules/agent/tools/memory.zig").execLoadMemory;
pub const execReadWorkspaceSession = @import("../modules/agent/tools/read_workspace_session.zig").execReadWorkspaceSession;
// run_session: start/resume a session agent, another workspace included.
pub const execRunSession = @import("../modules/agent/tools/run_session.zig").execRunSession;
// view_session: one session's detail (cwd, worktree, task, running state).
pub const execViewSession = @import("../modules/agent/tools/view_session.zig").execViewSession;
// Workspace credential DISCOVERY. The value never leaves the store — this
// adapter lists names only (see list_secrets.zig).
pub const execListSecrets = @import("../modules/agent/tools/list_secrets.zig").execListSecrets;
pub const execAddDocument = @import("../modules/agent/tools/document.zig").execAddDocument;
pub const execEditDocument = @import("../modules/agent/tools/document.zig").execEditDocument;
pub const execDeleteDocument = @import("../modules/agent/tools/document.zig").execDeleteDocument;
pub const execSearchDocuments = @import("../modules/agent/tools/document.zig").execSearchDocuments;
pub const execUseSkill = @import("../modules/agent/tools/skill_tools.zig").execUseSkill;
pub const execRemoveSkill = @import("../modules/agent/tools/skill_tools.zig").execRemoveSkill;
pub const execAddSkill = @import("../modules/agent/tools/skill_tools.zig").execAddSkill;
pub const execEditSkill = @import("../modules/agent/tools/skill_tools.zig").execEditSkill;
pub const execRemoveFile = @import("../modules/agent/tools/remove_file.zig").execRemoveFile;
pub const execSetGitWorktree = @import("../modules/agent/tools/set_git_worktree.zig").execSetGitWorktree;
pub const execSetPullRequest = @import("../modules/agent/tools/set_pull_request.zig").execSetPullRequest;
pub const execStatusPullRequest = @import("../modules/agent/tools/status_pull_request.zig").execStatusPullRequest;
pub const execKanbanList = @import("../modules/agent/tools/kanban_list.zig").execKanbanList;
pub const execKanbanMoveTask = @import("../modules/agent/tools/kanban_move_task.zig").execKanbanMoveTask;
pub const execCreateKanbanTask = @import("../modules/agent/tools/create_kanban_task.zig").execCreateKanbanTask;
pub const execSetDesignPage = @import("../modules/agent/tools/set_design_page.zig").execSetDesignPage;
pub const execAddElement = @import("../modules/agent/tools/add_design_element.zig").execAddElement;
pub const execUpdateElement = @import("../modules/agent/tools/update_design_element.zig").execUpdateElement;
pub const execGroupElements = @import("../modules/agent/tools/group_design_elements.zig").execGroupElements;
pub const execSetElementParent = @import("../modules/agent/tools/set_element_parent.zig").execSetElementParent;
pub const execMoveDesignElement = @import("../modules/agent/tools/move_design_element.zig").execMoveDesignElement;
pub const execMoveElementToPage = @import("../modules/agent/tools/move_element_to_page.zig").execMoveElementToPage;
pub const execPresentFiles = @import("../modules/agent/tools/present_files.zig").execPresentFiles;
pub const execGenerateImage = @import("../modules/agent/tools/generate_image.zig").execGenerateImage;
pub const execGetDesignContext = @import("../modules/agent/tools/get_design_context.zig").execGetDesignContext;
pub const execPreviewDesignPage = @import("../modules/agent/tools/preview_design_page.zig").execPreviewDesignPage;
pub const execWebSearch = @import("../modules/agent/tools/web_search.zig").execWebSearch;
pub const execListWebSearchProviders = @import("../modules/agent/tools/exec_list_web_search_providers.zig").execListWebSearchProviders;
pub const execGlob = @import("../modules/agent/tools/glob.zig").execGlob;
pub const execSearch = @import("../modules/agent/tools/search.zig").execSearch;
pub const execBash = @import("../modules/agent/tools/command.zig").execBash;
pub const execPwsh = @import("../modules/agent/tools/command.zig").execPwsh;
pub const execCommand = @import("../modules/agent/tools/command.zig").execCommand;
/// `process` — read the delta of a detached process's log, stop it (tree
/// included), or list what this session started.
pub const execProcess = @import("../modules/agent/tools/process.zig").execProcess;
// 2026-08-14 — list_directory agent tool (Task 5 of ban-absolute-paths plan).
pub const execListDirectory = @import("../modules/agent/tools/list_directory.zig").execListDirectory;
pub const execSpawnSubAgent = @import("../modules/agent/tools/spawn_sub_agent.zig").execSpawnSubAgent;

// 2026-08-19 — session_plan agent tools (Task 4 of 2026-08-19-session-plan-agent-tool.md).
// update_plan (UPSERT) + get_plan (fetch) — the markdown task plan that
// persists across iterations and gets re-injected into the system prompt.
pub const execUpdatePlan = @import("../modules/agent/tools/update_plan.zig").execUpdatePlan;
pub const execGetPlan = @import("../modules/agent/tools/get_plan.zig").execGetPlan;
pub const execListAgents = @import("../modules/agent/tools/list_agents.zig").execListAgents;
pub const execUsedTools = @import("../modules/agent/tools/used_tools.zig").execUsedTools;
// 2026-09-16 — ask_user: ends the turn so the human can answer in their own
// time; the answer rewrites this call's tool-result row and resumes a run.
pub const execAskUser = @import("../modules/agent/tools/ask_user.zig").execAskUser;
// 2026-08-28 — add_mcp_server agent tool (Step 3 of
// 2026-08-28-add-mcp-server-agent-tool.md).
pub const execAddMcpServer = @import("../modules/agent/tools/add_mcp_server.zig").execAddMcpServer;
// The edit + delete halves of the MCP-server trio. All three share the
// persist/reload/tools-listing helpers inside add_mcp_server.zig.
pub const execEditMcpServer = @import("../modules/agent/tools/add_mcp_server.zig").execEditMcpServer;
pub const execDeleteMcpServer = @import("../modules/agent/tools/add_mcp_server.zig").execDeleteMcpServer;

// Progressive tool search (plan 2026-09-12-progressive-tool-search): the three
// meta-tools that browse and enable the catalog of tools this session does not
// already have (MCP tools + not-enabled built-ins).
pub const execSearchTool = @import("../modules/agent/tools/progressive_tools.zig").execSearchTool;
pub const execViewTool = @import("../modules/agent/tools/progressive_tools.zig").execViewTool;
pub const execUseTool = @import("../modules/agent/tools/progressive_tools.zig").execUseTool;

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
    db: *sqlite.SqliteBackend,
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
    }
};
