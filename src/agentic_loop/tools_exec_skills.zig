//! Exec wrappers for the skill agent tools (`search_skills` / `use_skill` /
//! `remove_skill` / `add_skill` / `edit_skill`) — merged 2026-09-11
//! skills-merge refactor: one file, five exec fns. The public names
//! (`execSearchSkills` / `execUseSkill` / `execRemoveSkill` / `execAddSkill` /
//! `execEditSkill`) and behavior are unchanged.
//!
//! `search_skills` replaced the old `list_skills`: same skill library, but the
//! agent now narrows with a regex query and pages through the matches instead
//! of pulling every row into context. Matching + rendering live in
//! `skills_search.zig` (next to `progressive_catalog.zig`), because the regex
//! engine is under `src/agentic_loop/` and `src/modules/` must not import it.
//!
//! What this wrapper threads, and why
//! ────────────────────────────────────
//! The tool modules take `(allocator, db, caller_session_id, input)`. The
//! FIRST of those is a straight port; the second is the point of the change.
//! Until now each wrapper passed `ctx.cwd` and `ctx.environment` down so the
//! tool could pick a skills DIRECTORY out of the two it used to have. There is
//! no directory any more, so what is passed down instead is the pair that
//! decides which rows are even visible: `ctx.db` and `ctx.session_id`.
//!
//! Two details that are load-bearing, not boilerplate:
//!
//!  1. `ignore_unknown_fields`. A model that still says `"is_global": true`
//!     or `"scope": "global"` — from a prompt it was trained on, or a habit —
//!     has the key dropped rather than costing the call. The store's
//!     `workspace_id` scope is not something the model gets to name; a
//!     hallucinated `"workspace_id": "ws_other"` is dropped the same way, and
//!     the static contract test in `skill_tools.zig` fails the build if a real
//!     one ever appears in a schema.
//!  2. The `InnerErrorProbe` re-parse. The tools return `{"error": "..."}`
//!     as their inner payload; without re-probing, that would be wrapped as
//!     `success: true` and the model would read a refused edit as a completed
//!     one.
//!
//! `search_skills` composes more here than in its siblings, and that is not
//! an accident: its matcher lives under `src/agentic_loop/`, so the listing →
//! rows → match → page → render chain cannot live in `skill_tools.zig` without
//! a `modules → agentic_loop` import cycle. It calls
//! `skill_tools.resolveWorkspaceScope` for the same reason its document
//! sibling does — one resolver, one pair of refusal messages.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");
const skills_search = @import("skills_search.zig");

const testing = std.testing;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const SkillSaveInfo = tools.SkillSaveInfo;
const agent = pabrikcore.agent;
const skill_tools_mod = pabrikcore.skill_tools;
const skills_store = pabrikcore.skills_store;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");

/// Probe an inner JSON payload for a top-level `"error"` key. The returned
/// slice borrows from `parsed` — keep it alive through the
/// `wrapToolOutput` call, then `deinit`. A payload that fails to parse is
/// treated as success (the producers always emit valid JSON).
const InnerErrorProbe = struct {
    @"error": ?[]const u8 = null,
};

/// Turn a JSON parse failure into a message the model can act on.
///
/// The old form was `"add_skill failed: MissingField"` — an error NAME.
/// It named no field, showed none of what was received, and gave nothing
/// to correct itself from, so a model that omitted `description` simply
/// emitted the same call again. With every `*SkillInput` field defaulted
/// this path is now only reachable for genuinely malformed JSON or a
/// wrong-typed field; it still has to say WHICH and show the payload.
///
/// Caller owns the returned slice.
fn describeParseFailure(
    allocator: std.mem.Allocator,
    arguments: []const u8,
    err: anyerror,
    summary: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} ({s}). Arguments must be a JSON object whose keys are the tool's own parameters, each with the declared type — `name`/`description`/`content` are strings and `literal` is a boolean, not the string \"true\". Received: {s}", .{
        summary,
        @errorName(err),
        arguments,
    });
}

