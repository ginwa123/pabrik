//! Skill agent tools: `search_skills` + `use_skill` + `remove_skill` +
//! `add_skill` + `edit_skill`.

const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const skills_store = pabrikcore.skills_store;
const workspace_scope = pabrikcore.workspace_scope;
/// `skills.zig` next to this file is the BODY layer (frontmatter parsing
/// and bundle materialisation), not a tool definition.
const skills = @import("skills.zig");
const helpers = @import("helpers");
const testing = std.testing;
const migration = @import("../../../migrations/migration.zig");

// ─── shared: workspace scope ────────────────────────────────────────────

/// Resolve the calling session's workspace.
pub fn resolveWorkspaceScope(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
) !?[]u8 {
    // Rejected BEFORE any DB access: `SqliteBackend.exec` binds a
    // zero-length slice as SQL NULL, so querying with "" is not a
    // harmless no-op.
    if (caller_session_id.len == 0) return null;
    return workspace_scope.resolveWorkspaceId(allocator, db, caller_session_id) catch null;
}

/// The tool-level refusal for an unresolvable scope.
pub const SCOPE_MISSING_SESSION =
    "Missing caller session — cannot resolve which workspace to read or write skills in.";
pub const SCOPE_NO_WORKSPACE =
    "This session is not linked to any workspace, so there is nowhere to store a skill. " ++
    "Run from a workspace chat (a project task or a workspace-scoped chat).";

/// The refusal payload.
pub fn scopeErrorJSON(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    caller_session_id: []const u8,
) ![]const u8 {
    const msg = if (caller_session_id.len == 0) SCOPE_MISSING_SESSION else SCOPE_NO_WORKSPACE;
    return toolErrorJSON(allocator, tool_name, "", msg);
}

/// One JSON `{"error": "..."}` payload with every per-tool field at its
/// not-taken default.
pub fn toolErrorJSON(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    skill_name: []const u8,
    err_msg: []const u8,
) ![]const u8 {
    const clean_name = try helpers.sanitize_control_chars(allocator, skill_name);
    defer allocator.free(clean_name);
    const clean_err = try helpers.sanitize_control_chars(allocator, err_msg);
    defer allocator.free(clean_err);

    if (std.mem.eql(u8, tool_name, "use_skill")) {
        return try std.json.Stringify.valueAlloc(allocator, UseSkillJSON{
            .skill_name = clean_name,
            .content = "",
            .loaded = false,
            .asset_dir = null,
            .asset_count = 0,
            .@"error" = clean_err,
            .available_skills = null,
        }, .{});
    }
    if (std.mem.eql(u8, tool_name, "add_skill")) {
        return try std.json.Stringify.valueAlloc(allocator, AddSkillJSON{
            .skill_name = clean_name,
            .name = clean_name,
            .created = false,
            .@"error" = clean_err,
        }, .{});
    }
    if (std.mem.eql(u8, tool_name, "edit_skill")) {
        return try std.json.Stringify.valueAlloc(allocator, EditSkillJSON{
            .skill_name = clean_name,
            .name = clean_name,
            .updated = false,
            .edited = false,
            .@"error" = clean_err,
        }, .{});
    }
    return try std.json.Stringify.valueAlloc(allocator, RemoveSkillJSON{
        .skill_name = clean_name,
        .removed = false,
        .@"error" = clean_err,
    }, .{});
}

// ─── locked skills ───

/// The refusal for a skill the human has pinned. `is_can_auto_improve` off
/// means "the agent may not evolve this", and every agent write tool routes
/// its refusal through here so the three cannot drift into three wordings.
fn lockedSkillJSON(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    skill_name: []const u8,
) ![]const u8 {
    const msg = try std.fmt.allocPrint(
        allocator,
        "{s}: the skill '{s}' is locked — auto-improve is off for it, so no agent may change or delete it. Nothing was written. Ask the human to make this change, or to turn auto-improve back on for this skill in the workspace's Skills settings.",
        .{ tool_name, skill_name },
    );
    defer allocator.free(msg);
    return toolErrorJSON(allocator, tool_name, skill_name, msg);
}

// ─── search_skills ───

/// Input for `search_skills`. Every field is optional: no args returns the
/// first page of every skill installed in the caller's workspace.
pub const SearchSkillsInput = struct {
    query: ?[]const u8 = null,
    literal: ?bool = null,
    limit: ?i64 = null,
    offset: ?i64 = null,
};

pub const search_skills_tool_system_prompt =
    \\## Search Skills Tool — Behavior
    \\Use `search_skills` to find the skills installed in this workspace by name or description.
    \\- `query` is a REGEX (case-insensitive, unanchored) matched against each skill's name AND description. A pattern finds skills a phrase cannot: `doc|documentation`, `^zig`, `\btest\`. A query with no metacharacters still behaves as a plain substring search.
    \\- Set `literal: true` when the query is literal text (e.g. `*.zig`, `fn(`) — otherwise its metacharacters are interpreted.
    \\- Results are PAGED: `limit` (default 40, max 200) caps how many rows you get back, `total` is the real match count, and `offset` skips matches. The `hint` names the exact next offset instead of dumping the whole library into your context.
    \\- An invalid pattern is not a failure: it is matched as a literal substring and the result carries `pattern_warning` listing the supported syntax. Read it instead of retrying blindly.
    \\- Omitting `query` is a valid discovery call — it returns the first page of everything installed in this workspace.
    \\- Match on the `name`/`description`, then call `use_skill` with that row's exact `name`.
    \\
;

pub const search_skills_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "search_skills",
        .description =
        \\Search the skills installed in this workspace by name or description. Each row carries the exact `name` to pass to `use_skill`; omit `query` to list them all.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "query",
                    .type = "string",
                    .description = "Regex, matched case-insensitively against each skill's name and description. Supported: literals, '.', '[...]', '\\d \\w \\s \\b', '*', '+', '?', '{m,n}' ranges, '( )' groups, '|', '^', '$'. A metacharacter-free query is a plain substring search; an invalid one is matched as a literal substring and reported in `pattern_warning`.",
                },
                .{
                    .name = "literal",
                    .type = "boolean",
                    .description = "Treat `query` as a literal string — '.', '*', '[', '(' match verbatim. Set this for code-shaped queries ('*.zig', 'fn('). Default false (regex mode).",
                },
                .{
                    .name = "limit",
                    .type = "number",
                    .description = "Maximum matches in THIS response (default 40, max 200). The result always reports the true `total` — raise it or page with `offset` only when needed.",
                },
                .{
                    .name = "offset",
                    .type = "number",
                    .description = "Skip the first N matches (default 0). The previous page's `hint` names the offset that continues it.",
                },
            },
            .required = &.{},
        },
        .system_prompt = search_skills_tool_system_prompt,
    },
};

// ─── use_skill ───

/// Input for `use_skill`. The name is the whole handle — a skill is a
/// row keyed by `(workspace_id, name)`, not a file.
pub const UseSkillInput = struct {
    name: []const u8 = "",
};

/// JSON payload for `use_skill` results. `asset_dir` is `null` for a
/// single-file skill: there is no directory in that case at all, rather
/// than an empty one that would read as "a bundle with nothing in it".
pub const UseSkillJSON = struct {
    skill_name: []const u8,
    content: []const u8,
    loaded: bool,
    /// Absolute path of the materialised companion files, when the skill
    /// is a bundle. This is a MATERIALISATION created per load, not a
    /// location of record — it may be reaped between turns.
    asset_dir: ?[]const u8 = null,
    asset_count: usize = 0,
    @"error": ?[]const u8 = null,
    /// The workspace's other skill names, on a not-found. "No such skill"
    /// is only actionable if the model can see what DOES exist.
    available_skills: ?[]const []const u8 = null,
};

/// Parsed shape of `execute_use_skill_to_string` output, for tests and
/// for the exec wrapper's auto-save pass.
pub const UseSkillOutput = struct {
    skill_name: []const u8 = "",
    content: []const u8 = "",
    loaded: bool = false,
    asset_dir: ?[]const u8 = null,
    asset_count: usize = 0,
    @"error": ?[]const u8 = null,
    available_skills: ?[]const []const u8 = null,
};

/// Actionable `use_skill` failures. Exposed for tests.
pub const USE_SKILL_MISSING_NAME =
    "use_skill: `name` is required. Send the exact skill name `search_skills` reported (e.g. \"pdf\") — the name IS the handle; there is no file path and no SKILL.MD to reconstruct. Run search_skills if you are unsure what exists.";

pub const use_skill_tool_system_prompt =
    \\## Use Skill Tool — Behavior
    \\Use `use_skill` to load a skill's full instructions by exact name (from `search_skills`).
    \\- The name is the whole handle. Pass it verbatim — there is no path.
    \\
;

pub const use_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "use_skill",
        .description = "Load a skill's full instructions by the exact `name` `search_skills` returned. Returns the skill body; a bundle of companion files also returns `asset_dir` (an absolute directory holding them) and `asset_count`.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "name",
                    .type = "string",
                    .description = "The exact skill name from `search_skills` (e.g. 'skill-creator'). A single token — letters, digits, dots, dashes, underscores — not a path.",
                },
            },
            .required = &.{"name"},
        },
        .system_prompt = use_skill_tool_system_prompt,
    },
};

