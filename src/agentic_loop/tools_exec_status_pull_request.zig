const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const llm_history = pabrikcore.llm_history;
const status_pull_request_mod = pabrikcore.status_pull_request;
const pr_provider = pabrikcore.pr_provider;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");

fn payloadString(inner_parsed: ?std.json.Parsed(std.json.Value), field: []const u8) ?[]const u8 {
    const p = inner_parsed orelse return null;
    if (p.value != .object) return null;
    const v = p.value.object.get(field) orelse return null;
    if (v != .string) return null;
    if (v.string.len == 0) return null;
    return v.string;
}

/// Best-effort provider sniff from the worktree's own `origin` remote.
/// Returns null when there is no origin, git cannot be asked, or the remote
/// names no known forge.
fn providerFromOrigin(allocator: std.mem.Allocator, io: std.Io, worktree_path: []const u8) ?pr_provider.PrProvider {
    const res = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", worktree_path, "remote", "get-url", "origin" },
    }) catch return null;
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }
    if (res.term.exited != 0) return null;
    const url = std.mem.trim(u8, res.stdout, " \n\r");
    if (url.len == 0) return null;
    const p = pr_provider.detectProviderFromRemote(url);
    if (p == .generic) return null;
    return p;
}

pub fn execStatusPullRequest(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        status_pull_request_mod.StatusPullRequestInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "status_pull_request", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    if (status_pull_request_mod.validateProviderOverride(parsed.value.provider)) |err_text| {
        const output = try wrapToolOutput(ctx.allocator, "status_pull_request", tc.function.arguments, false, err_text, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    // The worktree is the lookup scope: the session binding if set,
    // otherwise the session's own directory. The forge CLIs resolve the
    // repo (and the current branch's PR/MR) from the cwd they run in.
    const worktree_path = ctx.cwd_override orelse ctx.cwd;

    // Which PR/MR: explicit arg wins; otherwise the session binding from
    // `set_pull_request`. Neither means there is nothing to report on.
    var owned_binding_url: ?[]u8 = null;
    defer if (owned_binding_url) |b| ctx.allocator.free(b);
    var owned_binding_provider: ?[]u8 = null;
    defer if (owned_binding_provider) |b| ctx.allocator.free(b);

    var pr_arg: []const u8 = parsed.value.pr_url;
    if (pr_arg.len == 0) {
        const fields = llm_history.getSessionPrFields(ctx.allocator, ctx.db, ctx.session_id) catch null;
        if (fields) |f| {
            owned_binding_url = ctx.allocator.dupe(u8, f.pr_url) catch null;
            owned_binding_provider = ctx.allocator.dupe(u8, f.pr_provider) catch null;
            // getSessionPrFields returns string literals (not owned) on the
            // missing-row path — only free non-empty slices, which always
            // come from the owned-dupe found-row path.
            if (f.pr_url.len > 0) ctx.allocator.free(f.pr_url);
            if (f.pr_provider.len > 0) ctx.allocator.free(f.pr_provider);
            if (owned_binding_url) |b| {
                if (b.len > 0) pr_arg = b;
            }
        }
        if (pr_arg.len == 0) {
            const msg = "no pull request bound to this session (call set_pull_request first) and no pr_url given";
            const inner = try status_pull_request_mod.jsonError(ctx.allocator, msg);
            defer ctx.allocator.free(inner);
            const output = try wrapToolOutput(ctx.allocator, "status_pull_request", tc.function.arguments, false, msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    // Which forge, most explicit first: the `provider` arg, then a
    // URL-shaped `pr_url`, then the session binding's provider, then the
    // worktree's origin remote, then GitHub (the pre-existing default).
    var provider: pr_provider.PrProvider = .github;
    if (parsed.value.provider.len > 0) {
        provider = pr_provider.PrProvider.fromString(parsed.value.provider).?;
    } else if (pr_arg.len > 0 and std.mem.indexOf(u8, pr_arg, "://") != null) {
        if (pr_provider.normalizePrUrl(ctx.allocator, pr_arg) catch null) |normalized| {
            defer ctx.allocator.free(normalized);
            const detected = pr_provider.detectProvider(normalized);
            if (detected != .generic) {
                provider = detected;
            } else if (owned_binding_provider) |bp| {
                if (pr_provider.PrProvider.fromString(bp)) |p| provider = p;
            }
        }
    } else if (owned_binding_provider) |bp| {
        if (bp.len > 0) {
            if (pr_provider.PrProvider.fromString(bp)) |p| provider = p;
        } else if (providerFromOrigin(ctx.allocator, ctx.io, worktree_path)) |p| {
            provider = p;
        }
    } else if (providerFromOrigin(ctx.allocator, ctx.io, worktree_path)) |p| {
        provider = p;
    }

    const inner = status_pull_request_mod.executeStatusPullRequestToJSON(
        ctx.allocator,
        ctx.io,
        worktree_path,
        pr_arg,
        provider,
        null,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "status_pull_request", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    var inner_parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch null;
    defer if (inner_parsed) |*p| p.deinit();

    if (payloadString(inner_parsed, "error")) |err_msg| {
        const output = try wrapToolOutput(ctx.allocator, "status_pull_request", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "status_pull_request", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const migration = @import("../migrations/migration.zig");
const sqlite = pabrikcore.sqlite;

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

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

/// Build a `ToolExecContext` for the exec wrapper. Fields the wrapper
/// never dereferences on the tested paths (`logger`, `config`)
/// are left `undefined`, mirroring the get_plan harness.
fn makeTestCtx(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .db = db,
        .logger = undefined,
        .session_id = session_id,
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

fn fakeToolCall(args: []const u8) agent.ToolCall {
    return .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = "status_pull_request", .arguments = args },
    };
}

test "execStatusPullRequest: no binding and no pr_url points at set_pull_request" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Session does not exist, so the binding read degrades to empty (the
    // string-literal path) — this must answer with guidance, never crash.
    const tcx = makeTestCtx(alloc, &ctx.db, "sess_no_binding");
    const tc = fakeToolCall("{}");

    const result = try execStatusPullRequest(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("status_pull_request", obj.get("tool").?.string);
    try testing.expect(!obj.get("success").?.bool);
    const err_text = obj.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, err_text, "set_pull_request") != null);
}

test "execStatusPullRequest: unknown provider override is rejected before any IO" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db, "sess_any");
    const tc = fakeToolCall("{\"provider\":\"bitbucket\"}");

    const result = try execStatusPullRequest(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(!obj.get("success").?.bool);
    try testing.expect(std.mem.indexOf(u8, obj.get("error").?.string, "github") != null);
}

test "execStatusPullRequest: session binding supplies the PR when pr_url is empty" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // A `generic`-provider binding answers WITHOUT spawning any CLI, so
    // this proves the binding was read from the session row (not the
    // args) while staying hermetic: no `gh`/`glab`, no network, fast.
    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name, status, pr_url, pr_provider) VALUES ('s_bound', 'B', 'active', 'https://git.corp.example.com/a/b/changes/9', 'generic')", &.{});

    const tcx = makeTestCtx(alloc, &ctx.db, "s_bound");
    const tc = fakeToolCall("{}");

    const result = try execStatusPullRequest(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(!obj.get("success").?.bool);
    const err_text = obj.get("error").?.string;
    // The generic-provider answer proves the DB binding resolved: had it
    // not, the error would say "no pull request bound" instead.
    try testing.expect(std.mem.indexOf(u8, err_text, "no pull request bound") == null);
    try testing.expect(std.mem.indexOf(u8, err_text, "generic") != null);
}