// ─── search_skills ───

pub fn execSearchSkills(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        skill_tools_mod.SearchSkillsInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        const output = try wrapToolOutput(
            ctx.allocator,
            "search_skills",
            tc.function.arguments,
            false,
            "search_skills failed to parse input (expected {\"query\"?: string, \"literal\"?: bool, \"limit\"?: number, \"offset\"?: number})",
            "",
        );
        return .{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // ── Paging bounds ──
    // Rejected, never silently clamped: the model pages by offset from the
    // `total` it was shown, so a quiet clamp would make its next call land on
    // the wrong window. The messages name the accepted range.
    const limit: usize = blk: {
        const raw = parsed.value.limit orelse @as(i64, @intCast(skills_search.DEFAULT_SEARCH_LIMIT));
        if (raw < 1) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "search_skills: limit must be at least 1 (got {d})", .{raw});
            defer ctx.allocator.free(msg);
            const output = try wrapToolOutput(ctx.allocator, "search_skills", tc.function.arguments, false, msg, "");
            return .{ .output = output, .output_allocated = true };
        }
        if (raw > @as(i64, @intCast(skills_search.MAX_SEARCH_LIMIT))) {
            const msg = try std.fmt.allocPrint(
                ctx.allocator,
                "search_skills: limit must be at most {d} (got {d})",
                .{ skills_search.MAX_SEARCH_LIMIT, raw },
            );
            defer ctx.allocator.free(msg);
            const output = try wrapToolOutput(ctx.allocator, "search_skills", tc.function.arguments, false, msg, "");
            return .{ .output = output, .output_allocated = true };
        }
        break :blk @intCast(raw);
    };
    const offset: usize = blk: {
        const raw = parsed.value.offset orelse 0;
        if (raw < 0) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "search_skills: offset must not be negative (got {d})", .{raw});
            defer ctx.allocator.free(msg);
            const output = try wrapToolOutput(ctx.allocator, "search_skills", tc.function.arguments, false, msg, "");
            return .{ .output = output, .output_allocated = true };
        }
        break :blk @intCast(raw);
    };
    // ── Workspace scope ──
    // Fail-closed, exactly as `document.zig` does it: an unresolvable
    // session is a readable refusal, NOT an empty result set. "this
    // workspace has no matching skills" and "you have no workspace" are
    // different facts and the model has to be able to tell them apart.
    const workspace_id = (skill_tools_mod.resolveWorkspaceScope(ctx.allocator, ctx.db, ctx.session_id) catch null) orelse {
        const msg = try skill_tools_mod.scopeErrorJSON(ctx.allocator, "search_skills", ctx.session_id);
        defer ctx.allocator.free(msg);
        const output = try wrapToolOutput(ctx.allocator, "search_skills", tc.function.arguments, false, msg, "");
        return .{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(workspace_id);

    const rows = skills_store.listSkills(ctx.allocator, ctx.db, workspace_id) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "search_skills", tc.function.arguments, false, err_msg, "");
        return .{ .output = output, .output_allocated = true };
    };
    defer skills_store.freeSkillRows(ctx.allocator, rows);

    const flat = try skills_search.collectRows(ctx.allocator, rows);
    defer ctx.allocator.free(flat);

    const query = parsed.value.query orelse "";
    const outcome = try skills_search.matchQuery(ctx.allocator, flat, query, .{
        .literal = parsed.value.literal orelse false,
    });
    defer ctx.allocator.free(outcome.rows);

    const page = skills_search.pageSlice(outcome.rows, offset, limit);
    const inner = try skills_search.renderSearchResult(ctx.allocator, page, .{
        .total = outcome.rows.len,
        .offset = offset,
        .limit = limit,
        .query = query,
        .mode = outcome.mode,
        .warning = outcome.warning,
    });
    defer ctx.allocator.free(inner);

    const output = try wrapToolOutput(ctx.allocator, "search_skills", tc.function.arguments, true, null, inner);
    return .{ .output = output, .output_allocated = true };
}

