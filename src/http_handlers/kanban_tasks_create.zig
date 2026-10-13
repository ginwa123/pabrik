//! `POST /api/workspaces/:workspace_id/items/:item_id/kanban/tasks`.
//!
//! Kanban-scoped task create endpoint with a `mode` discriminator:
//!
//!   - `mode='create'`           — create the task, auto-assign to the
//!                                 kanban's first column, emit
//!                                 `kanban_task` SSE (action='assigned').
//!                                 Returns `{ task, session: null }`.
//!                                 Does NOT insert a sessions row (legacy).
//!
//!   - `mode='create_session'`   — same as `create` PLUS insert the
//!                                 `sessions` row keyed by `task.id`,
//!                                 persist `selected_profile_model` +
//!                                 `is_auto_retry_until_stop`, emit
//!                                 `session_created` SSE. Does NOT
//!                                 call `emit_run_agent`. Returns
//!                                 `{ task, session: { id, name, status: 'idle' } }`.
//!
//!   - `mode='create_and_run'`   — same as `create_session` PLUS call
//!                                 `emit_run_agent` to queue the first
//!                                 user message + start the agent.
//!                                 Returns `{ task, session: { id, name, status: 'send' } }`.
//!
//! Body: `{ mode, name, description?, queue_message? (create_and_run only),
//!         tags?, image_urls?, cwd?, is_auto_retry_until_stop?,
//!         selected_profile_model? }`.
//!
//! Errors:
//!   - 400 missing/invalid JSON body, missing/invalid `mode`,
//!     empty `queue_message` for `create_and_run`
//!   - 404 parent item is not a kanban
//!   - 500 DB failure
//!
//! Layered as a thin orchestrator over `task_create.zig::useCase`
//! (which handles the standard-task INSERT + kanban auto-assign +
//! kanban_task SSE) plus the create_session / create_and_run
//! side-effects (sessions INSERT + session_created SSE; create_and_run
//! additionally calls emit_run_agent).
//!
//! Plan: docs/superpowers/plans/2026-08-19-kanban-create-task-inits-session.md

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const auth_common = @import("auth_common.zig");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const on_event_sent_kanban = pabrikcore.ai_mod.on_event_sent_kanban;
const model_guard = @import("../agentic_loop/llm_history_model_guard.zig");

/// HTTP request body for kanban task create. Decoupled from the
/// internal `TaskCreateRequest` struct so the wire format can evolve
/// independently (e.g. adding the `mode` discriminator + `queue_message`
/// fields) without touching the shared task-create use-case.
pub const KanbanTaskCreateBody = struct {
    /// "create" | "create_session" | "create_and_run"
    mode: []const u8 = "",
    name: []const u8 = "",
    description: ?[]const u8 = null,
    /// Required iff mode == "create_and_run".
    queue_message: ?[]const u8 = null,
    tags: ?[]const u8 = null,
    image_urls: ?[]const u8 = null,
    video_urls: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    is_auto_retry_until_stop: ?[]const u8 = null,
    selected_profile_model: ?[]const u8 = null,
};

