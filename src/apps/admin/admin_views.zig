//! The console's view layer: read what the page shows, hand it to the templates
//! as a context, and get HTML back.
//!
//! The page is rendered on the server, so it arrives with its rows and counts
//! already in it. The browser fetches no data of its own: one request, and the
//! document it returns is the document the operator reads.

const std = @import("std");
const database = @import("databases").database;
const kabelweb = @import("kabelweb");
const vmd = @import("vmd_manager");

const Template = kabelweb.Template;

const admin_machines = @import("admin_machines.zig");
const admin_store = @import("admin_store.zig");

/// The page's entry template, and the parts it includes. All of them are
/// embedded, so the binary needs no template directory at run time.
pub const entry = @embedFile("page/index.html");

pub const Part = struct {
    name: []const u8,
    body: []const u8,
};

pub const parts = [_]Part{
    .{ .name = "shell.html", .body = @embedFile("page/shell.html") },
    .{ .name = "accounts.html", .body = @embedFile("page/accounts.html") },
    .{ .name = "machines.html", .body = @embedFile("page/machines.html") },
    .{ .name = "dialogs.html", .body = @embedFile("page/dialogs.html") },
    .{ .name = "foot.html", .body = @embedFile("page/foot.html") },
};

/// The `{% include %}` loader: a part ships inside the binary, so a name is a
/// lookup, not a file read.
fn loadPart(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
    for (parts) |candidate| {
        if (std.mem.eql(u8, path, candidate.name)) return allocator.dupe(u8, candidate.body);
    }
    return error.TemplateNotFound;
}

/// One part by name, for the tests that render a section on its own.
pub fn part(name: []const u8) []const u8 {
    for (parts) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) return candidate.body;
    }
    return "";
}

/// A section of the console. Each one is a path of its own, and each one is a
/// view: the server reads what that view shows.
pub const Section = enum {
    accounts,
    machines,
};

/// What a visitor who is not the owner is told, instead of the data.
pub const signed_out_notice =
    "This console belongs to the installation's owner. Sign in as the owner to see the accounts and the machines.";

/// Render the page for one section. `owner` false renders the frame and the
/// explanation, and no data at all — the same rule the JSON endpoints enforce.
pub fn renderPage(
    allocator: std.mem.Allocator,
    db: *database.Db,
    section: Section,
    owner: bool,
) ![]u8 {
    // Everything the context points at lives in this arena, which is why the
    // maps and the rendered rows can be handed straight to the templates.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Nothing is read for a visitor who is not the owner: not the accounts, not
    // the machines, not even the counts, which say how big the installation is.
    const nobody = admin_store.Overview{};
    const counts = if (owner) (admin_store.overview(arena, db) catch nobody) else nobody;
    const users: []admin_store.UserRow = if (owner)
        (admin_store.listUsers(arena, db) catch &[_]admin_store.UserRow{})
    else
        &[_]admin_store.UserRow{};
    const machines: admin_machines.Snapshot = if (owner)
        (admin_machines.snapshot(arena, db) catch admin_machines.Snapshot{
            .manager = false,
            .reason = "the machines could not be read from the manager",
        })
    else
        .{};

    var ctx = Template.Context.init(arena);
    try ctx.put("owner", .{ .bool = owner });
    try ctx.put("accounts_shown", .{ .bool = owner and section == .accounts });
    try ctx.put("machines_shown", .{ .bool = owner and section == .machines });
    try ctx.put("page_notice", .{ .string = if (owner) "" else signed_out_notice });

    try ctx.put("count_total", .{ .int = counts.total_users });
    try ctx.put("count_active", .{ .int = counts.active_users });
    try ctx.put("count_owners", .{ .int = counts.admin_users });
    try ctx.put("count_bots", .{ .int = counts.bot_users });
    try ctx.put("count_sessions", .{ .int = counts.active_sessions });

    try ctx.put("users", .{ .array = try userValues(arena, if (owner) users else &.{}) });
    try ctx.put("machines", .{ .array = try machineValues(arena, if (owner) machines.machines else &.{}) });
    try ctx.put("manager", .{ .bool = owner and machines.manager });
    try ctx.put("note", .{ .string = if (owner) machines.reason else "" });
    try ctx.put("searchable", .{ .bool = owner and machines.manager and machines.machines.len > 0 });

    // The numbers the resize dialog refuses a size against, rendered as the
    // page's own JSON so the script needs no request to learn them.
    try ctx.put("min_vcpus", .{ .int = vmd.limits.min_vcpus });
    try ctx.put("max_vcpus", .{ .int = vmd.limits.max_vcpus });
    try ctx.put("min_mem_mib", .{ .int = vmd.limits.min_mem_mib });
    try ctx.put("max_mem_mib", .{ .int = vmd.limits.max_mem_mib });
    try ctx.put("mem_step_mib", .{ .int = vmd.limits.mem_step_mib });
    try ctx.put("min_disk_mib", .{ .int = vmd.limits.min_disk_mib });
    try ctx.put("max_disk_mib", .{ .int = vmd.limits.max_disk_mib });

    const nodes = try Template.parseSource(arena, entry);
    defer Template.freeNodes(arena, nodes);

    // The output belongs to the caller, so it outlives the arena.
    return Template.render(allocator, nodes, &ctx, .{ .loader_fn = &loadPart });
}

