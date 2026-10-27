//! Agent memory tools: `save_memory` + `load_memory` (append-only). Merged
//! from `save_memory.zig` + `load_memory.zig` (2026-09-11 memory-merge
//! refactor) — one file, two tools.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const sqlite = pabrikcore.sqlite;
const agent_memories = pabrikcore.agent_memories;

const helpers = @import("helpers");
const sanitizeControlChars = helpers.sanitize_control_chars;

const testing = std.testing;
const migration = @import("../../../migrations/migration.zig");

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

/// Test helper: extract the `"id"` value from a `save_memory`
/// success payload. Returns an allocator-owned dupe the caller frees.
fn extractSavedId(allocator: std.mem.Allocator, save_out: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(
        SaveMemorySuccess,
        allocator,
        save_out,
        .{ .allocate = .alloc_always },
    ) catch return error.MissingId;
    defer parsed.deinit();
    return allocator.dupe(u8, parsed.value.id);
}

/// Success payload for `save_memory`. Tag names from the old XML
/// envelope become keys 1:1.
pub const SaveMemorySuccess = struct {
    id: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    /// The workspace the note was filed under (Migration 095). Empty means
    /// "this session had no workspace".
    workspace_id: []const u8 = "",
};

/// Error payload shared by `save_memory` / `load_memory`.
pub const MemoryError = struct {
    @"error": []const u8,
};

// ─── save_memory ───

// Agent-callable tool: `save_memory` — append a short, structured note that
// the agent can recall later via `load_memory`.

/// Input for `save_memory`. Append-only — no `id`: the id is always
/// auto-generated (`mem_<16-hex>`). (Stale `id` fields in incoming JSON
/// are ignored via `ignore_unknown_fields` at the exec layer.)
pub const SaveMemoryInput = struct {
    /// The note body. 1 KiB – 1 MiB (validated by `agent_memories.saveMemory`).
    content: []const u8 = "",
    /// Optional labels as a single string. Multiple tags separated by `||`
    /// (preferred), `|`, `,`, or space. Empty string = no tags.
    tags: []const u8 = "",
};

/// Top-level tool definition for the LLM.
pub const save_memory_tool_system_prompt =
    \\## Save Memory Tool — Behavior
    \\Use `save_memory` to persist a fact across sessions (FTS5).
    \\- Content must be 1 KiB–1 MiB. Every call APPENDS a new row with a fresh `mem_<hex>` id — there is no update and no delete. To correct a fact, save a new memory; the latest row wins by recency.
    \\- Use for user preferences, project conventions, decisions, and corrections. Call immediately when you learn a preference.
    \\
;

pub const save_memory_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "save_memory",
        .description =
        \\Append a note you can recall later with `load_memory` — a preference, a convention, a decision, a correction worth persisting.
        \\
        \\- APPEND-ONLY: every call inserts a new row with a fresh auto-generated `mem_<16-hex>` id and `CURRENT_TIMESTAMP` timestamps. There is no update and no delete — to correct a fact, save a new memory; recency + FTS5 rank surface the latest one.
        \\- `content` must be 1 KiB – 1 MiB. Empty content is rejected; oversized is rejected (no silent truncation).
        \\- Stored in a SQLite FTS5 table; `load_memory` finds it by phrase matching on content or tags.
        \\- Per-workspace scope (Migration 095): only sessions in the same workspace can recall it, and the scope comes from the session, never from your arguments — there is no `workspace_id` parameter. A fact that must outlive this workspace belongs in `~/.config/pabrik/memories/*.md`, which is global.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "content", .type = "string", .description = "The note body. 1 KiB – 1 MiB. Required." },
                .{ .name = "tags", .type = "string", .description = "Labels, single string: `||`-separated (`|`, `,`, space also accepted), e.g. 'preferences||user'. Empty string = no tags." },
            },
            .required = &.{"content"},
        },
        .system_prompt = save_memory_tool_system_prompt,
    },
};

/// Execute save_memory. Returns a JSON string for the LLM. Caller owns the
/// returned slice and must free it with `allocator.free()`.
pub fn executeSaveMemory(
    allocator: std.mem.Allocator,
    db: *database.Db,
    input: SaveMemoryInput,
    workspace_id: []const u8,
) ![]const u8 {
    // Split the wire-string tags into an array for the storage layer.
    // Empty string → empty array (canonical "no tags" sentinel).
    const tags_array = try splitTagsString(allocator, input.tags);
    defer allocator.free(tags_array);

    const row = agent_memories.saveMemory(allocator, db, .{
        .content = input.content,
        .tags = tags_array,
        .workspace_id = workspace_id,
    }) catch |err| {
        const msg = switch (err) {
            error.InvalidContent => "content must be non-empty (1 KiB minimum)",
            error.ContentTooLarge => "content exceeds the 1 MiB per-memory cap",
            error.RowNotFoundAfterInsert => "row missing after insert (DB inconsistency)",
            else => @errorName(err),
        };
        return saveErrorJSON(allocator, msg);
    };
    defer agent_memories.freeMemoryRow(allocator, row);

    return saveSuccessJSON(allocator, row);
}

/// Split a tags wire string by `||` (preferred), `|`, `,`, and space.
pub fn splitTagsString(allocator: std.mem.Allocator, input: []const u8) ![]const []const u8 {
    // First pass: count tags (skip empty segments).
    var count: usize = 0;
    var in_segment = false;
    for (input) |c| {
        const is_sep = c == '|' or c == ',' or c == ' ';
        if (!is_sep and !in_segment) {
            count += 1;
            in_segment = true;
        } else if (is_sep) {
            in_segment = false;
        }
    }
    if (count == 0) return &.{};

    // Second pass: extract each tag (pointers into the input; bounds-check
    // ensures the input slice stays alive for the caller's use).
    var out = try allocator.alloc([]const u8, count);
    var idx: usize = 0;
    var start: ?usize = null;
    for (input, 0..) |c, i| {
        const is_sep = c == '|' or c == ',' or c == ' ';
        if (is_sep) {
            if (start) |s| {
                out[idx] = trimWhitespace(input[s..i]);
                idx += 1;
                start = null;
            }
        } else if (start == null) {
            start = i;
        }
    }
    if (start) |s| {
        out[idx] = trimWhitespace(input[s..]);
    }
    return out;
}

fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t' or s[start] == '\n' or s[start] == '\r')) : (start += 1) {}
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\n' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[start..end];
}

fn saveSuccessJSON(allocator: std.mem.Allocator, row: agent_memories.MemoryRow) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, SaveMemorySuccess{
        .id = row.id,
        .created_at = row.created_at,
        .updated_at = row.updated_at,
        .workspace_id = row.workspace_id,
    }, .{});
}

fn saveErrorJSON(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const clean = try sanitizeControlChars(allocator, msg);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, MemoryError{
        .@"error" = clean,
    }, .{});
}

// ─── load_memory ───

// Agent-callable tool: `load_memory` — FTS5 phrase search over the
// `agent_memories` store.

/// Input for `load_memory`.
pub const LoadMemoryInput = struct {
    /// FTS5 phrase search. Required when `id` is empty. Sanitized
    /// via `agent_memories.loadMemoriesByFts` (which calls
    /// `escapeFtsQuery` to strip FTS5 operators like `.`, `-`, `:`, `*`).
    query: []const u8 = "",
    /// Look up a single memory by exact id.
    id: []const u8 = "",
    /// Optional AND filter as a single string. Multiple tags separated by
    /// `||` (preferred), `|`, `,`, or space. Empty string = no filter.
    tags: []const u8 = "",
    /// Max rows to return. Default 10, hard cap MAX_LIMIT (50).
    limit: u32 = 10,
    /// Skip the first N rows. Default 0.
    offset: u32 = 0,
    /// When true, include the full content of each FTS hit (truncated to
    /// MAX_FULL_CONTENT_BYTES per row).
    with_content: bool = false,
};

/// Hard cap on the per-row content when `with_content=true`. 2 KiB matches
/// the snippet length used by workspace history search (16 KiB is too large
/// for a memory-note preview; 2 KiB is enough to see context around the
pub const MAX_FULL_CONTENT_BYTES: u32 = 2 * 1024;

