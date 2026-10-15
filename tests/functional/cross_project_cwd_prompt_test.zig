// Functional coverage for the cross-project cwd system prompt. Zig port of
// `tests/functional/cross_project_cwd_prompt_test.py` (same test names, same
// order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// More than the former 20-sibling cap. This is the whole point of the suite:
/// a cap regression would drop rows 21..25 and the loop below would miss them.
const SIBLING_COUNT: usize = 25;

/// The workspace-item root every sibling hangs off. Python's
/// `Path(harness.temp_dir) / "cross-project-cwd-self"`.
const SELF_DIR_NAME = "cross-project-cwd-self";

/// `POST /api/workspaces/:ws/items/agent` body (`CreateAgentBody`).
const AgentBody = struct { name: []const u8, path: []const u8 };

/// `POST /api/workspaces/:ws/items` body. `item_type` is optional server-side
/// (it defaults to `folder`); the Python seeded `'chat'`, so this port sends
/// the same value.
const ItemBody = struct {
    name: []const u8,
    path: []const u8,
    item_type: []const u8,
};

/// `POST .../items/:item_id/tasks` body (`TaskCreateRequest`). Only `name` is
/// needed; `task_type` defaults to `'standard'`, the branch that INSERTs the
/// `workspace_item_tasks` row.
const TaskBody = struct { name: []const u8 };

/// `POST /api/llm/session` body (`RequestSession`).
const SessionBody = struct {
    session_id: []const u8,
    session_name: []const u8,
    queue_message: []const u8,
    cwd_session: []const u8,
};

/// Poll `GET /test/system-prompt/:id` until it stops 404. POLLING THE
/// ENDPOINT UNDER TEST IS THE POINT, NOT A SHORTCUT.
fn waitForSystemPrompt(h: *Harness, session_id: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "/test/system-prompt/{s}", .{session_id});
    defer gpa.free(path);

    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 10_000;
    var last_status: u16 = 0;
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        var probe = try h.http(io, .GET, path, .{ .assert_status = false });
        last_status = probe.status;
        probe.deinit();
        if (last_status == 200) return;
        std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    }
    std.debug.print(
        "GET /test/system-prompt/{s} was still {d} after 10s " ++
            "(the llm_history row it joins on never landed)\n",
        .{ session_id, last_status },
    );
    return error.TestUnexpectedResult;
}