/// One `Value` per account, each a map the template reads by name.
fn userValues(arena: std.mem.Allocator, users: []const admin_store.UserRow) ![]Template.Value {
    const out = try arena.alloc(Template.Value, users.len);
    for (users, 0..) |user, i| {
        var map = std.StringHashMap(Template.Value).init(arena);
        try map.put("id", .{ .string = user.id });
        try map.put("email", .{ .string = user.email });
        try map.put("name", .{ .string = user.name });
        try map.put("role", .{ .string = user.role });
        try map.put("active", .{ .bool = user.is_active });
        out[i] = .{ .map = map };
    }
    return out;
}

/// One `Value` per machine. The formatted sizes are done here rather than in the
/// template, because a template that does arithmetic on MiB reads badly.
fn machineValues(arena: std.mem.Allocator, machines: []const admin_machines.Machine) ![]Template.Value {
    const out = try arena.alloc(Template.Value, machines.len);
    for (machines, 0..) |machine, i| {
        var map = std.StringHashMap(Template.Value).init(arena);
        try map.put("id", .{ .string = machine.workspace_id });
        try map.put("name", .{ .string = machine.workspace_name });
        try map.put("state", .{ .string = machine.state });
        try map.put("last_error", .{ .string = machine.last_error });
        try map.put("vcpus", .{ .int = machine.vcpus });
        try map.put("mem_mib", .{ .int = machine.mem_mib });
        try map.put("disk_mib", .{ .int = machine.disk_mib });
        try map.put("memory", .{ .string = try mibLabel(arena, machine.mem_mib) });
        try map.put("storage", .{ .string = try mibLabel(arena, machine.disk_mib) });
        out[i] = .{ .map = map };
    }
    return out;
}

/// A size in the unit that reads best: MiB below a gibibyte, GiB above it.
fn mibLabel(allocator: std.mem.Allocator, mib: u32) ![]const u8 {
    if (mib == 0) return "not started";
    if (mib >= 1024) {
        const gib = @as(f64, @floatFromInt(mib)) / 1024.0;
        const whole = @floor(gib);
        if (gib == whole) {
            return std.fmt.allocPrint(allocator, "{d} GiB", .{@as(u64, @intFromFloat(whole))});
        }
        return std.fmt.allocPrint(allocator, "{d:.1} GiB", .{gib});
    }
    return std.fmt.allocPrint(allocator, "{d} MiB", .{mib});
}

// =====================================================================
// Tests — the whole view, against an in-memory database.
// =====================================================================

const testing = std.testing;
const admin_common = @import("admin_common.zig");

fn seedDatabase(allocator: std.mem.Allocator, db: *database.Db) !void {
    try admin_store.ensureSchema(allocator, db);
    try db.exec(allocator,
        \\INSERT OR IGNORE INTO users (id, email, name, password_hash, role, is_active)
        \\VALUES ('user_system', 'system@local', 'System', '!disabled', 'admin', 0)
    , &.{});
}