/// Hard cap on the result set size. Caller's `limit` is silently
/// capped to this value. 50 rows × 120-char snippets = ~6 KiB
/// (snippet-only) or 50 × 2 KiB = 100 KiB worst case (with_content).
pub const MAX_LIMIT: u32 = 50;

/// Top-level tool definition for the LLM.
pub const load_memory_tool_system_prompt =
    \\## Memory Tools — save_memory + load_memory (append-only)
    \\SQLite FTS5, cross-session. **Mandatory, not optional.** Skipping `load_memory`
    \\when prior context exists, or skipping `save_memory` when a fact should
    \\persist, counts as a task failure.
    \\
    \\These are AGENT-managed notes — distinct from the curated `.md` files in
    \\`~/.config/pabrik/memories/` (auto-injected as `## Global Knowledge`).
    \\- `save_memory` → short structured facts you'd otherwise re-ask or re-derive.
    \\  Every call APPENDS a new timestamped row — there is no edit and no
    \\  delete. To correct a fact, save a new memory.
    \\- `.md` files → hand-curated insights (architecture notes, conventions). Not
    \\  written by these tools; edit directly if that's the surface you need.
    \\
    \\### Scope — per workspace, not global
    \\Notes are filed under the workspace THIS SESSION belongs to. `load_memory`
    \\searches only that workspace, and a `mem_<16-hex>` id from another
    \\workspace comes back `not found`. There is no `workspace_id` argument and
    \\no way to address another workspace from here — the scope comes from the
    \\session, resolved server-side.
    \\
    \\Consequence: a preference you save here will NOT come back in a different
    \\workspace. That is deliberate. If a fact must be true everywhere (a user
    \\preference, a machine-wide convention), it belongs in a `.md` file under
    \\`~/.config/pabrik/memories/`, not in `save_memory`.
    \\
    \\### Reference
    \\
    \\| Tool | Signature | Behavior |
    \\|---|---|---|
    \\| `save_memory` | `{ content, tags? }` | APPENDS a new row with an auto-generated `mem_<16-hex>` id and `CURRENT_TIMESTAMP` timestamps. `content`: 1 KiB–1 MiB (empty/oversized = rejected, never silently truncated). No update, no delete — corrections are new rows. |
    \\| `load_memory` | `{ query, tags?, limit?, offset?, with_content? }` | FTS5 phrase search over `content` + `tags`. Returns ranked hits with `"snippet"`. `with_content=true` → full body, capped 2 KiB/row. `limit` default 10, max 50. Paginate with `"total_count"` + `offset`. |
    \\
    \\### Wire format
    \\- `tags`: **one string**, not an array. Separator preference order: `||` >
    \\  `|` > `,` > space. Example: `tags: "dark-mode||preferences"`.
    \\- `id`: opaque auto-generated `mem_<16-hex>` (returned by `save_memory`,
    \\  echoed in `load_memory` hits). Never parse or construct it — pass it
    \\  through verbatim for by-id lookups.
    \\- FTS query: pass plain text. `.`, `-`, `:` etc. are auto-sanitized/stripped;
    \\  multi-word queries are OR-joined automatically. Do not pre-escape.
    \\
    \\### When to call `load_memory` (before proceeding)
    \\1. First user message of a session — before anything else.
    \\2. User says "do you remember…" / "last time we…" — never guess or fabricate
    \\   an answer to this; the tool call is the only acceptable source.
    \\3. Before re-deriving any fact you could plausibly have already verified
    \\   (a build command, a config value, a prior decision).
    \\4. On entry to any long-running or recurring project.
    \\
    \\### When to call `save_memory` (immediately, not batched for later)
    \\- A user preference is stated (theme, model, language, working hours, profile).
    \\- A project convention is established (build/test/deploy commands, code style).
    \\- A decision is made worth surviving the session.
    \\- A lookup key is defined (model aliases, session_id conventions, board/column
    \\  mappings).
    \\- The user corrects you — **even a single correction, save it immediately.**
    \\- You just re-derived a fact that `load_memory` should have returned — save it
    \\  so the next session doesn't redo the work.
    \\
    \\### Blocking gate (apply before every response)
    \\- About to ask the user something they may have already told you? → `load_memory` first, not a question.
    \\- About to re-derive a fact that could be stored? → `load_memory` first.
    \\- Just learned a preference/convention/correction? → `save_memory` now.
    \\- Is this the first turn of the session? → confirm `load_memory` already ran.
    \\
    \\These four checks are blocking preconditions, not suggestions — do not send a
    \\response that skips a check it should have passed.
    \\
    \\### Examples
    \\- ✅ User: "use pnpm not npm" → immediately `save_memory({ content: "Project uses pnpm, not npm, for all installs/scripts.", tags: "convention||tooling" })`.
    \\- ✅ Session start → `load_memory({ query: "project setup conventions" })` before reading any files.
    \\- ❌ Agent re-asks "which package manager do you use?" after the user already stated it in an earlier session → gate violation; should have called `load_memory` first.
    \\- ❌ Agent discovers the deploy command by trial-and-error but never calls `save_memory` → next session repeats the discovery; gate violation.
;

pub const load_memory_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "load_memory",
        .description =
        \\Search your saved notes (from `save_memory`) with SQLite FTS5. Each hit carries a short `"snippet"` (10-token window with `[match]` markers); `"total_count"` is the full match count.
        \\
        \\- MULTI-WORD QUERIES ARE JOINED WITH OR: `query="preferred model"` matches notes mentioning EITHER "preferred" OR "model". Use a single keyword for precision; `query` matches both content AND tags.
        \\- FTS5 operators (`.`, `-`, `:`, `*`, `^`, `(`, `)`, `"`, `+`) are auto-sanitized, so `handle_tool.zig` and `2026-08-06` are safe query text.
        \\- BY-ID LOOKUP: `id="mem_xxx"` returns one memory's full body (no FTS5, no 2 KiB snippet cap, up to 1 MiB) and ignores `tags`. Either `query` or `id` must be non-empty; supplying both is allowed (by-id wins).
        \\- By default only the `"snippet"` comes back: `with_content=true` adds each hit's full body (capped at 2 KiB per row). At the default `limit` of 10 (hard cap 50) that is at most ~6 KiB snippets-only, ~100 KiB with content.
        \\- SCOPE — PER WORKSPACE, NOT GLOBAL (Migration 095): only notes saved in the workspace THIS SESSION belongs to are reachable, by search or by `id`. A `mem_<16-hex>` id from another workspace returns `not found`, exactly like an id that never existed. There is no `workspace_id` parameter. A fact that must hold across every workspace belongs in a `.md` file under `~/.config/pabrik/memories/`, not in `save_memory`.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "query", .type = "string", .description = "FTS5 search keywords. Required when `id` is empty. Auto-sanitized (FTS5 operators stripped); multi-word queries are joined with OR." },
                .{ .name = "id", .type = "string", .description = "Single memory by exact id (e.g. 'mem_aabbcc...'). FTS5 is skipped and the full body is returned (no 2 KiB cap); `tags` is ignored." },
                .{ .name = "tags", .type = "string", .description = "AND filter, single string: `||`-separated (`|`, `,`, space also accepted), e.g. 'preferences||user'. Empty string = no filter. Ignored when `id` is set." },
                .{ .name = "limit", .type = "number", .description = "Max rows to return. Default 10, hard cap 50." },
                .{ .name = "offset", .type = "number", .description = "Skip the first N results. Default 0. Use total_count to know when to stop." },
                .{ .name = "with_content", .type = "boolean", .description = "Include each hit's full body (max 2 KiB per row) instead of the snippet alone. Default false. Ignored when `id` is set." },
            },
            // `query` was previously the only required field.
            .required = &.{},
        },
        .system_prompt = load_memory_tool_system_prompt,
    },
};

