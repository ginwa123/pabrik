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
const db_target = @import("db_target.zig");
const runtime = @import("runtime.zig");

const default_port: u16 = 8090;

const Options = struct {
    db_path: ?[]const u8 = null,
    /// `--database` (or `$PABRIK_DATABASE`): null means "the compiled backend".
    backend: ?[]const u8 = null,
    /// `--database-conninfo` (or `$PABRIK_DATABASE_CONNINFO`): postgres only.
    conninfo: ?[]const u8 = null,
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
        \\  --db <path>     the SQLite database to administer
        \\                  (default: ~/.config/pabrik/agent.db)
        \\  --database=sqlite|postgres
        \\                  the backend to open (default: the one this build
        \\                  compiled in, {s})
        \\  --database-conninfo=CONNINFO
        \\                  libpq conninfo or postgres:// URL, postgres only
        \\                  (default: $PABRIK_DATABASE_CONNINFO)
        \\  --port <n>      the port to listen on (default: {d})
        \\  --auth on|off   off: the local operator owns the installation
        \\                  on:  a pabrik_session cookie decides the owner
        \\  -h, --help      this text
        \\
        \\Then open http://127.0.0.1:<port>/admin
        \\
    , .{ db_target.Backend.compiled().text(), default_port });
}

/// `--name=value`, or `--name value` when this program already spells its other
/// flags that way. Null when `arg` is some other flag; `missing` when the flag
/// is there but carries nothing.
fn optionValue(
    it: *std.process.Args.Iterator,
    arg: []const u8,
    name: []const u8,
    missing: anyerror,
) !?[]const u8 {
    const value: ?[]const u8 = if (std.mem.eql(u8, arg, name))
        it.next() orelse return missing
    else if (arg.len > name.len and std.mem.startsWith(u8, arg, name) and arg[name.len] == '=')
        arg[name.len + 1 ..]
    else
        return null;
    if (value.?.len == 0) return missing;
    return value;
}

fn parseOptions(allocator: std.mem.Allocator, args: std.process.Args) !?Options {
    var out: Options = .{};
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    _ = it.next(); // argv[0]

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return null;
        // The postgres family first: `--database-conninfo` also starts with
        // `--database`, and `optionValue` only accepts it as its own flag.
        if (try optionValue(&it, arg, "--database-conninfo", error.ConninfoValueMissing)) |value| {
            out.conninfo = value;
            continue;
        }
        if (try optionValue(&it, arg, "--database", error.DatabaseValueMissing)) |value| {
            out.backend = value;
            continue;
        }
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

/// The manager socket an operator did not name, in the same order the server
/// resolves it: `$PABRIK_VMD_SOCKET`, then the runtime dir, then `/tmp`. A
/// socket nobody answers on is not a failure — the machines section says so.
fn defaultVmdSocket(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ?[]const u8 {
    if (environ.get("PABRIK_VMD_SOCKET")) |given| {
        if (given.len > 0) return given;
    }
    if (environ.get("XDG_RUNTIME_DIR")) |dir| {
        if (dir.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/pabrik-vmd.sock", .{dir}) catch null;
        }
    }
    return "/tmp/pabrik-vmd.sock";
}

fn registerRoutes(router: *gserverz.router.Router) !void {
    // The page loads without a session — it has to ask who is asking — and each
    // section is a path that renders its own view. The endpoints answer 401/403
    // themselves, so no middleware is needed.
    try router.get("/admin", admin_page.adminPageHandler);
    try router.get("/admin/", admin_page.adminPageHandler);
    try router.get("/admin/accounts", admin_page.adminAccountsHandler);
    try router.get("/admin/accounts/", admin_page.adminAccountsHandler);
    try router.get("/admin/machines", admin_page.adminMachinesHandler);
    try router.get("/admin/machines/", admin_page.adminMachinesHandler);
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

    // Which backend to open, and where it lives. The flag wins over the
    // environment, and no choice at all means the backend the build compiled in.
    const backend = db_target.resolve(options.backend orelse init.environ_map.get(db_target.env_backend)) catch |err| {
        std.log.err(
            "pabrik-admin: {s}: this binary opens the {s} backend (rebuild with -Ddb_used={s} for postgres)",
            .{ @errorName(err), db_target.Backend.compiled().text(), db_target.buildList(.postgres) },
        );
        printUsage();
        return err;
    };

    // Only one of the two is owned (and only the matching one is non-null):
    // sqlite needs the file path as a sentinel string, postgres the conninfo.
    var sqlite_path: ?[:0]u8 = null;
    defer if (sqlite_path) |path| allocator.free(path);
    var conninfo: ?[:0]u8 = null;
    defer if (conninfo) |value| allocator.free(value);

    // What the console says it is connected to, in words, never a password.
    // The sqlite path is owned here: the banner and any error print it long
    // after the branch that chose it.
    var place: []const u8 = "libpq defaults";
    var sqlite_plain: ?[]const u8 = null;
    defer if (sqlite_plain) |plain| allocator.free(plain);
    switch (backend) {
        .sqlite => {
            sqlite_plain = if (options.db_path) |given|
                try allocator.dupe(u8, given)
            else
                try defaultDbPath(allocator, io, init.environ_map);
            sqlite_path = try allocator.dupeZ(u8, sqlite_plain.?);
            place = sqlite_plain.?;
        },
        .postgres => {
            const given = options.conninfo orelse init.environ_map.get(db_target.env_conninfo) orelse "";
            conninfo = try allocator.dupeZ(u8, given);
            if (given.len != 0) place = "the conninfo given";
        },
    }

    var db: database.Db = .{};
    defer db.deinit();
    const open_config: database.OpenConfig = if (backend == .sqlite)
        .{ .sqlite_path = sqlite_path.? }
    else
        .{ .postgres_conninfo = conninfo.? };
    database.open(&db, io, open_config) catch |err| {
        std.log.err("pabrik-admin: cannot open the {s} database ({s}): {s}", .{
            backend.text(), place, @errorName(err),
        });
        return err;
    };
    if (!try admin_store.tableExists(allocator, &db, "users")) {
        try admin_store.ensureSchema(allocator, &db);
        std.log.info("pabrik-admin: created the `users` and `auth_sessions` tables in {s}", .{place});
    }

    runtime.install(&db, options.auth_enabled);
    defer runtime.uninstall();

    const vmd_socket = options.vmd_socket orelse defaultVmdSocket(allocator, init.environ_map);
    admin_machines.installSocket(vmd_socket);

    const address = try gserverz.Address.init("127.0.0.1", options.port);
    var gs = try gserverz.GinwaServer.init(allocator, io, address);
    defer gs.deinit();
    try registerRoutes(&gs.router);

    std.debug.print(
        "pabrik-admin ready\n  console: http://127.0.0.1:{d}/admin\n  database: {s} ({s})\n  owner: {s}\n  machines: {s}\n",
        .{
            options.port,
            backend.text(),
            place,
            if (options.auth_enabled) "the signed-in admin account" else "the local operator (no --auth)",
            if (vmd_socket) |path| path else "no manager socket (accounts only)",
        },
    );
    try gs.listenEventLoop(.{});
}