fn addUser(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    email: []const u8,
    name: []const u8,
    role: []const u8,
    active: bool,
) !void {
    // `COALESCE(?, '')` because an empty slice binds as NULL, and `name` is
    // NOT NULL: without it, an account with no name cannot be inserted at all.
    try db.exec(allocator,
        \\INSERT INTO users (id, email, name, password_hash, role, is_active, created_at)
        \\VALUES (?, ?, COALESCE(?, ''), 'x', ?, ?, datetime('now'))
    , &[_][]const u8{ id, email, name, role, if (active) "1" else "0" });
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "the accounts page arrives with its rows, counts and no second section" {
    const alloc = testing.allocator;
    var db: database.Db = .{};
    defer db.deinit();
    try db.init(testing.io, ":memory:");
    try seedDatabase(alloc, &db);
    try addUser(alloc, &db, "user_a", "alice@example.com", "Alice", "admin", true);
    try addUser(alloc, &db, "user_b", "bob@example.com", "", "user", false);

    const html = try renderPage(alloc, &db, .accounts, true);
    defer alloc.free(html);

    // The rows are in the document itself.
    try testing.expect(contains(html, "alice@example.com"));
    try testing.expect(contains(html, "bob@example.com"));
    // An account with no name says so, rather than showing an empty cell.
    try testing.expect(contains(html, "No name"));
    // The disabled account wears the off state.
    try testing.expect(contains(html, "status-on status-off"));
    // The counts came from the same read.
    try testing.expect(contains(html, "id=\"count-total\">2<"));
    try testing.expect(contains(html, "id=\"count-owners\">1<"));
    try testing.expect(contains(html, "id=\"count-active\">1<"));
    // The rail marks the section the path named, and only that section is in
    // the document.
    try testing.expect(contains(html, "href=\"/admin/accounts\" data-section=\"accounts\" aria-current=\"page\""));
    try testing.expect(contains(html, "id=\"section-accounts\""));
    try testing.expect(!contains(html, "id=\"section-machines\""));
    // The shell is intact around it.
    try testing.expect(std.mem.startsWith(u8, html, "<!doctype html>\n"));
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, html, "\n"), "</html>"));
}

test "the machines page explains a manager it cannot reach, and offers nothing" {
    const alloc = testing.allocator;
    var db: database.Db = .{};
    defer db.deinit();
    try db.init(testing.io, ":memory:");
    try seedDatabase(alloc, &db);

    const html = try renderPage(alloc, &db, .machines, true);
    defer alloc.free(html);

    try testing.expect(contains(html, "id=\"section-machines\""));
    try testing.expect(!contains(html, "id=\"section-accounts\""));
    // No socket is installed in a test, so the section says which one it tried
    // and draws no Resize button.
    try testing.expect(contains(html, "no manager socket was given"));
    try testing.expect(!contains(html, "data-action=\"resize\""));
    // The limits still travel with the page, as its own JSON.
    try testing.expect(contains(html, "id=\"resize-limits\""));
    try testing.expect(contains(html, "\"max_vcpus\": 8"));
}

test "a name with markup in it is escaped, not injected" {
    const alloc = testing.allocator;
    var db: database.Db = .{};
    defer db.deinit();
    try db.init(testing.io, ":memory:");
    try seedDatabase(alloc, &db);
    try addUser(alloc, &db, "user_x", "x@example.com", "<script>alert(1)</script>", "user", true);

    const html = try renderPage(alloc, &db, .accounts, true);
    defer alloc.free(html);

    try testing.expect(contains(html, "&lt;script&gt;alert(1)&lt;/script&gt;"));
    try testing.expect(!contains(html, "<script>alert(1)</script>"));
}

test "a visitor who is not the owner gets the frame and the reason, and no data" {
    const alloc = testing.allocator;
    var db: database.Db = .{};
    defer db.deinit();
    try db.init(testing.io, ":memory:");
    try seedDatabase(alloc, &db);
    try addUser(alloc, &db, "user_a", "alice@example.com", "Alice", "admin", true);

    for ([_]Section{ .accounts, .machines }) |section| {
        const html = try renderPage(alloc, &db, section, false);
        defer alloc.free(html);

        // The notice names the rule; its apostrophe arrives escaped, which is
        // also the proof that the templates escape what they are given.
        try testing.expect(contains(html, "This console belongs to the installation"));
        try testing.expect(contains(html, "installation&#x27;s owner"));
        try testing.expect(!contains(html, "alice@example.com"));
        try testing.expect(!contains(html, "id=\"section-accounts\""));
        try testing.expect(!contains(html, "id=\"section-machines\""));
        try testing.expect(contains(html, "id=\"count-total\">0<"));
    }
}

