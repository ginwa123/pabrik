//! Thin re-export surface for the `tui` module (mounted as
//! `pabrikcore.ai_mod.*`).

pub const pabrikcore = @import("pabrikcore");
pub const models = @import("../../agentic_loop/models.zig");
pub const http_handlers = @import("../../http_handlers/mod.zig");
pub const ai_workflow = @import("../../agentic_loop/workflow.zig");
pub const llm_history = @import("../../agentic_loop/llm_history.zig");
pub const on_event_sent = @import("../../agentic_loop/on_event_sent.zig");
pub const on_event_sent_kanban = @import("../../agentic_loop/on_event_sent_kanban.zig");
pub const on_event_design = @import("../../agentic_loop/on_event_design.zig");
pub const on_event_sent_design = @import("../../agentic_loop/on_event_sent_design.zig");
pub const present_files = @import("../../modules/agent/tools/present_files.zig");
pub const file_sandbox = @import("../../modules/agent/tools/file_sandbox.zig");
pub const generate_image = @import("../../modules/agent/tools/generate_image.zig");
pub const get_design_context = @import("../../modules/agent/tools/get_design_context.zig");
pub const preview_design_page = @import("../../modules/agent/tools/preview_design_page.zig");
pub const delete_worker = @import("../../agentic_loop/delete_worker.zig");
// Background-command completion queue (bg-completion Task 1+2) — pure log
// helpers + completion envelope, consumed by the
// schedulers/cleanup_stale_background_process.zig cron via
pub const background_process = @import("../../agentic_loop/background_process.zig");
pub const background_process_events = @import("../../agentic_loop/background_process_events.zig");
pub const routines = @import("routines/mod.zig");
pub const startup = @import("../../agentic_loop/startup.zig");
pub const kanban_model = @import("../../agentic_loop/kanban_model.zig");
pub const kanban_deps = @import("../../agentic_loop/kanban_deps.zig");
pub const design_io = @import("../../agentic_loop/design_io.zig");
pub const design_model = @import("../../agentic_loop/design_model.zig");
pub const inherited_context = @import("../../agentic_loop/inherited_context.zig");
pub const agent_memories = @import("../../agentic_loop/agent_memories.zig");
// In-flight stream snapshot registry (task_1787673548905_0
// stream-resume-on-reselect) — read by http_handlers/stream_get.zig.
pub const stream_snapshot = @import("../../agentic_loop/stream_snapshot.zig");
// Live spawn-batch snapshot registry (task_1788505292766_1
// spawn-subagent-refresh-persist) — mirrored on every progress emit,
// read by http_handlers/subagent_progress_get.zig.
pub const subagent_progress = @import("../../agentic_loop/subagent_progress.zig");
// `ask_user` question state + the answer round-trip (Migration 087). The HTTP
// answer handler and the `session_create` abandon guard both reach it through
// here.
pub const ask_user_pending = @import("../../agentic_loop/ask_user_pending.zig");

// Re-export workspace functions from llm_history for backward compatibility
pub const workspace_items = llm_history;
pub const workspace_item_tasks = llm_history;

// Re-export session->client mapping functions from root
pub const registerSessionClient = @import("pabrikcore").registerSessionClient;
pub const unregisterSessionClient = @import("pabrikcore").unregisterSessionClient;
pub const getClientIdForSession = @import("pabrikcore").getClientIdForSession;
pub const getListClientsForSession = @import("pabrikcore").getListClientsForSession;
pub const getSessionIdForClient = @import("pabrikcore").getSessionIdForClient;
pub const handleClientDisconnect = @import("pabrikcore").handleClientDisconnect;
