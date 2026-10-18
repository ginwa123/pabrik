//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

// Enable TLS support for HTTP client
/// Early panic log file path - set before main() runs
/// This allows panic handler to write to log file even before logger is initialized
var panic_log_path: ?[]const u8 = null;

pub fn getPanicLogPath() ?[]const u8 {
    return panic_log_path;
}

pub fn setPanicLogPath(path: []const u8) void {
    panic_log_path = path;
}

/// Panic handler that logs to file and notifies SSE clients
pub const std_options: std.Options = .{
    .http_disable_tls = false,
};

// ─── The App singleton ────────────────────────────────────────────────────
// The struct and its registry helpers live in `src/app.zig` (that file's
// header says why).
pub const app = @import("app.zig");
pub const App = app.App;
pub const LlmConfigHolder = app.LlmConfigHolder;
pub const EmitRunAgentInput = app.EmitRunAgentInput;
pub const getSingleton = app.getSingleton;
pub const setSingleton = app.setSingleton;
pub const getLlmConfig = app.getLlmConfig;
pub const setLlmConfig = app.setLlmConfig;
pub const freeAllLlmConfigs = app.freeAllLlmConfigs;
pub const registerClientOwner = app.registerClientOwner;
pub const getClientOwner = app.getClientOwner;
pub const unregisterClientOwner = app.unregisterClientOwner;
pub const registerSessionClient = app.registerSessionClient;
pub const unregisterSessionClient = app.unregisterSessionClient;
pub const unregisterSessionClientId = app.unregisterSessionClientId;
pub const getClientIdForSession = app.getClientIdForSession;
pub const getListClientsForSession = app.getListClientsForSession;
pub const getSessionIdForClient = app.getSessionIdForClient;
pub const handleClientDisconnect = app.handleClientDisconnect;
pub const mcpStdioRegistry = app.mcpStdioRegistry;
pub const mcpHttpRegistry = app.mcpHttpRegistry;

// Module exports - these are available via @import("pabrikcore")
// it should import from folder modules only
pub const agent = @import("modules/agent/Agent.zig");
pub const llm_models = @import("modules/agent/LLMModels.zig");
pub const prompt = @import("modules/agent/prompts.zig");
// `databases` is the self-contained sqlite3 + libpq package (ruangsql,
// github.com/ginwa123/ruangsql). Imported via the build-graph
// dependency declared in build.zig (mod.addImport("databases", databases_mod)).
pub const sqlite = @import("databases").sqlite;
// Unified interface — prefer this over `sqlite` in new code: const database =
// pabrikcore.database; var db: database.Db = .{}; App-controlled via root
// `-Ddb_used` (default sqlite).
pub const database = @import("databases").database;
pub const bash_tool = @import("modules/agent/tools/bash.zig");
pub const pwsh_tool = @import("modules/agent/tools/pwsh.zig");
pub const command_tool = @import("modules/agent/tools/command.zig");
/// The shell-exec core: `ShellInput` / `RunMode`, the detached spawn, and the
/// process-group kill.
pub const shell_tool = @import("modules/agent/tools/shell.zig");
/// `process` — read/stop/list the detached processes this session started.
/// The read half is what a `background_persistence` service needs, since that
/// mode deliberately never notifies.
pub const process_tool = @import("modules/agent/tools/process.zig");
pub const tool_models = @import("modules/agent/tools/schemas.zig");
pub const tools = @import("modules/agent/tools/tools.zig");