test "the sizes read in the unit that suits them" {
    const alloc = testing.allocator;
    const mib = try mibLabel(alloc, 512);
    defer alloc.free(mib);
    try testing.expectEqualStrings("512 MiB", mib);

    const gig = try mibLabel(alloc, 65536);
    defer alloc.free(gig);
    try testing.expectEqualStrings("64 GiB", gig);

    const half = try mibLabel(alloc, 1536);
    defer alloc.free(half);
    try testing.expectEqualStrings("1.5 GiB", half);

    try testing.expectEqualStrings("not started", try mibLabel(alloc, 0));
}

test "every template part parses, and the entry includes all of them" {
    const alloc = testing.allocator;
    for (parts) |entry_part| {
        const nodes = Template.parseSource(alloc, entry_part.body) catch |err| {
            std.debug.print("part {s} did not parse: {s}\n", .{ entry_part.name, @errorName(err) });
            return err;
        };
        Template.freeNodes(alloc, nodes);
        try testing.expect(contains(entry, entry_part.name));
    }
    const nodes = try Template.parseSource(alloc, entry);
    Template.freeNodes(alloc, nodes);
}

test "a machine row carries every number its Resize button needs" {
    // A test host has no manager, so the machines section is rendered here with
    // one fabricated machine. That is the only way to pin the row's markup, and
    // the dialog is driven entirely by it: lose an attribute and Resize opens on
    // the wrong size, or none.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx = Template.Context.init(arena);
    try ctx.put("machines_shown", .{ .bool = true });
    try ctx.put("manager", .{ .bool = true });
    try ctx.put("searchable", .{ .bool = true });
    try ctx.put("note", .{ .string = "" });
    try ctx.put("machines", .{ .array = try machineValues(arena, &.{.{
        .workspace_id = "ws_1",
        .workspace_name = "kabelweb",
        .state = "ready",
        .vcpus = 2,
        .mem_mib = 1024,
        .disk_mib = 8192,
    }}) });
    try ctx.put("min_vcpus", .{ .int = 1 });
    try ctx.put("max_vcpus", .{ .int = 8 });
    try ctx.put("min_mem_mib", .{ .int = 128 });
    try ctx.put("max_mem_mib", .{ .int = 16384 });
    try ctx.put("mem_step_mib", .{ .int = 128 });
    try ctx.put("min_disk_mib", .{ .int = 128 });
    try ctx.put("max_disk_mib", .{ .int = 65536 });

    const nodes = try Template.parseSource(arena, part("machines.html"));
    const html = try Template.render(testing.allocator, nodes, &ctx, .{ .loader_fn = &loadPart });
    defer testing.allocator.free(html);

    // The row carries the size the dialog opens on.
    try testing.expect(contains(html, "data-action=\"resize\""));
    try testing.expect(contains(html, "data-workspace=\"ws_1\""));
    try testing.expect(contains(html, "data-vcpus=\"2\""));
    try testing.expect(contains(html, "data-mem-mib=\"1024\""));
    try testing.expect(contains(html, "data-disk-mib=\"8192\""));
    // The same sizes, as a reader says them.
    try testing.expect(contains(html, ">1 GiB<"));
    try testing.expect(contains(html, ">8 GiB<"));
    try testing.expect(contains(html, ">ready<"));
    // A list worth searching offers the box, and the limits travel with it.
    try testing.expect(contains(html, "id=\"machines-search\""));
    try testing.expect(contains(html, "\"mem_step_mib\": 128"));
}

test "an account the console cannot explain is still a link to its own row" {
    // The buttons carry the id the script needs; a template change that drops
    // it would leave every row's controls pointing at nothing.
    const alloc = testing.allocator;
    var db: database.Db = .{};
    defer db.deinit();
    try db.init(testing.io, ":memory:");
    try seedDatabase(alloc, &db);
    try addUser(alloc, &db, "user_a", "alice@example.com", "Alice", "admin", true);

    const html = try renderPage(alloc, &db, .accounts, true);
    defer alloc.free(html);

    try testing.expect(contains(html, "data-action=\"role\" data-user-id=\"user_a\""));
    try testing.expect(contains(html, "data-action=\"toggle-active\" data-user-id=\"user_a\""));
    try testing.expect(contains(html, "data-action=\"reset-password\" data-user-id=\"user_a\""));
    try testing.expect(contains(html, "<option value=\"admin\" selected>Owner</option>"));
}
