// Functional tests for the kanban create_and_run message format. Zig port of
// `tests/functional/kanban_task_create_message_format.py` (same test names,
// same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// Python `_wait_for_user_message`'s default timeout.
const USER_MESSAGE_TIMEOUT_S: f64 = 20.0;
const POLL_INTERVAL_MS: u32 = 200;

// ============================================================================
// Fixtures
// ============================================================================

/// Python `worker_harness` fixture. Own boot with a stub LLM profile so
/// create_and_run workers drain.
fn bootWorkerHarness() !Harness {
    return Harness.boot(io, gpa, .{ .stub_llm_profile = true });
}

// ============================================================================
// HTTP helpers
// ============================================================================

/// Python `_create_workspace`. Owned.
fn createWorkspace(h: *Harness) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = "kanban-fmt-ws" }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const id = blk: {
        const root = switch (doc.value().*) {
            .object => |o| o,
            else => {
                std.debug.print("workspace create returned a non-object: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            },
        };
        const v = root.get("id") orelse {
            std.debug.print("workspace create returned no id: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        break :blk switch (v) {
            .string => |s| s,
            else => {
                std.debug.print("workspace id is not a string: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            },
        };
    };
    return gpa.dupe(u8, id);
}

/// Python `_create_kanban`. Returns the new kanban item id (owned).
fn createKanban(h: *Harness, workspace_id: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = "sprint-fmt" }, .{});
    defer gpa.free(body);
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/kanban",
        .{workspace_id},
    );
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const root = switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("create kanban returned a non-object: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    const item_val = root.get("item") orelse {
        std.debug.print("create kanban returned no `item`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const item = switch (item_val) {
        .object => |o| o,
        else => {
            std.debug.print("`item` is not an object: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    const id_val = item.get("id") orelse {
        std.debug.print("kanban item has no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id = switch (id_val) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    return gpa.dupe(u8, id);
}

/// Python `_create_task`: POST the exact wire body the frontend sends
/// for each mode. Returns the WHOLE body (owned).
fn createTask(
    h: *Harness,
    workspace_id: []const u8,
    kanban_id: []const u8,
    name: []const u8,
    description: []const u8,
    mode: []const u8,
    queue_message: ?[]const u8,
) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(
        gpa,
        .{
            .mode = mode,
            .name = name,
            .description = description,
            .queue_message = queue_message,
        },
        // `queue_message` is OMITTED when the caller did not pass one -
        // Python only added the key when it was not None.
        .{ .emit_null_optional_fields = false },
    );
    defer gpa.free(body);
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/tasks",
        .{ workspace_id, kanban_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// The `task.id` out of a create-task response body. Owned.
fn taskIdFrom(create_body: []const u8) ![]u8 {
    var doc: harness.Json = .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, create_body, .{}) };
    defer doc.deinit();
    const root = switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("create task returned a non-object: {s}\n", .{create_body});
            return error.TestUnexpectedResult;
        },
    };
    const task_val = root.get("task") orelse {
        std.debug.print("create task returned no `task`: {s}\n", .{create_body});
        return error.TestUnexpectedResult;
    };
    const task = switch (task_val) {
        .object => |o| o,
        else => {
            std.debug.print("`task` is not an object: {s}\n", .{create_body});
            return error.TestUnexpectedResult;
        },
    };
    const id_val = task.get("id") orelse {
        std.debug.print("task has no id: {s}\n", .{create_body});
        return error.TestUnexpectedResult;
    };
    const id = switch (id_val) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    return gpa.dupe(u8, id);
}

/// The user-role rows of a session, as an OWNED body slice. Python
/// `_user_role_messages` returned a list of dicts.
fn userRoleMessagesBody(h: *Harness, session_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/llm/session/{s}/messages",
        .{session_id},
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{
        .params = &.{
            .{ .name = "sort_by", .value = "created_at" },
            .{ .name = "direction", .value = "asc" },
            .{ .name = "limit", .value = "100" },
        },
        .expect = &.{200},
    });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// The `content` of the n-th user-role message. Owned.
fn nthUserContent(messages_body: []const u8, n: usize) ![]u8 {
    var doc: harness.Json = .{ .parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        messages_body,
        .{ .allocate = .alloc_always },
    ) };
    defer doc.deinit();
    const root = switch (doc.value().*) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    const msgs = switch (root.get("messages") orelse std.json.Value{ .null = {} }) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    var seen: usize = 0;
    for (msgs.items) |m| {
        const obj = switch (m) {
            .object => |o| o,
            else => continue,
        };
        const role = switch (obj.get("role") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, role, "user")) continue;
        if (seen == n) {
            const content = obj.get("content") orelse
                return error.TestUnexpectedResult;
            return switch (content) {
                .string => |s| gpa.dupe(u8, s),
                else => error.TestUnexpectedResult,
            };
        }
        seen += 1;
    }
    return error.TestUnexpectedResult;
}

/// How many user-role rows the session carries.
fn countUserMessages(messages_body: []const u8) !usize {
    var doc: harness.Json = .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, messages_body, .{}) };
    defer doc.deinit();
    const root = switch (doc.value().*) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    const msgs = switch (root.get("messages") orelse std.json.Value{ .null = {} }) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    var n: usize = 0;
    for (msgs.items) |m| {
        const obj = switch (m) {
            .object => |o| o,
            else => continue,
        };
        const role = switch (obj.get("role") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, role, "user")) n += 1;
    }
    return n;
}