pub const skill_tools = @import("modules/agent/tools/skill_tools.zig");
pub const use_skill_tool = skill_tools;
pub const remove_skill_tool = skill_tools;
pub const search_skills_tool = skill_tools;
// 2026-08-14 — first-level directory listing tool (Task 5 of the same plan).
pub const list_directory = @import("modules/agent/tools/list_directory.zig");
pub const memories = @import("modules/agent/tools/memories.zig");
pub const list_memory_tool = @import("modules/agent/tools/list_memory.zig");
pub const memory = @import("modules/agent/tools/memory.zig");
pub const save_memory = memory;
pub const load_memory = memory;
pub const add_mcp_server = @import("modules/agent/tools/add_mcp_server.zig"); // 2026-08-28-add-mcp-server-agent-tool
// The edit + delete halves of the MCP-server trio — same file, same
// Config.zig primitives, same exec-side persist/reload helpers.
pub const edit_mcp_server = add_mcp_server;
pub const delete_mcp_server = add_mcp_server;
pub const read_workspace_session_tool = @import("modules/agent/tools/read_workspace_session.zig");
/// `run_session` — start or resume a session agent in the caller's OWN
/// workspace; a target outside it is refused, so scope is never spoofable.
pub const run_session = @import("modules/agent/tools/run_session.zig");
/// `view_session` — read ONE session's detail (cwd, git worktree, task,
/// workspace, profile, PR, running state). Your own session by default.
pub const view_session = @import("modules/agent/tools/view_session.zig");
// Workspace credential discovery: names only, never a value.
pub const list_secrets = @import("modules/agent/tools/list_secrets.zig");
/// `add_document` / `edit_document` agent tools (Migration 098). The
/// module resolves its own workspace from the calling session, so the
/// tool schema deliberately carries no `workspace_id` parameter.
pub const document_tool = @import("modules/agent/tools/document.zig");

// `modules/http/HttpClient.zig` was removed — the project uses the
// libcurl-backed client inside the `kabelweb` package (imported via
// `@import("kabelweb").client`; the dep is added in build.zig).
pub const loggermod = @import("modules/logger/Logger.zig");
pub const mcp_stdio = @import("modules/agent/mcp/mcp/mcp_stdio.zig");
pub const mcp_http = @import("modules/agent/mcp/mcp/mcp_http.zig");
pub const mcp_types = @import("modules/agent/mcp/mcp/mcp_types.zig");

pub const skill_mod = @import("modules/agent/tools/skills.zig");
pub const skill_evals_db = @import("agentic_loop/skill_evals_db.zig");
pub const skill_eval_events = @import("agentic_loop/skill_eval_events.zig");
pub const git_file_stage_events = @import("agentic_loop/git_file_stage_events.zig");
pub const git_pr_state_events = @import("agentic_loop/git_pr_state_events.zig");
pub const skill_evals_drift = @import("agentic_loop/skill_evals_drift.zig");
pub const add_skill = skill_tools;
pub const edit_skill = skill_tools;
pub const set_git_worktree = @import("modules/agent/tools/set_git_worktree.zig");
pub const set_pull_request = @import("modules/agent/tools/set_pull_request.zig");
pub const status_pull_request = @import("modules/agent/tools/status_pull_request.zig");
pub const pr_provider = @import("modules/agent/tools/pr_provider.zig");
pub const pr_cli = @import("modules/agent/tools/pr_cli.zig");
pub const kanban_list = @import("modules/agent/tools/kanban_list.zig");
pub const kanban_move_task = @import("modules/agent/tools/kanban_move_task.zig");
pub const create_kanban_task = @import("modules/agent/tools/create_kanban_task.zig");
pub const set_design_page = @import("modules/agent/tools/set_design_page.zig");
pub const add_design_element = @import("modules/agent/tools/add_design_element.zig");
pub const update_design_element = @import("modules/agent/tools/update_design_element.zig");
pub const group_design_elements = @import("modules/agent/tools/group_design_elements.zig");
pub const set_element_parent = @import("modules/agent/tools/set_element_parent.zig");
pub const move_design_element = @import("modules/agent/tools/move_design_element.zig");
pub const move_element_to_page = @import("modules/agent/tools/move_element_to_page.zig");
pub const get_design_context = @import("modules/agent/tools/get_design_context.zig");
pub const preview_design_page = @import("modules/agent/tools/preview_design_page.zig");
pub const present_files = @import("modules/agent/tools/present_files.zig");
pub const file_sandbox = @import("modules/agent/tools/file_sandbox.zig");