/// Execute `use_skill`. Returns an inner JSON string the exec wrapper embeds.
/// Caller owns the returned memory and must free it.
pub fn execute_use_skill_to_string(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
    input: UseSkillInput,
) ![]const u8 {
    const name = std.mem.trim(u8, input.name, " \t\n\r");
    if (name.len == 0) return try toolErrorJSON(allocator, "use_skill", "", USE_SKILL_MISSING_NAME);
    // Not a path segment any more, but it IS the primary key of the row and
    // the literal argument of every subsequent lookup, so an empty or
    // malformed value is still worth naming rather than reporting as "not
    if (!skills_store.isValidSkillName(name)) {
        return try toolErrorJSON(allocator, "use_skill", "", USE_SKILL_MISSING_NAME);
    }

    const workspace_id = (try resolveWorkspaceScope(allocator, db, caller_session_id)) orelse
        return try scopeErrorJSON(allocator, "use_skill", caller_session_id);
    defer allocator.free(workspace_id);

    const row = skills_store.getSkillByName(allocator, db, workspace_id, name) catch |err| switch (err) {
        error.NotFound => return try useSkillNotFound(allocator, db, workspace_id, name),
        error.WorkspaceIdNameRequired => return try toolErrorJSON(allocator, "use_skill", name, USE_SKILL_MISSING_NAME),
        error.QueryFailed => return try toolErrorJSON(allocator, "use_skill", name, "Could not read this workspace's skills (database error)."),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer skills_store.freeSkillRow(allocator, row);

    // A bundle's body refers to its companions by relative path
    // (`scripts/run_eval.py`), so those rows have to exist on disk before the
    // model can follow them.
    var asset_dir: ?[]const u8 = null;
    // The STRING is ours to free once the payload has copied it.
    defer if (asset_dir) |d| allocator.free(d);
    var asset_count: usize = 0;
    const assets = try skills_store.listAssets(allocator, db, workspace_id, name);
    defer skills_store.freeSkillAssetRows(allocator, assets);
    if (assets.len > 0) {
        const materialized = skills.materializeAssetDir(io, allocator, name, assets) catch |err| {
            // A refused bundle is a real failure: returning the body with
            // no directory would hand the model instructions to run a
            // script that is not there.
            const detail = try std.fmt.allocPrint(allocator, "{s}: could not materialise this skill's {d} companion file(s).", .{ @errorName(err), assets.len });
            defer allocator.free(detail);
            return try toolErrorJSON(allocator, "use_skill", name, detail);
        };
        asset_dir = materialized.dir;
        asset_count = materialized.file_count;
    }

    const clean_name = try helpers.sanitize_control_chars(allocator, name);
    defer allocator.free(clean_name);
    const clean_content = try helpers.sanitize_control_chars(allocator, row.content);
    defer allocator.free(clean_content);
    const clean_dir: ?[]const u8 = if (asset_dir) |d| try helpers.sanitize_control_chars(allocator, d) else null;
    defer if (clean_dir) |d| allocator.free(d);

    return try std.json.Stringify.valueAlloc(allocator, UseSkillJSON{
        .skill_name = clean_name,
        .content = clean_content,
        .loaded = true,
        .asset_dir = clean_dir,
        .asset_count = asset_count,
        .@"error" = null,
        .available_skills = null,
    }, .{});
}

/// The not-found payload: the truthful "there is no such skill here" shape,
/// plus the names that DO exist in this workspace. The list is the whole
/// point.
fn useSkillNotFound(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
    name: []const u8,
) ![]const u8 {
    // The names are BORROWED from the store rows, so the rows have to outlive
    // the `Stringify` below.
    var rows: ?[]skills_store.SkillRow = null;
    defer if (rows) |r| skills_store.freeSkillRows(allocator, r);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    if (skills_store.listSkills(allocator, db, workspace_id)) |found| {
        rows = found;
        for (found) |r| try names.append(allocator, r.name);
    } else |_| {}

    const clean_name = try helpers.sanitize_control_chars(allocator, name);
    defer allocator.free(clean_name);
    const detail = try std.fmt.allocPrint(allocator, "use_skill: no skill named '{s}' exists in this workspace.", .{clean_name});
    defer allocator.free(detail);
    const clean_detail = try helpers.sanitize_control_chars(allocator, detail);
    defer allocator.free(clean_detail);

    return try std.json.Stringify.valueAlloc(allocator, UseSkillJSON{
        .skill_name = clean_name,
        .content = "",
        .loaded = false,
        .asset_dir = null,
        .asset_count = 0,
        .@"error" = clean_detail,
        .available_skills = if (names.items.len == 0) null else names.items,
    }, .{});
}

// ─── remove_skill ───

/// Input for `remove_skill`.
pub const RemoveSkillInput = struct {
    skill_name: []const u8,
};

/// JSON payload for `remove_skill` results. No `path`: there is no
/// directory any more, so there is nothing truthful to echo.
pub const RemoveSkillJSON = struct {
    skill_name: []const u8,
    removed: bool,
    @"error": ?[]const u8 = null,
};

/// Parsed shape of `execute_remove_skill_to_string` output, for tests.
pub const RemoveSkillOutput = struct {
    skill_name: []const u8 = "",
    removed: bool = false,
    @"error": ?[]const u8 = null,
};

/// Actionable `remove_skill` failures. Exposed for tests.
pub const REMOVE_SKILL_BAD_NAME =
    "remove_skill: `skill_name` must be a single name — letters, digits, dots, dashes, underscores; no slashes, spaces, or leading/trailing dot. It is the skill's primary key, not a path. Got: '";

pub const remove_skill_tool_system_prompt =
    \\## Remove Skill Tool — Behavior
    \\Use `remove_skill` to permanently delete a skill from this workspace.
    \\- Provide `skill_name`. Use only when the skill is obsolete or the user asks to remove it.
    \\
;

pub const remove_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "remove_skill",
        .description = "Permanently delete a skill from this workspace, with any companion files. Use only when it is obsolete or the user asks. A skill with auto-improve turned off is locked, and removing it is refused.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "skill_name",
                    .type = "string",
                    .description = "The exact name of the skill to remove, as `search_skills` reported it.",
                },
            },
            .required = &.{"skill_name"},
        },
        .system_prompt = remove_skill_tool_system_prompt,
    },
};

/// Execute `remove_skill`. Returns an inner JSON string the exec wrapper
/// embeds. Caller owns the returned memory and must free it.
pub fn execute_remove_skill_to_string(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
    input: RemoveSkillInput,
) ![]const u8 {
    const name = std.mem.trim(u8, input.skill_name, " \t\n\r");
    if (name.len == 0) {
        return try toolErrorJSON(allocator, "remove_skill", "", "remove_skill: skill_name cannot be empty.");
    }
    if (!skills_store.isValidSkillName(name)) {
        const msg = try std.fmt.allocPrint(allocator, "{s}{s}'", .{ REMOVE_SKILL_BAD_NAME, name });
        defer allocator.free(msg);
        return try toolErrorJSON(allocator, "remove_skill", name, msg);
    }

    const workspace_id = (try resolveWorkspaceScope(allocator, db, caller_session_id)) orelse
        return try scopeErrorJSON(allocator, "remove_skill", caller_session_id);
    defer allocator.free(workspace_id);

    const existing = skills_store.getSkillByName(allocator, db, workspace_id, name) catch |err| switch (err) {
        error.NotFound => {
            const msg = try std.fmt.allocPrint(allocator, "remove_skill: no skill named '{s}' exists in this workspace. Run search_skills to list the installed names.", .{name});
            defer allocator.free(msg);
            return try toolErrorJSON(allocator, "remove_skill", name, msg);
        },
        error.QueryFailed => return try toolErrorJSON(allocator, "remove_skill", name, "Could not read this workspace's skills (database error)."),
        error.OutOfMemory => return error.OutOfMemory,
        error.WorkspaceIdNameRequired => return try toolErrorJSON(allocator, "remove_skill", name, REMOVE_SKILL_BAD_NAME),
    };
    defer skills_store.freeSkillRow(allocator, existing);

    // A delete is the most destructive write there is, so a pinned skill is
    // off-limits for it too — otherwise "remove then re-add" walks straight
    // around the lock.
    if (!existing.is_can_auto_improve) {
        return try lockedSkillJSON(allocator, "remove_skill", name);
    }

    skills_store.deleteSkill(allocator, db, workspace_id, name) catch |err| switch (err) {
        error.NotFound => {
            const msg = try std.fmt.allocPrint(allocator, "remove_skill: no skill named '{s}' exists in this workspace. Run search_skills to list the installed names.", .{name});
            defer allocator.free(msg);
            return try toolErrorJSON(allocator, "remove_skill", name, msg);
        },
        error.WorkspaceIdNameRequired => return try toolErrorJSON(allocator, "remove_skill", name, REMOVE_SKILL_BAD_NAME),
        error.DeleteFailed => return try toolErrorJSON(allocator, "remove_skill", name, "remove_skill: the skill could not be deleted (database error)."),
    };

    const clean_name = try helpers.sanitize_control_chars(allocator, name);
    defer allocator.free(clean_name);
    return try std.json.Stringify.valueAlloc(allocator, RemoveSkillJSON{
        .skill_name = clean_name,
        .removed = true,
        .@"error" = null,
    }, .{});
}

// ─── shared argument resolution ──────────────────────────────────────────
// `add_skill` / `edit_skill` are the only tools a model calls with
// hand-written prose, and the two mistakes it makes most are both handled

/// A leading `---` … `---` frontmatter block split off `content`. Both
/// slices point into the input; nothing is allocated.
const FrontmatterSplit = struct {
    /// The text between the fences (no fences), or "" when `content` did
    /// not open with a frontmatter block.
    frontmatter: []const u8,
    /// Everything after the closing fence — the whole input when there
    /// was no frontmatter block.
    body: []const u8,
};

/// Split a leading YAML frontmatter block off `content`.
fn splitLeadingFrontmatter(content: []const u8) FrontmatterSplit {
    const none: FrontmatterSplit = .{ .frontmatter = "", .body = content };
    if (!std.mem.startsWith(u8, content, "---\n")) return none;

    const rest = content["---\n".len..];
    var idx: usize = 0;
    while (std.mem.indexOfScalarPos(u8, rest, idx, '-')) |i| {
        idx = i + 1;
        if (i != 0 and rest[i - 1] != '\n') continue;
        if (!std.mem.startsWith(u8, rest[i..], "---")) continue;

        var end = i + 3;
        if (end < rest.len and rest[end] == '\r') end += 1;
        if (end < rest.len and rest[end] == '\n') end += 1;
        // `---x` is not a closing fence; only EOF / `\n` / `\r\n` is.
        if (end != rest.len and end != i + 4 and end != i + 5) continue;

        return .{ .frontmatter = rest[0..i], .body = rest[end..] };
    }
    return none;
}

/// Read `key: value` out of a frontmatter block. Borrowed, trimmed, with one
/// layer of matching quotes removed. Null when the key is absent or its value
/// is empty.
fn frontmatterField(frontmatter: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        const after = trimmed[key.len..];
        // Guards `name` matching a `names:` line.
        if (after.len == 0 or after[0] != ':') continue;

        var value = std.mem.trim(u8, after[1..], " \t\r");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        } else if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') {
            value = value[1 .. value.len - 1];
        }
        if (value.len == 0) return null;
        return value;
    }
    return null;
}

/// The first of `args` that is not empty, else null. Borrowed.
fn firstNonEmpty(args: []const ?[]const u8) ?[]const u8 {
    for (args) |maybe| {
        const v = maybe orelse continue;
        if (v.len != 0) return v;
    }
    return null;
}

// ─── add_skill ───

/// Input for `add_skill`. Every field carries a default, which makes it
/// optional to `std.json.parseFromSlice`.
pub const AddSkillInput = struct {
    /// Skill identifier. Required, but may be omitted when `content`
    /// opens with a `name:` frontmatter line.
    name: []const u8 = "",
    /// When to trigger this skill. Required, but may be omitted when
    /// `content` opens with a `description:` frontmatter line.
    description: []const u8 = "",
    /// Skill body. A leading `---` frontmatter block is stripped and its
    /// fields lifted; the body is what gets written after the generated
    /// frontmatter.
    content: []const u8 = "",
};

pub const add_skill_tool_system_prompt =
    \\## Add Skill Tool — Behavior
    \\Use `add_skill` to create a new skill in this workspace.
    \\- Provide `name`, `description`, and markdown `content`. Use to capture a proven workflow for future sessions.
    \\- Check for existing skill with `search_skills` first to avoid duplicates.
    \\
;

pub const add_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "add_skill",
        .description =
        \\Create a new skill in this workspace — a reusable workflow, pattern or set of instructions for future sessions. `name`, `description` and `content` are separate arguments: the `---` YAML frontmatter is generated from the first two, so never paste one into `content`.
        \\
        \\- `description` decides whether any future session finds the skill at all: `search_skills` returns that one sentence and nothing else.
        \\
        \\- Re-adding an existing name REPLACES that skill. When it is locked (auto-improve off) the call is refused and nothing is written.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "name",
                    .type = "string",
                    .description = "The skill's name, sent as its own argument. Letters, digits, dots, dashes, underscores; no slashes, spaces or leading dot. Example: 'my-workflow'.",
                },
                .{
                    .name = "description",
                    .type = "string",
                    .description = "One sentence: what the skill does AND when to use it — trigger conditions, not a title. E.g. \"Use when moving Zig code between files here.\"",
                },
                .{
                    .name = "content",
                    .type = "string",
                    .description = "The markdown BODY: `## When to Use`, `## Procedure`, `## Pitfalls`. Skip sections that do not apply. No `---` frontmatter — it is generated.",
                },
            },
            .required = &.{ "name", "description", "content" },
        },
        .system_prompt = add_skill_tool_system_prompt,
    },
};