/// Python `_wait_for_user_message`: poll until the queue-drained user row
/// lands (create_and_run is async). Returns the user-role CONTENT of the
/// first drained row, owned.
fn waitForUserMessage(h: *Harness, session_id: []const u8, timeout_s: f64) ![]u8 {
    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() +
        @as(i64, @intFromFloat(timeout_s * 1000.0));
    var last: []u8 = "";
    defer if (last.len > 0) gpa.free(last);

    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        const body = try userRoleMessagesBody(h, session_id);
        if (last.len > 0) gpa.free(last);
        last = body;
        const n = try countUserMessages(body);
        if (n > 0) {
            const content = try nthUserContent(body, 0);
            gpa.free(last);
            last = "";
            return content;
        }
        std.Io.sleep(io, .fromMilliseconds(POLL_INTERVAL_MS), .awake) catch {};
    }
    std.debug.print(
        "no user-role row drained within {d}s for {s}\n",
        .{ @as(u32, @intFromFloat(timeout_s)), session_id },
    );
    return error.TestUnexpectedResult;
}

// ============================================================================
// git fixture helpers
// ============================================================================

/// Write `contents` to `path` (absolute), creating/truncating it.
fn writeFileAt(path: []const u8, contents: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

/// Python `_git`: `subprocess.run(["git", "-C", repo, *args],
/// check=True)`. Skips the test when `git` cannot be spawned at all.
fn git(repo: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "-C", repo });
    try argv.appendSlice(gpa, args);

    const res = std.process.run(gpa, io, .{ .argv = argv.items }) catch |err| {
        std.debug.print("git did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    if (res.term.exited != 0) {
        std.debug.print("git {s} exited {d}: {s}\n", .{ args[0], res.term.exited, res.stderr });
        return error.TestUnexpectedResult;
    }
}

/// Python `_make_repo_with_branches`. Create a throwaway repo with one local
/// branch, two remote-tracking refs, and a symbolic `origin/HEAD` (the row
/// the parser must drop). Returns the repo path (owned) under `root`.
fn makeRepoWithBranches(root: []const u8) ![]u8 {
    const repo = try std.fs.path.join(gpa, &.{ root, "branches-repo" });
    errdefer gpa.free(repo);
    try std.Io.Dir.cwd().createDirPath(io, repo);

    try git(repo, &.{ "init", "--initial-branch=main", "--quiet" });
    const a_txt = try std.fs.path.join(gpa, &.{ repo, "a.txt" });
    defer gpa.free(a_txt);
    try writeFileAt(a_txt, "a\n");
    try git(repo, &.{ "add", "a.txt" });
    try git(repo, &.{
        "-c",     "user.email=test@example.com",
        "-c",     "user.name=Test",
        "-c",     "commit.gpgsign=false",
        "commit", "--quiet",
        "-m",     "init",
    });
    // Fabricate remote-tracking refs — no network, no `origin` remote
    // needed.
    try git(repo, &.{ "update-ref", "refs/remotes/origin/main", "HEAD" });
    try git(repo, &.{ "update-ref", "refs/remotes/origin/feature-x", "HEAD" });
    try git(repo, &.{ "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" });
    try git(repo, &.{ "branch", "local-dev" });
    return repo;
}