pub const config = @import("modules/config/Config.zig");
pub const parse_thinking = @import("modules/config/parse_thinking.zig");
// Per-user LLM config store for opt-in `--auth` mode (users.config_json,
// Migration 092).
pub const user_config_store = @import("modules/config/UserConfigStore.zig");

/// Per-session/per-owner LLM-config resolution for opt-in `--auth` mode. THE
/// ONE module that decides whether a user-scoped read sees the user's
/// `users.config_json` or the process-global `config.json`.
pub const session_llm_config = @import("agentic_loop/session_llm_config.zig");
/// models.dev's model catalog: the ONE owner of "what do we know about this
/// model?" — context window, output cap, reasoning shape, price.
pub const model_catalog = @import("agentic_loop/model_catalog.zig");
/// The durable half of the catalog (Migration 106). One store, no file cache.
pub const model_catalog_store = @import("models/model_catalog_store.zig");
/// The network half: fetch models.dev, save the snapshot, swap the index.
pub const model_catalog_refresh = @import("agentic_loop/model_catalog_refresh.zig");
// Plan 2026-09-10-web-launch-toggle: random loopback port picker for browser
// mode (`--port 0` resolution).
pub const web_port = @import("modules/config/web_port.zig");
pub const read_file = @import("modules/agent/tools/read_file.zig");
pub const write_file = @import("modules/agent/tools/write_file.zig");
pub const remove_file = @import("modules/agent/tools/remove_file.zig");
pub const system_folder = @import("modules/system_folder/system_folder.zig");

// 2026-08-19 — session_plan agent tools (Task 4 of 2026-08-19-session-plan-agent-tool.md).
// update_plan (UPSERT) + get_plan (fetch) — the agent's persistent markdown task plan.
pub const update_plan = @import("modules/agent/tools/update_plan.zig");
pub const get_plan = @import("modules/agent/tools/get_plan.zig");
pub const list_sub_agent = @import("modules/agent/tools/list_sub_agent.zig");
pub const used_tools = @import("modules/agent/tools/used_tools.zig");
// Progressive tool search: search_tool / view_tool / use_tool. The catalog
// and the result renderers live in src/agentic_loop/progressive_catalog.zig
// (this module is pure tool data).
pub const progressive_tools = @import("modules/agent/tools/progressive_tools.zig");

pub const web_search = @import("modules/agent/tools/web_search.zig");
pub const generate_image = @import("modules/agent/tools/generate_image.zig");
pub const glob_tool = @import("modules/agent/tools/glob.zig");
pub const search_tool = @import("modules/agent/tools/search.zig");
pub const semantic_search = @import("modules/agent/tools/semantic_search.zig");
pub const text_replace_tool = @import("modules/agent/tools/text_replace.zig");
pub const cronjob = @import("modules/cronjob/mod.zig");

