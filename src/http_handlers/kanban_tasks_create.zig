//! `POST /api/workspaces/:workspace_id/items/:item_id/kanban/tasks`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const auth_common = @import("auth_common.zig");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const on_event_sent_kanban = pabrikcore.ai_mod.on_event_sent_kanban;
const model_guard = @import("../agentic_loop/llm_history_model_guard.zig");

/// HTTP request body for kanban task create.
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

/// Thin orchestrator over `task_create.zig::useCase` + the create_and_run
/// side-effects.
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

    // Owner for the `sessions` row this request creates (plan 2026-09-25).
    // Server-derived from the `pabrik_session` cookie only — never a body
    // field.
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

    // 4. Build the standard `TaskCreateInput` and delegate to the task_create
    // use-case for the INSERT + auto-assign + kanban_task SSE.
    const std_req = http_response.TaskCreateRequest{
        .name = parsed.name,
        .description = parsed.description,
        .task_type = "standard",
        // Only legacy mode='create' forwards the unattended flag into the
        // use-case (its bare sessions INSERT is the ONLY sessions write on
        // that path).
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
        // through the one config-resolution module
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

        // Claim an ownerless row when the INSERT OR IGNORE above no-opped on
        // a pre-existing row (e.g. legacy mode='create' wrote a bare sessions
        // row first without `user_id`).
        if (di.auth_enabled and owner.len > 0) {
            sqlite_db.exec(
                allocator,
                "UPDATE sessions SET user_id = ? WHERE id = ? AND (user_id IS NULL OR user_id = '' OR user_id = 'user_system')",
                &[_][]const u8{ owner, standard_result.task_id },
            ) catch {};
        }

        // Queue the agent turn.
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
                .user_id = owner,
            }) catch |err| {
                std.log.warn("kanban_tasks_create: emit_run_agent failed (non-fatal): {s}", .{@errorName(err)});
            };
        }

        // FIX (bug: "create task still not insert user llm history role"):
        // for create_session (plain "Create task" button) the sessions row is
        // inserted but NO user-role row is added to llm_history — so the
        if (is_create_session) {
            const description = parsed.description orelse "";
            // image_urls on the wire is `||`-joined (Migration 069).
            const initial_message = try std.fmt.allocPrint(
                allocator,
                "{s}\n\n{s}",
                .{ standard_result.name, description },
            );
            const now_ns = std.Io.Timestamp.now(ctx.io, .real).nanoseconds;
            const id_str = try std.fmt.allocPrint(allocator, "{}", .{now_ns});
            const created_at_str = try std.fmt.allocPrint(allocator, "{}", .{now_ns});
            // Direct INSERT (vs. inserLLMHistories) — keeps the patch minimal
            // and avoids relying on the helper's SSE/FTS plumbing for what is
            // effectively a one-shot wire-side message.
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

        // Emit the session_created SSE so the sidebar's ChatsList gets the
        // new session without a manual refetch.
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

    // 6. Build the success response.
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