comptime {
    // Body-analysis barrier: an unreferenced fn body is never
    // type-checked, so a stdlib rename inside one hides until a caller
    // appears.
    _ = bootWorkerHarness;
    _ = createWorkspace;
    _ = createKanban;
    _ = createTask;
    _ = taskIdFrom;
    _ = userRoleMessagesBody;
    _ = nthUserContent;
    _ = countUserMessages;
    _ = waitForUserMessage;
    _ = makeRepoWithBranches;
    _ = git;
}

// ============================================================================
// Test 1: name + description, toggle OFF
// ============================================================================

// queue_message `Task : <name>\nDescription: <desc>` drains verbatim.
test "create_and_run_formats_task_and_description" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootWorkerHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h);
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id);
    defer gpa.free(kanban_id);

    const create_body = try createTask(
        &h,
        ws_id,
        kanban_id,
        "Fix login",
        "blablabla",
        "create_and_run",
        "Task : Fix login\nDescription: blablabla",
    );
    defer gpa.free(create_body);
    const task_id = try taskIdFrom(create_body);
    defer gpa.free(task_id);

    const content = try waitForUserMessage(&h, task_id, USER_MESSAGE_TIMEOUT_S);
    defer gpa.free(content);
    if (!std.mem.eql(u8, content, "Task : Fix login\nDescription: blablabla")) {
        const escaped = try harness.debugString(gpa, content);
        defer gpa.free(escaped);
        std.debug.print("drained content = \"{s}\"\n", .{escaped});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 2: name only, toggle OFF — no Description line
// ============================================================================

test "create_and_run_omits_description_line_when_empty" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootWorkerHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h);
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id);
    defer gpa.free(kanban_id);

    const create_body = try createTask(
        &h,
        ws_id,
        kanban_id,
        "Title-only task",
        "",
        "create_and_run",
        "Task : Title-only task",
    );
    defer gpa.free(create_body);
    const task_id = try taskIdFrom(create_body);
    defer gpa.free(task_id);

    const content = try waitForUserMessage(&h, task_id, USER_MESSAGE_TIMEOUT_S);
    defer gpa.free(content);
    if (!std.mem.eql(u8, content, "Task : Title-only task")) {
        const escaped = try harness.debugString(gpa, content);
        defer gpa.free(escaped);
        std.debug.print("unexpected content: \"{s}\"\n", .{escaped});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, content, "Description") != null) {
        const escaped = try harness.debugString(gpa, content);
        defer gpa.free(escaped);
        std.debug.print("unexpected content (carries a Description line): \"{s}\"\n", .{escaped});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 3: toggle ON appends the worktree note
// ============================================================================

test "create_and_run_appends_worktree_note_when_toggled" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootWorkerHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h);
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id);
    defer gpa.free(kanban_id);

    const create_body = try createTask(
        &h,
        ws_id,
        kanban_id,
        "Isolated work",
        "blablabla",
        "create_and_run",
        "Task : Isolated work\nDescription: blablabla\n\n#Notes UseGitWorktree",
    );
    defer gpa.free(create_body);
    const task_id = try taskIdFrom(create_body);
    defer gpa.free(task_id);

    const content = try waitForUserMessage(&h, task_id, USER_MESSAGE_TIMEOUT_S);
    defer gpa.free(content);
    if (!std.mem.eql(u8, content, "Task : Isolated work\nDescription: blablabla\n\n#Notes UseGitWorktree")) {
        const escaped = try harness.debugString(gpa, content);
        defer gpa.free(escaped);
        std.debug.print("drained content = \"{s}\"\n", .{escaped});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 4: create_session keeps the server-side composition
// ============================================================================

// Scope lock: plain Create task is untouched by the frontend-only change.
test "create_session_keeps_server_composition" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h);
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id);
    defer gpa.free(kanban_id);

    const create_body = try createTask(
        &h,
        ws_id,
        kanban_id,
        "Plain task",
        "plain desc",
        "create_session",
        null,
    );
    defer gpa.free(create_body);
    const task_id = try taskIdFrom(create_body);
    defer gpa.free(task_id);

    // create_session is SYNCHRONOUS: the row is already there, so no
    // poll (Python called `_user_role_messages` directly).
    const messages_body = try userRoleMessagesBody(&h, task_id);
    defer gpa.free(messages_body);

    const n = try countUserMessages(messages_body);
    if (n != 1) {
        std.debug.print("expected exactly 1 user row, got {d}: {s}\n", .{ n, messages_body });
        return error.TestUnexpectedResult;
    }
    const content = try nthUserContent(messages_body, 0);
    defer gpa.free(content);
    if (!std.mem.eql(u8, content, "Plain task\n\nplain desc")) {
        const escaped = try harness.debugString(gpa, content);
        defer gpa.free(escaped);
        std.debug.print("drained content = \"{s}\"\n", .{escaped});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 5: toggle ON + custom path appends the Path line
// ============================================================================

// The worktree path input lands as the `Path:` line after the note.
test "create_and_run_appends_worktree_path_when_provided" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootWorkerHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h);
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id);
    defer gpa.free(kanban_id);

    const expected = "Task : Isolated work\nDescription: blablabla\n\n" ++
        "#Notes UseGitWorktree\nPath: ~/.config/pabrik/.worktrees/isolated-work";

    const create_body = try createTask(
        &h,
        ws_id,
        kanban_id,
        "Isolated work",
        "blablabla",
        "create_and_run",
        expected,
    );
    defer gpa.free(create_body);
    const task_id = try taskIdFrom(create_body);
    defer gpa.free(task_id);

    const content = try waitForUserMessage(&h, task_id, USER_MESSAGE_TIMEOUT_S);
    defer gpa.free(content);
    if (!std.mem.eql(u8, content, expected)) {
        const escaped = try harness.debugString(gpa, content);
        defer gpa.free(escaped);
        std.debug.print("drained content = \"{s}\"\n", .{escaped});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 6: toggle ON + path + base branch appends the Base line
// ============================================================================

// The base-branch picker lands as the `Base:` line after `Path:`. This is the
// wire half of the feature: the agent only knows which ref to branch the
// worktree FROM because this line reaches llm_history verbatim.
test "create_and_run_appends_worktree_base_branch_when_provided" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootWorkerHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h);
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id);
    defer gpa.free(kanban_id);

    const expected = "Task : Isolated work\nDescription: blablabla\n\n" ++
        "#Notes UseGitWorktree\nPath: /home/you/.config/pabrik/.worktrees/x\n" ++
        "Base: origin/main";

    const create_body = try createTask(
        &h,
        ws_id,
        kanban_id,
        "Isolated work",
        "blablabla",
        "create_and_run",
        expected,
    );
    defer gpa.free(create_body);
    const task_id = try taskIdFrom(create_body);
    defer gpa.free(task_id);

    const content = try waitForUserMessage(&h, task_id, USER_MESSAGE_TIMEOUT_S);
    defer gpa.free(content);
    if (!std.mem.eql(u8, content, expected)) {
        const escaped = try harness.debugString(gpa, content);
        defer gpa.free(escaped);
        std.debug.print("drained content = \"{s}\"\n", .{escaped});
        return error.TestUnexpectedResult;
    }
}