// Decoupled pabrik-service (Chunk 3) — re-export the service plumbing so
// main.zig and other internal callers can `@import("pabrikcore").service_*`.
pub const service = @import("service/mod.zig");
pub const state_file = service.state_file;
pub const daemon = service.daemon;
pub const signal_handlers = service.signal_handlers;
pub const crash_handler = service.crash_handler;
pub const main_service = service.main_service;
// Top-level CLI flag parsing (`--port`, `--static-dir`, `--http2`, `--tls`,
// `--auth`, `--help`).
pub const cli_args = @import("cli_args.zig");
// The HTTP route table, moved out of `main` so `main` reads as startup
// sequence rather than ~490 lines of registration. See http_routes.zig
// for why the call order inside it is load-bearing.
pub const http_routes = @import("http_routes.zig");
// `pub const helpers = ...` was removed: `helpers` is now its own Zig module
// (see `b.createModule` in build.zig) wired in via `mod.addImport("helpers",
// helpers_mod)`.
pub const kerjabot_get_session = @import("agentic_loop/llm_history.zig");
pub const kerjabot_create_session = @import("agentic_loop/llm_history.zig");
pub const kerjabot_get_list_session = @import("agentic_loop/llm_history.zig");
pub const tui_check_session_exists = @import("agentic_loop/llm_history.zig");
pub const session_helpers = @import("agentic_loop/llm_history.zig");
pub const session_db = @import("agentic_loop/llm_history.zig");
pub const llm_history = @import("agentic_loop/llm_history.zig");
pub const llm_history_model_guard = @import("agentic_loop/llm_history_model_guard.zig");
pub const workspace_scope = @import("agentic_loop/workspace_scope.zig");
/// The `--saas` execution substrate for shell commands, and the manager client
/// it speaks to. The wire protocol and its policy live under `src/vmd/` and are
/// std-only, so the daemon, the server and the tests share one definition.
pub const vm_runtime = @import("agentic_loop/vm_runtime.zig");
pub const vmd_policy = @import("vmd/policy.zig");
pub const vmd_rpc = @import("vmd/rpc.zig");
pub const vmd_client = @import("vmd/vmd_client.zig");
pub const agent_memories = @import("agentic_loop/agent_memories.zig");
/// Workspace-scoped document storage (Migration 098).
pub const documents_store = @import("agentic_loop/documents_store.zig");
/// Workspace-scoped skill storage (Migration 101).
pub const skills_store = @import("agentic_loop/skills_store.zig");
/// Workspace-scoped secret storage (Migration 103).
pub const secrets_store = @import("agentic_loop/secrets_store.zig");
// Per-workspace config overlay: the sparse JSON merge rule and the
// store behind `workspace_settings` (Migration 105). These two are what
// make Profiles / MCP Servers / Tools / Skill Evals per-workspace.
pub const workspace_settings_store = @import("agentic_loop/workspace_settings_store.zig");
pub const workspace_config = @import("agentic_loop/workspace_config.zig");
// 2026-08-19 — session_plan agent tools (Task 4 of 2026-08-19-session-plan-agent-tool.md).
// Storage layer for the per-session markdown task plan (savePlan / getPlan / getPlanOpt).
pub const session_plan = @import("agentic_loop/session_plan.zig");
// `ask_user` state + answer round-trip (Migration 087's
// session_pending_question). Re-exported so the HTTP handler can reach it
// without importing an agentic_loop file directly.
pub const ask_user_pending = @import("agentic_loop/ask_user_pending.zig");
// Re-export so the exe module (main.zig) can access
// cleanup_stale_worker.handle for the cron registration WITHOUT directly
// @import'ing the file (which would put it in two modules and trigger Zig's
pub const cleanup_stale_worker = @import("schedulers/cleanup_stale_worker.zig");
// Re-export cleanup_stale_background_process for the same reason as
// above — see plan 2026-08-19-cleanup-stale-background-process.
pub const cleanup_stale_background_process = @import("schedulers/cleanup_stale_background_process.zig");
// The DB connection policy (and its `--db-*` CLI overrides). Re-exported so
// the exe module and the schedulers share ONE definition of the defaults.
pub const boot_db_config = @import("boot/db_config.zig");
pub const workspace_items = @import("agentic_loop/llm_history.zig");
pub const workspace_item_tasks = @import("agentic_loop/llm_history.zig");
pub const http_response = @import("http_handlers/http_response.zig");
pub const spawn_sub_agent = @import("modules/agent/tools/spawn_sub_agent.zig");
// `ask_user` — the interactive tool that ends the turn to ask the human a
// question.
pub const ask_user = @import("modules/agent/tools/ask_user.zig");
pub const http_handlers = @import("http_handlers/mod.zig");
// kabelweb — external web-framework library (pure-Zig HTTP server +
// libcurl-backed HTTP client, pinned by URL in build.zig.zon). `gserverz`
// stays as the server alias so the ~40 handlers keep compiling untouched.
pub const kabelweb = @import("kabelweb");
pub const gserverz = kabelweb.server;
pub const ai_mod = @import("ai_workflow/tui/mod.zig");
pub const event_bus = @import("modules/event_bus/src/event.zig");
pub const static_files = @import("modules/static_files.zig");
// Boot phases extracted from main.zig (refactor-main-zig): re-exported so
// the exe module reaches them via pabrikcore.* without @import'ing the
// files directly (dual-module error — see cleanup_stale_worker above).
pub const boot_shutdown = @import("boot/shutdown.zig");
pub const boot_cli_dispatch = @import("boot/cli_dispatch.zig");
pub const boot_server_boot = @import("boot/server_boot.zig");
// `pabrik headless ...` — the no-server, no-port backend runner.
pub const boot_headless_dispatch = @import("boot/headless_dispatch.zig");
// The headless backend itself: boot phases, argv parsing, the turn runner
// and the read-only session views. `src/headless/README.md` is the
// user-facing contract.
pub const headless = @import("headless/mod.zig");
pub const http_static_serve = @import("http_static/static_serve.zig");

