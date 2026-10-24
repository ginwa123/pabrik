//! `pabrik-admin` — the admin console as a program of its own. It serves
//! `/admin` and `/api/admin/*` straight from a pabrik database, so the
//! console runs without booting the whole server.

const std = @import("std");
const database = @import("databases").database;
const gserverz = @import("kabelweb").server;

const admin_api = @import("admin_api.zig");
const admin_machines = @import("admin_machines.zig");
const admin_page = @import("admin_page.zig");
const admin_store = @import("admin_store.zig");
const runtime = @import("runtime.zig");

const default_port: u16 = 8090;

const Options = struct {
    db_path: ?[]const u8 = null,
    port: u16 = default_port,
    auth_enabled: bool = false,
    /// Where `pabrik-vmd` listens. Absent means "no machines section": this
    /// program links no manager of its own.
    vmd_socket: ?[]const u8 = null,
};

fn printUsage() void {
    std.debug.print(
        \\Usage: pabrik-admin [options]
        \\
        \\  --db <path>     the pabrik database to administer
        \\                  (default: ~/.config/pabrik/agent.db)
        \\  --port <n>      the port to listen on (default: {d})
        \\  --auth on|off   off: the local operator owns the installation
        \\                  on:  a pabrik_session cookie decides the owner
        \\  -h, --help      this text
        \\
        \\Then open http://127.0.0.1:<port>/admin
        \\
    , .{default_port});
}

fn parseOptions(allocator: std.mem.Allocator, args: std.process.Args) !?Options {
    var out: Options = .{};
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    _ = it.next(); // argv[0]

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return null;
        if (std.mem.eql(u8, arg, "--db")) {
            out.db_path = it.next() orelse return error.DbValueMissing;
            continue;
        }
        if (std.mem.eql(u8, arg, "--port")) {
            const raw = it.next() orelse return error.PortValueMissing;
            out.port = std.fmt.parseInt(u16, raw, 10) catch return error.InvalidPort;
            continue;
        }
        if (std.mem.eql(u8, arg, "--vmd-socket")) {
            out.vmd_socket = it.next() orelse return error.VmdSocketValueMissing;
            continue;
        }
        if (std.mem.eql(u8, arg, "--auth")) {
            const raw = it.next() orelse return error.AuthValueMissing;
            if (std.mem.eql(u8, raw, "on")) {
                out.auth_enabled = true;
            } else if (std.mem.eql(u8, raw, "off")) {
                out.auth_enabled = false;
            } else {
                return error.InvalidAuthValue;
            }
            continue;
        }
        return error.UnknownArgument;
    }
    return out;
}

/// `$HOME/.config/pabrik/agent.db`, the file pabrik itself opens.
fn defaultDbPath(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) ![]const u8 {
    const home = environ.get("HOME") orelse environ.get("USERPROFILE") orelse return error.NoHome;
    if (!std.fs.path.isAbsolute(home)) return error.HomeNotAbsolute;

    var home_dir = try std.Io.Dir.openDirAbsolute(io, home, .{});
    defer home_dir.close(io);
    try home_dir.createDirPath(io, ".config/pabrik");

    return std.fs.path.join(allocator, &.{ home, ".config", "pabrik", "agent.db" });
}

/// The manager socket an operator did not name: `$PABRIK_VMD_SOCKET` if it is
/// set, else the runtime dir's `pabrik-vmd.sock` when that file exists. A
/// socket that is not there is "no machines", not a reason to refuse to start.
fn defaultVmdSocket(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) ?[]const u8 {
    if (environ.get("PABRIK_VMD_SOCKET")) |given| {
        if (given.len > 0) return given;
    }
    const runtime_dir = environ.get("XDG_RUNTIME_DIR") orelse return null;
    const path = std.fmt.allocPrint(allocator, "{s}/pabrik-vmd.sock", .{runtime_dir}) catch return null;
    var dir = std.Io.Dir.openDirAbsolute(io, runtime_dir, .{}) catch {
        allocator.free(path);
        return null;
    };
    defer dir.close(io);
    _ = dir.statFile(io, "pabrik-vmd.sock", .{}) catch {
        allocator.free(path);
        return null;
    };
    return path;
}

fn usersTableExists(allocator: std.mem.Allocator, db: *database.Db) bool {
    var q = db.query(allocator,
        \\SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'users'
    , &.{}) catch return false;
    defer q.deinit();
    const row = q.next() catch return false;
    if (row) |r| {
        r.deinit(allocator);
        return true;
    }
    return false;
}

fn registerRoutes(router: *gserverz.router.Router) !void {
    // The page loads without a session: it has to ask who is asking. The
    // endpoints answer 401/403 themselves, so no middleware is needed.
    try router.get("/admin", admin_page.adminPageHandler);
    try router.get("/admin/", admin_page.adminPageHandler);
    try router.get("/admin/admin.css", admin_page.adminCssHandler);
    try router.get("/admin/admin.js", admin_page.adminJsHandler);

    try router.get("/api/admin/overview", admin_api.adminOverviewHandler);
    try router.get("/api/admin/users", admin_api.adminUsersListHandler);
    try router.post("/api/admin/users", admin_api.adminUserCreateHandler);
    try router.patch("/api/admin/users/:id", admin_api.adminUserUpdateHandler);
    try router.post("/api/admin/users/:id/password", admin_api.adminUserPasswordHandler);

    // The machines section. Without a socket the handlers say so and the page
    // offers no control, which is the honest answer for a console that was
    // never told where the manager lives.
    try router.get("/api/admin/vms", admin_machines.listHandler);
    try router.post("/api/admin/vms/:workspace/resize", admin_machines.resizeHandler);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const options = (parseOptions(allocator, init.minimal.args) catch |err| {
        std.log.err("pabrik-admin: {s}", .{@errorName(err)});
        printUsage();
        return err;
    }) orelse {
        printUsage();
        return;
    };

    const db_path = if (options.db_path) |given|
        try allocator.dupe(u8, given)
    else
        try defaultDbPath(allocator, io, init.environ_map);
    defer allocator.free(db_path);

    var db: database.Db = .{};
    defer db.deinit();
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    database.open(&db, io, .{ .sqlite_path = db_path_z }) catch |err| {
        std.log.err("pabrik-admin: cannot open {s}: {s}", .{ db_path, @errorName(err) });
        return err;
    };
    if (!usersTableExists(allocator, &db)) {
        try admin_store.ensureSchema(allocator, &db);
        std.log.info("pabrik-admin: created the `users` and `auth_sessions` tables in {s}", .{db_path});
    }

    runtime.install(&db, options.auth_enabled);
    defer runtime.uninstall();

    const vmd_socket = options.vmd_socket orelse defaultVmdSocket(allocator, io, init.environ_map);
    admin_machines.installSocket(vmd_socket);

    const address = try gserverz.Address.init("127.0.0.1", options.port);
    var gs = try gserverz.GinwaServer.init(allocator, io, address);
    defer gs.deinit();
    try registerRoutes(&gs.router);

    std.debug.print(
        "pabrik-admin ready\n  console: http://127.0.0.1:{d}/admin\n  database: {s}\n  owner: {s}\n  machines: {s}\n",
        .{
            options.port,
            db_path,
            if (options.auth_enabled) "the signed-in admin account" else "the local operator (no --auth)",
            if (vmd_socket) |path| path else "no manager socket (accounts only)",
        },
    );
    try gs.listenEventLoop(.{});
}