/// Thin orchestrator over `task_create.zig::useCase` + the
/// create_and_run side-effects. The shape mirrors
/// `kanban_columns_create.zig::kanbanColumnsCreateHandler` (path
/// params → body parse → mode dispatch → use-case call → response
/// build).
pub fn kanbanTasksCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;
    // The per-user LLM config is resolved further down, once `:workspace_id`
    // is parsed: the seeding below needs the EFFECTIVE config for THIS
    // workspace (the user config layered under the workspace overlay), and
    // that needs the workspace id. See
    // `session_llm_config.forOwnerAndWorkspace`.

    // Owner for the `sessions` row this request creates (plan 2026-09-25).
    // Server-derived from the `pabrik_session` cookie only — never a body
    // field. Empty when auth is off, which leaves the row in the shared
    // legacy bucket. Without this the row is ownerless, `forSession` cannot
    // resolve the user's `users.config_json`, and the agent run falls back
    // to the process-global `config.json`.
    var owner_buf: [128]u8 = undefined;
    const owner: []const u8 = auth_common.resolveOwnerInto(&owner_buf, req.headers) orelse "";

    // 1. Validate path params + body presence + JSON shape.
    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }
    const ws_id = req.params.get("workspace_id") orelse "";

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(KanbanTaskCreateBody, allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    // 2. Validate the `mode` discriminator. The two valid values are
    // 'create' (just make the card) and 'create_and_run' (make the
    // card AND kick off an agent turn via the session_created SSE).
    if (parsed.mode.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "mode is required (must be 'create' or 'create_and_run')" }),
        });
    }

    const is_create_only = std.mem.eql(u8, parsed.mode, "create");
    const is_create_and_run = std.mem.eql(u8, parsed.mode, "create_and_run");
    const is_create_session = std.mem.eql(u8, parsed.mode, "create_session");
    if (!is_create_only and !is_create_and_run and !is_create_session) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "mode must be 'create', 'create_session', or 'create_and_run'" }),
        });
    }

    if (is_create_and_run) {
        const qm = parsed.queue_message orelse "";
        if (qm.len == 0) {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "queue_message is required when mode='create_and_run'" }),
            });
        }
    }

    // 3. Verify parent item is a kanban — reject 404 otherwise.
    {
        var q = sqlite_db.query(allocator, "SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'kanban'", &[_][]const u8{item_id}) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to verify parent item" }),
            });
        };
        defer q.deinit();
        const row = (q.next() catch null) orelse {
            return res.jsonResponse(.{
                .status_code = 404,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Workspace item not found or is not a kanban" }),
            });
        };
        row.deinit(allocator);
    }

    // 4. Build the standard `TaskCreateInput` and delegate to the
    // task_create use-case for the INSERT + auto-assign + kanban_task
    // SSE. This avoids duplicating the per-mode INSERT logic in
    // task_create.zig (tags validation, image_urls validation, cwd
    // validation, unattended-mode flag, kanban auto-assign, kanban_task
    // SSE). The kanban-scoped task always forces `task_type='standard'`
    // — memory-tasks have their own dedicated dialog in the UI, and
    // routines are workspace-level items now (Migration 084).
    const std_req = http_response.TaskCreateRequest{
        .name = parsed.name,
        .description = parsed.description,
        .task_type = "standard",
        // Only legacy mode='create' forwards the unattended flag into
        // the use-case (its bare sessions INSERT is the ONLY sessions
        // write on that path). For create_session / create_and_run,
        // step 5 below inserts the FULL sessions row (profile + flag)
        // — forwarding the flag here would make useCase insert a bare
        // row first, and this handler's INSERT OR IGNORE would then
        // no-op on the PK conflict, silently dropping
        // selected_profile_model (bug: "wrong profile select",
        // task_1787494153778_2).
        .is_auto_retry_until_stop = if (is_create_only) parsed.is_auto_retry_until_stop else null,
        .tags = parsed.tags,
        .image_urls = parsed.image_urls,
        .video_urls = parsed.video_urls,
        .cwd = parsed.cwd,
    };

    const tc_handler = @import("task_create.zig");
    const input = tc_handler.TaskCreateInput{
        .item_id = item_id,
        .workspace_id = ws_id,
        .io = ctx.io,
        .body = std_req,
        .owner = owner,
    };

    const outcome = tc_handler.useCase(allocator, sqlite_db, input) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired, error.MissingBody, error.InvalidJson => 400,
            error.InvalidTags => 400,
            error.InvalidImageUrls => 400,
            error.ImageUrlsTooLarge => 413,
            error.InvalidVideoUrls => 400,
            error.VideoUrlsTooLarge => 413,
            error.CwdTooLong, error.CwdNotAbsolute, error.CwdContainsControlChar => 400,
            error.StandardTaskCreateFailed => 500,
            error.OutOfMemory, error.Canceled => 500,
            else => 500, // catch-all for the memory variants that shouldn't fire here
        };
        const message: []const u8 = @errorName(err);
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // outcome is .standard (we forced task_type='standard' above).
    const standard_result = switch (outcome) {
        .standard => |s| s,
        else => {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Unexpected task_type outcome from useCase" }),
            });
        },
    };

    // 5. If mode='create_session' OR mode='create_and_run', insert the
    // sessions row keyed by task.id and emit the session_created SSE.
    // Only mode='create_and_run' additionally calls `di.emit_run_agent(...)`
    // to queue the agent turn. Mirrors session_create.zig's path
    // verbatim. The `emit_run_agent` call is what actually starts the
    // agent: it heap-dupes each string into `di.allocator`
    // (synchronously) and enqueues a RunParamsNew event on the
    // `ai_worker_flow` channel; CallbackAiWorkerFlow in main.zig picks
    // it up and runs runAgenticMultiStepnew. Without this call, the
    // row exists but the worker pool never picks it up — the
    // user-visible symptom is exactly what the user reported: task
    // gets created, agent never starts.
    if (is_create_and_run or is_create_session) {
        const normalized: []const u8 = blk: {
            if (parsed.is_auto_retry_until_stop) |f| {
                if (std.mem.eql(u8, f, "1")) break :blk "1";
            }
            break :blk "0";
        };
        var profile: []const u8 = parsed.selected_profile_model orelse "";
        // Per-user LLM config under `--auth` — the active-profile default and
        // the model seed below both belong to the REQUESTING user, resolved
        // through the one config-resolution module (`session_llm_config.zig`).
        //
        // Workspace-scoped, not user-only: this route carries `:workspace_id`,
        // and Settings -> Workspace -> "Set active" writes the workspace
        // overlay, so the EFFECTIVE config is what this task must be seeded
        // from. Resolving `forOwner` here seeded a brand-new task in a
        // workspace whose Active profile is `deepseek auto` with the
        // user-level `killll`; the workflow's non-empty profile write-back
        // then made that the chat's model for every later turn.
        const user_cfg = pabrikcore.session_llm_config.forOwnerAndWorkspace(
            allocator,
            di.io,
            di.db,
            di.environment,
            di.auth_enabled,
            owner,
            ws_id,
        ) orelse auth_common.requestUserConfig(allocator, di.db, di.auth_enabled, req.headers) orelse
            pabrikcore.getLlmConfig(di);
        if (profile.len == 0) {
            if (user_cfg.active_profile) |ap| {
                profile = ap;
            }
        }
        const queue_message = parsed.queue_message orelse "";
        // image_urls/video_urls on the wire are `||`-joined (Migration
        // 069/090 shapes); pass through to the worker pool verbatim.
        const image_urls_wire = parsed.image_urls orelse "";
        const video_urls_wire = parsed.video_urls orelse "";

        sqlite_db.exec(
            allocator,
            "INSERT OR IGNORE INTO sessions (id, name, status, cwd, created_at, updated_at, selected_profile_model, is_auto_retry_until_stop, user_id) " ++
                "VALUES (?, ?, 'active', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, ?, ?)",
            &[_][]const u8{
                standard_result.task_id,
                standard_result.name,
                standard_result.cwd,
                profile,
                normalized,
                owner,
            },
        ) catch |err| {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }),
            });
        };

        // Claim an ownerless row when the INSERT OR IGNORE above no-opped
        // on a pre-existing row (e.g. legacy mode='create' wrote a bare
        // sessions row first without `user_id`). Only claims ownerless
        // rows, so a real owner is never overwritten. Mirrors
        // session_create.zig's post-create stamp.
        if (di.auth_enabled and owner.len > 0) {
            sqlite_db.exec(
                allocator,
                "UPDATE sessions SET user_id = ? WHERE id = ? AND (user_id IS NULL OR user_id = '' OR user_id = 'user_system')",
                &[_][]const u8{ owner, standard_result.task_id },
            ) catch {};
        }

        // Queue the agent turn. Only fire for create_and_run —
        // create_session wants the row inserted but no worker started
        // (the user clicks the card to open the chat themselves).
        // Borrowed slices here are safe because emit_run_agent
        // heap-dupes them before the concurrent worker task reads
        // them.
        if (is_create_and_run) {
            di.emit_run_agent(.{
                .session_id = standard_result.task_id,
                .session_name = standard_result.name,
                .queue_message = queue_message,
                .cwd = standard_result.cwd,
                .body_message = "",
                .allowed_tools = "all",
                .image_urls = image_urls_wire,
                .video_urls = video_urls_wire,
                .selected_profile_model = profile,
                .is_auto_retry_until_stop = normalized,
                // Owner rides along so the concurrent insert_worker task
                // stamps the session row at INSERT time (plan 2026-09-25).
                // Without it the row is briefly ownerless and the workflow
                // resolves the process-global config.json instead of the
                // user's users.config_json.
                .user_id = owner,
            }) catch |err| {
                std.log.warn("kanban_tasks_create: emit_run_agent failed (non-fatal): {s}", .{@errorName(err)});
            };
        }

        // FIX (bug: "create task still not insert user llm history role"):
        // for create_session (plain "Create task" button) the sessions
        // row is inserted but NO user-role row is added to llm_history —
        // so the chatview lands on an empty session and the user's
        // description is silently dropped. create_and_run already does
        // this via the workflow's queue-drain path; here we mirror it
        // inline so the description becomes a visible user message
        // before the user types anything. The INSERT always fires —
        // title-only tasks (empty description + no attachments) ALSO
        // get a user-role row with content `name + "\n\n"` so the
        // chatview never lands on the "How can I help you?" empty
        // state (regression: task_1787757006639_2). Borrowed slices
        // are safe: inserLLMHistories heap-dupes them and the
        // per-request arena reaps on handler return.
        if (is_create_session) {
            const description = parsed.description orelse "";
            // image_urls on the wire is `||`-joined (Migration 069).
            // For create_session we attach them to the user-role
            // llm_history row so the chatview shows the user's
            // attachments inline with the message they typed. The
            // create_and_run path goes through emit_run_agent →
            // workflow queue-drain → inserLLMHistories which handles
            // image_urls separately.
            const initial_message = try std.fmt.allocPrint(
                allocator,
                "{s}\n\n{s}",
                .{ standard_result.name, description },
            );
            const now_ns = std.Io.Timestamp.now(ctx.io, .real).nanoseconds;
            const id_str = try std.fmt.allocPrint(allocator, "{}", .{now_ns});
            const created_at_str = try std.fmt.allocPrint(allocator, "{}", .{now_ns});
            // Direct INSERT (vs. inserLLMHistories) — keeps the
            // patch minimal and avoids relying on the helper's
            // SSE/FTS plumbing for what is effectively a one-shot
            // wire-side message. The FTS trigger on llm_history
            // (see migration.zig) still keeps messages_fts in sync;
            // the SSE emit goes through the existing
            // session_created SSE emitted a few lines below.
            // columns: id, session_id, model, response_content,
            // finish_reason, role, agent, parent_id,
            // parent_session_id, is_input, image_url, video_url,
            // created_at_nano, created_iso, is_feed_to_llm —
            // every other column uses its DEFAULT.
            // image_url/video_url are the `||`-joined wire values.
            //
            // `model` is the session's REAL effective model (the same cascade
            // the workflow resolves on its first turn), guarded so it can
            // never be empty. It used to be a hardcoded `''` literal, which
            // satisfied NOT NULL but wrote a blank model into chat history —
            // visible in the UI and useless to anything reading the row.
            const seed_model = model_guard.resolve(
                user_cfg.resolveEffectiveProfile(profile).model,
            );
            sqlite_db.exec(
                allocator,
                "INSERT INTO llm_history " ++
                    "(id, session_id, model, response_content, finish_reason, role, " ++
                    "agent, parent_id, parent_session_id, is_input, image_url, video_url, " ++
                    "is_feed_to_llm, created_at_nano, created_iso) " ++
                    "VALUES (?, ?, ?, ?, 'null', 'user', 'Agent', ?, ?, 1, ?, ?, 1, ?, '')",
                &[_][]const u8{
                    id_str,
                    standard_result.task_id,
                    seed_model,
                    initial_message,
                    standard_result.task_id,
                    standard_result.task_id,
                    image_urls_wire,
                    video_urls_wire,
                    created_at_str,
                },
            ) catch |err| {
                std.log.warn("kanban_tasks_create: initial user llm_history insert failed (non-fatal): {s}", .{@errorName(err)});
            };
        }

        // Emit the session_created SSE so the sidebar's ChatsList
        // gets the new session without a manual refetch. Mirrors
        // session_create.zig::insertWorker's onEventSendSessions
        // call (action='created'). NOTE: we re-derive the session
        // name from standard_result.name (the bound task name) to
        // match task.id == session.id + session.name = task.name
        // per the 2026-08-13-kanban-task-session-name-match plan.
        //
        // Gated on the INSERT actually having created the row: the
        // `INSERT OR IGNORE` above no-ops when the task already has a
        // sessions row (a re-create, or a task whose session was
        // written by an earlier path), and a `session_created` for a
        // row that already existed makes every connected sidebar
        // re-fetch its whole list for nothing.
        if (sqlite_db.changes() > 0) {
            const on_event_sent = pabrikcore.ai_mod.on_event_sent;
            on_event_sent.onEventSendSessions(allocator, .{
                .action = "created",
                .id = standard_result.task_id,
                .name = standard_result.name,
                .status = "active",
                .cwd = standard_result.cwd,
                .created_at = "",
                .updated_at = "",
                .selected_profile_model = profile,
                .is_auto_retry_until_stop = normalized,
                .last_finish_reason = "",
            }) catch |err| {
                std.log.warn("kanban_tasks_create: session_created SSE emit failed (non-fatal): {s}", .{@errorName(err)});
            };
        }
    }

    // 6. Build the success response. Use std.json.Stringify.valueAlloc
    // for JSON-safe escaping (matches task_create.zig's pattern — see
    // the doc comment above MemoryResponse/StandardResponse
    // in that file for the rationale).
    const ResponseEnvelope = struct {
        task: http_response.TaskCreateResponse,
        session: ?struct {
            id: []const u8,
            name: []const u8,
            status: []const u8,
        } = null,
    };

    const task_resp = http_response.TaskCreateResponse{
        .id = standard_result.task_id,
        .name = standard_result.name,
        .description = parsed.description,
        .completed = false,
        // Media-flags change — echo media-presence flags so the frontend knows
        // whether to lazy-fetch via the media endpoint.
        .is_have_image = standard_result.is_have_image,
        .is_have_video = standard_result.is_have_video,
    };

    var response_body: ResponseEnvelope = .{ .task = task_resp };
    if (is_create_and_run) {
        response_body.session = .{
            .id = standard_result.task_id,
            .name = standard_result.name,
            .status = "send",
        };
    } else if (is_create_session) {
        response_body.session = .{
            .id = standard_result.task_id,
            .name = standard_result.name,
            .status = "idle",
        };
    }

    return res.jsonResponse(.{
        .status_code = 201,
        .data = try std.json.Stringify.valueAlloc(allocator, response_body, .{}),
    });
}