pub const startup = @import("startup.zig");
pub const agentic_loop_mod = @import("agentic_loop/workflow.zig");

pub const notifications_mod = @import("modules/notification/notifications.zig");
pub const migrations_mod = @import("migrations/mod.zig");

test {
    _ = @import("ai_workflow/tui/test_runner.zig");
    _ = @import("modules/agent/test_runner.zig");
    // Agent Mode helpers: impl + tests in one file. Importing these
    // makes their inline `test` blocks discoverable by `zig build test`.
    _ = @import("agentic_loop/agent_tools_allowed.zig");
    _ = @import("agentic_loop/model_catalog.zig");
    _ = @import("agentic_loop/workspace_fs.zig");
    _ = @import("agentic_loop/prompts_make_agent_knowledge.zig");
    _ = @import("agentic_loop/prompts_make_agent_system_prompt.zig");
    // Agent-Kanbans mirror (Migration 081): impl + tests in one file.
    _ = @import("agentic_loop/agent_kanban_tools_allowed.zig");
    _ = @import("agentic_loop/prompts_make_agent_kanban_knowledge.zig");
    _ = @import("agentic_loop/prompts_make_agent_kanban_system_prompt.zig");
    // Agent-Routines mirror (Migration 087).
    _ = @import("agentic_loop/prompts_make_agent_routine_knowledge.zig");
    _ = @import("agentic_loop/prompts_make_agent_routine_system_prompt.zig");
    // Single-file Lua hooks (plan 2026-09-12-hook-lua-pre-post-tool-use):
    // impl + inline tests in one file each. Same discovery workaround as
    // mcp_http above — the `pub const` re-export alone doesn't pull tests.
    _ = @import("agentic_loop/lua_bindings.zig");
    _ = @import("agentic_loop/hooks.zig");
    // Workspace-scoped secret storage (Migration 103): impl + inline tests
    // in one file. Same discovery workaround as the Lua hooks above — the
    // `pub const secrets_store` re-export alone doesn't pull tests in.
    _ = @import("agentic_loop/secrets_store.zig");
    _ = @import("agentic_loop/workspace_settings_store.zig");
    _ = @import("agentic_loop/workspace_config.zig");
    // Workspace-secret placeholder substitution: a pure module whose inline
    // tests are otherwise invisible to `zig build test` — the same discovery
    // workaround as the Lua hooks above.
    _ = @import("agentic_loop/secrets_substitution.zig");
    // The workspace-secrets HTTP surface (Migration 103): one file per verb,
    // each carrying its own `useCase` tests plus the route-registration
    // contracts that pin the literal routes ahead of the `:secret_id` ones.
    _ = @import("http_handlers/secrets_list.zig");
    _ = @import("http_handlers/secrets_create.zig");
    _ = @import("http_handlers/secrets_update.zig");
    _ = @import("http_handlers/secrets_delete.zig");
    // The skills write surface: one file per verb, each carrying its own
    // `useCase` tests.
    _ = @import("http_handlers/skill_create.zig");
    _ = @import("http_handlers/skill_update.zig");
    // `databases` package tests run in the ruangsql repo's own CI
    // (github.com/ginwa123/ruangsql) — see the package's build.zig.
    _ = @import("modules/event_bus/src/test_runner.zig");
    _ = @import("modules/logger/test_runner.zig"); // needs Zig 0.16 API updates
    // kabelweb (server + client) is an external URL dependency — its suites
    // run in its own repo CI (github.com/ginwa123/kabelweb), not here. A
    // consumer build never runs a dependency's test blocks.
    _ = @import("modules/test_runner.zig");
    _ = @import("modules/notification/test_runner.zig");
    _ = @import("migrations/test_runner.zig");
    // schedulers/cleanup_stale_worker.zig has inline tests.
    _ = @import("schedulers/cleanup_stale_worker.zig");
    // The `worker` table's two writers of record, and the listing both the
    // desktop and the Android app derive "is running" from.
    _ = @import("agentic_loop/update_worker.zig");
    _ = @import("http_handlers/worker_list.zig");
    // The `skills` table (Migration 101) and its store. Same lazy-compilation
    // workaround: the `pub const skills_store` re-export above puts the file
    // in the module tree but does NOT discover its inline tests.
    _ = @import("agentic_loop/skills_store.zig");
    // The one-shot directory -> `skills` table importer. Same
    // lazy-compilation workaround: nothing else in the tree imports it yet,
    // and an unreferenced file's tests are never discovered.
    _ = @import("agentic_loop/skills_import.zig");
    // The download endpoint half of the present_files contract: it holds the
    // status mapping tests plus the static checks that keep it on the shared
    // file_sandbox rule (docs/plans/2026-09-29-present-files-sandbox-parity.md).
    _ = @import("http_handlers/files_download.zig");
    _ = @import("http_handlers/preview_origin.zig");
    // schedulers/cleanup_stale_background_process.zig has inline tests
    // (mirrors cleanup_stale_worker pattern). Re-imported here for the
    // same reason — see plan 2026-08-19-cleanup-stale-background-process.
    _ = @import("schedulers/cleanup_stale_background_process.zig");
    // boot/db_config.zig holds the pragma assertions plus the `--db-*`
    // override parser's tests.
    _ = @import("boot/db_config.zig");
    // modules/agent/mcp/mcp/mcp_http.zig has inline tests for the SSE parser
    // + spec-compliant header builder.
    _ = @import("modules/agent/mcp/mcp/mcp_http.zig");
    // mcp_stdio.zig's lease / framing / bounded-send contracts (these run even
    // without this line — measured — but the project convention is to register
    // every test-bearing file explicitly).
    _ = @import("modules/agent/mcp/mcp/mcp_stdio.zig");
    // Browser-mode (web launch) random port picker (plan
    // 2026-09-10-web-launch-toggle): impl + unit tests in one file.
    // Same discovery workaround as mcp_http above.
    _ = @import("modules/config/web_port.zig");
    // Boot phases extracted from main.zig: inline behaviour tests live in
    // each file. Same discovery workaround as web_port above.
    _ = @import("boot/shutdown.zig");
    _ = @import("boot/cli_dispatch.zig");
    _ = @import("boot/server_boot.zig");
    // Headless mode: argv parsing is pure and unit-tested without booting
    // anything; the boot/run/sessions phases carry their own inline tests.
    _ = @import("boot/headless_dispatch.zig");
    _ = @import("headless/args.zig");
    _ = @import("headless/boot.zig");
    _ = @import("headless/run.zig");
    _ = @import("headless/sessions.zig");
    _ = @import("http_static/static_serve.zig");
    // Config struct + its `test { ... }` block at the bottom of Config.zig
    // (the config_test.zig + parse_thinking_test.zig suites are now inline in
    // Config.zig itself).
    _ = @import("modules/config/Config.zig");
    // Per-user config store unit tests (Migration 092, users.config_json).
    // Same discovery workaround as Config.zig above.
    _ = @import("modules/config/UserConfigStore.zig");
    _ = @import("service/crash_handler.zig"); // crash signal/exception handler contracts
    _ = @import("service/signal_handlers.zig"); // SIGINT+SIGTERM graceful-shutdown contracts
    // Top-level CLI flag parser: impl + inline tests in one file.
    _ = @import("cli_args.zig");
    // The App singleton (src/app.zig) carries the fetch-once MCP tools cache
    // tests with its implementation.
    _ = @import("app.zig");
    // Route-table contracts (registration + relative order). The
    // re-export above does not trigger test discovery; importing the
    // file again here does — same workaround as cli_args.zig above.
    _ = @import("http_routes.zig");
    // http_handlers/git_file_diffs.zig has inline tests for the diff
    // splitter, the path extractor, and capDiff's truncation branch.
    _ = @import("http_handlers/git_file_diffs.zig");
    // http_handlers/ask_user_answer.zig holds the `remainingQuestions`
    // counter that gates the answer endpoint's resume, so a wrong count
    // either strands a recorded answer or resumes a turn the model is not
    _ = @import("http_handlers/ask_user_answer.zig");
    // The `gh` handlers spawn child processes, and their inline tests (JSON
    // payload shapes, error mapping, and the `run_captured` contract) never
    // ran — same discovery gap as git_file_diffs above.
    _ = @import("http_handlers/git_pr_status.zig");
    _ = @import("http_handlers/git_pr_checks.zig");
    _ = @import("http_handlers/git_pr_create.zig");
    _ = @import("http_handlers/git_pr_diff.zig");
    _ = @import("http_handlers/git_pr_conflicts.zig");
    _ = @import("http_handlers/git_blame.zig");
    _ = @import("http_handlers/workspace_config.zig");

    // ===== src/models/: Sanity tests for the entity models (split out of
    // models_test.zig) ===== The per-model `init` / `deinit` / `clone` sanity
    // tests used to live in one models_test.zig that no test root imported,
    _ = @import("models/workspace.zig");
    _ = @import("models/workspace_item.zig");
    _ = @import("models/workspace_item_task.zig");
    _ = @import("models/workspace_routine.zig");
    _ = @import("models/session.zig");
    _ = @import("models/session_activity.zig");
    _ = @import("models/session_agent.zig");
    _ = @import("models/session_queue_message.zig");
    _ = @import("models/session_skill.zig");
    _ = @import("models/session_background_process.zig");
    _ = @import("models/kanban_column.zig");
    _ = @import("models/kanban_assignment.zig");
    _ = @import("models/design_page.zig");
    _ = @import("models/design_page_element.zig");
    _ = @import("models/llm_history.zig");
    _ = @import("models/model_catalog_store.zig");
    // `llm_history.model` is never empty — see the module header for the
    // NULL-collapse vs. ''-literal distinction this guard closes.
    _ = @import("agentic_loop/llm_history_model_guard.zig");
    _ = @import("models/worker.zig");
    _ = @import("models/log.zig");
    _ = @import("models/agent_memory.zig");
}