// ─── use_skill ───

pub fn execUseSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = try std.json.parseFromSlice(
        skill_tools_mod.UseSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const inner = skill_tools_mod.execute_use_skill_to_string(
        ctx.allocator,
        ctx.io,
        ctx.db,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "use_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    // The tool module allocated `inner` from `ctx.allocator`, so the
    // wrapper owns it. The `skill_save` duplications below are taken
    // BEFORE this fires, so nothing borrowed outlives the buffer.
    defer ctx.allocator.free(inner);

    if (std.json.parseFromSlice(InnerErrorProbe, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed_inner| {
        defer parsed_inner.deinit();
        if (parsed_inner.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "use_skill", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    } else |_| {}

    const output = try wrapToolOutput(ctx.allocator, "use_skill", tc.function.arguments, true, null, inner);

    // Check if skill was successfully loaded and extract skill info for
    // auto-save. The inner payload is JSON
    // (`{skill_name, content, loaded, ...}`); parse it and key off `loaded`
    // instead of substring-matching tags.
    if (std.json.parseFromSlice(skill_tools_mod.UseSkillOutput, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed_inner| {
        defer parsed_inner.deinit();
        if (parsed_inner.value.loaded) {
            const skill_name = try ctx.allocator.dupe(u8, parsed_inner.value.skill_name);
            errdefer ctx.allocator.free(skill_name);
            const skill_content = try ctx.allocator.dupe(u8, parsed_inner.value.content);
            // Return with skill_save info so handle_tool can auto-save to
            // session_skills.
            return ToolExecResult{
                .output = output,
                .output_allocated = true,
                .skill_save = SkillSaveInfo{
                    .name = skill_name,
                    .content = skill_content,
                },
            };
        }
    } else |_| {}

    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── remove_skill ───

pub fn execRemoveSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // `ignore_unknown_fields`, same reason as execAddSkill: a stray key
    // must not cost the call. `session_id` and `is_global` are BOTH gone
    // from the schema — the first was always unused, the second described
    // a tier that no longer exists — but a model trained on the old schema
    // will still send them, and they must be dropped rather than fatal.
    const parsed = std.json.parseFromSlice(
        skill_tools_mod.RemoveSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try describeParseFailure(ctx.allocator, tc.function.arguments, err, "remove_skill failed to parse its arguments");
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = skill_tools_mod.execute_remove_skill_to_string(
        ctx.allocator,
        ctx.db,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // If the inner JSON carries an `error`, treat as failure.
    if (std.json.parseFromSlice(skill_tools_mod.RemoveSkillOutput, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed_inner| {
        defer parsed_inner.deinit();
        if (parsed_inner.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    } else |_| {}

    const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── add_skill ───

pub fn execAddSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // `ignore_unknown_fields` — the sibling `execSearchSkills` has always
    // had it, and without it a model that volunteers one extra key
    // (`is_global`, `scope`, `session_id`, …) gets `UnknownField` and the
    // write is lost. Every `*SkillInput` field now carries a default, so
    // an OMITTED field also parses; `executeAddSkillToString` is where the
    // "which argument is missing" message is produced.
    const parsed = std.json.parseFromSlice(
        skill_tools_mod.AddSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try describeParseFailure(ctx.allocator, tc.function.arguments, err, "add_skill failed to parse its arguments");
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = skill_tools_mod.executeAddSkillToString(
        ctx.allocator,
        ctx.db,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    if (std.json.parseFromSlice(skill_tools_mod.AddSkillOutput, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed_inner| {
        defer parsed_inner.deinit();
        if (parsed_inner.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    } else |_| {}

    const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, true, null, inner);

    // The registry entry has auto_save_skill = true → the dispatcher in
    // handle_tool.zig reads the wrapped JSON `data` (`skill_name`/`content`
    // keys), then saves to session_skills. We return skill_save (not used
    // directly here, but kept for symmetry with execUseSkill's auto-save
    // contract — both rely on the dispatcher's parsing pass over the
    // wrapped output).
    _ = SkillSaveInfo;
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── edit_skill ───

pub fn execEditSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // `ignore_unknown_fields`, same reason as execAddSkill.
    const parsed = std.json.parseFromSlice(
        skill_tools_mod.EditSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try describeParseFailure(ctx.allocator, tc.function.arguments, err, "edit_skill failed to parse its arguments");
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = skill_tools_mod.executeEditSkillToString(
        ctx.allocator,
        ctx.db,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // If the inner JSON carries an `error`, treat as failure. This is the
    // arm that matters most for `edit_skill`: a patch that changed nothing
    // comes back as `{"updated": false, "error": "…"}`, and wrapping that
    // as `success: true` would teach the model that an empty edit works.
    if (std.json.parseFromSlice(skill_tools_mod.EditSkillOutput, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed_inner| {
        defer parsed_inner.deinit();
        if (parsed_inner.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    } else |_| {}

    const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ============================================================================
// tools_exec_skills.zig — inline tests
// ============================================================================
//
// These are ENVELOPE tests, and they exist for one reason: what used to make
// the scope decision was `ctx.cwd` and `ctx.environment`, and both are still
// on `ToolExecContext` — a future edit that reaches for `ctx.cwd` again would
// compile fine and silently resolve nothing. Pinning the behaviour at this
// layer is what makes the refactor observable rather than merely intended.
//
// Rows are seeded through the STORE. A test that INSERTs SQL bypasses the
// `COALESCE(NULLIF(?, ''), '')` write path and would pass while the real
// tool fails.

const sqlite = pabrikcore.sqlite;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT DEFAULT 'active', cwd TEXT)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES
        \\  ('i1', 'ws_1', 'kanban', 'A', '/proj/a', 1),
        \\  ('i2', 'ws_2', 'kanban', 'B', '/proj/b', 1)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('s1', 'T1', 'i1'), ('s2', 'T2', 'i2')
    , &.{});
    try migration.Migration102CreateSkills.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

fn makeTestCtx(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = alloc,
        .io = testing.io,
        .db = db,
        .logger = undefined,
        .session_id = session_id,
        .model = "test-model",
        // Deliberately a directory that holds no skills: if any wrapper
        // still reached for `ctx.cwd`, these tests would find nothing and
        // fail here rather than in production.
        .cwd = "/tmp/pabrik-no-such-skills-dir",
        .api_key = "test-key",
        .base_url = "http://test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
    };
}

fn fakeToolCall(name: []const u8, args: []const u8) agent.ToolCall {
    return .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = name, .arguments = args },
    };
}

/// Flattened, OWNED view of a tool envelope. See `tools_exec_document.zig`
/// for why this dupes everything instead of handing back `p.value` after
/// `deinit()`.
const Envelope = struct {
    allocator: std.mem.Allocator,
    raw: []const u8 = "",
    tool: []const u8 = "",
    success: bool = false,
    err: ?[]const u8 = null,
    skill_name: []const u8 = "",
    name: []const u8 = "",
    content: []const u8 = "",
    loaded: bool = false,
    created: bool = false,
    updated: bool = false,
    removed: bool = false,
    asset_count: usize = 0,
    count: usize = 0,
    total: usize = 0,
    truncated: bool = false,
    next_offset: ?usize = null,
    pattern_mode: []const u8 = "",
    hint: []const u8 = "",
    skills: []const RenderedSkill = &.{},

    fn deinit(self: *Envelope) void {
        const a = self.allocator;
        a.free(self.raw);
        a.free(self.tool);
        if (self.err) |e| a.free(e);
        a.free(self.skill_name);
        a.free(self.name);
        a.free(self.content);
        a.free(self.pattern_mode);
        a.free(self.hint);
        for (self.skills) |s| {
            a.free(s.name);
            a.free(s.description);
        }
        a.free(self.skills);
    }
};

const RenderedSkill = struct {
    name: []const u8,
    description: []const u8,
};

fn parseEnvelope(allocator: std.mem.Allocator, raw: []const u8) !Envelope {
    const DataWire = struct {
        skill_name: []const u8 = "",
        name: []const u8 = "",
        content: []const u8 = "",
        loaded: bool = false,
        created: bool = false,
        updated: bool = false,
        removed: bool = false,
        asset_count: usize = 0,
        pattern_mode: []const u8 = "",
        count: usize = 0,
        total: usize = 0,
        truncated: bool = false,
        next_offset: ?usize = null,
        hint: []const u8 = "",
        skills: []const RenderedSkill = &.{},
    };
    const Wire = struct {
        tool: []const u8 = "",
        success: bool = false,
        @"error": ?[]const u8 = null,
        data: ?DataWire = null,
    };
    const p = try std.json.parseFromSlice(Wire, allocator, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer p.deinit();

    const data: DataWire = p.value.data orelse .{};

    var skills = std.ArrayList(RenderedSkill).empty;
    errdefer {
        for (skills.items) |s| {
            allocator.free(s.name);
            allocator.free(s.description);
        }
        skills.deinit(allocator);
    }
    for (data.skills) |s| {
        try skills.append(allocator, .{
            .name = try allocator.dupe(u8, s.name),
            .description = try allocator.dupe(u8, s.description),
        });
    }

    return .{
        .allocator = allocator,
        .raw = try allocator.dupe(u8, raw),
        .tool = try allocator.dupe(u8, p.value.tool),
        .success = p.value.success,
        .err = if (p.value.@"error") |e| try allocator.dupe(u8, e) else null,
        .skill_name = try allocator.dupe(u8, data.skill_name),
        .name = try allocator.dupe(u8, data.name),
        .content = try allocator.dupe(u8, data.content),
        .loaded = data.loaded,
        .created = data.created,
        .updated = data.updated,
        .removed = data.removed,
        .asset_count = data.asset_count,
        .count = data.count,
        .total = data.total,
        .truncated = data.truncated,
        .next_offset = data.next_offset,
        .pattern_mode = try allocator.dupe(u8, data.pattern_mode),
        .hint = try allocator.dupe(u8, data.hint),
        .skills = try skills.toOwnedSlice(allocator),
    };
}

fn seedSkill(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
    name: []const u8,
    description: []const u8,
    content: []const u8,
) !void {
    const row = try skills_store.upsertSkill(alloc, db, .{
        .workspace_id = workspace_id,
        .name = name,
        .description = description,
        .content = content,
    });
    skills_store.freeSkillRow(alloc, row);
}

test "execAddSkill writes into the SESSION's workspace, and the envelope says created" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try execAddSkill(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall(
        "add_skill",
        "{\"name\":\"notes\",\"description\":\"Keep notes.\",\"content\":\"## When to Use\\n\\nAlways.\"}",
    ));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();

    try testing.expectEqualStrings("add_skill", env.tool);
    try testing.expect(env.success);
    try testing.expect(env.err == null);
    try testing.expect(env.created);
    try testing.expectEqualStrings("notes", env.skill_name);

    // The row is in ws_1, reachable through the store — not on disk.
    const row = try skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "notes");
    defer skills_store.freeSkillRow(alloc, row);
    try testing.expectEqualStrings("Keep notes.", row.description);
    try testing.expectError(error.NotFound, skills_store.getSkillByName(alloc, &ctx.db, "ws_2", "notes"));
}

test "execAddSkill: a hallucinated workspace_id is ignored, not honoured" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // s1 belongs to ws_1. The model asks for ws_2. The wrapper parses with
    // ignore_unknown_fields, the field is dropped, and the write lands in
    // ws_1 — the session's own workspace, never the requested one.
    const result = try execAddSkill(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall(
        "add_skill",
        "{\"name\":\"spoof\",\"description\":\"d\",\"content\":\"body\",\"workspace_id\":\"ws_2\"}",
    ));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();
    try testing.expect(env.success);

    try testing.expectError(error.NotFound, skills_store.getSkillByName(alloc, &ctx.db, "ws_2", "spoof"));
    const mine = try skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "spoof");
    defer skills_store.freeSkillRow(alloc, mine);
}

test "execAddSkill: a stale is_global from the old schema does not cost the call" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // The pre-refactor schema had `is_global`. A model trained on it (or
    // working from an old prompt) still sends it. Under the old parser
    // shape this key existed on the struct; now it is simply unknown, and
    // the write must still happen.
    const result = try execAddSkill(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall(
        "add_skill",
        "{\"name\":\"legacy\",\"description\":\"d\",\"content\":\"body\",\"is_global\":true}",
    ));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();
    try testing.expect(env.success);
    try testing.expectEqualStrings("legacy", env.skill_name);

    const row = try skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "legacy");
    defer skills_store.freeSkillRow(alloc, row);
}

test "execUseSkill returns the body AND the SkillSaveInfo handle_tool persists" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSkill(alloc, &ctx.db, "ws_1", "pdf", "Work with PDFs", "## When to Use\n\nRun scripts/convert.py.");

    const result = try execUseSkill(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("use_skill", "{\"name\":\"pdf\"}"));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();

    try testing.expect(env.success);
    try testing.expect(env.loaded);
    try testing.expectEqualStrings("pdf", env.skill_name);
    try testing.expect(std.mem.indexOf(u8, env.content, "Run scripts/convert.py.") != null);

    // `handle_tool.zig` persists this to session_skills. It is the contract
    // that file owns, so the return value is what must survive here.
    const save = result.skill_save orelse return error.NoSkillSave;
    defer alloc.free(save.name);
    defer alloc.free(save.content);
    try testing.expectEqualStrings("pdf", save.name);
    try testing.expectEqualStrings(env.content, save.content);
}

test "execUseSkill: an unknown name is success=false, never a successful empty load" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSkill(alloc, &ctx.db, "ws_1", "alpha", "first", "a");

    const result = try execUseSkill(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("use_skill", "{\"name\":\"ghost\"}"));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();

    try testing.expect(!env.success);
    try testing.expect(env.err != null);
    try testing.expect(!env.loaded);
    try testing.expect(result.skill_save == null);
}

test "execEditSkill: an ineffective patch surfaces as success=false" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seeded with EXACTLY what `buildSkillContent` produces — that is what
    // the tool stores, so anything else would make this patch a real
    // change and the assertion below would be testing the wrong branch.
    try seedSkill(alloc, &ctx.db, "ws_1", "same", "same description", "---\nname: same\ndescription: \"same description\"\n---\nsame body\n");

    const result = try execEditSkill(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall(
        "edit_skill",
        "{\"skill_name\":\"same\",\"description\":\"same description\",\"content\":\"same body\"}",
    ));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();

    try testing.expect(!env.success);
    try testing.expect(!env.updated);
    try testing.expect(env.err != null);
    try testing.expect(std.mem.indexOf(u8, env.err.?, "nothing to change") != null);
}

test "execEditSkill: a cross-workspace edit is refused and the row is untouched" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSkill(alloc, &ctx.db, "ws_1", "private", "ws_1's copy", "TOPSECRETBODY");

    const result = try execEditSkill(makeTestCtx(alloc, &ctx.db, "s2"), fakeToolCall(
        "edit_skill",
        "{\"skill_name\":\"private\",\"content\":\"hijacked\"}",
    ));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();

    try testing.expect(!env.success);
    try testing.expect(std.mem.indexOf(u8, result.output, "TOPSECRETBODY") == null);

    const survivor = try skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "private");
    defer skills_store.freeSkillRow(alloc, survivor);
    try testing.expectEqualStrings("TOPSECRETBODY", survivor.content);
}

test "execRemoveSkill removes the row from the caller's workspace only" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSkill(alloc, &ctx.db, "ws_1", "doomed", "obsolete", "body");

    const wrong = try execRemoveSkill(makeTestCtx(alloc, &ctx.db, "s2"), fakeToolCall("remove_skill", "{\"skill_name\":\"doomed\"}"));
    defer alloc.free(wrong.output);
    var denied = try parseEnvelope(alloc, wrong.output);
    defer denied.deinit();
    try testing.expect(!denied.success);
    try testing.expect(!denied.removed);

    const result = try execRemoveSkill(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("remove_skill", "{\"skill_name\":\"doomed\"}"));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();
    try testing.expect(env.success);
    try testing.expect(env.removed);
    try testing.expectError(error.NotFound, skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "doomed"));
}

test "execSearchSkills lists the workspace and NEVER mentions a tier or a path" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSkill(alloc, &ctx.db, "ws_1", "alpha", "first skill", "a");
    try seedSkill(alloc, &ctx.db, "ws_1", "beta", "second skill", "b");
    try seedSkill(alloc, &ctx.db, "ws_2", "must-not-leak", "another workspace", "c");

    const result = try execSearchSkills(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("search_skills", "{}"));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();

    try testing.expect(env.success);
    try testing.expectEqual(@as(usize, 2), env.total);
    try testing.expectEqual(@as(usize, 2), env.count);
    try testing.expectEqualStrings("all", env.pattern_mode);

    // The whole point of the row shape: the model gets a NAME to hand
    // back, and nothing that describes a place that no longer exists.
    try testing.expect(std.mem.indexOf(u8, env.raw, "\"scope\"") == null);
    try testing.expect(std.mem.indexOf(u8, env.raw, "\"is_global\"") == null);
    try testing.expect(std.mem.indexOf(u8, env.raw, "\"path\"") == null);
    try testing.expect(std.mem.indexOf(u8, env.raw, "SKILL.MD") == null);
    try testing.expect(std.mem.indexOf(u8, env.raw, ".pabrik/skills") == null);
    try testing.expect(std.mem.indexOf(u8, env.raw, "must-not-leak") == null);
}

test "execSearchSkills: a stale scope argument is ignored, and paging still works" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    for ([_][]const u8{ "d1", "d2", "d3" }) |n| {
        try seedSkill(alloc, &ctx.db, "ws_1", n, "shared body", "x");
    }

    // `"scope": "global"` used to be a filter with a real meaning. Now it is
    // an unknown key: dropped, and the search still returns this
    // workspace's rows.
    const result = try execSearchSkills(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall(
        "search_skills",
        "{\"query\":\"shared\",\"limit\":2,\"scope\":\"global\"}",
    ));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();

    try testing.expect(env.success);
    try testing.expectEqual(@as(usize, 3), env.total);
    try testing.expectEqual(@as(usize, 2), env.count);
    try testing.expect(env.truncated);
    try testing.expectEqual(@as(usize, 2), env.next_offset.?);
    try testing.expect(std.mem.indexOf(u8, env.hint, "offset=2") != null);
}

test "execSearchSkills: out-of-range paging is rejected, never silently clamped" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const zero = try execSearchSkills(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("search_skills", "{\"limit\":0}"));
    defer alloc.free(zero.output);
    var a = try parseEnvelope(alloc, zero.output);
    defer a.deinit();
    try testing.expect(!a.success);
    try testing.expect(std.mem.indexOf(u8, a.err.?, "at least 1") != null);

    const negative = try execSearchSkills(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("search_skills", "{\"offset\":-1}"));
    defer alloc.free(negative.output);
    var b = try parseEnvelope(alloc, negative.output);
    defer b.deinit();
    try testing.expect(!b.success);
    try testing.expect(std.mem.indexOf(u8, b.err.?, "negative") != null);
}

test "every skill exec wrapper treats an unresolvable session as a REFUSAL" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSkill(alloc, &ctx.db, "ws_1", "alpha", "first", "a");

    // "no matching skills" and "you have no workspace" are different facts.
    // A silent empty page would read as "your skills are gone".
    const tc = makeTestCtx(alloc, &ctx.db, "s_orphan");

    const search = try execSearchSkills(tc, fakeToolCall("search_skills", "{}"));
    defer alloc.free(search.output);
    var s = try parseEnvelope(alloc, search.output);
    defer s.deinit();
    try testing.expect(!s.success);
    try testing.expect(std.mem.indexOf(u8, s.err.?, "workspace") != null);

    const add = try execAddSkill(tc, fakeToolCall("add_skill", "{\"name\":\"x\",\"description\":\"d\",\"content\":\"c\"}"));
    defer alloc.free(add.output);
    var a = try parseEnvelope(alloc, add.output);
    defer a.deinit();
    try testing.expect(!a.success);

    const use_ = try execUseSkill(tc, fakeToolCall("use_skill", "{\"name\":\"alpha\"}"));
    defer alloc.free(use_.output);
    var u = try parseEnvelope(alloc, use_.output);
    defer u.deinit();
    try testing.expect(!u.success);

    const edit = try execEditSkill(tc, fakeToolCall("edit_skill", "{\"skill_name\":\"alpha\",\"description\":\"new\"}"));
    defer alloc.free(edit.output);
    var e = try parseEnvelope(alloc, edit.output);
    defer e.deinit();
    try testing.expect(!e.success);

    const remove = try execRemoveSkill(tc, fakeToolCall("remove_skill", "{\"skill_name\":\"alpha\"}"));
    defer alloc.free(remove.output);
    var r = try parseEnvelope(alloc, remove.output);
    defer r.deinit();
    try testing.expect(!r.success);

    // Nothing was written or deleted on the way through.
    const survivor = try skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "alpha");
    defer skills_store.freeSkillRow(alloc, survivor);
    try testing.expectError(error.NotFound, skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "x"));
}