/// Actionable `add_skill` failures.
pub const ADD_SKILL_MISSING_NAME =
    "add_skill: `name` is required. Send the skill's name as its own argument — kebab-case, letters/digits/dots/dashes/underscores, no slashes or spaces (e.g. \"zig-move-code-static-contract-path-pins\"). It becomes the row's key AND the frontmatter `name:`. (A `name:` inside `content`'s frontmatter is read from there instead.)";
pub const ADD_SKILL_MISSING_DESCRIPTION =
    "add_skill: `description` is required. Send it as its own argument: ONE sentence saying what the skill does AND when to use it — it is the only text `search_skills` returns, so a title or a restatement of `name` makes the skill undiscoverable. (A `description:` inside `content`'s frontmatter is read from there instead.)";
pub const ADD_SKILL_MISSING_CONTENT =
    "add_skill: `content` is empty. Send the markdown BODY — `## When to Use` (when it should load), `## Procedure` (atomic steps, exact commands, how to verify), `## Pitfalls` (failure modes you actually hit). A frontmatter block alone leaves nothing for the skill to teach; frontmatter is generated from `name` + `description`.";
pub const ADD_SKILL_BAD_NAME =
    "add_skill: `name` must be a single name — letters, digits, dots, dashes, underscores; no slashes, spaces, or leading/trailing dot. It is the skill's primary key, not a path. Got: '";

/// JSON payload for `add_skill` results.
pub const AddSkillJSON = struct {
    skill_name: []const u8,
    name: []const u8,
    created: bool,
    @"error": ?[]const u8 = null,
};

/// Parsed shape of `executeAddSkillToString` output, for tests.
pub const AddSkillOutput = struct {
    skill_name: []const u8 = "",
    name: []const u8 = "",
    created: bool = false,
    @"error": ?[]const u8 = null,
};

/// Execute `add_skill`. Returns an inner JSON string the exec wrapper
/// embeds. Caller owns the returned memory and must free it.
pub fn executeAddSkillToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
    input: AddSkillInput,
) ![]const u8 {
    // `SkillWriteToolRule` shows the skill format as a `---` frontmatter
    // block, so models routinely paste one into `content`.
    const split = splitLeadingFrontmatter(input.content);
    const fm: ?[]const u8 = if (split.frontmatter.len != 0) split.frontmatter else null;

    const name = firstNonEmpty(&.{ input.name, if (fm) |f| frontmatterField(f, "name") else null });
    const description = firstNonEmpty(&.{ input.description, if (fm) |f| frontmatterField(f, "description") else null });
    const content = split.body;

    // Every message names the argument AND what to send, because the old
    // ones ("Description cannot be empty") told the model nothing and it
    // retried the identical call.
    const resolved_name = name orelse
        return try toolErrorJSON(allocator, "add_skill", "", ADD_SKILL_MISSING_NAME);
    if (description == null) {
        return try toolErrorJSON(allocator, "add_skill", resolved_name, ADD_SKILL_MISSING_DESCRIPTION);
    }
    if (content.len == 0) {
        return try toolErrorJSON(allocator, "add_skill", resolved_name, ADD_SKILL_MISSING_CONTENT);
    }
    if (!skills_store.isValidSkillName(resolved_name)) {
        const msg = try std.fmt.allocPrint(allocator, "{s}{s}'", .{ ADD_SKILL_BAD_NAME, resolved_name });
        defer allocator.free(msg);
        return try toolErrorJSON(allocator, "add_skill", resolved_name, msg);
    }
    const resolved: AddSkillInput = .{
        .name = resolved_name,
        .description = description.?,
        .content = content,
    };

    const workspace_id = (try resolveWorkspaceScope(allocator, db, caller_session_id)) orelse
        return try scopeErrorJSON(allocator, "add_skill", caller_session_id);
    defer allocator.free(workspace_id);

    // `created` has to be read BEFORE the write.
    var replacing_locked = false;
    const existed = blk: {
        const existing = skills_store.getSkillByName(allocator, db, workspace_id, resolved_name) catch |err| switch (err) {
            error.NotFound => break :blk false,
            error.QueryFailed => return try toolErrorJSON(allocator, "add_skill", resolved_name, "Could not read this workspace's skills (database error)."),
            error.OutOfMemory => return error.OutOfMemory,
            error.WorkspaceIdNameRequired => return try toolErrorJSON(allocator, "add_skill", resolved_name, ADD_SKILL_BAD_NAME),
        };
        replacing_locked = !existing.is_can_auto_improve;
        skills_store.freeSkillRow(allocator, existing);
        break :blk true;
    };

    // `upsertSkill` is create-or-REPLACE, so re-adding a pinned name is an
    // edit of a locked skill wearing a create's clothes.
    if (replacing_locked) {
        return try lockedSkillJSON(allocator, "add_skill", resolved_name);
    }

    const file_content = buildSkillContent(allocator, resolved);
    defer allocator.free(file_content);
    if (file_content.len == 0) {
        return try toolErrorJSON(allocator, "add_skill", resolved_name, "add_skill: could not build the skill content.");
    }

    const written = skills_store.upsertSkill(allocator, db, .{
        .workspace_id = workspace_id,
        .name = resolved_name,
        .description = resolved.description,
        .content = file_content,
    }) catch |err| switch (err) {
        error.WorkspaceIdNameRequired => return try toolErrorJSON(allocator, "add_skill", resolved_name, ADD_SKILL_BAD_NAME),
        error.NameTooLong => return try toolErrorJSON(allocator, "add_skill", resolved_name, ADD_SKILL_BAD_NAME),
        error.ContentTooLarge => return try toolErrorJSON(allocator, "add_skill", resolved_name, "add_skill: content exceeds the 2 MiB per-skill cap."),
        error.WriteFailed, error.RowNotFoundAfterWrite => return try toolErrorJSON(allocator, "add_skill", resolved_name, "add_skill: the skill could not be written (database error)."),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer skills_store.freeSkillRow(allocator, written);

    const clean_name = try helpers.sanitize_control_chars(allocator, resolved_name);
    defer allocator.free(clean_name);
    return try std.json.Stringify.valueAlloc(allocator, AddSkillJSON{
        .skill_name = clean_name,
        .name = clean_name,
        .created = !existed,
        .@"error" = null,
    }, .{});
}

/// Build skill content with YAML frontmatter.
pub fn buildSkillContent(allocator: std.mem.Allocator, input: AddSkillInput) []const u8 {
    // Escape quotes in description for YAML string
    const escaped_desc = addSkillEscapeYamlString(allocator, input.description);
    defer allocator.free(escaped_desc);

    // Build the content: frontmatter + separator + content
    const total_len = 15 + input.name.len + 16 + escaped_desc.len + 5 + input.content.len + 1;
    var result = std.ArrayList(u8).initCapacity(allocator, total_len) catch return "";
    errdefer result.deinit(allocator);

    result.appendSlice(allocator, "---\n") catch return "";
    result.appendSlice(allocator, "name: ") catch return "";
    result.appendSlice(allocator, input.name) catch return "";
    result.appendSlice(allocator, "\n") catch return "";
    result.appendSlice(allocator, "description: \"") catch return "";
    result.appendSlice(allocator, escaped_desc) catch return "";
    result.appendSlice(allocator, "\"\n") catch return "";
    result.appendSlice(allocator, "---\n") catch return "";
    result.appendSlice(allocator, input.content) catch return "";
    result.append(allocator, '\n') catch return "";

    return result.toOwnedSlice(allocator) catch return "";
}

/// Escape special characters in a YAML string value
/// Handles: double quotes, backslashes
fn addSkillEscapeYamlString(allocator: std.mem.Allocator, s: []const u8) []const u8 {
    var needs_escape = false;

    // Check if escaping is needed
    for (s) |c| {
        if (c == '"' or c == '\\') {
            needs_escape = true;
            break;
        }
    }

    if (!needs_escape) {
        return allocator.dupe(u8, s) catch return s;
    }

    // Build escaped string
    var result = std.ArrayList(u8).initCapacity(allocator, s.len + 16) catch return s;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '"' => result.appendSlice(allocator, "\\\"") catch return s,
            '\\' => result.appendSlice(allocator, "\\\\") catch return s,
            else => result.append(allocator, c) catch return s,
        }
    }

    return result.toOwnedSlice(allocator) catch return s;
}

// ─── edit_skill ───

/// Input for `edit_skill`. `skill_name` is defaulted so a call that
/// omits it parses and gets a message naming the field rather than
/// `error.MissingField`.
pub const EditSkillInput = struct {
    /// Skill identifier (required)
    skill_name: []const u8 = "",
    /// New description (optional - omit to keep existing). A `description:`
    /// line inside `content`'s frontmatter is used when this is null.
    description: ?[]const u8 = null,
    /// New skill content (optional - omit to keep existing). A leading
    /// `---` frontmatter block is stripped and its `description:` lifted.
    content: ?[]const u8 = null,
};

pub const edit_skill_tool_system_prompt =
    \\## Edit Skill Tool — Behavior
    \\Use `edit_skill` to update an existing skill's description or body.
    \\- Provide `skill_name` and new `description`/`content`. Use to fix or improve a skill after learning a better approach.
    \\
;

pub const edit_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "edit_skill",
        .description =
        \\Edit an existing skill — its `description`, its `content` body, or both. Omit a field to keep its current value; at least one must be supplied. `skill_name` is the exact name `search_skills` reported.
        \\
        \\- `content` is the BODY only (frontmatter is regenerated). Rewriting `description` is the highest-leverage edit: that one line decides whether the skill is ever loaded.
        \\
        \\- A skill with auto-improve turned off is LOCKED: this call is refused and its body is left untouched. Do not retry it — ask the human to make the edit, or to unlock the skill in the workspace's Skills settings.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "skill_name",
                    .type = "string",
                    .description = "The skill's name, exactly as `search_skills` reported it (e.g. 'my-workflow').",
                },
                .{
                    .name = "description",
                    .type = "string",
                    .description = "New one-sentence description: what the skill does AND when to use it. Omit to keep it.",
                },
                .{
                    .name = "content",
                    .type = "string",
                    .description = "New markdown BODY — `## When to Use` / `## Procedure` / `## Pitfalls`. No `---` frontmatter. Omit to keep the existing body.",
                },
            },
            .required = &.{"skill_name"},
        },
        .system_prompt = edit_skill_tool_system_prompt,
    },
};

/// Actionable `edit_skill` failures. Exposed for tests.
pub const EDIT_SKILL_MISSING_NAME =
    "edit_skill: `skill_name` is required. Send the exact skill name `search_skills` reported (e.g. \"my-workflow\"). Run `search_skills` if you are unsure the skill exists.";
pub const EDIT_SKILL_BAD_NAME =
    "edit_skill: `skill_name` must be a single name — letters, digits, dots, dashes, underscores; no slashes, spaces, or leading/trailing dot. It is the skill's primary key, not a path. Got: '";
pub const EDIT_SKILL_NOTHING_TO_CHANGE =
    "edit_skill: nothing to change — `description` and `content` were both omitted. Send a new `description` (the one line that decides whether this skill is ever found), a new `content` body, or both.";