// ─── Fetch-once MCP tools cache tests (plan: mcp-fetch-once-cache) ───

fn mcpCacheTestTool(allocator: std.mem.Allocator) !tool_models.AgentTool {
    const props = try allocator.alloc(tool_models.ToolProperty, 1);
    props[0] = .{
        .name = try allocator.dupe(u8, "q"),
        .type = try allocator.dupe(u8, "string"),
        .description = try allocator.dupe(u8, "query"),
    };
    const required = try allocator.alloc([]const u8, 1);
    required[0] = try allocator.dupe(u8, "q");
    return .{
        .type = try allocator.dupe(u8, "function"),
        .function = .{
            .name = try allocator.dupe(u8, "mcp_srv_do"),
            .description = try allocator.dupe(u8, "does things"),
            .parameters = .{
                .type = try allocator.dupe(u8, "object"),
                .properties = props,
                .required = required,
            },
            .system_prompt = try allocator.dupe(u8, ""),
        },
    };
}

fn mcpCacheFreeTestTool(allocator: std.mem.Allocator, tool: tool_models.AgentTool) void {
    app.freeAgentTool(allocator, tool);
}

fn mcpCacheTestCtx() app.App {
    var ctx: app.App = undefined;
    ctx.allocator = std.testing.allocator;
    ctx.mcp_tools_cache = null;
    ctx.mcp_tools_init = false;
    ctx.mcp_tools_lock = .unlocked;
    return ctx;
}