/// Execute load_memory. Returns a JSON string for the LLM. Caller owns the
/// returned slice and must free it with `allocator.free()`.
pub fn executeLoadMemory(
    allocator: std.mem.Allocator,
    db: *database.Db,
    input: LoadMemoryInput,
    workspace_id: []const u8,
) ![]const u8 {
    // Either id OR query must be non-empty. The OpenAI tool-schema DSL
    // can't express "oneOf: query OR id" for primitive strings, so the
    // validation lives here.
    if (input.id.len == 0 and input.query.len == 0) {
        return loadErrorJSON(allocator, "must supply either query or id");
    }

    // By-id path: skip FTS5 entirely. Storage layer's `getMemoryById`
    // returns the FULL content (up to 1 MiB) — no MAX_FULL_CONTENT_BYTES
    // 2 KiB cap. `tags` is ignored (only 1 row can match).
    if (input.id.len > 0) {
        return executeById(allocator, db, input, workspace_id);
    }

    // FTS5 path (unchanged from the 2026-08-06 implementation).
    const effective_limit = @min(input.limit, MAX_LIMIT);

    // Split the wire-string tags into an array for the storage layer.
    // Empty string → empty array (canonical "no filter" sentinel).
    const tags_array = try splitTagsString(allocator, input.tags);
    defer allocator.free(tags_array);

    // Build hits from the FTS5 query.
    const hits = agent_memories.loadMemoriesByFts(allocator, db, .{
        .query = input.query,
        .tags = tags_array,
        .limit = effective_limit,
        .offset = input.offset,
        .workspace_id = workspace_id,
    }) catch |err| {
        const msg = switch (err) {
            error.OutOfMemory => "out of memory",
            else => @errorName(err),
        };
        return loadErrorJSON(allocator, msg);
    };
    defer agent_memories.freeMemoryHits(allocator, hits);

    // Optional: fetch full content for each hit (truncated to
    // MAX_FULL_CONTENT_BYTES). Stored in a separate parallel array so
    // we can free it independently if the XML build fails mid-way.
    var contents: ?[]?[]u8 = null;
    defer if (contents) |cs| {
        for (cs) |maybe_c| if (maybe_c) |c| allocator.free(c);
        allocator.free(cs);
    };

    if (input.with_content and hits.len > 0) {
        const cs = try allocator.alloc(?[]u8, hits.len);
        contents = cs;
        for (hits, 0..) |hit, i| {
            // Scoped even though the hit came from an already-scoped search:
            // this is the one read that returns raw content, so it must not
            // become a way around the workspace filter if the caller's scope
            const row = agent_memories.getMemoryById(allocator, db, hit.id, workspace_id) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "getMemoryById failed: {s}", .{@errorName(err)}) catch "?";
                defer allocator.free(msg);
                return loadErrorJSON(allocator, msg);
            };
            if (row) |r| {
                defer agent_memories.freeMemoryRow(allocator, r);
                const was_truncated = r.content.len > MAX_FULL_CONTENT_BYTES;
                const src: []const u8 = if (was_truncated) r.content[0..MAX_FULL_CONTENT_BYTES] else r.content;
                cs[i] = try allocator.dupe(u8, src);
            } else {
                cs[i] = null;
            }
        }
    }

    return loadSuccessJSON(allocator, hits, contents, input, effective_limit, workspace_id);
}

/// By-id branch of `executeLoadMemory`.
fn executeById(
    allocator: std.mem.Allocator,
    db: *database.Db,
    input: LoadMemoryInput,
    workspace_id: []const u8,
) ![]u8 {
    // Scoped: another workspace's row is reported as `not found`, which
    // is indistinguishable from a row that never existed. Returning
    // "denied" would confirm the id is real.
    const row = agent_memories.getMemoryById(allocator, db, input.id, workspace_id) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "getMemoryById failed: {s}", .{@errorName(err)}) catch "?";
        defer allocator.free(msg);
        return loadErrorJSON(allocator, msg);
    };

    const r = row orelse {
        const msg = std.fmt.allocPrint(allocator, "not found: {s}", .{input.id}) catch "?";
        defer allocator.free(msg);
        return loadErrorJSON(allocator, msg);
    };
    defer agent_memories.freeMemoryRow(allocator, r);

    return loadSuccessByIdJSON(allocator, r, input);
}

/// One hit in a `load_memory` results array. Keys mirror the old
/// `<memory>` child tags 1:1; tags omitted-when-empty in XML
/// (`created_at`, `updated_at`, `content`) are explicit nulls here.
pub const LoadMemoryHitJSON = struct {
    id: []const u8,
    tags: []const u8,
    created_at: ?[]const u8,
    updated_at: ?[]const u8,
    snippet: []const u8,
    content: ?[]const u8 = null,
    truncated: ?bool = null,
};

/// Success payload for `load_memory` (both the FTS5 and by-id branches).
/// Attribute names from the old `<load_memory ...>` wrapper become keys
/// 1:1; `id`/`by_id` are null/false on the FTS5 path.
pub const LoadMemorySuccess = struct {
    query: []const u8,
    id: ?[]const u8 = null,
    by_id: bool = false,
    limit: u32,
    offset: u32,
    with_content: bool,
    count: u32,
    total_count: u32,
    /// The workspace this result set is scoped to (Migration 095).
    /// `total_count` and every row come from this workspace alone.
    workspace_id: []const u8 = "",
    results: []const LoadMemoryHitJSON,
};

fn loadSuccessJSON(
    allocator: std.mem.Allocator,
    hits: []agent_memories.MemoryHit,
    contents: ?[]?[]u8,
    input: LoadMemoryInput,
    effective_limit: u32,
    workspace_id: []const u8,
) ![]u8 {
    const query = try sanitizeControlChars(allocator, input.query);
    defer allocator.free(query);

    var owned = std.ArrayList([]u8).empty;
    defer {
        for (owned.items) |b| allocator.free(b);
        owned.deinit(allocator);
    }
    var results = try allocator.alloc(LoadMemoryHitJSON, hits.len);
    defer allocator.free(results);

    const total_count: u32 = if (hits.len > 0) hits[0].total_count else 0;
    for (hits, 0..) |hit, i| {
        const tags = try sanitizeControlChars(allocator, hit.tags);
        try owned.append(allocator, tags);
        const snippet = try sanitizeControlChars(allocator, hit.snippet);
        try owned.append(allocator, snippet);
        var content: ?[]const u8 = null;
        var truncated: ?bool = null;
        if (contents) |cs| {
            if (cs[i]) |c| {
                const clean = try sanitizeControlChars(allocator, c);
                try owned.append(allocator, clean);
                content = clean;
                truncated = c.len == MAX_FULL_CONTENT_BYTES;
            }
        }
        results[i] = .{
            .id = hit.id,
            .tags = tags,
            .created_at = if (hit.created_at.len > 0) hit.created_at else null,
            .updated_at = if (hit.updated_at.len > 0) hit.updated_at else null,
            .snippet = snippet,
            .content = content,
            .truncated = truncated,
        };
    }

    return std.json.Stringify.valueAlloc(allocator, LoadMemorySuccess{
        .query = query,
        .limit = effective_limit,
        .offset = input.offset,
        .with_content = input.with_content,
        .count = @intCast(hits.len),
        .total_count = total_count,
        .workspace_id = workspace_id,
        .results = results,
    }, .{});
}

/// Build the success payload for the by-id branch. Mirrors the FTS5 shape
/// (one hit wrapped in `results`) so the LLM sees the same JSON structure
/// regardless of which branch ran.
fn loadSuccessByIdJSON(
    allocator: std.mem.Allocator,
    row: agent_memories.MemoryRow,
    input: LoadMemoryInput,
) ![]u8 {
    const tags = try sanitizeControlChars(allocator, row.tags);
    defer allocator.free(tags);
    const content = try sanitizeControlChars(allocator, row.content);
    defer allocator.free(content);

    const results = [_]LoadMemoryHitJSON{.{
        .id = row.id,
        .tags = tags,
        .created_at = if (row.created_at.len > 0) row.created_at else null,
        .updated_at = if (row.updated_at.len > 0) row.updated_at else null,
        .snippet = "",
        .content = content,
        .truncated = false,
    }};

    return std.json.Stringify.valueAlloc(allocator, LoadMemorySuccess{
        .query = "",
        .id = row.id,
        .by_id = true,
        .limit = input.limit,
        .offset = input.offset,
        .with_content = true,
        .count = 1,
        .total_count = 1,
        .workspace_id = row.workspace_id,
        .results = &results,
    }, .{});
}