/// The store's `NothingToChange`, worded for the model.
pub const EDIT_SKILL_NO_CHANGE_EFFECT =
    "edit_skill: nothing to change — the new `description` and `content` are identical to what is already stored. Send text that actually differs.";

pub const EDIT_SKILL_NOT_FOUND =
    "edit_skill: no skill named '";

/// JSON payload for `edit_skill` results. `skill_name`/`name` and
/// `updated`/`edited` are duplicated: the first of each pair matches the
/// tool schema, the second matches the legacy tag name.
pub const EditSkillJSON = struct {
    skill_name: []const u8,
    name: []const u8,
    updated: bool,
    edited: bool,
    @"error": ?[]const u8 = null,
};

/// Parsed shape of `executeEditSkillToString` output, for tests.
pub const EditSkillOutput = struct {
    skill_name: []const u8 = "",
    name: []const u8 = "",
    updated: bool = false,
    edited: bool = false,
    @"error": ?[]const u8 = null,
};

/// Execute `edit_skill`. Returns an inner JSON string the exec wrapper
/// embeds. Caller owns the returned memory and must free it.
pub fn executeEditSkillToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
    input: EditSkillInput,
) ![]const u8 {
    const name = std.mem.trim(u8, input.skill_name, " \t\n\r");
    if (name.len == 0) {
        return try toolErrorJSON(allocator, "edit_skill", "", EDIT_SKILL_MISSING_NAME);
    }
    if (!skills_store.isValidSkillName(name)) {
        const msg = try std.fmt.allocPrint(allocator, "{s}{s}'", .{ EDIT_SKILL_BAD_NAME, name });
        defer allocator.free(msg);
        return try toolErrorJSON(allocator, "edit_skill", name, msg);
    }

    // A `description:` carried in `content`'s frontmatter counts as a
    // supplied description, so the model is not told "nothing to change"
    // for sending one field in the place it was taught to.
    const split = splitLeadingFrontmatter(input.content orelse "");
    const fm: ?[]const u8 = if (split.frontmatter.len != 0) split.frontmatter else null;
    const lifted_description: ?[]const u8 = if (fm) |f| frontmatterField(f, "description") else null;

    if (input.description == null and input.content == null) {
        return try toolErrorJSON(allocator, "edit_skill", name, EDIT_SKILL_NOTHING_TO_CHANGE);
    }

    const workspace_id = (try resolveWorkspaceScope(allocator, db, caller_session_id)) orelse
        return try scopeErrorJSON(allocator, "edit_skill", caller_session_id);
    defer allocator.free(workspace_id);

    const existing = skills_store.getSkillByName(allocator, db, workspace_id, name) catch |err| switch (err) {
        error.NotFound => {
            const msg = try std.fmt.allocPrint(allocator, "{s}{s}' exists in this workspace. Run search_skills to list the installed names.", .{ EDIT_SKILL_NOT_FOUND, name });
            defer allocator.free(msg);
            return try toolErrorJSON(allocator, "edit_skill", name, msg);
        },
        error.QueryFailed => return try toolErrorJSON(allocator, "edit_skill", name, "Could not read this workspace's skills (database error)."),
        error.OutOfMemory => return error.OutOfMemory,
        error.WorkspaceIdNameRequired => return try toolErrorJSON(allocator, "edit_skill", name, EDIT_SKILL_BAD_NAME),
    };
    defer skills_store.freeSkillRow(allocator, existing);

    if (!existing.is_can_auto_improve) {
        return try lockedSkillJSON(allocator, "edit_skill", name);
    }

    const new_description = firstNonEmpty(&.{ input.description, lifted_description }) orelse existing.description;

    // Only a supplied body triggers a frontmatter rebuild.
    const patch: skills_store.UpdateSkillArgs = if (input.content) |_| blk: {
        const rebuilt = try buildEditSkillContent(allocator, name, new_description, split.body);
        break :blk .{ .description = new_description, .content = rebuilt };
    } else blk: {
        break :blk .{ .description = new_description };
    };
    defer if (patch.content) |c| allocator.free(c);

    const updated = skills_store.updateSkill(allocator, db, workspace_id, name, patch) catch |err| switch (err) {
        error.NotFound => {
            const msg = try std.fmt.allocPrint(allocator, "{s}{s}' exists in this workspace. Run search_skills to list the installed names.", .{ EDIT_SKILL_NOT_FOUND, name });
            defer allocator.free(msg);
            return try toolErrorJSON(allocator, "edit_skill", name, msg);
        },
        error.NothingToChange => return try toolErrorJSON(allocator, "edit_skill", name, EDIT_SKILL_NO_CHANGE_EFFECT),
        error.WorkspaceIdNameRequired => return try toolErrorJSON(allocator, "edit_skill", name, EDIT_SKILL_BAD_NAME),
        error.ContentTooLarge => return try toolErrorJSON(allocator, "edit_skill", name, "edit_skill: content exceeds the 2 MiB per-skill cap."),
        error.UpdateFailed => return try toolErrorJSON(allocator, "edit_skill", name, "edit_skill: the skill could not be written (database error)."),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer skills_store.freeSkillRow(allocator, updated);

    const clean_name = try helpers.sanitize_control_chars(allocator, name);
    defer allocator.free(clean_name);
    return try std.json.Stringify.valueAlloc(allocator, EditSkillJSON{
        .skill_name = clean_name,
        .name = clean_name,
        .updated = true,
        .edited = true,
        .@"error" = null,
    }, .{});
}

/// Build skill content with YAML frontmatter. Same generated block as
/// `buildSkillContent`; the `!`-returning spelling the write path uses.
fn buildEditSkillContent(allocator: std.mem.Allocator, name: []const u8, description: []const u8, content: []const u8) ![]const u8 {
    const escaped_desc = try editSkillEscapeYamlString(allocator, description);
    defer allocator.free(escaped_desc);

    const total_len = 15 + name.len + 16 + escaped_desc.len + 5 + content.len + 1;
    var result = try std.ArrayList(u8).initCapacity(allocator, total_len);
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "---\n");
    try result.appendSlice(allocator, "name: ");
    try result.appendSlice(allocator, name);
    try result.appendSlice(allocator, "\n");
    try result.appendSlice(allocator, "description: \"");
    try result.appendSlice(allocator, escaped_desc);
    try result.appendSlice(allocator, "\"\n");
    try result.appendSlice(allocator, "---\n");
    try result.appendSlice(allocator, content);
    try result.append(allocator, '\n');

    return result.toOwnedSlice(allocator);
}

/// Escape special characters in a YAML string value
/// Handles: double quotes, backslashes
fn editSkillEscapeYamlString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var needs_escape = false;
    for (s) |c| {
        if (c == '"' or c == '\\') {
            needs_escape = true;
            break;
        }
    }

    if (!needs_escape) {
        return allocator.dupe(u8, s);
    }

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            else => try result.append(allocator, c),
        }
    }

    return result.toOwnedSlice(allocator);
}

// ============================================================================
// skill_tools.zig — inline tests
// ============================================================================

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Real Migration 101 tables plus the three tables
/// `workspace_scope.resolveWorkspaceId` reads, so a test can hand the
/// tools a `caller_session_id` and get a real workspace back.
fn setupSkillsDb() !TestCtx {
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
    // Exact task link — the resolver's first and most precise hit.
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

fn parseJson(comptime T: type, alloc: std.mem.Allocator, raw: []const u8) !std.json.Parsed(T) {
    return try std.json.parseFromSlice(T, alloc, raw, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}

// ─── argument resolution (kept: these are the two live model mistakes) ───

test "splitLeadingFrontmatter - splits a fenced block, leaves everything else alone" {
    const with_fm = "---\nname: foo\ndescription: \"bar\"\n---\n## Body\n";
    const s = splitLeadingFrontmatter(with_fm);
    try testing.expectEqualStrings("name: foo\ndescription: \"bar\"\n", s.frontmatter);
    try testing.expectEqualStrings("## Body\n", s.body);

    // No fence at the head → the whole input is the body.
    const bare = splitLeadingFrontmatter("## Body\n\n---\nnot a fence\n");
    try testing.expectEqualStrings("", bare.frontmatter);
    try testing.expectEqualStrings("## Body\n\n---\nnot a fence\n", bare.body);

    // Unterminated fence → not treated as frontmatter (never a guess).
    const open = splitLeadingFrontmatter("---\nname: foo\n");
    try testing.expectEqualStrings("", open.frontmatter);

    // Closing fence at EOF (no trailing newline) still splits.
    const eof = splitLeadingFrontmatter("---\nname: foo\n---");
    try testing.expectEqualStrings("name: foo\n", eof.frontmatter);
    try testing.expectEqualStrings("", eof.body);

    // `---x` is not a fence.
    const notfence = splitLeadingFrontmatter("---\nname: foo\n---x\nbody");
    try testing.expectEqualStrings("", notfence.frontmatter);
}

test "frontmatterField - reads values, strips quotes, rejects near-misses" {
    const fm = "name: foo-bar\ndescription: \"Use when X.\"\nnames: wrong-key\nempty:\n";
    try testing.expectEqualStrings("foo-bar", frontmatterField(fm, "name").?);
    try testing.expectEqualStrings("Use when X.", frontmatterField(fm, "description").?);
    // `name` must not match the `names:` line.
    try testing.expectEqualStrings("right", frontmatterField("names: wrong-key\nname: right\n", "name").?);
    // An empty value is no value.
    try testing.expect(frontmatterField("empty:\n", "empty") == null);
    try testing.expect(frontmatterField("name: foo\n", "description") == null);
}

// ─── add_skill ───

test "add_skill writes a row into the CALLER's workspace and reads back through use_skill" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const added = try executeAddSkillToString(alloc, &ctx.db, "s1", .{
        .name = "round-trip",
        .description = "The one sentence search returns.",
        .content = "## When to Use\n\nFirst body.\n",
    });
    defer alloc.free(added);

    var added_out = try parseJson(AddSkillOutput, alloc, added);
    defer added_out.deinit();
    try testing.expect(added_out.value.created);
    try testing.expectEqualStrings("round-trip", added_out.value.skill_name);
    try testing.expect(added_out.value.@"error" == null);

    const used = try execute_use_skill_to_string(alloc, testing.io, &ctx.db, "s1", .{ .name = "round-trip" });
    defer alloc.free(used);
    var used_out = try parseJson(UseSkillOutput, alloc, used);
    defer used_out.deinit();

    try testing.expect(used_out.value.loaded);
    try testing.expectEqualStrings("round-trip", used_out.value.skill_name);
    try testing.expect(std.mem.indexOf(u8, used_out.value.content, "First body.") != null);
    // A single-file skill has NO directory — an empty one would read as
    // "a bundle with nothing in it".
    try testing.expect(used_out.value.asset_dir == null);
    try testing.expectEqual(@as(usize, 0), used_out.value.asset_count);
}

test "add_skill - re-running the same name REPLACES, and reports created: false" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const first = try executeAddSkillToString(alloc, &ctx.db, "s1", .{
        .name = "refined",
        .description = "First version description",
        .content = "# First version\n\nA long original body that must not survive the overwrite.",
    });
    defer alloc.free(first);
    var first_out = try parseJson(AddSkillOutput, alloc, first);
    defer first_out.deinit();
    try testing.expect(first_out.value.created);

    const second = try executeAddSkillToString(alloc, &ctx.db, "s1", .{
        .name = "refined",
        .description = "Second desc",
        .content = "v2",
    });
    defer alloc.free(second);
    var second_out = try parseJson(AddSkillOutput, alloc, second);
    defer second_out.deinit();

    // A replacement is not a creation, and reporting it as one is a lie
    // about what happened to the previous body.
    try testing.expect(!second_out.value.created);

    const row = try skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "refined");
    defer skills_store.freeSkillRow(alloc, row);
    try testing.expectEqualStrings("Second desc", row.description);
    try testing.expect(std.mem.indexOf(u8, row.content, "v2") != null);
    // No append-mode leftovers: one row, old bytes gone.
    try testing.expect(std.mem.indexOf(u8, row.content, "First version description") == null);
    try testing.expect(std.mem.indexOf(u8, row.content, "should not survive") == null);
}