test "malformed JSON arguments become a parse failure, not a crash" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tc = makeTestCtx(alloc, &ctx.db, "s1");

    const add = try execAddSkill(tc, fakeToolCall("add_skill", "{not json"));
    defer alloc.free(add.output);
    var a = try parseEnvelope(alloc, add.output);
    defer a.deinit();
    try testing.expect(!a.success);
    try testing.expect(std.mem.indexOf(u8, a.err.?, "parse") != null);

    const search = try execSearchSkills(tc, fakeToolCall("search_skills", "{not json"));
    defer alloc.free(search.output);
    var s = try parseEnvelope(alloc, search.output);
    defer s.deinit();
    try testing.expect(!s.success);
    try testing.expect(std.mem.indexOf(u8, s.err.?, "parse") != null);
}

test "execEditSkill: a locked skill is a refusal at the envelope, and the body survives" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const seeded = try skills_store.upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .name = "pinned",
        .description = "pinned by the human",
        .content = "KEEPME",
        .is_can_auto_improve = false,
    });
    skills_store.freeSkillRow(alloc, seeded);

    // The tool's inner payload carries `error`, and the `InnerErrorProbe`
    // re-parse is what turns that into `success: false`. Without it the
    // model would read a refused edit as a completed one.
    const result = try execEditSkill(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall(
        "edit_skill",
        "{\"skill_name\":\"pinned\",\"content\":\"hijacked\"}",
    ));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();

    try testing.expect(!env.success);
    try testing.expect(!env.updated);
    try testing.expect(env.err != null);
    try testing.expect(std.mem.indexOf(u8, env.err.?, "locked") != null);

    const survivor = try skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "pinned");
    defer skills_store.freeSkillRow(alloc, survivor);
    try testing.expectEqualStrings("KEEPME", survivor.content);
}