fn loadErrorJSON(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const clean = try sanitizeControlChars(allocator, msg);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, MemoryError{
        .@"error" = clean,
    }, .{});
}

/// Parsed shape of `executeLoadMemory` output, for tests.
pub const LoadMemoryOutput = LoadMemorySuccess;

// ─── tests: save_memory ───

test "save_memory_tool: tool name is 'save_memory'" {
    const tool = save_memory_tool;
    try testing.expectEqualStrings("save_memory", tool.function.name);
}

test "save_memory_tool: parameters include content and tags (no id — append-only)" {
    const tool = save_memory_tool;
    var found_content = false;
    var found_tags = false;
    var found_id = false;
    for (tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "content")) found_content = true;
        if (std.mem.eql(u8, prop.name, "tags")) found_tags = true;
        if (std.mem.eql(u8, prop.name, "id")) found_id = true;
    }
    try testing.expect(found_content);
    try testing.expect(found_tags);
    try testing.expect(!found_id);
}

// ─── workspace_id is NOT a model-suppliable field (Migration 095) ───── The
// backend resolves the workspace from `ctx.session_id`; the model never names
// it.

test "neither memory tool schema exposes a workspace_id parameter" {
    for (save_memory_tool.function.parameters.properties) |prop| {
        try testing.expect(!std.mem.eql(u8, prop.name, "workspace_id"));
        try testing.expect(!std.mem.eql(u8, prop.name, "workspace"));
        try testing.expect(!std.mem.eql(u8, prop.name, "scope"));
    }
    for (load_memory_tool.function.parameters.properties) |prop| {
        try testing.expect(!std.mem.eql(u8, prop.name, "workspace_id"));
        try testing.expect(!std.mem.eql(u8, prop.name, "workspace"));
        try testing.expect(!std.mem.eql(u8, prop.name, "scope"));
    }
    for (save_memory_tool.function.parameters.required) |r| {
        try testing.expect(!std.mem.eql(u8, r, "workspace_id"));
    }
    for (load_memory_tool.function.parameters.required) |r| {
        try testing.expect(!std.mem.eql(u8, r, "workspace_id"));
    }
}

test "neither *Input struct has a workspace_id field" {
    // These two literals are the assertion: if someone adds a
    // `workspace_id` field to either struct, the suite stops BUILDING
    // rather than quietly accepting a model-supplied scope.
    const save: SaveMemoryInput = .{ .content = "c", .tags = "t" };
    const load: LoadMemoryInput = .{ .query = "q" };
    try testing.expect(save.content.len > 0);
    try testing.expect(load.query.len > 0);

    // The resolved scope travels as a separate trailing argument, not on the
    // struct.
    comptime {
        const SaveFn = *const fn (std.mem.Allocator, *database.Db, SaveMemoryInput, []const u8) anyerror![]const u8;
        const LoadFn = *const fn (std.mem.Allocator, *database.Db, LoadMemoryInput, []const u8) anyerror![]const u8;
        const save_fn: SaveFn = &executeSaveMemory;
        const load_fn: LoadFn = &executeLoadMemory;
        _ = save_fn;
        _ = load_fn;
    }
}

test "save_memory_tool: returns success JSON payload on insert" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = SaveMemoryInput{
        .content = "user prefers dark mode",
        .tags = "preferences",
    };
    const out = try executeSaveMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    // Returns {"id","created_at","updated_at"} on success.
    try testing.expect(std.mem.indexOf(u8, out, "\"id\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"created_at\":") != null);
    // Auto-generated mem_<16-hex> id.
    const generated_id = try extractSavedId(alloc, out);
    defer alloc.free(generated_id);
    try testing.expectEqual(@as(usize, 4 + 16), generated_id.len);
    try testing.expect(std.mem.startsWith(u8, generated_id, "mem_"));
    try testing.expect(std.mem.indexOf(u8, out, "\"created_at\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"updated_at\":") != null);
    // No error envelope.
    try testing.expect(std.mem.indexOf(u8, out, "\"error\":") == null);

    const parsed = try std.json.parseFromSlice(SaveMemorySuccess, alloc, out, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(generated_id, parsed.value.id);
    try std.testing.expect(parsed.value.created_at.len > 0);
    try std.testing.expect(parsed.value.updated_at.len > 0);
}

test "save_memory_tool: returns error JSON on empty content" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = SaveMemoryInput{
        .content = "",
        .tags = "",
    };
    const out = try executeSaveMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    const parsed = try std.json.parseFromSlice(MemoryError, alloc, out, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.@"error", "empty") != null or
        std.mem.indexOf(u8, parsed.value.@"error", "InvalidContent") != null);
}

test "save_memory_tool: returns error JSON on content > 1 MiB" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Allocate 1 MiB + 1 byte of garbage.
    const oversize = alloc.alloc(u8, (1 << 20) + 1) catch @panic("alloc failed for the oversize memory-tool fixture");
    defer alloc.free(oversize);
    @memset(oversize, 'x');

    const input = SaveMemoryInput{
        .content = oversize,
        .tags = "",
    };
    const out = try executeSaveMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"error\":") != null);
}

test "save_memory_tool: saving twice appends two rows (never overwrites)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input1 = SaveMemoryInput{
        .content = "original content",
        .tags = "preferences",
    };
    const out1 = try executeSaveMemory(alloc, &ctx.db, input1, "");
    defer alloc.free(out1);
    const id1 = try extractSavedId(alloc, out1);
    defer alloc.free(id1);
    try testing.expect(id1.len > 0);

    const input2 = SaveMemoryInput{
        .content = "updated content",
        .tags = "preferences||updated",
    };
    const out2 = try executeSaveMemory(alloc, &ctx.db, input2, "");
    defer alloc.free(out2);
    const id2 = try extractSavedId(alloc, out2);
    defer alloc.free(id2);

    // Different ids — the second save did NOT overwrite the first.
    try testing.expect(!std.mem.eql(u8, id1, id2));
    try testing.expect(std.mem.indexOf(u8, out2, "\"error\":") == null);

    // TWO rows in the DB (append, not UPSERT).
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_memories", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);
}

test "save_memory_tool: auto-generates mem_<16-hex> id when none provided" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = SaveMemoryInput{
        .content = "auto-generated memory",
        .tags = "",
    };
    const out = try executeSaveMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    // Extract the auto-generated id.
    const generated_id = try extractSavedId(alloc, out);
    defer alloc.free(generated_id);

    // Format: mem_<16 hex chars>.
    try testing.expectEqual(@as(usize, 4 + 16), generated_id.len);
    try testing.expect(std.mem.startsWith(u8, generated_id, "mem_"));
    for (generated_id[4..]) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(is_hex);
    }
}