test "mcp fetch-once: uninitialized cache returns null snapshot" {
    var ctx = mcpCacheTestCtx();
    try std.testing.expect(!ctx.isMcpToolsInit());
    try std.testing.expect(ctx.getMcpToolsCached(std.testing.allocator) == null);
}

test "mcp fetch-once: store + snapshot roundtrip with deep-dupe isolation" {
    var ctx = mcpCacheTestCtx();
    const src = try std.testing.allocator.alloc(tool_models.AgentTool, 1);
    defer std.testing.allocator.free(src);
    src[0] = try mcpCacheTestTool(std.testing.allocator);
    defer mcpCacheFreeTestTool(std.testing.allocator, src[0]);
    ctx.storeMcpToolsCache(src, true);
    defer ctx.clearMcpToolsCache();
    try std.testing.expect(ctx.isMcpToolsInit());
    const snap = ctx.getMcpToolsCached(std.testing.allocator) orelse return error.SnapshotMiss;
    defer {
        for (snap) |s| app.freeAgentTool(std.testing.allocator, s);
        std.testing.allocator.free(snap);
    }
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqualStrings("mcp_srv_do", snap[0].function.name);
    // Snapshots must be independently duped (not aliased to the cache):
    // different backing pointers prove the deep dupe.
    try std.testing.expect(snap[0].function.name.ptr != ctx.mcp_tools_cache.?[0].function.name.ptr);
    try std.testing.expect(snap[0].function.parameters.properties.ptr != ctx.mcp_tools_cache.?[0].function.parameters.properties.ptr);
}

test "mcp fetch-once: clear resets to uninitialized" {
    var ctx = mcpCacheTestCtx();
    const src = try std.testing.allocator.alloc(tool_models.AgentTool, 1);
    defer std.testing.allocator.free(src);
    src[0] = try mcpCacheTestTool(std.testing.allocator);
    defer mcpCacheFreeTestTool(std.testing.allocator, src[0]);
    ctx.storeMcpToolsCache(src, true);
    try std.testing.expect(ctx.isMcpToolsInit());
    ctx.clearMcpToolsCache();
    try std.testing.expect(!ctx.isMcpToolsInit());
    try std.testing.expect(ctx.getMcpToolsCached(std.testing.allocator) == null);
}

test "mcp fetch-once: error publish (mark_init=false) leaves retry open" {
    var ctx = mcpCacheTestCtx();
    ctx.storeMcpToolsCache(null, false);
    try std.testing.expect(!ctx.isMcpToolsInit());
    // A null publish WITH init (no servers configured) is a valid cached state.
    ctx.storeMcpToolsCache(null, true);
    try std.testing.expect(ctx.isMcpToolsInit());
    try std.testing.expect(ctx.getMcpToolsCached(std.testing.allocator) == null);
}