test "add_skill - content carrying frontmatter does NOT double the block" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Exactly the shape a model produces when it pastes the skill format:
    // frontmatter inside `content`, and NO `description` argument.
    const out = try executeAddSkillToString(alloc, &ctx.db, "s1", .{
        .name = "fm-lifted",
        .description = "",
        .content = "---\nname: fm-lifted\ndescription: \"Lifted from content.\"\n---\n## When to Use\n\nAlways.\n",
    });
    defer alloc.free(out);
    var parsed = try parseJson(AddSkillOutput, alloc, out);
    defer parsed.deinit();
    try testing.expect(parsed.value.created);

    const row = try skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "fm-lifted");
    defer skills_store.freeSkillRow(alloc, row);

    // Exactly TWO fences (the generated block's open + close). Four is the
    // bug that shipped.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, row.content, "---\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, row.content, "name: fm-lifted"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, row.content, "Lifted from content."));
    try testing.expectEqualStrings("Lifted from content.", row.description);
    try testing.expect(std.mem.indexOf(u8, row.content, "## When to Use") != null);
}

test "add_skill - an empty description round-trips as \"\" (the COALESCE(NULLIF) trap)" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seeded with no description at all: `SqliteBackend.exec` binds a
    // zero-length slice as SQL NULL, which used to violate NOT NULL and
    // surface as a failed write.
    try seedSkill(alloc, &ctx.db, "ws_1", "no-desc", "", "## Body\n");

    const used = try execute_use_skill_to_string(alloc, testing.io, &ctx.db, "s1", .{ .name = "no-desc" });
    defer alloc.free(used);
    var parsed = try parseJson(UseSkillOutput, alloc, used);
    defer parsed.deinit();
    try testing.expect(parsed.value.loaded);
    try testing.expect(std.mem.indexOf(u8, parsed.value.content, "## Body") != null);
}

test "add_skill - missing arguments each name the field and what to send" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const no_name = try executeAddSkillToString(alloc, &ctx.db, "s1", .{
        .name = "",
        .description = "Test description",
        .content = "Test content",
    });
    defer alloc.free(no_name);
    var a = try parseJson(AddSkillOutput, alloc, no_name);
    defer a.deinit();
    try testing.expect(!a.value.created);
    try testing.expectEqualStrings(ADD_SKILL_MISSING_NAME, a.value.@"error" orelse "");

    const no_desc = try executeAddSkillToString(alloc, &ctx.db, "s1", .{
        .name = "test-skill",
        .description = "",
        .content = "Test content",
    });
    defer alloc.free(no_desc);
    var b = try parseJson(AddSkillOutput, alloc, no_desc);
    defer b.deinit();
    try testing.expectEqualStrings(ADD_SKILL_MISSING_DESCRIPTION, b.value.@"error" orelse "");

    const no_content = try executeAddSkillToString(alloc, &ctx.db, "s1", .{
        .name = "test-skill",
        .description = "Test description",
        .content = "",
    });
    defer alloc.free(no_content);
    var c = try parseJson(AddSkillOutput, alloc, no_content);
    defer c.deinit();
    try testing.expectEqualStrings(ADD_SKILL_MISSING_CONTENT, c.value.@"error" orelse "");
}

test "add_skill - a path-like name is refused with a message naming the rule" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try executeAddSkillToString(alloc, &ctx.db, "s1", .{
        .name = "../escaped",
        .description = "d",
        .content = "## Body\n",
    });
    defer alloc.free(out);
    var parsed = try parseJson(AddSkillOutput, alloc, out);
    defer parsed.deinit();
    try testing.expect(!parsed.value.created);
    const err = parsed.value.@"error" orelse "";
    try testing.expect(std.mem.startsWith(u8, err, ADD_SKILL_BAD_NAME));
    try testing.expect(std.mem.indexOf(u8, err, "../escaped") != null);

    // And nothing was written under any name.
    const rows = try skills_store.listSkills(alloc, &ctx.db, "ws_1");
    defer skills_store.freeSkillRows(alloc, rows);
    try testing.expectEqual(@as(usize, 0), rows.len);
}

test "add_skill - buildSkillContent generates the block unchanged" {
    const alloc = testing.allocator;
    const content = buildSkillContent(alloc, .{
        .name = "test-skill",
        .description = "Test \"description\" with quotes and\\backslash",
        .content = "Test content",
    });
    defer alloc.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "name: test-skill") != null);
    try testing.expect(std.mem.indexOf(u8, content, "description: \"Test \\\"description\\\" with quotes and\\\\backslash\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\\\\") != null);
}

// ─── use_skill ───

test "use_skill - a bundle returns content plus a materialised asset_dir" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSkill(alloc, &ctx.db, "ws_1", "pdf", "Work with PDFs", "Run scripts/convert.py first.\n");
    try skills_store.replaceAssets(alloc, &ctx.db, "ws_1", "pdf", &.{
        .{ .rel_path = "scripts/convert.py", .content = "print('hi')" },
        .{ .rel_path = "references/notes.md", .content = "# notes" },
    });

    const out = try execute_use_skill_to_string(alloc, testing.io, &ctx.db, "s1", .{ .name = "pdf" });
    defer alloc.free(out);
    var parsed = try parseJson(UseSkillOutput, alloc, out);
    defer parsed.deinit();

    try testing.expect(parsed.value.loaded);
    try testing.expectEqual(@as(usize, 2), parsed.value.asset_count);
    const dir = parsed.value.asset_dir orelse return error.NoAssetDir;
    try testing.expect(std.fs.path.isAbsolute(dir));
    defer std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};

    // The body's relative reference resolves against the returned dir.
    const script = try std.fs.path.join(alloc, &.{ dir, "scripts", "convert.py" });
    defer alloc.free(script);
    const body = try std.Io.Dir.cwd().readFileAlloc(testing.io, script, alloc, std.Io.Limit.limited(1024));
    defer alloc.free(body);
    try testing.expectEqualStrings("print('hi')", body);
}

test "use_skill - not found is loaded:false and lists what DOES exist" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSkill(alloc, &ctx.db, "ws_1", "alpha", "first", "a");
    try seedSkill(alloc, &ctx.db, "ws_1", "beta", "second", "b");

    const out = try execute_use_skill_to_string(alloc, testing.io, &ctx.db, "s1", .{ .name = "gamma" });
    defer alloc.free(out);
    var parsed = try parseJson(UseSkillOutput, alloc, out);
    defer parsed.deinit();

    try testing.expect(!parsed.value.loaded);
    try testing.expect(parsed.value.@"error" != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value.@"error".?, "gamma") != null);
    const available = parsed.value.available_skills orelse return error.NoAvailableList;
    try testing.expectEqual(@as(usize, 2), available.len);
    try testing.expectEqualStrings("alpha", available[0]);
    try testing.expectEqualStrings("beta", available[1]);
}

test "use_skill - an empty name is a named refusal, not a not-found" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try execute_use_skill_to_string(alloc, testing.io, &ctx.db, "s1", .{});
    defer alloc.free(out);
    var parsed = try parseJson(UseSkillOutput, alloc, out);
    defer parsed.deinit();
    try testing.expect(!parsed.value.loaded);
    try testing.expectEqualStrings(USE_SKILL_MISSING_NAME, parsed.value.@"error" orelse "");
}

// ─── edit_skill ───

test "edit_skill - a content-only edit KEEPS the description (it used to be wiped)" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSkill(alloc, &ctx.db, "ws_1", "keep-desc", "The sentence search_skills will return.", "---\nname: keep-desc\ndescription: \"The sentence search_skills will return.\"\n---\n## When to Use\n\nFirst body.\n");

    // `description` omitted — the tool must read the existing one off the row.
    const out = try executeEditSkillToString(alloc, &ctx.db, "s1", .{
        .skill_name = "keep-desc",
        .content = "## When to Use\n\nSecond body.\n",
    });
    defer alloc.free(out);
    var parsed = try parseJson(EditSkillOutput, alloc, out);
    defer parsed.deinit();
    try testing.expect(parsed.value.updated);

    const row = try skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "keep-desc");
    defer skills_store.freeSkillRow(alloc, row);
    try testing.expectEqualStrings("The sentence search_skills will return.", row.description);
    try testing.expect(std.mem.indexOf(u8, row.content, "Second body.") != null);
    try testing.expect(std.mem.indexOf(u8, row.content, "First body.") == null);
    // The empty frontmatter this used to write.
    try testing.expect(std.mem.indexOf(u8, row.content, "description: \"\"") == null);
    // And no doubled block from rebuilding on top of the stored frontmatter.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, row.content, "---\n"));
}

test "edit_skill - frontmatter in content lifts the description and is not re-duplicated" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSkill(alloc, &ctx.db, "ws_1", "edit-fm", "Original description.", "## When to Use\n\nOriginal body.\n");

    // The model rewrites the body and, out of habit, re-pastes frontmatter
    // with the new description in it.
    const out = try executeEditSkillToString(alloc, &ctx.db, "s1", .{
        .skill_name = "edit-fm",
        .content = "---\ndescription: \"Rewritten description.\"\n---\n## When to Use\n\nNew body.\n",
    });
    defer alloc.free(out);
    var parsed = try parseJson(EditSkillOutput, alloc, out);
    defer parsed.deinit();
    try testing.expect(parsed.value.updated);

    const row = try skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "edit-fm");
    defer skills_store.freeSkillRow(alloc, row);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, row.content, "---\n"));
    try testing.expect(std.mem.indexOf(u8, row.content, "Rewritten description.") != null);
    try testing.expect(std.mem.indexOf(u8, row.content, "Original description.") == null);
    try testing.expect(std.mem.indexOf(u8, row.content, "New body.") != null);
    try testing.expect(std.mem.indexOf(u8, row.content, "Original body.") == null);
}

test "edit_skill - an ineffective patch is a TOOL ERROR, never a success with an empty diff" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seeded with EXACTLY what `buildSkillContent` produces, because that is
    // what the tool stores: seeding a bare body would make the patch below a
    // real change (the regenerated frontmatter) and the test would be
    try seedSkill(alloc, &ctx.db, "ws_1", "same", "same description", "---\nname: same\ndescription: \"same description\"\n---\nsame body\n");

    // Byte-identical to what is stored. Reporting `updated: true` teaches
    // the model that an empty edit rewrites a skill.
    const out = try executeEditSkillToString(alloc, &ctx.db, "s1", .{
        .skill_name = "same",
        .description = "same description",
        .content = "same body",
    });
    defer alloc.free(out);
    var parsed = try parseJson(EditSkillOutput, alloc, out);
    defer parsed.deinit();
    try testing.expect(!parsed.value.updated);
    try testing.expect(!parsed.value.edited);
    try testing.expectEqualStrings(EDIT_SKILL_NO_CHANGE_EFFECT, parsed.value.@"error" orelse "");
}