test "save_memory_tool: round-trips tag list through storage" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = SaveMemoryInput{
        .content = "memory with multiple tags",
        .tags = "alpha||beta||gamma",
    };
    const out = try executeSaveMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);
    const saved_id = try extractSavedId(alloc, out);
    defer alloc.free(saved_id);

    // Verify tags are stored as ||-joined string.
    var q = try ctx.db.query(alloc, "SELECT tags FROM agent_memories WHERE id = ?", &.{saved_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("alpha||beta||gamma", row.values[0]);
}

// -----------------------------------------------------------------------
// REGRESSION: tags as a single STRING (the new wire format, 2026-08-06) The
// LLM tool schema declares `tags` as a string.
test "save_memory_tool: tags wire format is a string (parses without UnexpectedToken)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // EXACT shape the LLM produced in session-1785986173692 (the bug).
    // tags is a STRING with `|` separator. The stale `id` field is
    // ignored (append-only) via `ignore_unknown_fields`.
    const llm_arguments =
        \\{"content":"Demo note","tags":"demo|tool-test|pabrik","id":"test-bug-string"}
    ;

    const parsed = std.json.parseFromSlice(
        SaveMemoryInput,
        alloc,
        llm_arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        std.debug.print("UNEXPECTED parse failure: {s}\n", .{@errorName(err)});
        return err;
    };
    defer parsed.deinit();

    // The parser must succeed without "UnexpectedToken" (and the stale
    // `id` field is ignored — append-only always mints a fresh id).
    try testing.expect(parsed.value.content.len > 0);
    try testing.expectEqualStrings("demo|tool-test|pabrik", parsed.value.tags);

    // The string form must be passed through to storage correctly
    // (split on || at the wire boundary, joined back to || in DB).
    const out = try executeSaveMemory(alloc, &ctx.db, parsed.value, "");
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"error\":") == null);
    const saved_id = try extractSavedId(alloc, out);
    defer alloc.free(saved_id);

    var q = try ctx.db.query(alloc, "SELECT tags FROM agent_memories WHERE id = ?", &.{saved_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    // After splitTagsString + joinTags, the `|` separator is normalized
    // to `||` (the documented storage convention).
    try testing.expectEqualStrings("demo||tool-test||pabrik", row.values[0]);
}

test "save_memory_tool: single tag (no separator) round-trips" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = SaveMemoryInput{
        .content = "single tag",
        .tags = "demo",
    };
    const out = try executeSaveMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"error\":") == null);
    const saved_id = try extractSavedId(alloc, out);
    defer alloc.free(saved_id);

    var q = try ctx.db.query(alloc, "SELECT tags FROM agent_memories WHERE id = ?", &.{saved_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("demo", row.values[0]);
}

test "save_memory_tool: empty tags string saves empty tags" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = SaveMemoryInput{
        .content = "no tags",
        .tags = "",
    };
    const out = try executeSaveMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"error\":") == null);
    const saved_id = try extractSavedId(alloc, out);
    defer alloc.free(saved_id);

    var q = try ctx.db.query(alloc, "SELECT tags FROM agent_memories WHERE id = ?", &.{saved_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "save_memory_tool: splitTagsString accepts ||, |, comma, and space separators" {
    const alloc = testing.allocator;

    // || separator (the documented "join" form).
    {
        const out = try splitTagsString(alloc, "foo||bar||baz");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 3), out.len);
        try testing.expectEqualStrings("foo", out[0]);
        try testing.expectEqualStrings("bar", out[1]);
        try testing.expectEqualStrings("baz", out[2]);
    }

    // | separator (the LLM tried this in the bug session).
    {
        const out = try splitTagsString(alloc, "demo|tool-test|pabrik");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 3), out.len);
        try testing.expectEqualStrings("demo", out[0]);
    }

    // comma separator (intuitive fallback).
    {
        const out = try splitTagsString(alloc, "foo,bar,baz");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 3), out.len);
    }

    // space separator (also tried by the LLM).
    {
        const out = try splitTagsString(alloc, "demo tool-test pabrik");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 3), out.len);
    }

    // Empty string → empty array.
    {
        const out = try splitTagsString(alloc, "");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 0), out.len);
    }

    // Only separators → empty array.
    {
        const out = try splitTagsString(alloc, "||,, ,|");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 0), out.len);
    }

    // Mixed separators (the LLM might mix).
    {
        const out = try splitTagsString(alloc, "foo||bar,baz qux");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 4), out.len);
        try testing.expectEqualStrings("foo", out[0]);
        try testing.expectEqualStrings("bar", out[1]);
        try testing.expectEqualStrings("baz", out[2]);
        try testing.expectEqualStrings("qux", out[3]);
    }
}

// ─── tests: load_memory ───

test "load_memory_tool: tool name is 'load_memory'" {
    try testing.expectEqualStrings("load_memory", load_memory_tool.function.name);
}

test "load_memory_tool: parameters include query, id, tags, limit, offset, with_content" {
    var found_query = false;
    var found_id = false;
    var found_tags = false;
    var found_limit = false;
    var found_offset = false;
    var found_with_content = false;
    for (load_memory_tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "query")) found_query = true;
        if (std.mem.eql(u8, prop.name, "id")) found_id = true;
        if (std.mem.eql(u8, prop.name, "tags")) found_tags = true;
        if (std.mem.eql(u8, prop.name, "limit")) found_limit = true;
        if (std.mem.eql(u8, prop.name, "offset")) found_offset = true;
        if (std.mem.eql(u8, prop.name, "with_content")) found_with_content = true;
    }
    try testing.expect(found_query);
    try testing.expect(found_id);
    try testing.expect(found_tags);
    try testing.expect(found_limit);
    try testing.expect(found_offset);
    try testing.expect(found_with_content);
}

test "load_memory_tool: returns success JSON payload" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed one memory.
    const _out = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "the user prefers dark mode",
        .tags = "preferences",
    }, "");
    defer alloc.free(_out);
    const seeded_id = try extractSavedId(alloc, _out);
    defer alloc.free(seeded_id);

    const input = LoadMemoryInput{
        .query = "dark mode",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    const parsed = try std.json.parseFromSlice(LoadMemorySuccess, alloc, out, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.count);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.total_count);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.results.len);
    try std.testing.expectEqualStrings(seeded_id, parsed.value.results[0].id);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.results[0].snippet, "[") != null); // [match] marker
    try std.testing.expect(parsed.value.results[0].content == null);
    try std.testing.expect(parsed.value.results[0].truncated == null);
}

test "load_memory_tool: returns error JSON on empty query" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = LoadMemoryInput{
        .query = "",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    const parsed = try std.json.parseFromSlice(MemoryError, alloc, out, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("must supply either query or id", parsed.value.@"error");
}

test "load_memory_tool: limits result count to MAX_LIMIT (50) when caller requests more" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed 60 memories that all match the query.
    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        const _out = try executeSaveMemory(alloc, &ctx.db, .{
            .content = "shared memory content for cap test",
            .tags = "",
        }, "");
        defer alloc.free(_out);
    }

    // Request limit=999 — should be capped to 50.
    const input = LoadMemoryInput{
        .query = "shared",
        .tags = "",
        .limit = 999,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    // Verify "count":50 appears (the cap).
    try testing.expect(std.mem.indexOf(u8, out, "\"count\":50") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"total_count\":60") != null);
}

test "load_memory_tool: snippets contain [match] markers (FTS5 convention)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _out = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "the user prefers dark mode for the editor",
        .tags = "",
    }, "");
    defer alloc.free(_out);

    const input = LoadMemoryInput{
        .query = "dark",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    // Every snippet must have [match] markers (the FTS5 convention).
    try testing.expect(std.mem.indexOf(u8, out, "\"snippet\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[dark]") != null or
        std.mem.indexOf(u8, out, "[dark mode]") != null);
}

test "load_memory_tool: AND-filters by tags" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _out1 = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "memory one with model preference",
        .tags = "preferences||user",
    }, "");
    defer alloc.free(_out1);
    const id1 = try extractSavedId(alloc, _out1);
    defer alloc.free(id1);
    const _out2 = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "memory two with project context",
        .tags = "preferences||project",
    }, "");
    defer alloc.free(_out2);
    const id2 = try extractSavedId(alloc, _out2);
    defer alloc.free(id2);
    const _out3 = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "memory three with project context",
        .tags = "project",
    }, "");
    defer alloc.free(_out3);
    const id3 = try extractSavedId(alloc, _out3);
    defer alloc.free(id3);

    const input = LoadMemoryInput{
        .query = "context",
        .tags = "project",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    // row two + row three match (both have "context" + "project" tag).
    const needle2 = try std.fmt.allocPrint(alloc, "\"id\":\"{s}\"", .{id2});
    defer alloc.free(needle2);
    try testing.expect(std.mem.indexOf(u8, out, needle2) != null);
    const needle3 = try std.fmt.allocPrint(alloc, "\"id\":\"{s}\"", .{id3});
    defer alloc.free(needle3);
    try testing.expect(std.mem.indexOf(u8, out, needle3) != null);
    // row one does NOT match (no "context" in content).
    const needle1 = try std.fmt.allocPrint(alloc, "\"id\":\"{s}\"", .{id1});
    defer alloc.free(needle1);
    try testing.expect(std.mem.indexOf(u8, out, needle1) == null);
    try testing.expect(std.mem.indexOf(u8, out, "\"count\":2") != null);
}