// Regression guard: no base ref => byte-identical to the pre-feature form.
test "create_and_run_without_base_keeps_the_old_message_shape" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootWorkerHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h);
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id);
    defer gpa.free(kanban_id);

    const create_body = try createTask(
        &h,
        ws_id,
        kanban_id,
        "Isolated work",
        "blablabla",
        "create_and_run",
        "Task : Isolated work\nDescription: blablabla\n\n" ++
            "#Notes UseGitWorktree\nPath: /tmp/wt/x",
    );
    defer gpa.free(create_body);
    const task_id = try taskIdFrom(create_body);
    defer gpa.free(task_id);

    const content = try waitForUserMessage(&h, task_id, USER_MESSAGE_TIMEOUT_S);
    defer gpa.free(content);
    if (std.mem.indexOf(u8, content, "Base:") != null) {
        const escaped = try harness.debugString(gpa, content);
        defer gpa.free(escaped);
        std.debug.print("message unexpectedly carries a `Base:` line: \"{s}\"\n", .{escaped});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// GET /api/git/branches — the dropdown's data source
// ============================================================================

// Default hoisted, then remotes, then locals; symbolic HEAD dropped.
test "git_branches_lists_refs_in_picker_order" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // Scratch root: a sibling of the harness tempdir under the OS temp root,
    // so the orphan reaper (which only matches `pabrik-func-*`) cannot take
    // the fixture mid-test.
    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const repo = try makeRepoWithBranches(scratch);
    defer gpa.free(repo);

    var r = try h.http(io, .GET, "/api/git/branches", .{
        .params = &.{.{ .name = "path", .value = repo }},
        .expect = &.{200},
    });
    defer r.deinit();

    var data = try r.json();
    defer data.deinit();

    const is_repo = data.boolean("is_git_repo") orelse {
        std.debug.print("git branches returned no is_git_repo: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!is_repo) {
        std.debug.print("expected is_git_repo=true for {s}: {s}\n", .{ repo, r.body });
        return error.TestUnexpectedResult;
    }
    const current = data.str("current_branch") orelse {
        std.debug.print("git branches returned no current_branch: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, current, "main")) {
        std.debug.print("current_branch = \"{s}\", expected \"main\"\n", .{current});
        return error.TestUnexpectedResult;
    }

    const branches = data.array("branches") orelse {
        std.debug.print("git branches returned no `branches` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };

    // Name order: the picker order.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for (branches.items) |b| {
        const obj = switch (b) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const n = switch (obj.get("name") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        try names.append(gpa, n);
    }
    const has = struct {
        fn f(list: []const []const u8, needle: []const u8) bool {
            for (list) |x| {
                if (std.mem.eql(u8, x, needle)) return true;
            }
            return false;
        }
    }.f;

    if (!has(names.items, "origin/main")) {
        std.debug.print("origin/main missing from branches\n", .{});
        return error.TestUnexpectedResult;
    }
    if (!has(names.items, "origin/feature-x")) {
        std.debug.print("origin/feature-x missing from branches\n", .{});
        return error.TestUnexpectedResult;
    }
    if (!has(names.items, "local-dev")) {
        std.debug.print("local-dev missing from branches\n", .{});
        return error.TestUnexpectedResult;
    }
    // The symbolic ref shortens to a bare `origin` — it must never
    // surface as a selectable base branch.
    if (has(names.items, "origin")) {
        std.debug.print("symbolic origin/HEAD surfaced as a bare `origin`\n", .{});
        return error.TestUnexpectedResult;
    }
    if (has(names.items, "HEAD")) {
        std.debug.print("symbolic origin/HEAD surfaced as a bare `HEAD`\n", .{});
        return error.TestUnexpectedResult;
    }
    // Detected default first, then the other remote-tracking ref, then
    // the local branch.
    if (names.items.len == 0 or !std.mem.eql(u8, names.items[0], "origin/main")) {
        const rendered = try renderNames(names.items);
        defer gpa.free(rendered);
        std.debug.print("expected origin/main first, got: {s}\n", .{rendered});
        return error.TestUnexpectedResult;
    }

    // Per-branch flag shapes.
    {
        const b = branchByName(branches, "origin/main") orelse return error.TestUnexpectedResult;
        try expectBranchFlags(b, .{ .is_remote = true, .is_current = false, .is_default = true }, "origin/main");
    }
    {
        const b = branchByName(branches, "origin/feature-x") orelse return error.TestUnexpectedResult;
        try expectBranchFlags(b, .{ .is_remote = true, .is_current = false, .is_default = false }, "origin/feature-x");
    }
    {
        const b = branchByName(branches, "local-dev") orelse return error.TestUnexpectedResult;
        try expectBranchFlags(b, .{ .is_remote = false, .is_current = false, .is_default = false }, "local-dev");
    }
    {
        const b = branchByName(branches, "main") orelse {
            std.debug.print("current branch `main` missing from branches\n", .{});
            return error.TestUnexpectedResult;
        };
        const cur = switch (b.get("is_current") orelse return error.TestUnexpectedResult) {
            .bool => |x| x,
            else => return error.TestUnexpectedResult,
        };
        if (!cur) {
            std.debug.print("main.is_current must be true\n", .{});
            return error.TestUnexpectedResult;
        }
    }
}

test "git_branches_404_when_path_is_not_a_repo" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    const plain = try std.fs.path.join(gpa, &.{ scratch, "not-a-repo" });
    defer gpa.free(plain);
    try std.Io.Dir.cwd().createDirPath(io, plain);

    var r = try h.http(io, .GET, "/api/git/branches", .{
        .params = &.{.{ .name = "path", .value = plain }},
        .expect = &.{404},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const err = doc.str("error") orelse "";
    if (std.mem.indexOf(u8, err, "not a git repository") == null) {
        std.debug.print("expected \"not a git repository\", got: {s}\n", .{err});
        return error.TestUnexpectedResult;
    }
}

test "git_branches_400_when_path_is_missing" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/branches", .{ .expect = &.{400} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    if (doc.get("error") == null) {
        std.debug.print("expected an `error` key, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// `..` traversal and relative paths are rejected before git is spawned.
test "git_branches_400_when_path_is_not_absolute" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/branches", .{
        .params = &.{.{ .name = "path", .value = "relative/repo" }},
        .expect = &.{400},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    if (doc.get("error") == null) {
        std.debug.print("expected an `error` key, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

const BranchFlags = struct {
    is_remote: bool,
    is_current: bool,
    is_default: bool,
};

fn branchByName(branches: std.json.Array, name: []const u8) ?std.json.ObjectMap {
    for (branches.items) |b| {
        const obj = switch (b) {
            .object => |o| o,
            else => continue,
        };
        const n = switch (obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, n, name)) return obj;
    }
    return null;
}

fn boolFlag(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) !bool {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: missing `{s}`\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .bool => |b| b,
        else => {
            std.debug.print("{s}: `{s}` is not a bool\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
}

/// Python `by_name[name] == {name, is_remote, is_current, is_default}`
/// — i.e. the object carries EXACTLY those four keys with those values.
fn expectBranchFlags(b: std.json.ObjectMap, want: BranchFlags, name: []const u8) !void {
    var count: usize = 0;
    var it = b.iterator();
    while (it.next()) |_| count += 1;
    if (count != 4) {
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(gpa);
        var kit = b.iterator();
        while (kit.next()) |e| try keys.append(gpa, e.key_ptr.*);
        const rendered = try std.mem.join(gpa, ", ", keys.items);
        defer gpa.free(rendered);
        std.debug.print("{s}: expected exactly 4 keys, got {d} ({s})\n", .{ name, count, rendered });
        return error.TestUnexpectedResult;
    }
    const n = switch (b.get("name") orelse return error.TestUnexpectedResult) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    if (!std.mem.eql(u8, n, name)) {
        std.debug.print("{s}: name field = \"{s}\"\n", .{ name, n });
        return error.TestUnexpectedResult;
    }
    if (try boolFlag(b, "is_remote", name) != want.is_remote) {
        std.debug.print("{s}: is_remote mismatch\n", .{name});
        return error.TestUnexpectedResult;
    }
    if (try boolFlag(b, "is_current", name) != want.is_current) {
        std.debug.print("{s}: is_current mismatch\n", .{name});
        return error.TestUnexpectedResult;
    }
    if (try boolFlag(b, "is_default", name) != want.is_default) {
        std.debug.print("{s}: is_default mismatch\n", .{name});
        return error.TestUnexpectedResult;
    }
}

fn renderNames(names: []const []const u8) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    for (names) |n| {
        buf.writer.print("{s}, ", .{n}) catch return error.OutOfMemory;
    }
    return buf.toOwnedSlice();
}