test "edit_skill - omitting both fields is refused by name" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try executeEditSkillToString(alloc, &ctx.db, "s1", .{ .skill_name = "whatever" });
    defer alloc.free(out);
    var parsed = try parseJson(EditSkillOutput, alloc, out);
    defer parsed.deinit();
    try testing.expect(!parsed.value.updated);
    try testing.expectEqualStrings(EDIT_SKILL_NOTHING_TO_CHANGE, parsed.value.@"error" orelse "");
}

test "edit_skill - a missing skill says so instead of blaming a tier" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try executeEditSkillToString(alloc, &ctx.db, "s1", .{
        .skill_name = "never-existed",
        .description = "new",
    });
    defer alloc.free(out);
    var parsed = try parseJson(EditSkillOutput, alloc, out);
    defer parsed.deinit();
    try testing.expect(!parsed.value.updated);
    const err = parsed.value.@"error" orelse "";
    try testing.expect(std.mem.indexOf(u8, err, "never-existed") != null);
    // There is no tier to name any more, so the old wording must be gone.
    try testing.expect(std.mem.indexOf(u8, err, "tier") == null);
    try testing.expect(std.mem.indexOf(u8, err, "is_global") == null);
}

// ─── remove_skill ───

test "remove_skill deletes the row AND its companion rows" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSkill(alloc, &ctx.db, "ws_1", "doomed", "obsolete", "body");
    try skills_store.replaceAssets(alloc, &ctx.db, "ws_1", "doomed", &.{
        .{ .rel_path = "scripts/convert.py", .content = "print('hi')" },
    });

    const out = try execute_remove_skill_to_string(alloc, &ctx.db, "s1", .{ .skill_name = "doomed" });
    defer alloc.free(out);
    var parsed = try parseJson(RemoveSkillOutput, alloc, out);
    defer parsed.deinit();
    try testing.expect(parsed.value.removed);
    try testing.expectEqualStrings("doomed", parsed.value.skill_name);

    try testing.expectError(error.NotFound, skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "doomed"));
    const assets = try skills_store.listAssets(alloc, &ctx.db, "ws_1", "doomed");
    defer skills_store.freeSkillAssetRows(alloc, assets);
    try testing.expectEqual(@as(usize, 0), assets.len);
}

test "remove_skill - an empty or path-like name is refused with a message naming the rule" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const empty = try execute_remove_skill_to_string(alloc, &ctx.db, "s1", .{ .skill_name = "" });
    defer alloc.free(empty);
    var a = try parseJson(RemoveSkillOutput, alloc, empty);
    defer a.deinit();
    try testing.expect(!a.value.removed);
    try testing.expect(std.mem.indexOf(u8, a.value.@"error" orelse "", "cannot be empty") != null);

    const traversal = try execute_remove_skill_to_string(alloc, &ctx.db, "s1", .{ .skill_name = "../../etc" });
    defer alloc.free(traversal);
    var b = try parseJson(RemoveSkillOutput, alloc, traversal);
    defer b.deinit();
    try testing.expect(!b.value.removed);
    try testing.expect(std.mem.startsWith(u8, b.value.@"error" orelse "", REMOVE_SKILL_BAD_NAME));
}

test "remove_skill - removing a name that exists in ANOTHER workspace deletes nothing" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSkill(alloc, &ctx.db, "ws_1", "private", "ws_1's copy", "TOPSECRET");

    const out = try execute_remove_skill_to_string(alloc, &ctx.db, "s2", .{ .skill_name = "private" });
    defer alloc.free(out);
    var parsed = try parseJson(RemoveSkillOutput, alloc, out);
    defer parsed.deinit();
    try testing.expect(!parsed.value.removed);

    const survivor = try skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "private");
    defer skills_store.freeSkillRow(alloc, survivor);
    try testing.expectEqualStrings("TOPSECRET", survivor.content);
}

// ─── workspace scope ───

test "the workspace comes from the SESSION, in both directions" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Same name, two workspaces: two rows. This is what replaced the
    // global/local tier — "shared" is now two rows, not a flag.
    try seedSkill(alloc, &ctx.db, "ws_1", "pdf", "A's copy", "A's body");
    try seedSkill(alloc, &ctx.db, "ws_2", "pdf", "B's copy", "B's body");

    const in_a = try execute_use_skill_to_string(alloc, testing.io, &ctx.db, "s1", .{ .name = "pdf" });
    defer alloc.free(in_a);
    var a = try parseJson(UseSkillOutput, alloc, in_a);
    defer a.deinit();
    try testing.expect(std.mem.indexOf(u8, a.value.content, "A's body") != null);

    const in_b = try execute_use_skill_to_string(alloc, testing.io, &ctx.db, "s2", .{ .name = "pdf" });
    defer alloc.free(in_b);
    var b = try parseJson(UseSkillOutput, alloc, in_b);
    defer b.deinit();
    try testing.expect(std.mem.indexOf(u8, b.value.content, "B's body") != null);
    try testing.expect(std.mem.indexOf(u8, in_b, "TOPSECRET") == null);
}

test "an unresolvable session is a refusal, and the TWO refusals differ" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSkill(alloc, &ctx.db, "ws_1", "alpha", "first", "a");

    // No session at all.
    const no_session = try execute_use_skill_to_string(alloc, testing.io, &ctx.db, "", .{ .name = "alpha" });
    defer alloc.free(no_session);
    var a = try parseJson(UseSkillOutput, alloc, no_session);
    defer a.deinit();
    try testing.expect(!a.value.loaded);
    try testing.expectEqualStrings(SCOPE_MISSING_SESSION, a.value.@"error" orelse "");

    // A session that is not linked to any workspace. Same shape, DIFFERENT
    // message — the two need different user actions.
    const orphan = try execute_use_skill_to_string(alloc, testing.io, &ctx.db, "s_orphan", .{ .name = "alpha" });
    defer alloc.free(orphan);
    var b = try parseJson(UseSkillOutput, alloc, orphan);
    defer b.deinit();
    try testing.expect(!b.value.loaded);
    try testing.expectEqualStrings(SCOPE_NO_WORKSPACE, b.value.@"error" orelse "");
    try testing.expect(!std.mem.eql(u8, a.value.@"error" orelse "", b.value.@"error" orelse ""));

    // "No skills" and "no workspace" are different facts; a silent empty
    // answer would read as "your skills are gone". The same resolver
    // answers for every tool, not just the read one.
    const removed = try execute_remove_skill_to_string(alloc, &ctx.db, "s_orphan", .{ .skill_name = "alpha" });
    defer alloc.free(removed);
    var c = try parseJson(RemoveSkillOutput, alloc, removed);
    defer c.deinit();
    try testing.expect(!c.value.removed);
    try testing.expectEqualStrings(SCOPE_NO_WORKSPACE, c.value.@"error" orelse "");
}

test "every skill tool refuses an unresolvable workspace with the same message" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // One resolver, one pair of messages: `add_skill` reporting "could not
    // build skills directory path" while `remove_skill` reported "Environment
    // not available" is how two tools started disagreeing about whether the
    const added = try executeAddSkillToString(alloc, &ctx.db, "s_orphan", .{
        .name = "x",
        .description = "d",
        .content = "## Body\n",
    });
    defer alloc.free(added);
    var a = try parseJson(AddSkillOutput, alloc, added);
    defer a.deinit();
    try testing.expect(!a.value.created);
    try testing.expectEqualStrings(SCOPE_NO_WORKSPACE, a.value.@"error" orelse "");

    const edited = try executeEditSkillToString(alloc, &ctx.db, "s_orphan", .{
        .skill_name = "x",
        .description = "new",
    });
    defer alloc.free(edited);
    var b = try parseJson(EditSkillOutput, alloc, edited);
    defer b.deinit();
    try testing.expect(!b.value.updated);
    try testing.expectEqualStrings(SCOPE_NO_WORKSPACE, b.value.@"error" orelse "");
}

// ─── schema contracts ─── Asserted against the LIVE `AgentTool` constants
// the model receives and the LIVE struct types the exec wrappers parse, not
// against this file's text.

/// Every field that described a DIRECTORY TIER, plus the two that only
/// ever named one. A skill is a row; none of these has anything to say
/// about a row.
const directory_shaped_fields = [_][]const u8{
    "path",
    "scope",
    "is_global",
    "cwd",
    "session_id",
    "create_with_dir",
};

/// The five tool schemas — the exact constants `tools_equipped` hands the LLM.
const skill_tool_schemas = [_]AgentTool{
    search_skills_tool,
    use_skill_tool,
    add_skill_tool,
    edit_skill_tool,
    remove_skill_tool,
};

test "schema contract: no skill tool schema or payload carries a directory-shaped field" {
    for (skill_tool_schemas) |tool| {
        for (tool.function.parameters.properties) |prop| {
            for (directory_shaped_fields) |f| {
                if (std.mem.eql(u8, prop.name, f)) {
                    std.debug.print("!! {s} still declares the `{s}` property\n", .{ tool.function.name, f });
                    return error.DirectoryShapedFieldSurvived;
                }
            }
        }
        for (tool.function.parameters.required) |req| {
            for (directory_shaped_fields) |f| {
                if (std.mem.eql(u8, req, f)) {
                    std.debug.print("!! {s} still requires the `{s}` property\n", .{ tool.function.name, f });
                    return error.DirectoryShapedFieldSurvived;
                }
            }
        }
    }

    // The payload structs the exec wrapper deserialises are the other half of
    // the wire: a field there is a slot for `ignore_unknown_fields` to fill.
    inline for (.{
        SearchSkillsInput,
        UseSkillInput,
        AddSkillInput,
        EditSkillInput,
        RemoveSkillInput,
        UseSkillJSON,
        RemoveSkillJSON,
        AddSkillJSON,
        EditSkillJSON,
    }) |T| {
        // `fields` values hold a `type`, so they must be indexed at comptime
        // — hence inline for, not a runtime loop.
        inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
            _ = i;
            for (directory_shaped_fields) |f| {
                if (std.mem.eql(u8, field.name, f)) {
                    std.debug.print("!! {s} still has a `{s}` field\n", .{ @typeName(T), f });
                    return error.DirectoryShapedFieldSurvived;
                }
            }
        }
    }
}

test "schema contract: no skill input accepts a workspace_id" {
    // A model-supplied workspace id would be a spoofing vector — the LLM
    // would be choosing which isolation boundary it writes inside.
    for (skill_tool_schemas) |tool| {
        for (tool.function.parameters.properties) |prop| {
            if (std.mem.eql(u8, prop.name, "workspace_id")) {
                std.debug.print("!! {s} accepts a workspace_id\n", .{tool.function.name});
                return error.WorkspaceIdInSchema;
            }
        }
        for (tool.function.parameters.required) |req| {
            if (std.mem.eql(u8, req, "workspace_id")) {
                std.debug.print("!! {s} requires a workspace_id\n", .{tool.function.name});
                return error.WorkspaceIdInSchema;
            }
        }
    }

    inline for (.{
        SearchSkillsInput,
        UseSkillInput,
        AddSkillInput,
        EditSkillInput,
        RemoveSkillInput,
    }) |T| {
        inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
            _ = i;
            if (std.mem.eql(u8, field.name, "workspace_id")) {
                std.debug.print("!! {s} accepts a workspace_id\n", .{@typeName(T)});
                return error.WorkspaceIdInSchema;
            }
        }
    }
}