test "load_memory_tool: without with_content, snippets only (content is null)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _out = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "short content for anti-bloat test",
        .tags = "",
    }, "");
    defer alloc.free(_out);

    const input = LoadMemoryInput{
        .query = "content",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false, // ← snippets only
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    // "snippet" present, "content" explicitly null.
    try testing.expect(std.mem.indexOf(u8, out, "\"snippet\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"content\":null") != null);
}

test "load_memory_tool: paginates via limit + offset" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed 5 memories that all match "pageword".
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const _out = try executeSaveMemory(alloc, &ctx.db, .{
            .content = "pageword row",
            .tags = "",
        }, "");
        defer alloc.free(_out);
    }

    // Page 1: limit=3 → 3 hits.
    const out1 = try executeLoadMemory(alloc, &ctx.db, .{
        .query = "pageword",
        .tags = "",
        .limit = 3,
        .offset = 0,
        .with_content = false,
    }, "");
    defer alloc.free(out1);
    try testing.expect(std.mem.indexOf(u8, out1, "\"count\":3") != null);
    try testing.expect(std.mem.indexOf(u8, out1, "\"total_count\":5") != null);

    // Page 2: limit=3 offset=3 → 2 hits.
    const out2 = try executeLoadMemory(alloc, &ctx.db, .{
        .query = "pageword",
        .tags = "",
        .limit = 3,
        .offset = 3,
        .with_content = false,
    }, "");
    defer alloc.free(out2);
    try testing.expect(std.mem.indexOf(u8, out2, "\"count\":2") != null);
    try testing.expect(std.mem.indexOf(u8, out2, "\"total_count\":5") != null);
}

test "load_memory_tool: FTS5 query sanitization (dots, dashes, colons don't crash)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _out = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "this row contains handle_tool.zig and AGENTS.md",
        .tags = "",
    }, "");
    defer alloc.free(_out);
    const seeded_id = try extractSavedId(alloc, _out);
    defer alloc.free(seeded_id);

    // Queries with FTS5-special chars must NOT crash (escapeFtsQuery
    // strips the operators and joins tokens with OR, so the FTS5 query
    // parser doesn't see `.`, `:`, `-`, etc.).
    const input = LoadMemoryInput{
        .query = "handle_tool.zig",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    // No "error" — the query didn't crash.
    try testing.expect(std.mem.indexOf(u8, out, "\"error\":") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\"results\":") != null);
    const expected_id = try std.fmt.allocPrint(alloc, "\"id\":\"{s}\"", .{seeded_id});
    defer alloc.free(expected_id);
    try testing.expect(std.mem.indexOf(u8, out, expected_id) != null);
}

// --- Regression tests for the strict-search bug (task_1787050039216_3) ---
// Symptom: load_memory({query: "preferred model"}) returned 0 hits because
// the query was wrapped in FTS5 phrase syntax, requiring "preferred" to be

test "load_memory_tool: multi-token query joins with OR (regression for strict-search bug)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed 3 memories that mention "preferred" or "model" separately,
    // but NOT the literal substring "preferred model" as adjacent text.
    const _o1 = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "the user's preferred model is claude-sonnet",
        .tags = "",
    }, "");
    defer alloc.free(_o1);
    const id1 = try extractSavedId(alloc, _o1);
    defer alloc.free(id1);
    const _o2 = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "user prefers claude-sonnet for writing tasks",
        .tags = "",
    }, "");
    defer alloc.free(_o2);
    const id2 = try extractSavedId(alloc, _o2);
    defer alloc.free(id2);
    const _o3 = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "the project's database model is documented in spec",
        .tags = "",
    }, "");
    defer alloc.free(_o3);
    const id3 = try extractSavedId(alloc, _o3);
    defer alloc.free(id3);

    // With the old phrase-wrap behavior, this query would return 0 hits
    // because no memory contains the literal substring "preferred model".
    // With the new OR-join behavior, this query should find all 3.
    const input = LoadMemoryInput{
        .query = "preferred model",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    // No "error", no crash.
    try testing.expect(std.mem.indexOf(u8, out, "\"error\":") == null);

    // All 3 memories should be found (each contains at least one of the
    // two tokens).
    for ([_][]u8{ id1, id2, id3 }) |saved_id| {
        const needle = try std.fmt.allocPrint(alloc, "\"id\":\"{s}\"", .{saved_id});
        defer alloc.free(needle);
        try testing.expect(std.mem.indexOf(u8, out, needle) != null);
    }
    try testing.expect(std.mem.indexOf(u8, out, "\"count\":3") != null);
}

test "load_memory_tool: single-token query still works (regression guard)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _o1 = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "the user prefers dark mode for the editor",
        .tags = "",
    }, "");
    defer alloc.free(_o1);
    const seeded_id = try extractSavedId(alloc, _o1);
    defer alloc.free(seeded_id);

    const input = LoadMemoryInput{
        .query = "dark",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"error\":") == null);
    const expected_id = try std.fmt.allocPrint(alloc, "\"id\":\"{s}\"", .{seeded_id});
    defer alloc.free(expected_id);
    try testing.expect(std.mem.indexOf(u8, out, expected_id) != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"count\":1") != null);
}

test "load_memory_tool: hyphenated date query returns sanitized recall (no crash)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Memory contains a date that the user might search for verbatim.
    const _o1 = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "log entry on 2026-08-06 says the build is green",
        .tags = "",
    }, "");
    defer alloc.free(_o1);
    const seeded_id = try extractSavedId(alloc, _o1);
    defer alloc.free(seeded_id);

    // The old phrase-wrap behavior turned this into "2026 08 06" (phrase).
    // The new OR-join behavior turns it into "2026 OR 08 OR 06". Both find
    // the row — but we just want to verify no crash and at least 1 hit.
    const input = LoadMemoryInput{
        .query = "2026-08-06",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"error\":") == null);
    const expected_date_id = try std.fmt.allocPrint(alloc, "\"id\":\"{s}\"", .{seeded_id});
    defer alloc.free(expected_date_id);
    try testing.expect(std.mem.indexOf(u8, out, expected_date_id) != null);
}

test "load_memory_tool: empty-after-sanitize query returns empty results (no crash)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // A query of only FTS5 operators sanitizes to empty string. The
    // load_memories helper now guards against FTS5's "empty query"
    // error and returns 0 hits instead of crashing.
    const input = LoadMemoryInput{
        .query = "+++--",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"error\":") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\"count\":0") != null);
}

// ─── by-id lookup (Task 1 of 2026-08-19-load-memory-by-id) ──────────────
// Adds an `id` parameter to `load_memory` so the LLM can fetch a specific
// memory's FULL body (no 2 KiB cap) without running an FTS5 query.

test "load_memory_tool: by-id lookup returns single row with full content" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _out = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "the user's preferred model is claude-sonnet",
        .tags = "preferences||user",
    }, "");
    defer alloc.free(_out);
    const seeded_id = try extractSavedId(alloc, _out);
    defer alloc.free(seeded_id);

    // id-only, with_content defaults to false — content still comes back
    // because the by-id path is targeted (not an FTS snippet).
    const input = LoadMemoryInput{
        .query = "",
        .id = seeded_id,
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"results\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"error\":") == null);
    const expected_id = try std.fmt.allocPrint(alloc, "\"id\":\"{s}\"", .{seeded_id});
    defer alloc.free(expected_id);
    try testing.expect(std.mem.indexOf(u8, out, expected_id) != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"tags\":\"preferences||user\"") != null);
    // Full body, not just a 10-token snippet.
    try testing.expect(std.mem.indexOf(u8, out, "preferred model is claude-sonnet") != null);
    // Wrapped in "results" for shape consistency with the FTS path.
    try testing.expect(std.mem.indexOf(u8, out, "\"count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"total_count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"results\":") != null);
}