// Every sibling project path reaches the prompt, and the session's OWN item
// does not appear in the sibling list.
test "system_prompt_contains_every_workspace_item_sibling_path" {
    try harness.requirePabrikBin(io, gpa);
    // `stub_llm_profile` is LOAD-BEARING, not a convenience.
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // 1. The workspace that owns both the self item and every sibling.
    var ws_r = try h.http(io, .POST, "/api/workspaces", .{
        .json_body = "{\"name\":\"cross-project-cwd-all\"}",
        .expect = &.{201},
    });
    defer ws_r.deinit();
    var ws_doc = try ws_r.json();
    defer ws_doc.deinit();
    const ws_id = ws_doc.str("id") orelse {
        std.debug.print("workspace create returned no id: {s}\n", .{ws_r.body});
        return error.TestUnexpectedResult;
    };

    // 2. The self project root, on disk (Python did `mkdir(parents=True)`).
    const self_root = try harness.harnessPath(gpa, h.temp_dir, &.{SELF_DIR_NAME});
    defer gpa.free(self_root);
    try std.Io.Dir.cwd().createDirPath(io, self_root);

    // Python's `UPDATE sessions SET cwd = str(root / "self")`: the session's
    // cwd is a SUBDIRECTORY of the agent item's path, not the path itself.
    const session_cwd = try std.fs.path.join(gpa, &.{ self_root, "self" });
    defer gpa.free(session_cwd);

    // 3. The self agent item — the row the anchor resolves to.
    const agent_path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/agent", .{ws_id});
    defer gpa.free(agent_path);
    {
        const body = try std.json.Stringify.valueAlloc(gpa, AgentBody{
            .name = "Self project",
            .path = self_root,
        }, .{});
        defer gpa.free(body);
        var r = try h.http(io, .POST, agent_path, .{ .json_body = body, .expect = &.{201} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const item = doc.object("item") orelse {
            std.debug.print("agent item create returned no `item`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        const self_item_id = blk: {
            const id_value = item.get("id") orelse {
                std.debug.print("agent item has no id: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            };
            break :blk switch (id_value) {
                .string => |sv| sv,
                else => {
                    std.debug.print("agent item id is not a string: {s}\n", .{r.body});
                    return error.TestUnexpectedResult;
                },
            };
        };

        // 4. The 25 siblings: real directories plus one workspace_items row
        //    each. Owned by `siblings` so the assertion loop below can read
        //    them after every response has been deinit'd.
        var siblings: std.ArrayList([]u8) = .empty;
        defer {
            for (siblings.items) |p| gpa.free(p);
            siblings.deinit(gpa);
        }

        const items_path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items", .{ws_id});
        defer gpa.free(items_path);

        for (0..SIBLING_COUNT) |index| {
            const seg = try std.fmt.allocPrint(gpa, "sibling-{d}", .{index});
            defer gpa.free(seg);

            const path = try harness.harnessPath(gpa, h.temp_dir, &.{ SELF_DIR_NAME, seg });
            try std.Io.Dir.cwd().createDirPath(io, path);
            try siblings.append(gpa, path); // ownership moves into the list

            const name = try std.fmt.allocPrint(gpa, "Sibling {d}", .{index});
            defer gpa.free(name);

            const item_body = try std.json.Stringify.valueAlloc(gpa, ItemBody{
                .name = name,
                .path = path,
                .item_type = "chat",
            }, .{});
            defer gpa.free(item_body);

            // `defer` inside a loop body runs at the end of EACH
            // iteration, so 25 responses are all released and none pile up.
            var item_r = try h.http(io, .POST, items_path, .{ .json_body = item_body, .expect = &.{201} });
            defer item_r.deinit();
        }

        // 5. The anchor row.
        const task_path = try std.fmt.allocPrint(
            gpa,
            "/api/workspaces/{s}/items/{s}/tasks",
            .{ ws_id, self_item_id },
        );
        defer gpa.free(task_path);
        const create_task_body = try std.json.Stringify.valueAlloc(gpa, TaskBody{
            .name = "Cross-project test",
        }, .{});
        defer gpa.free(create_task_body);
        var task_r = try h.http(io, .POST, task_path, .{ .json_body = create_task_body, .expect = &.{201} });
        defer task_r.deinit();
        var task_doc = try task_r.json();
        defer task_doc.deinit();
        const session_id = task_doc.str("id") orelse {
            std.debug.print("task create returned no id: {s}\n", .{task_r.body});
            return error.TestUnexpectedResult;
        };

        // 6. The session row: cwd (so /test/system-prompt does not 404) and
        //    one history message (the Python seeded an `llm_history` row).
        const sess_body = try std.json.Stringify.valueAlloc(gpa, SessionBody{
            .session_id = session_id,
            .session_name = "Cross-project cwd prompt test",
            .queue_message = "seed",
            .cwd_session = session_cwd,
        }, .{});
        defer gpa.free(sess_body);
        var sess_r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = sess_body,
            .expect = &.{201},
        });
        defer sess_r.deinit();

        try waitForSystemPrompt(&h, session_id);

        // 7. The wire response under test.
        const sp_path = try std.fmt.allocPrint(gpa, "/test/system-prompt/{s}", .{session_id});
        defer gpa.free(sp_path);
        var sp = try h.http(io, .GET, sp_path, .{ .expect = &.{200} });
        defer sp.deinit();
        var sp_doc = try sp.json();
        defer sp_doc.deinit();
        const system_prompt = sp_doc.str("system_prompt") orelse {
            std.debug.print("system-prompt response has no system_prompt: {s}\n", .{sp.body});
            return error.TestUnexpectedResult;
        };

        if (std.mem.indexOf(u8, system_prompt, "## Cross-Project Context") == null) {
            std.debug.print("prompt is missing the `## Cross-Project Context` block\n", .{});
            return error.TestUnexpectedResult;
        }
        const sibling_section = harness.afterFirst(system_prompt, "Sibling project directories:") orelse {
            std.debug.print("prompt is missing the `Sibling project directories:` heading\n", .{});
            return error.TestUnexpectedResult;
        };

        for (siblings.items) |path| {
            // The backticks are load-bearing: `<self_root>` is a PREFIX of
            // every `<self_root>/sibling-N`, so without them the final
            // "self must not appear" assertion could never hold.
            const needle = try std.fmt.allocPrint(gpa, "`{s}`", .{path});
            defer gpa.free(needle);
            if (std.mem.indexOf(u8, sibling_section, needle) == null) {
                std.debug.print(
                    "missing sibling cwd: {s} (only {d} of {d} rendered)\n",
                    .{ path, countRendered(sibling_section, siblings.items), siblings.items.len },
                );
                return error.TestUnexpectedResult;
            }
        }

        const self_needle = try std.fmt.allocPrint(gpa, "`{s}`", .{self_root});
        defer gpa.free(self_needle);
        if (std.mem.indexOf(u8, sibling_section, self_needle) != null) {
            std.debug.print(
                "the session's OWN item path {s} leaked into the sibling list\n",
                .{self_root},
            );
            return error.TestUnexpectedResult;
        }
    }
}

/// How many of `paths` are rendered in the sibling section. Only used to make
/// a failure message say WHICH rows were dropped — a cap regression takes the
/// tail, and "missing sibling cwd: X" alone does not tell you it took 21..25.
fn countRendered(sibling_section: []const u8, paths: []const []u8) usize {
    var n: usize = 0;
    for (paths) |path| {
        var buf: [std.fs.max_path_bytes + 2]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "`{s}`", .{path}) catch continue;
        if (std.mem.indexOf(u8, sibling_section, needle) != null) n += 1;
    }
    return n;
}