test "schema contract: use_skill is keyed by name, not by path" {
    // The name IS the handle.
    inline for (@typeInfo(UseSkillInput).@"struct".fields, 0..) |field, i| {
        _ = i;
        if (std.mem.eql(u8, field.name, "path")) {
            std.debug.print("!! UseSkillInput is keyed by path again\n", .{});
            return error.SkillKeyedByPath;
        }
    }
    var has_name = false;
    inline for (@typeInfo(UseSkillInput).@"struct".fields, 0..) |field, i| {
        _ = i;
        if (std.mem.eql(u8, field.name, "name")) has_name = true;
    }
    try testing.expect(has_name);
}

// ─── the auto-improve lock ───

fn seedLockedSkill(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
    name: []const u8,
    content: []const u8,
) !void {
    const row = try skills_store.upsertSkill(alloc, db, .{
        .workspace_id = workspace_id,
        .name = name,
        .description = "pinned by the human",
        .content = content,
        .is_can_auto_improve = false,
    });
    skills_store.freeSkillRow(alloc, row);
}

test "edit_skill refuses a skill whose auto-improve flag is off and writes nothing" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedLockedSkill(alloc, &ctx.db, "ws_1", "pinned", "TOPSECRETBODY");

    const out = try executeEditSkillToString(alloc, &ctx.db, "s1", .{
        .skill_name = "pinned",
        .content = "hijacked",
    });
    defer alloc.free(out);
    var parsed = try parseJson(EditSkillOutput, alloc, out);
    defer parsed.deinit();

    try testing.expect(!parsed.value.updated);
    try testing.expect(!parsed.value.edited);
    try testing.expect(std.mem.indexOf(u8, parsed.value.@"error" orelse "", "locked") != null);

    const row = try skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "pinned");
    defer skills_store.freeSkillRow(alloc, row);
    try testing.expectEqualStrings("TOPSECRETBODY", row.content);
    try testing.expect(!row.is_can_auto_improve);
}

test "add_skill refuses to replace a locked skill but still creates a new name" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedLockedSkill(alloc, &ctx.db, "ws_1", "pinned", "ORIGINAL");

    // `upsertSkill` is create-or-replace, so a re-add of a pinned name would
    // otherwise walk straight past the lock.
    const replaced = try executeAddSkillToString(alloc, &ctx.db, "s1", .{
        .name = "pinned",
        .description = "a new description",
        .content = "## When to Use\n\nHijacked.\n",
    });
    defer alloc.free(replaced);
    var a = try parseJson(AddSkillOutput, alloc, replaced);
    defer a.deinit();
    try testing.expect(!a.value.created);
    try testing.expect(std.mem.indexOf(u8, a.value.@"error" orelse "", "locked") != null);

    const survivor = try skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "pinned");
    defer skills_store.freeSkillRow(alloc, survivor);
    try testing.expectEqualStrings("ORIGINAL", survivor.content);
    try testing.expectEqualStrings("pinned by the human", survivor.description);

    // A name that does not exist yet is not locked by anything: the agent
    // can still grow the library, and what it writes is auto-improvable.
    const fresh = try executeAddSkillToString(alloc, &ctx.db, "s1", .{
        .name = "brand-new",
        .description = "written by the agent",
        .content = "## When to Use\n\nAlways.\n",
    });
    defer alloc.free(fresh);
    var b = try parseJson(AddSkillOutput, alloc, fresh);
    defer b.deinit();
    try testing.expect(b.value.created);

    const created = try skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "brand-new");
    defer skills_store.freeSkillRow(alloc, created);
    try testing.expect(created.is_can_auto_improve);
}

test "remove_skill refuses a locked skill and leaves the row in place" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedLockedSkill(alloc, &ctx.db, "ws_1", "pinned", "KEEPME");

    // Deleting is a write too, and the most destructive one — otherwise
    // "remove then re-add" is how the lock gets bypassed.
    const out = try execute_remove_skill_to_string(alloc, &ctx.db, "s1", .{ .skill_name = "pinned" });
    defer alloc.free(out);
    var parsed = try parseJson(RemoveSkillOutput, alloc, out);
    defer parsed.deinit();
    try testing.expect(!parsed.value.removed);
    try testing.expect(std.mem.indexOf(u8, parsed.value.@"error" orelse "", "locked") != null);

    const survivor = try skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "pinned");
    defer skills_store.freeSkillRow(alloc, survivor);
    try testing.expectEqualStrings("KEEPME", survivor.content);
}

test "an unlocked skill still edits, and the edit keeps it unlocked" {
    const alloc = testing.allocator;
    var ctx = try setupSkillsDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSkill(alloc, &ctx.db, "ws_1", "open", "a description", "first body");

    const out = try executeEditSkillToString(alloc, &ctx.db, "s1", .{
        .skill_name = "open",
        .content = "second body",
    });
    defer alloc.free(out);
    var parsed = try parseJson(EditSkillOutput, alloc, out);
    defer parsed.deinit();

    try testing.expect(parsed.value.updated);
    const row = try skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "open");
    defer skills_store.freeSkillRow(alloc, row);
    try testing.expect(std.mem.indexOf(u8, row.content, "second body") != null);
    try testing.expect(row.is_can_auto_improve);
}

// Exec adapter — merged from `skill_tools.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const skills_search = @import("../../../agentic_loop/skills_search.zig");
const exec_testing = std.testing;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const SkillSaveInfo = tools.SkillSaveInfo;
const agent = exec_pabrikcore.agent;
const exec_skills_store = exec_pabrikcore.skills_store;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
/// Probe an inner JSON payload for a top-level `"error"` key. The returned
/// slice borrows from `parsed` — keep it alive through the `wrapToolOutput`
/// call, then `deinit`.
const InnerErrorProbe = struct {
    @"error": ?[]const u8 = null,
};