test "load_memory_tool: by-id lookup returns content beyond 2 KiB (no MAX_FULL_CONTENT_BYTES cap)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed a memory with content > 2 KiB so the FTS5 + with_content=true
    // path would truncate at MAX_FULL_CONTENT_BYTES (2 KiB). The by-id
    // path must return the FULL body.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(alloc);
    const filler = "lorem ipsum dolor sit amet consectetur adipiscing elit ";
    var i: u32 = 0;
    while (big.items.len < 4096) : (i += 1) {
        try big.print(alloc, "{s}", .{filler});
    }
    try big.appendSlice(alloc, "DISTINCT_TAIL_TOKEN_AFTER_2KIB_MARK");

    const _out = try executeSaveMemory(alloc, &ctx.db, .{
        .content = big.items,
        .tags = "",
    }, "");
    defer alloc.free(_out);
    const big_id = try extractSavedId(alloc, _out);
    defer alloc.free(big_id);

    const input = LoadMemoryInput{
        .query = "",
        .id = big_id,
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"error\":") == null);
    // Tail marker is well past the 2 KiB cutoff — only reachable if the
    // by-id path bypasses MAX_FULL_CONTENT_BYTES.
    try testing.expect(std.mem.indexOf(u8, out, "DISTINCT_TAIL_TOKEN_AFTER_2KIB_MARK") != null);
    // No "truncated":true — content is not truncated.
    try testing.expect(std.mem.indexOf(u8, out, "\"truncated\":true") == null);
}

test "load_memory_tool: by-id lookup returns error when id not found" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = LoadMemoryInput{
        .query = "",
        .id = "mem-does-not-exist",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"error\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "not found") != null);
    // No "results" key — error shape only.
    try testing.expect(std.mem.indexOf(u8, out, "\"results\":") == null);
}

test "load_memory_tool: empty id + empty query returns error" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = LoadMemoryInput{
        .query = "",
        .id = "",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"error\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "must supply either query or id") != null);
}

test "load_memory_tool: by-id ignores tags (only one row can match anyway)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed two memories — the by-id lookup must return only the one
    // with the matching id, regardless of the tags filter.
    const _a = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "memory alpha",
        .tags = "alpha",
    }, "");
    defer alloc.free(_a);
    const alpha_id = try extractSavedId(alloc, _a);
    defer alloc.free(alpha_id);
    const _b = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "memory beta",
        .tags = "beta",
    }, "");
    defer alloc.free(_b);
    const beta_id = try extractSavedId(alloc, _b);
    defer alloc.free(beta_id);

    const input = LoadMemoryInput{
        .query = "",
        .id = alpha_id,
        .tags = "beta", // intentionally wrong tag — must be ignored
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input, "");
    defer alloc.free(out);

    const needle_alpha = try std.fmt.allocPrint(alloc, "\"id\":\"{s}\"", .{alpha_id});
    defer alloc.free(needle_alpha);
    try testing.expect(std.mem.indexOf(u8, out, needle_alpha) != null);
    const needle_beta = try std.fmt.allocPrint(alloc, "\"id\":\"{s}\"", .{beta_id});
    defer alloc.free(needle_beta);
    try testing.expect(std.mem.indexOf(u8, out, needle_beta) == null);
}

// Exec adapter — merged from `memory.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const exec_testing = std.testing;
const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const exec_migration = @import("../../../migrations/migration.zig");
const workspace_scope = @import("../../../agentic_loop/workspace_scope.zig");
const exec_sqlite = exec_pabrikcore.sqlite;
const database = exec_pabrikcore.database;
const exec_agent_memories = exec_pabrikcore.agent_memories;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
/// Probe an inner JSON payload for a top-level `"error"` key. The returned
/// slice borrows from `parsed` — keep it alive through the `wrapToolOutput`
/// call, then `deinit`.
const InnerErrorProbe = struct {
    @"error": ?[]const u8 = null,
};

// ─── save_memory ───

/// Resolve the workspace this session's memory operations are scoped to.
fn resolveScope(ctx: ToolExecContext) !?[]u8 {
    return workspace_scope.resolveWorkspaceId(ctx.allocator, ctx.db, ctx.session_id);
}

pub fn execSaveMemory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        SaveMemoryInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "save_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const resolved = try resolveScope(ctx);
    defer if (resolved) |w| ctx.allocator.free(w);
    const workspace_id = resolved orelse "";

    const inner = executeSaveMemory(
        ctx.allocator,
        ctx.db,
        parsed.value,
        workspace_id,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "save_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the {"error":...} shape and surface it as a tool failure
    // (so the LLM sees success=false rather than a successful wrapper
    // around an error body).
    if (std.json.parseFromSlice(InnerErrorProbe, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "save_memory", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "save_memory", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── load_memory ───

pub fn execLoadMemory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        LoadMemoryInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "load_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const resolved = try resolveScope(ctx);
    defer if (resolved) |w| ctx.allocator.free(w);
    const workspace_id = resolved orelse "";

    const inner = executeLoadMemory(
        ctx.allocator,
        ctx.db,
        parsed.value,
        workspace_id,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "load_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the {"error":...} shape and surface it as a tool failure
    // (so the LLM sees success=false rather than a successful wrapper
    // around an error body).
    if (std.json.parseFromSlice(InnerErrorProbe, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "load_memory", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "load_memory", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── tests ───

const exec_TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn exec_setupDb() !exec_TestCtx {
    const alloc = exec_testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    var manager = exec_migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try exec_migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn makeTestCtx(allocator: std.mem.Allocator, db: *database.Db) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .db = db,
        .logger = undefined,
        .session_id = "sess_exec",
        .model = "test-model",
        .cwd = "/tmp",
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

test "execSaveMemory: happy path wraps success=true and appends a new row" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("save_memory", "{\"content\":\"row saved via exec wrapper\",\"tags\":\"test\"}");

    const result = try execSaveMemory(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try exec_testing.expect(result.output_allocated);
    const env = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env.deinit();
    try exec_testing.expectEqualStrings("save_memory", env.value.object.get("tool").?.string);
    try exec_testing.expect(env.value.object.get("success").?.bool);
    try exec_testing.expect(env.value.object.get("error").? == .null);
    // Inner payload rides in "data" with the saved row id.
    const data = env.value.object.get("data").?.object;
    try exec_testing.expect(data.get("id").?.string.len > 0);

    // Saving the same payload again appends a second row (append-only).
    const result2 = try execSaveMemory(tcx, tc);
    defer if (result2.output_allocated) alloc.free(result2.output);
    const env2 = try std.json.parseFromSlice(std.json.Value, alloc, result2.output, .{});
    defer env2.deinit();
    try exec_testing.expect(env2.value.object.get("success").?.bool);

    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_memories", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try exec_testing.expectEqualStrings("2", row.values[0]);
}

test "execSaveMemory: empty content surfaces inner error as success=false" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("save_memory", "{\"content\":\"\"}");

    const result = try execSaveMemory(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try exec_testing.expect(result.output_allocated);
    const env = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env.deinit();
    try exec_testing.expect(!env.value.object.get("success").?.bool);
    try exec_testing.expect(env.value.object.get("error").?.string.len > 0);
}

// ─── workspace scope (Migration 095) ──────────────────────────────────

/// Link a session id to a workspace the deterministic way:
/// `workspace_item_tasks.id` IS the session id, so the exact-task branch
/// of `resolveWorkspaceId` resolves without touching the cwd heuristic.
fn linkSessionToWorkspace(alloc: std.mem.Allocator, db: *database.Db, session_id: []const u8, workspace_id: []const u8, item_id: []const u8) !void {
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path) " ++
            "VALUES (?, ?, 'kanban', 'test', ?)",
        &.{ item_id, workspace_id, "/tmp/does-not-match-any-workspace" },
    );
    try db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES (?, 't', ?)",
        &.{ session_id, item_id },
    );
}

fn ctxForSession(allocator: std.mem.Allocator, db: *database.Db, session_id: []const u8) ToolExecContext {
    var base = makeTestCtx(allocator, db);
    base.session_id = session_id;
    return base;
}

test "execSaveMemory / execLoadMemory: a session only sees its OWN workspace's memories" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try linkSessionToWorkspace(alloc, &ctx.db, "sess_alpha", "ws_alpha", "item_alpha");
    try linkSessionToWorkspace(alloc, &ctx.db, "sess_beta", "ws_beta", "item_beta");

    const alpha_ctx = ctxForSession(alloc, &ctx.db, "sess_alpha");
    const beta_ctx = ctxForSession(alloc, &ctx.db, "sess_beta");

    // Workspace A saves a note about a term B also searches for.
    const save = fakeToolCall("save_memory", "{\"content\":\"alpha workspace: the deploy token rotates weekly\"}");
    const saved = try execSaveMemory(alpha_ctx, save);
    defer if (saved.output_allocated) alloc.free(saved.output);
    const saved_env = try std.json.parseFromSlice(std.json.Value, alloc, saved.output, .{});
    defer saved_env.deinit();
    const saved_id = try alloc.dupe(u8, saved_env.value.object.get("data").?.object.get("id").?.string);
    defer alloc.free(saved_id);
    // The payload tells the agent which workspace filed the note.
    try exec_testing.expectEqualStrings("ws_alpha", saved_env.value.object.get("data").?.object.get("workspace_id").?.string);

    // Workspace B runs the same search and gets nothing.
    const search = fakeToolCall("load_memory", "{\"query\":\"deploy token\"}");
    const beta_out = try execLoadMemory(beta_ctx, search);
    defer if (beta_out.output_allocated) alloc.free(beta_out.output);
    const beta_env = try std.json.parseFromSlice(std.json.Value, alloc, beta_out.output, .{});
    defer beta_env.deinit();
    const beta_data = beta_env.value.object.get("data").?.object;
    try exec_testing.expectEqual(@as(i64, 0), beta_data.get("count").?.integer);
    try exec_testing.expectEqual(@as(i64, 0), beta_data.get("total_count").?.integer);
    try exec_testing.expectEqualStrings("ws_beta", beta_data.get("workspace_id").?.string);

    // Workspace B cannot reach A's note by id either.
    const by_id_args = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\"}}", .{saved_id});
    defer alloc.free(by_id_args);
    const stolen = try execLoadMemory(beta_ctx, fakeToolCall("load_memory", by_id_args));
    defer if (stolen.output_allocated) alloc.free(stolen.output);
    const stolen_env = try std.json.parseFromSlice(std.json.Value, alloc, stolen.output, .{});
    defer stolen_env.deinit();
    // Reported as a plain "not found" — never as a denial, which would
    // confirm the id exists somewhere.
    try exec_testing.expect(!stolen_env.value.object.get("success").?.bool);
    const stolen_err = stolen_env.value.object.get("error").?.string;
    try exec_testing.expect(std.mem.indexOf(u8, stolen_err, "not found") != null);

    // Workspace A still reads its own note by id, and by search.
    const own = try execLoadMemory(alpha_ctx, fakeToolCall("load_memory", by_id_args));
    defer if (own.output_allocated) alloc.free(own.output);
    const own_env = try std.json.parseFromSlice(std.json.Value, alloc, own.output, .{});
    defer own_env.deinit();
    try exec_testing.expect(own_env.value.object.get("success").?.bool);
    try exec_testing.expectEqual(@as(i64, 1), own_env.value.object.get("data").?.object.get("count").?.integer);

    const alpha_search = try execLoadMemory(alpha_ctx, search);
    defer if (alpha_search.output_allocated) alloc.free(alpha_search.output);
    const alpha_env = try std.json.parseFromSlice(std.json.Value, alloc, alpha_search.output, .{});
    defer alpha_env.deinit();
    try exec_testing.expectEqual(@as(i64, 1), alpha_env.value.object.get("data").?.object.get("count").?.integer);
}

test "execSaveMemory: a session with no resolvable workspace writes to the '' bucket" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // "sess_exec" has no workspace link and its cwd (/tmp) matches no
    // workspace_items.path → resolveWorkspaceId returns null.
    const tcx = makeTestCtx(alloc, &ctx.db);
    const result = try execSaveMemory(tcx, fakeToolCall("save_memory", "{\"content\":\"no workspace here\"}"));
    defer if (result.output_allocated) alloc.free(result.output);

    const env = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env.deinit();
    try exec_testing.expect(env.value.object.get("success").?.bool);
    try exec_testing.expectEqualStrings("", env.value.object.get("data").?.object.get("workspace_id").?.string);

    // Stored as '' — NOT NULL satisfied via the column DEFAULT, not a
    // NULL bind.
    var q = try ctx.db.query(alloc, "SELECT workspace_id FROM agent_memories", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try exec_testing.expectEqualStrings("", row.values[0]);
}

test "a workspace_id smuggled into the tool payload is ignored — the session still decides" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try linkSessionToWorkspace(alloc, &ctx.db, "sess_alpha", "ws_alpha", "item_alpha");
    try linkSessionToWorkspace(alloc, &ctx.db, "sess_beta", "ws_beta", "item_beta");

    const alpha_ctx = ctxForSession(alloc, &ctx.db, "sess_alpha");
    const beta_ctx = ctxForSession(alloc, &ctx.db, "sess_beta");

    // A note in beta, so alpha has something it must NOT be able to reach.
    const beta_seed = try execSaveMemory(beta_ctx, fakeToolCall("save_memory", "{\"content\":\"beta only: the vault token\"}"));
    defer if (beta_seed.output_allocated) alloc.free(beta_seed.output);
    const beta_env = try std.json.parseFromSlice(std.json.Value, alloc, beta_seed.output, .{});
    defer beta_env.deinit();
    const beta_id = try alloc.dupe(u8, beta_env.value.object.get("data").?.object.get("id").?.string);
    defer alloc.free(beta_id);

    // Alpha tries to WRITE into beta by naming it. `ignore_unknown_fields`
    // drops the key, and the row is filed under alpha's own workspace.
    const smuggle_save =
        \\{"content":"alpha tries to plant a note in beta","workspace_id":"ws_beta","workspace":"ws_beta","scope":"ws_beta"}
    ;
    const planted = try execSaveMemory(alpha_ctx, fakeToolCall("save_memory", smuggle_save));
    defer if (planted.output_allocated) alloc.free(planted.output);
    const planted_env = try std.json.parseFromSlice(std.json.Value, alloc, planted.output, .{});
    defer planted_env.deinit();
    try exec_testing.expect(planted_env.value.object.get("success").?.bool);
    try exec_testing.expectEqualStrings("ws_alpha", planted_env.value.object.get("data").?.object.get("workspace_id").?.string);

    var q = try ctx.db.query(alloc, "SELECT workspace_id FROM agent_memories WHERE content = ?", &.{"alpha tries to plant a note in beta"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try exec_testing.expectEqualStrings("ws_alpha", row.values[0]);

    // Alpha tries to READ beta by naming it — both by search and by id.
    const smuggle_search =
        \\{"query":"vault token","workspace_id":"ws_beta"}
    ;
    const peek = try execLoadMemory(alpha_ctx, fakeToolCall("load_memory", smuggle_search));
    defer if (peek.output_allocated) alloc.free(peek.output);
    const peek_env = try std.json.parseFromSlice(std.json.Value, alloc, peek.output, .{});
    defer peek_env.deinit();
    try exec_testing.expectEqual(@as(i64, 0), peek_env.value.object.get("data").?.object.get("count").?.integer);

    const smuggle_id = try std.fmt.allocPrint(
        alloc,
        "{{\"id\":\"{s}\",\"workspace_id\":\"ws_beta\"}}",
        .{beta_id},
    );
    defer alloc.free(smuggle_id);
    const peek_id = try execLoadMemory(alpha_ctx, fakeToolCall("load_memory", smuggle_id));
    defer if (peek_id.output_allocated) alloc.free(peek_id.output);
    const peek_id_env = try std.json.parseFromSlice(std.json.Value, alloc, peek_id.output, .{});
    defer peek_id_env.deinit();
    try exec_testing.expect(!peek_id_env.value.object.get("success").?.bool);
}