/// Turn a JSON parse failure into a message the model can act on. The old
/// form was `"add_skill failed: MissingField"` — an error NAME.
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
        SearchSkillsInput,
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

    // ── Paging bounds ── Rejected, never silently clamped: the model pages
    // by offset from the `total` it was shown, so a quiet clamp would make
    // its next call land on the wrong window.
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
    // ── Workspace scope ── Fail-closed, exactly as `document.zig` does it:
    // an unresolvable session is a readable refusal, NOT an empty result set.
    // "this workspace has no matching skills" and "you have no workspace" are
    const workspace_id = (resolveWorkspaceScope(ctx.allocator, ctx.db, ctx.session_id) catch null) orelse {
        const msg = try scopeErrorJSON(ctx.allocator, "search_skills", ctx.session_id);
        defer ctx.allocator.free(msg);
        const output = try wrapToolOutput(ctx.allocator, "search_skills", tc.function.arguments, false, msg, "");
        return .{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(workspace_id);

    const rows = exec_skills_store.listSkills(ctx.allocator, ctx.db, workspace_id) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "search_skills", tc.function.arguments, false, err_msg, "");
        return .{ .output = output, .output_allocated = true };
    };
    defer exec_skills_store.freeSkillRows(ctx.allocator, rows);

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
        UseSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const inner = execute_use_skill_to_string(
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
    // auto-save.
    if (std.json.parseFromSlice(UseSkillOutput, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed_inner| {
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
    // `ignore_unknown_fields`, same reason as execAddSkill: a stray key must
    // not cost the call.
    const parsed = std.json.parseFromSlice(
        RemoveSkillInput,
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

    const inner = execute_remove_skill_to_string(
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
    if (std.json.parseFromSlice(RemoveSkillOutput, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed_inner| {
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
    // `ignore_unknown_fields` — the sibling `execSearchSkills` has always had
    // it, and without it a model that volunteers one extra key (`is_global`,
    // `scope`, `session_id`, …) gets `UnknownField` and the write is lost.
    const parsed = std.json.parseFromSlice(
        AddSkillInput,
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

    const inner = executeAddSkillToString(
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

    if (std.json.parseFromSlice(AddSkillOutput, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed_inner| {
        defer parsed_inner.deinit();
        if (parsed_inner.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    } else |_| {}

    const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, true, null, inner);

    // The registry entry has auto_save_skill = true → the dispatcher in
    // handle_tool.zig reads the wrapped JSON `data` (`skill_name`/`content`
    // keys), then saves to session_skills.
    _ = SkillSaveInfo;
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── edit_skill ───

pub fn execEditSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // `ignore_unknown_fields`, same reason as execAddSkill.
    const parsed = std.json.parseFromSlice(
        EditSkillInput,
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

    const inner = executeEditSkillToString(
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

    // If the inner JSON carries an `error`, treat as failure.
    if (std.json.parseFromSlice(EditSkillOutput, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed_inner| {
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
// skill_tools.zig — inline tests
// ============================================================================

const exec_sqlite = exec_pabrikcore.sqlite;
const exec_migration = @import("../../../migrations/migration.zig");

const exec_TestCtx = struct {
    db: exec_sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !exec_TestCtx {
    const alloc = exec_testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: exec_sqlite.SqliteBackend = .{};
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
    try exec_migration.Migration102CreateSkills.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

fn makeTestCtx(alloc: std.mem.Allocator, db: *exec_sqlite.SqliteBackend, session_id: []const u8) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = alloc,
        .io = exec_testing.io,
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

/// Flattened, OWNED view of a tool envelope. See `document.zig`
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

    var local_skills = std.ArrayList(RenderedSkill).empty;
    errdefer {
        for (local_skills.items) |s| {
            allocator.free(s.name);
            allocator.free(s.description);
        }
        local_skills.deinit(allocator);
    }
    for (data.skills) |s| {
        try local_skills.append(allocator, .{
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
        .skills = try local_skills.toOwnedSlice(allocator),
    };
}

fn exec_seedSkill(
    alloc: std.mem.Allocator,
    db: *exec_sqlite.SqliteBackend,
    workspace_id: []const u8,
    name: []const u8,
    description: []const u8,
    content: []const u8,
) !void {
    const row = try exec_skills_store.upsertSkill(alloc, db, .{
        .workspace_id = workspace_id,
        .name = name,
        .description = description,
        .content = content,
    });
    exec_skills_store.freeSkillRow(alloc, row);
}

test "execAddSkill writes into the SESSION's workspace, and the envelope says created" {
    const alloc = exec_testing.allocator;
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

    try exec_testing.expectEqualStrings("add_skill", env.tool);
    try exec_testing.expect(env.success);
    try exec_testing.expect(env.err == null);
    try exec_testing.expect(env.created);
    try exec_testing.expectEqualStrings("notes", env.skill_name);

    // The row is in ws_1, reachable through the store — not on disk.
    const row = try exec_skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "notes");
    defer exec_skills_store.freeSkillRow(alloc, row);
    try exec_testing.expectEqualStrings("Keep notes.", row.description);
    try exec_testing.expectError(error.NotFound, exec_skills_store.getSkillByName(alloc, &ctx.db, "ws_2", "notes"));
}

test "execAddSkill: a hallucinated workspace_id is ignored, not honoured" {
    const alloc = exec_testing.allocator;
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
    try exec_testing.expect(env.success);

    try exec_testing.expectError(error.NotFound, exec_skills_store.getSkillByName(alloc, &ctx.db, "ws_2", "spoof"));
    const mine = try exec_skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "spoof");
    defer exec_skills_store.freeSkillRow(alloc, mine);
}

test "execAddSkill: a stale is_global from the old schema does not cost the call" {
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // The pre-refactor schema had `is_global`. A model trained on it (or
    // working from an old prompt) still sends it.
    const result = try execAddSkill(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall(
        "add_skill",
        "{\"name\":\"legacy\",\"description\":\"d\",\"content\":\"body\",\"is_global\":true}",
    ));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();
    try exec_testing.expect(env.success);
    try exec_testing.expectEqualStrings("legacy", env.skill_name);

    const row = try exec_skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "legacy");
    defer exec_skills_store.freeSkillRow(alloc, row);
}

test "execUseSkill returns the body AND the SkillSaveInfo handle_tool persists" {
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try exec_seedSkill(alloc, &ctx.db, "ws_1", "pdf", "Work with PDFs", "## When to Use\n\nRun scripts/convert.py.");

    const result = try execUseSkill(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("use_skill", "{\"name\":\"pdf\"}"));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();

    try exec_testing.expect(env.success);
    try exec_testing.expect(env.loaded);
    try exec_testing.expectEqualStrings("pdf", env.skill_name);
    try exec_testing.expect(std.mem.indexOf(u8, env.content, "Run scripts/convert.py.") != null);

    // `handle_tool.zig` persists this to session_skills. It is the contract
    // that file owns, so the return value is what must survive here.
    const save = result.skill_save orelse return error.NoSkillSave;
    defer alloc.free(save.name);
    defer alloc.free(save.content);
    try exec_testing.expectEqualStrings("pdf", save.name);
    try exec_testing.expectEqualStrings(env.content, save.content);
}

test "execUseSkill: an unknown name is success=false, never a successful empty load" {
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try exec_seedSkill(alloc, &ctx.db, "ws_1", "alpha", "first", "a");

    const result = try execUseSkill(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("use_skill", "{\"name\":\"ghost\"}"));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();

    try exec_testing.expect(!env.success);
    try exec_testing.expect(env.err != null);
    try exec_testing.expect(!env.loaded);
    try exec_testing.expect(result.skill_save == null);
}

test "execEditSkill: an ineffective patch surfaces as success=false" {
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seeded with EXACTLY what `buildSkillContent` produces — that is what
    // the tool stores, so anything else would make this patch a real
    // change and the assertion below would be exec_testing the wrong branch.
    try exec_seedSkill(alloc, &ctx.db, "ws_1", "same", "same description", "---\nname: same\ndescription: \"same description\"\n---\nsame body\n");

    const result = try execEditSkill(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall(
        "edit_skill",
        "{\"skill_name\":\"same\",\"description\":\"same description\",\"content\":\"same body\"}",
    ));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();

    try exec_testing.expect(!env.success);
    try exec_testing.expect(!env.updated);
    try exec_testing.expect(env.err != null);
    try exec_testing.expect(std.mem.indexOf(u8, env.err.?, "nothing to change") != null);
}

test "execEditSkill: a cross-workspace edit is refused and the row is untouched" {
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try exec_seedSkill(alloc, &ctx.db, "ws_1", "private", "ws_1's copy", "TOPSECRETBODY");

    const result = try execEditSkill(makeTestCtx(alloc, &ctx.db, "s2"), fakeToolCall(
        "edit_skill",
        "{\"skill_name\":\"private\",\"content\":\"hijacked\"}",
    ));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();

    try exec_testing.expect(!env.success);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "TOPSECRETBODY") == null);

    const survivor = try exec_skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "private");
    defer exec_skills_store.freeSkillRow(alloc, survivor);
    try exec_testing.expectEqualStrings("TOPSECRETBODY", survivor.content);
}

test "execRemoveSkill removes the row from the caller's workspace only" {
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try exec_seedSkill(alloc, &ctx.db, "ws_1", "doomed", "obsolete", "body");

    const wrong = try execRemoveSkill(makeTestCtx(alloc, &ctx.db, "s2"), fakeToolCall("remove_skill", "{\"skill_name\":\"doomed\"}"));
    defer alloc.free(wrong.output);
    var denied = try parseEnvelope(alloc, wrong.output);
    defer denied.deinit();
    try exec_testing.expect(!denied.success);
    try exec_testing.expect(!denied.removed);

    const result = try execRemoveSkill(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("remove_skill", "{\"skill_name\":\"doomed\"}"));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();
    try exec_testing.expect(env.success);
    try exec_testing.expect(env.removed);
    try exec_testing.expectError(error.NotFound, exec_skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "doomed"));
}

test "execSearchSkills lists the workspace and NEVER mentions a tier or a path" {
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try exec_seedSkill(alloc, &ctx.db, "ws_1", "alpha", "first skill", "a");
    try exec_seedSkill(alloc, &ctx.db, "ws_1", "beta", "second skill", "b");
    try exec_seedSkill(alloc, &ctx.db, "ws_2", "must-not-leak", "another workspace", "c");

    const result = try execSearchSkills(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("search_skills", "{}"));
    defer alloc.free(result.output);
    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();

    try exec_testing.expect(env.success);
    try exec_testing.expectEqual(@as(usize, 2), env.total);
    try exec_testing.expectEqual(@as(usize, 2), env.count);
    try exec_testing.expectEqualStrings("all", env.pattern_mode);

    // The whole point of the row shape: the model gets a NAME to hand
    // back, and nothing that describes a place that no longer exists.
    try exec_testing.expect(std.mem.indexOf(u8, env.raw, "\"scope\"") == null);
    try exec_testing.expect(std.mem.indexOf(u8, env.raw, "\"is_global\"") == null);
    try exec_testing.expect(std.mem.indexOf(u8, env.raw, "\"path\"") == null);
    try exec_testing.expect(std.mem.indexOf(u8, env.raw, "SKILL.MD") == null);
    try exec_testing.expect(std.mem.indexOf(u8, env.raw, ".pabrik/skills") == null);
    try exec_testing.expect(std.mem.indexOf(u8, env.raw, "must-not-leak") == null);
}

test "execSearchSkills: a stale scope argument is ignored, and paging still works" {
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    for ([_][]const u8{ "d1", "d2", "d3" }) |n| {
        try exec_seedSkill(alloc, &ctx.db, "ws_1", n, "shared body", "x");
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

    try exec_testing.expect(env.success);
    try exec_testing.expectEqual(@as(usize, 3), env.total);
    try exec_testing.expectEqual(@as(usize, 2), env.count);
    try exec_testing.expect(env.truncated);
    try exec_testing.expectEqual(@as(usize, 2), env.next_offset.?);
    try exec_testing.expect(std.mem.indexOf(u8, env.hint, "offset=2") != null);
}

test "execSearchSkills: out-of-range paging is rejected, never silently clamped" {
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const zero = try execSearchSkills(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("search_skills", "{\"limit\":0}"));
    defer alloc.free(zero.output);
    var a = try parseEnvelope(alloc, zero.output);
    defer a.deinit();
    try exec_testing.expect(!a.success);
    try exec_testing.expect(std.mem.indexOf(u8, a.err.?, "at least 1") != null);

    const negative = try execSearchSkills(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("search_skills", "{\"offset\":-1}"));
    defer alloc.free(negative.output);
    var b = try parseEnvelope(alloc, negative.output);
    defer b.deinit();
    try exec_testing.expect(!b.success);
    try exec_testing.expect(std.mem.indexOf(u8, b.err.?, "negative") != null);
}

test "every skill exec wrapper treats an unresolvable session as a REFUSAL" {
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try exec_seedSkill(alloc, &ctx.db, "ws_1", "alpha", "first", "a");

    // "no matching skills" and "you have no workspace" are different facts.
    // A silent empty page would read as "your skills are gone".
    const tc = makeTestCtx(alloc, &ctx.db, "s_orphan");

    const search = try execSearchSkills(tc, fakeToolCall("search_skills", "{}"));
    defer alloc.free(search.output);
    var s = try parseEnvelope(alloc, search.output);
    defer s.deinit();
    try exec_testing.expect(!s.success);
    try exec_testing.expect(std.mem.indexOf(u8, s.err.?, "workspace") != null);

    const add = try execAddSkill(tc, fakeToolCall("add_skill", "{\"name\":\"x\",\"description\":\"d\",\"content\":\"c\"}"));
    defer alloc.free(add.output);
    var a = try parseEnvelope(alloc, add.output);
    defer a.deinit();
    try exec_testing.expect(!a.success);

    const use_ = try execUseSkill(tc, fakeToolCall("use_skill", "{\"name\":\"alpha\"}"));
    defer alloc.free(use_.output);
    var u = try parseEnvelope(alloc, use_.output);
    defer u.deinit();
    try exec_testing.expect(!u.success);

    const edit = try execEditSkill(tc, fakeToolCall("edit_skill", "{\"skill_name\":\"alpha\",\"description\":\"new\"}"));
    defer alloc.free(edit.output);
    var e = try parseEnvelope(alloc, edit.output);
    defer e.deinit();
    try exec_testing.expect(!e.success);

    const remove = try execRemoveSkill(tc, fakeToolCall("remove_skill", "{\"skill_name\":\"alpha\"}"));
    defer alloc.free(remove.output);
    var r = try parseEnvelope(alloc, remove.output);
    defer r.deinit();
    try exec_testing.expect(!r.success);

    // Nothing was written or deleted on the way through.
    const survivor = try exec_skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "alpha");
    defer exec_skills_store.freeSkillRow(alloc, survivor);
    try exec_testing.expectError(error.NotFound, exec_skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "x"));
}

test "malformed JSON arguments become a parse failure, not a crash" {
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tc = makeTestCtx(alloc, &ctx.db, "s1");

    const add = try execAddSkill(tc, fakeToolCall("add_skill", "{not json"));
    defer alloc.free(add.output);
    var a = try parseEnvelope(alloc, add.output);
    defer a.deinit();
    try exec_testing.expect(!a.success);
    try exec_testing.expect(std.mem.indexOf(u8, a.err.?, "parse") != null);

    const search = try execSearchSkills(tc, fakeToolCall("search_skills", "{not json"));
    defer alloc.free(search.output);
    var s = try parseEnvelope(alloc, search.output);
    defer s.deinit();
    try exec_testing.expect(!s.success);
    try exec_testing.expect(std.mem.indexOf(u8, s.err.?, "parse") != null);
}

test "execEditSkill: a locked skill is a refusal at the envelope, and the body survives" {
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const seeded = try exec_skills_store.upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .name = "pinned",
        .description = "pinned by the human",
        .content = "KEEPME",
        .is_can_auto_improve = false,
    });
    exec_skills_store.freeSkillRow(alloc, seeded);

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

    try exec_testing.expect(!env.success);
    try exec_testing.expect(!env.updated);
    try exec_testing.expect(env.err != null);
    try exec_testing.expect(std.mem.indexOf(u8, env.err.?, "locked") != null);

    const survivor = try exec_skills_store.getSkillByName(alloc, &ctx.db, "ws_1", "pinned");
    defer exec_skills_store.freeSkillRow(alloc, survivor);
    try exec_testing.expectEqualStrings("KEEPME", survivor.content);
}

